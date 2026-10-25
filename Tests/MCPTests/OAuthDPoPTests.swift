@preconcurrency import Foundation
import Crypto
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// DPoP (RFC 9449, SEP-1932): proofs, token requests, the authorizer and the
// transport.

private let endpoint = URL(string: "https://mcp.example.com/mcp")!
private let tokenEndpoint = URL(string: "https://auth.example.com/token")!
private let headers401 = [
    "WWW-Authenticate":
        "DPoP resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
]

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// A decoded compact JWS.
private struct DecodedProof {
    let header: [String: Any]
    let claims: [String: Any]
    let signingInput: String
    let signature: Data

    struct Malformed: Error {}

    init(_ compact: String) throws {
        let parts = compact.split(separator: ".").map(String.init)
        guard parts.count == 3,
            let headerData = Self.decode(parts[0]), let claimsData = Self.decode(parts[1]),
            let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
            let signature = Self.decode(parts[2])
        else { throw Malformed() }
        self.header = header
        self.claims = claims
        self.signingInput = "\(parts[0]).\(parts[1])"
        self.signature = signature
    }

    var jwk: [String: String] { header["jwk"] as? [String: String] ?? [:] }

    /// Verifies the signature with the key in the `jwk` header.
    func verifies() throws -> Bool {
        guard let x = Self.decode(jwk["x"] ?? ""), let y = Self.decode(jwk["y"] ?? "") else {
            throw Malformed()
        }
        let key = try P256.Signing.PublicKey(rawRepresentation: x + y)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        return key.isValidSignature(signature, for: Data(signingInput.utf8))
    }

    static func decode(_ base64URL: String) -> Data? {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private func accessTokenHash(_ token: String) -> String {
    Data(SHA256.hash(data: Data(token.utf8))).base64URLEncodedString()
}

private func dpopAuthorizer(
    dpop: OAuthConfiguration.DPoP? = .init(),
    tokenStorage: TokenStorage = InMemoryTokenStorage(),
    discovery: MockDiscoveryClient = MockDiscoveryClient(),
    tokenClient: MockTokenClient = MockTokenClient()
) -> OAuthAuthorizer {
    OAuthAuthorizer(
        configuration: .init(authentication: .none(clientID: "client"), dpop: dpop),
        tokenStorage: tokenStorage, urlValidator: MockURLValidator(), discoveryClient: discovery,
        tokenEndpointClient: tokenClient, clientRegistrar: MockClientRegistrar(),
        authCodeFlow: MockAuthCodeFlow())
}

/// Runs `body` and returns the `OAuthAuthorizationError` it throws.
private func authorizationError(_ body: () async throws -> Void) async -> OAuthAuthorizationError? {
    do {
        try await body()
    } catch let error as OAuthAuthorizationError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
    Issue.record("No error thrown")
    return nil
}

private func dpopTokenClient(_ token: String = "dpop-token") -> MockTokenClient {
    let client = MockTokenClient()
    client.tokenResponse = OAuthTokenResponse(
        accessToken: token, tokenType: "DPoP", expiresIn: 3600, scope: nil, refreshToken: nil)
    return client
}

@Suite("DPoP proofs")
struct DPoPProofTests {
    let signer = DPoPProofSigner(configuration: .init())

    @Test("A proof is an ES256 dpop+jwt signed by the key in its jwk header")
    func structure() throws {
        let proof = try DecodedProof(
            signer.proof(
                method: "post", url: URL(string: "HTTPS://MCP.example.com/mcp?tenant=a#frag")!,
                accessToken: "token-1", server: .resourceServer))
        #expect(proof.header["typ"] as? String == "dpop+jwt")
        #expect(proof.header["alg"] as? String == "ES256")
        #expect(proof.jwk["kty"] == "EC")
        #expect(proof.jwk["crv"] == "P-256")
        #expect(proof.jwk["d"] == nil)
        #expect(try proof.verifies())

        #expect(proof.claims["htm"] as? String == "POST")
        #expect(proof.claims["htu"] as? String == "https://mcp.example.com/mcp")
        #expect(proof.claims["ath"] as? String == accessTokenHash("token-1"))
        #expect(proof.claims["nonce"] == nil)
        let issuedAt = try #require(proof.claims["iat"] as? Int)
        #expect(abs(Double(issuedAt) - Date().timeIntervalSince1970) < 5)
        #expect((proof.claims["jti"] as? String)?.isEmpty == false)
    }

    @Test("Every proof has a new jti; a token request proof has no ath")
    func freshProofs() throws {
        let first = try DecodedProof(
            signer.proof(method: "POST", url: tokenEndpoint, accessToken: nil, server: .authorizationServer))
        let second = try DecodedProof(
            signer.proof(method: "POST", url: tokenEndpoint, accessToken: nil, server: .authorizationServer))
        #expect(first.claims["jti"] as? String != second.claims["jti"] as? String)
        #expect(first.claims["ath"] == nil)
    }

    @Test("Nonces apply per origin and per server kind")
    func nonces() throws {
        signer.recordNonce(
            from: ["dpop-nonce": "n-rs"], for: URL(string: "https://mcp.example.com/other")!,
            server: .resourceServer)
        func nonce(_ url: URL, _ server: DPoPProofSigner.ServerKind) throws -> String? {
            try DecodedProof(signer.proof(method: "GET", url: url, accessToken: nil, server: server))
                .claims["nonce"] as? String
        }
        #expect(try nonce(endpoint, .resourceServer) == "n-rs")
        #expect(try nonce(endpoint, .authorizationServer) == nil)
        #expect(try nonce(URL(string: "https://mcp.example.com:8443/mcp")!, .resourceServer) == nil)
    }

    @Test("htu drops user information")
    func targetDropsUserInfo() throws {
        let proof = try DecodedProof(
            signer.proof(
                method: "POST", url: URL(string: "https://user:secret@mcp.example.com/mcp?a=1")!,
                accessToken: nil, server: .resourceServer))
        #expect(proof.claims["htu"] as? String == "https://mcp.example.com/mcp")
    }

    /// Signs with a key it holds, as a hardware-backed key would.
    private struct ExternalKey: DPoPSigningKey {
        let wrapped = P256.Signing.PrivateKey()
        let signatures = Counter()
        var publicKey: P256.Signing.PublicKey { wrapped.publicKey }
        func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
            signatures.increment()
            return try wrapped.signature(for: data)
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test("A DPoPSigningKey signs proofs and names the thumbprint")
    func externalKey() throws {
        let key = ExternalKey()
        let configuration = OAuthConfiguration.DPoP(key: key)
        let signer = DPoPProofSigner(configuration: configuration)
        let proof = try DecodedProof(
            signer.proof(method: "POST", url: endpoint, accessToken: nil, server: .resourceServer))
        #expect(try proof.verifies())
        #expect(key.signatures.value == 1)
        #expect(proof.jwk == DPoPProofSigner.jwk(of: key.wrapped.publicKey))
        #expect(configuration.keyThumbprint == DPoPProofSigner.thumbprint(of: key.wrapped.publicKey))
        #expect(signer.thumbprint == configuration.keyThumbprint)
    }

    @Test("The thumbprint is the RFC 7638 hash of the canonical JWK")
    func thumbprint() throws {
        let configuration = OAuthConfiguration.DPoP()
        let jwk = DPoPProofSigner.jwk(of: configuration.key.publicKey)
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(jwk["x"]!)","y":"\#(jwk["y"]!)"}"#
        let expected = Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString()
        #expect(configuration.keyThumbprint == expected)
        #expect(DPoPProofSigner(configuration: configuration).thumbprint == expected)
        #expect(expected.count == 43)
    }

    @Test("The DPoP challenge parses alongside Bearer")
    func challenge() {
        let parser = DefaultOAuthWWWAuthenticateParser()
        let headers = [
            "www-authenticate":
                #"Bearer realm="mcp", DPoP error="use_dpop_nonce", error_description="Resource server requires nonce in DPoP proof""#
        ]
        let dpop = parser.parseChallenge(scheme: "dpop", from: headers)
        #expect(dpop?.error == "use_dpop_nonce")
        #expect(dpop?.errorDescription == "Resource server requires nonce in DPoP proof")
        #expect(parser.parseBearer(from: headers)?.parameters == ["realm": "mcp"])
        #expect(parser.parseChallenge(scheme: "Basic", from: headers) == nil)
    }
}

@Suite("DPoP authorizer")
struct DPoPAuthorizerTests {
    @Test("A DPoP token is presented with the DPoP scheme and a proof for the request")
    func presentsBoundToken() async throws {
        let tokenClient = dpopTokenClient()
        let authorizer = dpopAuthorizer(tokenClient: tokenClient)
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared))
        #expect(tokenClient.capturedDPoP != nil)

        let headers = try authorizer.authorizationHeaders(for: endpoint, method: "GET")
        #expect(headers[HTTPHeaderName.authorization] == "DPoP dpop-token")
        let proof = try DecodedProof(try #require(headers[HTTPHeaderName.dpop]))
        #expect(proof.claims["htm"] as? String == "GET")
        #expect(proof.claims["htu"] as? String == endpoint.absoluteString)
        #expect(proof.claims["ath"] as? String == accessTokenHash("dpop-token"))
    }

    @Test("The stored token records the key thumbprint")
    func storesThumbprint() async throws {
        let dpop = OAuthConfiguration.DPoP()
        let storage = InMemoryTokenStorage()
        let authorizer = dpopAuthorizer(dpop: dpop, tokenStorage: storage, tokenClient: dpopTokenClient())
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        let token = try #require(storage.load())
        #expect(token.isDPoPBound)
        #expect(token.keyThumbprint == dpop.keyThumbprint)
    }

    @Test("A Bearer answer is a downgrade: Bearer scheme, no proof")
    func bearerDowngrade() async throws {
        let authorizer = dpopAuthorizer(tokenClient: MockTokenClient())
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        let headers = try authorizer.authorizationHeaders(for: endpoint, method: "POST")
        #expect(headers == [HTTPHeaderName.authorization: "Bearer mock-access-token"])
    }

    @Test("A stored token bound to another key is discarded")
    func otherKey() throws {
        let storage = InMemoryTokenStorage()
        storage.save(OAuthAccessToken(
            value: "old", tokenType: "DPoP", expiresAt: nil, scopes: [], authorizationServer: nil,
            refreshToken: nil, keyThumbprint: "another-key"))
        let authorizer = dpopAuthorizer(tokenStorage: storage)
        #expect(try authorizer.authorizationHeaders(for: endpoint, method: "POST").isEmpty)
        #expect(storage.load() == nil)
    }

    @Test("Without DPoP configured, a DPoP-bound stored token is discarded")
    func boundTokenWithoutDPoP() throws {
        let storage = InMemoryTokenStorage()
        storage.save(OAuthAccessToken(
            value: "old", tokenType: "DPoP", expiresAt: nil, scopes: [], authorizationServer: nil,
            refreshToken: nil, keyThumbprint: "k"))
        let authorizer = dpopAuthorizer(dpop: nil, tokenStorage: storage)
        #expect(try authorizer.authorizationHeaders(for: endpoint, method: "POST").isEmpty)
    }

    @Test("use_dpop_nonce from the resource keeps the token and retries with the nonce")
    func resourceNonce() async throws {
        let tokenClient = dpopTokenClient()
        let authorizer = dpopAuthorizer(tokenClient: tokenClient)
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        #expect(tokenClient.requestCallCount == 1)

        let challenge = [
            "WWW-Authenticate": #"DPoP error="use_dpop_nonce", error_description="nonce required""#,
            "DPoP-Nonce": "rs-nonce-1",
        ]
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: challenge, endpoint: endpoint, session: .shared))
        #expect(tokenClient.requestCallCount == 1)

        let headers = try authorizer.authorizationHeaders(for: endpoint, method: "POST")
        #expect(headers[HTTPHeaderName.authorization] == "DPoP dpop-token")
        let proof = try DecodedProof(try #require(headers[HTTPHeaderName.dpop]))
        #expect(proof.claims["nonce"] as? String == "rs-nonce-1")
    }

    @Test("A nonce in any response is kept for the origin the request was sent to")
    func responseNonce() async throws {
        let authorizer = dpopAuthorizer(tokenClient: dpopTokenClient())
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        let other = URL(string: "https://edge.example.com/mcp")!
        authorizer.didReceiveResponse(headers: ["dpop-nonce": "edge-nonce"], for: other)

        func nonce(_ url: URL) throws -> String? {
            let headers = try authorizer.authorizationHeaders(for: url, method: "POST")
            return try DecodedProof(try #require(headers[HTTPHeaderName.dpop])).claims["nonce"] as? String
        }
        #expect(try nonce(other) == "edge-nonce")
        #expect(try nonce(endpoint) == nil)
    }

    @Test("token_type is trimmed once: a padded DPoP answer is stored as DPoP-bound")
    func paddedTokenType() async throws {
        let decoded = try JSONDecoder().decode(
            OAuthTokenResponse.self,
            from: Data(#"{"access_token":"t","token_type":" DPoP\n"}"#.utf8))
        #expect(decoded.tokenType == "DPoP")

        let tokenClient = MockTokenClient()
        tokenClient.tokenResponse = decoded
        let dpop = OAuthConfiguration.DPoP()
        let storage = InMemoryTokenStorage()
        let authorizer = dpopAuthorizer(dpop: dpop, tokenStorage: storage, tokenClient: tokenClient)
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        let token = try #require(storage.load())
        #expect(token.isDPoPBound)
        #expect(token.keyThumbprint == dpop.keyThumbprint)
    }

    @Test("use_dpop_nonce without a token acquires one")
    func resourceNonceWithoutToken() async throws {
        let tokenClient = dpopTokenClient()
        let authorizer = dpopAuthorizer(tokenClient: tokenClient)
        let challenge = [
            "WWW-Authenticate": #"DPoP error="use_dpop_nonce""#, "DPoP-Nonce": "rs-nonce-1",
        ]
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: challenge, endpoint: endpoint, session: .shared))
        #expect(tokenClient.requestCallCount == 1)
        let proof = try DecodedProof(
            try #require(try authorizer.authorizationHeaders(for: endpoint, method: "POST")[HTTPHeaderName.dpop]))
        #expect(proof.claims["nonce"] as? String == "rs-nonce-1")
    }

    @Test("A resource that requires DPoP fails without it")
    func resourceRequiresDPoP() async {
        let discovery = MockDiscoveryClient()
        discovery.protectedResourceMetadataResult.dpopBoundAccessTokensRequired = true
        let tokenClient = MockTokenClient()
        let authorizer = dpopAuthorizer(dpop: nil, discovery: discovery, tokenClient: tokenClient)
        let error = await authorizationError {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
        guard case .dpopRequired = error else {
            Issue.record("Expected dpopRequired, got \(String(describing: error))")
            return
        }
        #expect(tokenClient.requestCallCount == 0)
    }

    @Test("An authorization server without ES256 proofs fails")
    func algorithmUnsupported() async {
        let discovery = MockDiscoveryClient()
        discovery.authorizationServerMetadataResult.metadata.dpopSigningAlgValuesSupported = ["RS256"]
        let authorizer = dpopAuthorizer(discovery: discovery)
        let error = await authorizationError {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
        guard case .dpopAlgorithmUnsupported(let supported) = error else {
            Issue.record("Expected dpopAlgorithmUnsupported, got \(String(describing: error))")
            return
        }
        #expect(supported == ["RS256"])
    }
}

#if swift(>=6.1) && !os(Linux)

    private func json(_ url: URL, _ status: Int, _ object: [String: Any], headers: [String: String] = [:])
        throws -> (HTTPURLResponse, Data)
    {
        var fields = headers
        fields["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        return (response, try JSONSerialization.data(withJSONObject: object))
    }

    @Suite("DPoP token requests", .serialized)
    struct DPoPTokenRequestTests {
        let client = OAuthTokenEndpointClient(urlValidator: OAuthURLValidator())
        let signer = DPoPProofSigner(configuration: .init())

        @Test("The token request carries a proof for POST to the token endpoint")
        func proof() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return try json(request.url!, 200, ["access_token": "t", "token_type": "DPoP"])
            }
            var parameters = ["grant_type": "client_credentials"]
            let response = try await client.request(
                parameters: &parameters, endpoint: tokenEndpoint, authentication: .none(clientID: "c"),
                dpop: signer, session: session)
            #expect(response.tokenType == "DPoP")

            let sent = try #require(await requests.values.first)
            let proof = try DecodedProof(try #require(sent.value(forHTTPHeaderField: "DPoP")))
            #expect(proof.claims["htm"] as? String == "POST")
            #expect(proof.claims["htu"] as? String == tokenEndpoint.absoluteString)
            #expect(proof.claims["ath"] == nil)
            #expect(try proof.verifies())
        }

        @Test("use_dpop_nonce is retried once with the server's nonce")
        func nonceRetry() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                if await requests.values.count == 1 {
                    return try json(
                        request.url!, 400, ["error": "use_dpop_nonce"], headers: ["DPoP-Nonce": "as-nonce"])
                }
                return try json(request.url!, 200, ["access_token": "t", "token_type": "DPoP"])
            }
            var parameters = ["grant_type": "client_credentials"]
            _ = try await client.request(
                parameters: &parameters, endpoint: tokenEndpoint, authentication: .none(clientID: "c"),
                dpop: signer, session: session)

            let sent = await requests.values
            #expect(sent.count == 2)
            let retry = try DecodedProof(try #require(sent[1].value(forHTTPHeaderField: "DPoP")))
            #expect(retry.claims["nonce"] as? String == "as-nonce")
        }

        @Test("A second use_dpop_nonce fails the request")
        func singleRetry() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return try json(
                    request.url!, 400, ["error": "use_dpop_nonce"],
                    headers: ["DPoP-Nonce": "n-\(await requests.values.count)"])
            }
            var parameters = ["grant_type": "client_credentials"]
            let error = await authorizationError {
                _ = try await client.request(
                    parameters: &parameters, endpoint: tokenEndpoint, authentication: .none(clientID: "c"),
                    dpop: signer, session: session)
            }
            guard case .tokenRequestFailed(400, "use_dpop_nonce") = error else {
                Issue.record("Expected tokenRequestFailed, got \(String(describing: error))")
                return
            }
            #expect(await requests.values.count == 2)
        }

        @Test("A DPoP token answering a request without a proof is invalid")
        func unexpectedDPoP() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                try json(request.url!, 200, ["access_token": "t", "token_type": "DPoP"])
            }
            var parameters = ["grant_type": "client_credentials"]
            let error = await authorizationError {
                _ = try await client.request(
                    parameters: &parameters, endpoint: tokenEndpoint, authentication: .none(clientID: "c"),
                    session: session)
            }
            guard case .tokenResponseInvalid = error else {
                Issue.record("Expected tokenResponseInvalid, got \(String(describing: error))")
                return
            }
        }
    }

    /// Returns fixed headers and records the requests they were made for.
    private final class RecordingAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(url: URL, method: String)] = []
        var requests: [(url: URL, method: String)] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }
        let maxAuthorizationAttempts = 1
        func validateEndpointSecurity(for endpoint: URL) throws {}
        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            lock.lock()
            _requests.append((url, method))
            lock.unlock()
            return ["Authorization": "DPoP t", "DPoP": "proof-for-\(method)"]
        }
        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool { false }
    }

    /// Accepts every challenge, as an authorizer that has a token and a nonce does.
    private final class NonceAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        let maxAuthorizationAttempts: Int
        private let lock = NSLock()
        private var challengeCount = 0
        private var responseURLs: [URL] = []
        var challenges: Int { lock.withLock { challengeCount } }
        var responses: [URL] { lock.withLock { responseURLs } }

        init(maxAuthorizationAttempts: Int = 5) {
            self.maxAuthorizationAttempts = maxAuthorizationAttempts
        }

        func validateEndpointSecurity(for endpoint: URL) throws {}
        func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
            ["Authorization": "DPoP t", "DPoP": "proof"]
        }
        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            lock.withLock { challengeCount += 1 }
            return true
        }
        func didReceiveResponse(headers: [String: String], for url: URL) {
            lock.withLock { responseURLs.append(url) }
        }
    }

    private func mockSession(
        _ respond: @escaping @Sendable (URLRequest, Int) async -> HTTPURLResponse
    ) async -> (URLSessionConfiguration, Recorder<URLRequest>) {
        let key = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IsolatedMockURLProtocol.self]
        configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
        let sent = Recorder<URLRequest>()
        await IsolatedMockURLProtocol.setHandler(key: key) { request in
            await sent.append(request)
            return (await respond(request, await sent.values.count), Data())
        }
        return (configuration, sent)
    }

    @Suite("DPoP transport", .serialized)
    struct DPoPTransportTests {
        @Test("A resource server's use_dpop_nonce is retried once per request")
        func resourceNonceRetriedOnce() async throws {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            let sent = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await sent.append(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "WWW-Authenticate": #"DPoP error="use_dpop_nonce""#,
                        "DPoP-Nonce": "rs-\(await sent.values.count)",
                    ])!
                return (response, Data())
            }
            let authorizer = NonceAuthorizer()
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false,
                authorizer: authorizer)
            try await transport.connect()
            await #expect(throws: (any Error).self) {
                try await transport.send(
                    Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
            }
            #expect(await sent.values.count == 2)
            // The second nonce challenge fails the request without the authorizer.
            #expect(authorizer.challenges == 1)
            #expect(authorizer.responses.count == 2)
            await transport.disconnect()
        }

        @Test("A nonce retry does not use up an authorization attempt")
        func nonceRetryIsFree() async throws {
            let (configuration, sent) = await mockSession { request, count in
                let headers: [String: String] =
                    switch count {
                    case 1: ["WWW-Authenticate": #"DPoP error="use_dpop_nonce""#, "DPoP-Nonce": "n"]
                    case 2: ["WWW-Authenticate": #"DPoP error="invalid_token""#]
                    default: [:]
                    }
                return HTTPURLResponse(
                    url: request.url!, statusCode: count <= 2 ? 401 : 202, httpVersion: "HTTP/1.1",
                    headerFields: headers)!
            }
            let authorizer = NonceAuthorizer(maxAuthorizationAttempts: 2)
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false,
                authorizer: authorizer)
            try await transport.connect()
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            #expect(await sent.values.count == 3)
            #expect(authorizer.challenges == 2)
            await transport.disconnect()
        }

        @Test("Authorization headers are set after requestModifier, for the final URL and method")
        func afterRequestModifier() async throws {
            let key = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedMockURLProtocol.self]
            configuration.httpAdditionalHeaders = [IsolatedMockURLProtocol.sessionKeyHeader: key]
            let sent = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await sent.append(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }
            let authorizer = RecordingAuthorizer()
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false,
                authorizer: authorizer,
                requestModifier: { request in
                    var request = request
                    request.url = URL(string: "https://mcp.example.com/mcp?tenant=a")!
                    request.setValue("Bearer from-modifier", forHTTPHeaderField: "Authorization")
                    return request
                })
            try await transport.connect()
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            await transport.disconnect()

            #expect(authorizer.requests.first?.url.absoluteString == "https://mcp.example.com/mcp?tenant=a")
            #expect(authorizer.requests.first?.method == "POST")
            let request = try #require(await sent.values.first)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP t")
            #expect(request.value(forHTTPHeaderField: "DPoP") == "proof-for-POST")
        }
    }

#endif
