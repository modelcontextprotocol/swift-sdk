@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// The jwt-bearer grant (RFC 7523), the RFC 8693 token exchange, and
// enterprise-managed authorization (SEP-990) built from both.

private let endpoint = URL(string: "https://mcp.example.com/mcp")!
private let headers401 = [
    "WWW-Authenticate":
        "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
]

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

private func body(_ request: URLRequest) -> [String: String] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
    }
    var fields: [String: String] = [:]
    for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        fields[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return fields
}

private func json(_ url: URL, _ status: Int, _ object: [String: Any], headers: [String: String] = [:])
    throws -> (HTTPURLResponse, Data)
{
    var fields = headers
    fields["Content-Type"] = "application/json"
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    return (response, try JSONSerialization.data(withJSONObject: object))
}

private func jwtBearerAuthorizer(
    _ configuration: OAuthConfiguration,
    discovery: MockDiscoveryClient = MockDiscoveryClient(),
    tokenClient: MockTokenClient = MockTokenClient(),
    registrar: MockClientRegistrar = MockClientRegistrar()
) -> OAuthAuthorizer {
    OAuthAuthorizer(
        configuration: configuration, urlValidator: MockURLValidator(), discoveryClient: discovery,
        tokenEndpointClient: tokenClient, clientRegistrar: registrar, authCodeFlow: MockAuthCodeFlow())
}

@Suite("OAuth jwt-bearer grant")
struct OAuthJWTBearerGrantTests {
    @Test("The token request presents the assertion with the resource and scopes")
    func tokenRequest() async throws {
        let contexts = Recorder<OAuthConfiguration.AssertionContext>()
        let tokenClient = MockTokenClient()
        let registrar = MockClientRegistrar()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                assertionProvider: { context, _ in
                    await contexts.append(context)
                    return "workload-jwt"
                }, allowsDiscoveredAuthorizationServer: true),
            tokenClient: tokenClient, registrar: registrar)
        let headers = [
            "WWW-Authenticate":
                "Bearer scope=\"read write\", resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
        ]
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: headers, endpoint: endpoint, session: .shared))

        let parameters = try #require(tokenClient.capturedParameters)
        #expect(parameters["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(parameters["assertion"] == "workload-jwt")
        #expect(parameters["resource"] == "https://mcp.example.com/mcp")
        #expect(parameters["scope"] == "read write")
        #expect(parameters["client_assertion"] == nil)
        #expect(registrar.registerCallCount == 0)

        let context = try #require(await contexts.values.first)
        #expect(context.audience == URL(string: "https://auth.example.com")!)
        #expect(context.resource == endpoint)
        #expect(context.tokenEndpoint == URL(string: "https://auth.example.com/token")!)
        #expect(context.requestedScopes == ["read", "write"])
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer mock-access-token")
    }

    @Test("Every token request gets a new assertion")
    func freshAssertion() async throws {
        let calls = Recorder<Int>()
        let tokenClient = MockTokenClient()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                assertionProvider: { _, _ in
                    await calls.append(1)
                    return "jwt-\(await calls.values.count)"
                }, allowsDiscoveredAuthorizationServer: true),
            tokenClient: tokenClient)
        for _ in 0..<2 {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
        #expect(await calls.values.count == 2)
        #expect(tokenClient.capturedParameters?["assertion"] == "jwt-2")
    }

    @Test("Without an assertion provider the grant fails")
    func missingProvider() async {
        let authorizer = jwtBearerAuthorizer(.init(grantType: .jwtBearer, authentication: .none(clientID: "")))
        await #expect(throws: OAuthAuthorizationError.self) {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
    }

    @Test("An error from the assertion provider fails the attempt without a token request")
    func providerError() async {
        struct Unavailable: Error {}
        let tokenClient = MockTokenClient()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                assertionProvider: { _, _ in throw Unavailable() }, allowsDiscoveredAuthorizationServer: true),
            tokenClient: tokenClient)
        await #expect(throws: Unavailable.self) {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        }
        #expect(tokenClient.requestCallCount == 0)
    }

    @Test("A pinned authorization server is used whatever the resource metadata says")
    func pinnedServer() async throws {
        let discovery = MockDiscoveryClient(
            authorizationServer: URL(string: "https://pinned.example.com")!,
            tokenEndpoint: URL(string: "https://pinned.example.com/token")!)
        discovery.protectedResourceMetadataResult = .init(
            resource: nil, authorizationServers: [URL(string: "https://other.example.com")!],
            scopesSupported: nil)
        let audiences = Recorder<URL>()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                endpointOverrides: .init(authorizationServerURL: URL(string: "https://pinned.example.com")!),
                assertionProvider: { context, _ in
                    await audiences.append(context.audience)
                    return "jwt"
                }),
            discovery: discovery)
        _ = try await authorizer.handleChallenge(
            statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        #expect(await audiences.values == [URL(string: "https://pinned.example.com")!])
    }

    #if swift(>=6.1) && !os(Linux)
        @Test("A rejected grant is reported once, with no retry and no other grant")
        func noRetry() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<[String: String]>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let url = request.url!
                switch url.path {
                case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
                    return try json(url, 200, [
                        "resource": "https://mcp.example.com/mcp",
                        "authorization_servers": ["https://auth.example.com"],
                    ])
                case "/.well-known/oauth-authorization-server":
                    return try json(url, 200, [
                        "issuer": "https://auth.example.com",
                        "token_endpoint": "https://auth.example.com/token",
                        "registration_endpoint": "https://auth.example.com/register",
                        "grant_types_supported": ["urn:ietf:params:oauth:grant-type:jwt-bearer"],
                    ])
                case "/token":
                    await requests.append(body(request))
                    return try json(url, 400, ["error": "invalid_grant"])
                default:
                    return try json(url, 404, [:])
                }
            }
            let authorizer = OAuthAuthorizer(
                configuration: .init(
                    grantType: .jwtBearer, authentication: .none(clientID: ""),
                    assertionProvider: { _, _ in "expired-jwt" }, allowsDiscoveredAuthorizationServer: true))
            do {
                _ = try await authorizer.handleChallenge(
                    statusCode: 401, headers: headers401, endpoint: endpoint, session: session)
                Issue.record("The grant should fail")
            } catch OAuthAuthorizationError.tokenRequestFailed(let status, let error) {
                #expect(status == 400)
                #expect(error == "invalid_grant")
            }
            let sent = await requests.values
            #expect(sent.count == 1)
            #expect(sent.first?["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
            #expect(sent.first?["client_id"] == nil)
        }
    #endif
}

#if swift(>=6.1) && !os(Linux)

    @Suite("OAuth token exchange (RFC 8693)", .serialized)
    struct OAuthTokenExchangeTests {
        let idpToken = URL(string: "https://idp.example.com/token")!
        let request = OAuthTokenExchange.Request(
            subjectToken: "id-token",
            subjectTokenType: OAuthTokenExchange.TokenType.idToken,
            requestedTokenType: OAuthTokenExchange.TokenType.idJAG,
            audience: "https://auth.example.com",
            resource: URL(string: "https://mcp.example.com/mcp")!,
            scopes: ["write", "read"])

        @Test("The request carries the RFC 8693 parameters; N_A is accepted")
        func exchange() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<URLRequest>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await requests.append(request)
                return try json(request.url!, 200, [
                    "access_token": "id-jag",
                    "issued_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                    "token_type": "N_A",
                    "expires_in": 300,
                ])
            }
            let response = try await OAuthTokenExchange.exchange(
                request, tokenEndpoint: idpToken,
                authentication: .clientSecretPost(clientID: "idp-client", clientSecret: "s"),
                session: session)
            #expect(response.accessToken == "id-jag")
            #expect(response.tokenType == "N_A")
            #expect(response.expiresIn == 300)

            let sent = try #require(await requests.values.first)
            #expect(sent.httpMethod == "POST")
            let fields = body(sent)
            #expect(fields == [
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": "id-token",
                "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                "audience": "https://auth.example.com",
                "resource": "https://mcp.example.com/mcp",
                "scope": "read write",
                "client_id": "idp-client",
                "client_secret": "s",
            ])
        }

        @Test("Another issued token type is rejected")
        func wrongIssuedType() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                try json(request.url!, 200, [
                    "access_token": "token",
                    "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                    "token_type": "Bearer",
                ])
            }
            do {
                _ = try await OAuthTokenExchange.exchange(
                    request, tokenEndpoint: idpToken, authentication: .none(clientID: "c"), session: session)
                Issue.record("The exchange should fail")
            } catch OAuthAuthorizationError.issuedTokenTypeMismatch(let expected, let actual) {
                #expect(expected == OAuthTokenExchange.TokenType.idJAG)
                #expect(actual == OAuthTokenExchange.TokenType.accessToken)
            }
        }

        @Test("An error response surfaces its status and OAuth error")
        func errorResponse() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                try json(request.url!, 400, ["error": "invalid_target"])
            }
            do {
                _ = try await OAuthTokenExchange.exchange(
                    request, tokenEndpoint: idpToken, authentication: .none(clientID: "c"), session: session)
                Issue.record("The exchange should fail")
            } catch OAuthAuthorizationError.tokenRequestFailed(let status, let error) {
                #expect(status == 400)
                #expect(error == "invalid_target")
            }
        }

        @Test("Insecure and private endpoints are refused before any request")
        func endpointChecks() async throws {
            let (session, key) = makeIsolatedSession()
            let calls = Recorder<Int>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await calls.append(1)
                return try json(request.url!, 500, [:])
            }
            for url in ["http://idp.example.com/token", "https://10.0.0.1/token", "http://localhost:9000/token"] {
                await #expect(throws: OAuthAuthorizationError.self) {
                    _ = try await OAuthTokenExchange.exchange(
                        request, tokenEndpoint: URL(string: url)!, authentication: .none(clientID: "c"),
                        session: session)
                }
            }
            #expect(await calls.values.isEmpty)
        }

        @Test("The token endpoint is discovered from the issuer's metadata")
        func discovery() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let url = request.url!
                if url.path == "/.well-known/openid-configuration" {
                    return try json(url, 200, [
                        "issuer": "https://idp.example.com",
                        "token_endpoint": "https://idp.example.com/oauth/token",
                    ])
                }
                return try json(url, 404, [:])
            }
            let tokenEndpoint = try await OAuthTokenExchange.tokenEndpoint(
                issuer: URL(string: "https://idp.example.com")!, session: session)
            #expect(tokenEndpoint == URL(string: "https://idp.example.com/oauth/token")!)
        }
    }

    @Suite("Enterprise-managed authorization (SEP-990)", .serialized)
    struct EnterpriseManagedAuthorizationTests {
        /// An IdP, an authorization server and the MCP server's metadata.
        private func installServers(
            key: String, requests: Recorder<(String, URLRequest)>, assertionAudiences: Recorder<String>
        ) async {
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let url = request.url!
                await requests.append((url.host! + url.path, request))
                switch (url.host!, url.path) {
                case ("mcp.example.com", _):
                    return try json(url, 200, [
                        "resource": "https://mcp.example.com/mcp",
                        "authorization_servers": ["https://auth.example.com"],
                    ])
                case ("auth.example.com", "/.well-known/oauth-authorization-server"):
                    return try json(url, 200, [
                        "issuer": "https://auth.example.com",
                        "token_endpoint": "https://auth.example.com/token",
                        "registration_endpoint": "https://auth.example.com/register",
                    ])
                case ("idp.example.com", "/token"):
                    let fields = body(request)
                    await assertionAudiences.append(fields["audience"] ?? "")
                    return try json(url, 200, [
                        "access_token": "id-jag-for-\(fields["subject_token"] ?? "")",
                        "issued_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                        "token_type": "N_A",
                    ])
                case ("auth.example.com", "/token"):
                    return try json(url, 200, ["access_token": "mcp-token", "token_type": "Bearer", "expires_in": 3600])
                default:
                    return try json(url, 404, [:])
                }
            }
        }

        private func configuration(pinned: URL?) -> OAuthConfiguration {
            .enterpriseManaged(
                authentication: .clientSecretBasic(clientID: "mcp-client", clientSecret: "mcp-secret"),
                authorizationServer: pinned,
                identityProvider: .init(
                    endpoint: .tokenEndpoint(URL(string: "https://idp.example.com/token")!),
                    authentication: .none(clientID: "idp-client")),
                idToken: { _ in "user-id-token" },
                allowsDiscoveredAuthorizationServer: pinned == nil)
        }

        @Test("The ID token becomes an ID-JAG, and the ID-JAG an access token")
        func twoLegs() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<(String, URLRequest)>()
            let audiences = Recorder<String>()
            await installServers(key: key, requests: requests, assertionAudiences: audiences)

            let authorizer = OAuthAuthorizer(
                configuration: configuration(pinned: URL(string: "https://auth.example.com")!))
            #expect(try await authorizer.handleChallenge(
                statusCode: 401, headers: headers401, endpoint: endpoint, session: session))
            #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer mcp-token")

            let sent = await requests.values
            let paths = sent.map(\.0)
            #expect(!paths.contains("auth.example.com/register"))
            let exchange = try #require(sent.first { $0.0 == "idp.example.com/token" }?.1)
            let exchangeFields = body(exchange)
            #expect(exchangeFields["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
            #expect(exchangeFields["subject_token"] == "user-id-token")
            #expect(exchangeFields["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag")
            #expect(exchangeFields["resource"] == "https://mcp.example.com/mcp")
            #expect(exchangeFields["client_id"] == "idp-client")
            #expect(await audiences.values == ["https://auth.example.com"])

            let grant = try #require(sent.first { $0.0 == "auth.example.com/token" }?.1)
            let grantFields = body(grant)
            #expect(grantFields["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
            #expect(grantFields["assertion"] == "id-jag-for-user-id-token")
            #expect(grantFields["client_secret"] == nil)
            let basic = Data("mcp-client:mcp-secret".utf8).base64EncodedString()
            #expect(grant.value(forHTTPHeaderField: "Authorization") == "Basic \(basic)")
            // The exchange goes to the IdP before the grant goes to the authorization server.
            #expect(paths.firstIndex(of: "idp.example.com/token")! < paths.firstIndex(of: "auth.example.com/token")!)
        }

        @Test("A failed exchange fails the attempt; no grant is sent")
        func exchangeFails() async throws {
            let (session, key) = makeIsolatedSession()
            let requests = Recorder<String>()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let url = request.url!
                await requests.append(url.host! + url.path)
                switch (url.host!, url.path) {
                case ("mcp.example.com", _):
                    return try json(url, 200, ["authorization_servers": ["https://auth.example.com"]])
                case ("auth.example.com", "/.well-known/oauth-authorization-server"):
                    return try json(url, 200, [
                        "issuer": "https://auth.example.com", "token_endpoint": "https://auth.example.com/token",
                    ])
                case ("idp.example.com", "/token"):
                    return try json(url, 400, ["error": "invalid_grant"])
                default:
                    return try json(url, 404, [:])
                }
            }
            let authorizer = OAuthAuthorizer(configuration: configuration(pinned: nil))
            await #expect(throws: OAuthAuthorizationError.self) {
                _ = try await authorizer.handleChallenge(
                    statusCode: 401, headers: headers401, endpoint: endpoint, session: session)
            }
            #expect(!(await requests.values).contains("auth.example.com/token"))
        }

        @Test("The pinned authorization server must publish metadata with its own issuer")
        func pinnedIssuerMismatch() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let url = request.url!
                switch (url.host!, url.path) {
                case ("mcp.example.com", _):
                    return try json(url, 200, ["authorization_servers": ["https://evil.example.com"]])
                case ("auth.example.com", "/.well-known/oauth-authorization-server"):
                    return try json(url, 200, [
                        "issuer": "https://evil.example.com", "token_endpoint": "https://evil.example.com/token",
                    ])
                default:
                    return try json(url, 404, [:])
                }
            }
            let authorizer = OAuthAuthorizer(
                configuration: configuration(pinned: URL(string: "https://auth.example.com")!))
            await #expect(throws: OAuthAuthorizationError.self) {
                _ = try await authorizer.handleChallenge(
                    statusCode: 401, headers: headers401, endpoint: endpoint, session: session)
            }
        }
    }

#endif

/// A JWT with the given `aud`, unsigned: only the payload is read.
private func jwt(audience: Any) -> String {
    func part(_ object: [String: Any]) -> String {
        (try! JSONSerialization.data(withJSONObject: object)).base64URLEncodedString()
    }
    return "\(part(["alg": "none"])).\(part(["aud": audience, "sub": "workload"])).sig"
}

@Suite("OAuth jwt-bearer destination")
struct OAuthJWTBearerDestinationTests {
    @Test("Without a configured server or the opt-in, no assertion is made or sent")
    func unpinnedRefused() async throws {
        let calls = Recorder<Int>()
        let tokenClient = MockTokenClient()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                assertionProvider: { _, _ in
                    await calls.append(1)
                    return "jwt"
                }),
            tokenClient: tokenClient)
        await #expect {
            _ = try await authorizer.handleChallenge(statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
        } throws: { error in
            guard case .authorizationServerNotConfigured = error as? OAuthAuthorizationError else { return false }
            return true
        }
        #expect(await calls.values.isEmpty)
        #expect(tokenClient.requestCallCount == 0)
    }

    @Test("A discovered server gets only an assertion for its issuer or token endpoint")
    func audienceChecked() async throws {
        for (audience, accepted) in [
            (jwt(audience: "https://auth.example.com"), true),
            (jwt(audience: ["https://auth.example.com/token", "x"]), true),
            (jwt(audience: "https://real-as.example.com"), false),
        ] {
            let tokenClient = MockTokenClient()
            let authorizer = jwtBearerAuthorizer(
                .init(
                    grantType: .jwtBearer, authentication: .none(clientID: ""),
                    assertionProvider: { _, _ in audience }, allowsDiscoveredAuthorizationServer: true),
                tokenClient: tokenClient)
            do {
                _ = try await authorizer.handleChallenge(
                    statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared)
                #expect(accepted, "\(audience)")
            } catch OAuthAuthorizationError.assertionAudienceMismatch {
                #expect(!accepted, "\(audience)")
            }
            #expect(tokenClient.requestCallCount == (accepted ? 1 : 0))
        }
    }

    @Test("A configured server gets the assertion whatever its audience")
    func pinnedUnchecked() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                endpointOverrides: .init(authorizationServerURL: URL(string: "https://auth.example.com")!),
                assertionProvider: { _, _ in jwt(audience: "sts.example.com") }),
            tokenClient: tokenClient)
        #expect(try await authorizer.handleChallenge(statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared))
        #expect(tokenClient.requestCallCount == 1)
    }

    // IsolatedMockURLProtocol needs the session headers, which Linux does not pass to it.
    #if !os(Linux)
    @Test("The jwt-bearer grant never uses the 2025-03-26 default endpoints")
    func noDefaultEndpoints() async throws {
        let (session, key) = makeIsolatedSession()
        let requests = Recorder<String>()
        await IsolatedMockURLProtocol.setHandler(key: key) { request in
            await requests.append(request.url!.absoluteString)
            return try json(request.url!, 404, [:])
        }
        let authorizer = OAuthAuthorizer(
            configuration: .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                assertionProvider: { _, _ in "jwt" }, allowsDiscoveredAuthorizationServer: true))
        await #expect(throws: (any Error).self) {
            _ = try await authorizer.handleChallenge(statusCode: 401, headers: [:], endpoint: endpoint, session: session)
        }
        #expect(!(await requests.values).contains("https://mcp.example.com/token"))
    }
    #endif

    @Test("A token without a refresh token is replaced before it expires")
    func proactiveReacquisition() async throws {
        let calls = Recorder<Int>()
        let tokenClient = MockTokenClient()
        tokenClient.tokenResponse = OAuthTokenResponse(
            accessToken: "short", tokenType: "Bearer", expiresIn: 40, scope: nil, refreshToken: nil)
        let authorizer = jwtBearerAuthorizer(
            .init(
                grantType: .jwtBearer, authentication: .none(clientID: ""),
                endpointOverrides: .init(authorizationServerURL: URL(string: "https://auth.example.com")!),
                assertionProvider: { _, _ in
                    await calls.append(1)
                    return "jwt"
                }),
            tokenClient: tokenClient)
        #expect(try await authorizer.handleChallenge(statusCode: 401, headers: headers401, endpoint: endpoint, session: .shared))
        try await authorizer.prepareAuthorization(for: endpoint, session: .shared)
        #expect(await calls.values.count == 2)
        #expect(tokenClient.requestCallCount == 2)
    }

    // IsolatedMockURLProtocol needs the session headers, which Linux does not pass to it.
    #if !os(Linux)
    @Test("The identity provider's token endpoint is discovered once")
    func idpEndpointCached() async throws {
        let (session, key) = makeIsolatedSession()
        let discoveries = Recorder<String>()
        await IsolatedMockURLProtocol.setHandler(key: key) { request in
            let url = request.url!
            switch (url.host!, url.path) {
            case ("mcp.example.com", _):
                return try json(url, 200, ["authorization_servers": ["https://auth.example.com"]])
            case ("auth.example.com", "/.well-known/oauth-authorization-server"):
                return try json(url, 200, ["issuer": "https://auth.example.com", "token_endpoint": "https://auth.example.com/token"])
            case ("login.example.com", "/.well-known/oauth-authorization-server"):
                await discoveries.append(url.path)
                return try json(url, 200, ["issuer": "https://login.example.com", "token_endpoint": "https://login.example.com/token"])
            case ("login.example.com", "/token"):
                return try json(url, 200, [
                    "access_token": "id-jag", "issued_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                    "token_type": "N_A",
                ])
            case ("auth.example.com", "/token"):
                return try json(url, 200, ["access_token": "mcp-token", "token_type": "Bearer", "expires_in": 3600])
            default:
                return try json(url, 404, [:])
            }
        }
        let authorizer = OAuthAuthorizer(
            configuration: .enterpriseManaged(
                authentication: .clientSecretBasic(clientID: "c", clientSecret: "s"),
                authorizationServer: URL(string: "https://auth.example.com")!,
                identityProvider: .init(endpoint: .issuer(URL(string: "https://login.example.com")!), authentication: .none(clientID: "i")),
                idToken: { _ in "id-token" }))
        for _ in 0..<3 {
            #expect(try await authorizer.handleChallenge(statusCode: 401, headers: headers401, endpoint: endpoint, session: session))
        }
        #expect(await discoveries.values.count == 1)
    }
    #endif
}

