@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Shared authorizer state: transient discovery failures, the binding of
// refresh tokens to their server, and concurrent challenges.

/// Records token requests and answers them with numbered tokens.
final class RecordingTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    struct Call {
        let endpoint: URL
        let grantType: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var issued = 0
    /// Grant types answered with HTTP 400 `invalid_grant`.
    var refusedGrants: Set<String> = []
    var expiresIn = 3600
    var delay: Duration = .zero

    var calls: [Call] { lock.withLock { recorded } }

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        let grant = parameters[OAuthParameterName.grantType]
        let number: Int = lock.withLock {
            recorded.append(Call(endpoint: endpoint, grantType: grant))
            issued += 1
            return issued
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let grant, refusedGrants.contains(grant) {
            throw OAuthAuthorizationError.tokenRequestFailed(statusCode: 400, oauthError: "invalid_grant")
        }
        return OAuthTokenResponse(
            accessToken: "token-\(number)", tokenType: "Bearer", expiresIn: expiresIn, scope: nil,
            refreshToken: "refresh-\(number)")
    }
}

private func asMetadata(_ issuer: URL) -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
    (
        issuer,
        OAuthAuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: issuer.appendingPathComponent("authorize"),
            tokenEndpoint: issuer.appendingPathComponent("token"),
            registrationEndpoint: nil,
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: nil,
            clientIDMetadataDocumentSupported: nil)
    )
}

@Suite("OAuthAuthorizer state")
struct OAuthAuthorizerStateTests {
    let endpoint = URL(string: "https://mcp.example.com/mcp")!
    let serverA = URL(string: "https://a.example.com")!
    let serverB = URL(string: "https://b.example.com")!
    let challenge = ["WWW-Authenticate": "Bearer"]

    func makeAuthorizer(
        discovery: MockDiscoveryClient, tokens: RecordingTokenClient,
        storage: TokenStorage = InMemoryTokenStorage(),
        overrides: OAuthConfiguration.EndpointOverrides = .none
    ) -> OAuthAuthorizer {
        OAuthAuthorizer(
            configuration: OAuthConfiguration(
                grantType: .clientCredentials,
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
                endpointOverrides: overrides),
            tokenStorage: storage,
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: tokens,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow())
    }

    func discovery(listing server: URL) -> MockDiscoveryClient {
        let discovery = MockDiscoveryClient(authorizationServer: server, tokenEndpoint: server.appendingPathComponent("token"))
        discovery.authorizationServerMetadataResult = asMetadata(server)
        return discovery
    }

    func challenge(_ authorizer: OAuthAuthorizer, status: Int = 401, headers: [String: String]? = nil) async throws -> Bool {
        try await authorizer.handleChallenge(
            statusCode: status, headers: headers ?? challenge, endpoint: endpoint, operationKey: "tools/call",
            session: .shared)
    }

    @Test("A 401 refreshes at the token's server before reading the resource metadata again")
    func refreshesFirst() async throws {
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens)
        #expect(try await challenge(authorizer))
        let fetches = discovery.fetchProtectedResourceMetadataCallCount

        #expect(try await challenge(authorizer))
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token"])
        #expect(discovery.fetchProtectedResourceMetadataCallCount == fetches)
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer token-2")
    }

    @Test("A transient failure to read the metadata keeps the token's server; nothing goes to the MCP origin")
    func transientFailureKeepsServer() async throws {
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens)
        #expect(try await challenge(authorizer))

        // The refresh is refused, so the metadata is read again; that fails.
        tokens.refusedGrants = ["refresh_token"]
        discovery.protectedResourceMetadataError = OAuthMetadataUnavailable(url: endpoint, reason: "HTTP 503")
        #expect(try await challenge(authorizer))
        #expect(tokens.calls.allSatisfy { $0.endpoint.host == serverA.host })
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token", "client_credentials"])
    }

    @Test("A token rejected right after its refresh makes the next challenge read the metadata again")
    func rejectedRefreshRereadsMetadata() async throws {
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens)
        #expect(try await challenge(authorizer))
        #expect(try await challenge(authorizer))  // refresh
        let fetches = discovery.fetchProtectedResourceMetadataCallCount

        // The resource moved to B (SEP-2352) and rejects the refreshed token.
        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil, authorizationServers: [serverB], scopesSupported: nil)
        discovery.authorizationServerMetadataResult = asMetadata(serverB)
        #expect(try await challenge(authorizer))
        #expect(discovery.fetchProtectedResourceMetadataCallCount == fetches + 1)
        #expect(tokens.calls.last?.endpoint.host == serverB.host)
        #expect(tokens.calls.last?.grantType == "client_credentials")
    }

    @Test("A new authorization server drops the stored token, so its refresh token never reaches that server")
    func newServerDropsToken() async throws {
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        tokens.expiresIn = 30  // inside the proactive refresh window
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens)
        #expect(try await challenge(authorizer))

        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil, authorizationServers: [serverB], scopesSupported: nil)
        discovery.authorizationServerMetadataResult = asMetadata(serverB)
        let moved = [
            "WWW-Authenticate":
                #"Bearer error="insufficient_scope", scope="admin", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/other""#
        ]
        tokens.refusedGrants = ["client_credentials"]
        await #expect(throws: (any Error).self) { _ = try await challenge(authorizer, status: 403, headers: moved) }
        #expect(authorizer.authorizationHeader(for: endpoint) == nil)

        try await authorizer.prepareAuthorization(for: endpoint, session: .shared)
        #expect(!tokens.calls.contains { $0.grantType == "refresh_token" })
    }

    @Test("A token without a recorded server is not refreshed at a discovered one")
    func unboundTokenIsNotRefreshed() async throws {
        let storage = InMemoryTokenStorage()
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens, storage: storage)
        #expect(try await challenge(authorizer))
        storage.save(
            OAuthAccessToken(
                value: "old", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(10), scopes: [],
                authorizationServer: nil, refreshToken: "old-refresh"))
        try await authorizer.prepareAuthorization(for: endpoint, session: .shared)
        #expect(tokens.calls.map(\.grantType) == ["client_credentials"])

        // With a configured server, the token belongs to it.
        let configured = makeAuthorizer(
            discovery: discovery, tokens: tokens, storage: storage,
            overrides: .init(authorizationServerURL: serverA))
        #expect(try await challenge(configured))
        storage.save(
            OAuthAccessToken(
                value: "old", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(10), scopes: [],
                authorizationServer: nil, refreshToken: "old-refresh"))
        try await configured.prepareAuthorization(for: endpoint, session: .shared)
        #expect(tokens.calls.last?.grantType == "refresh_token")
        #expect(discovery.lastTrustedIssuer == serverA)
    }

    @Test("Concurrent challenges run one token request")
    func concurrentChallenges() async throws {
        let tokens = RecordingTokenClient()
        tokens.delay = .milliseconds(50)
        let authorizer = makeAuthorizer(discovery: discovery(listing: serverA), tokens: tokens)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { try await challenge(authorizer) }
            }
            for try await handled in group { #expect(handled) }
        }
        #expect(tokens.calls.count == 1)
    }

    @Test("Concurrent proactive refreshes run one refresh")
    func concurrentRefreshes() async throws {
        let tokens = RecordingTokenClient()
        tokens.expiresIn = 30
        let authorizer = makeAuthorizer(discovery: discovery(listing: serverA), tokens: tokens)
        #expect(try await challenge(authorizer))
        tokens.expiresIn = 3600
        tokens.delay = .milliseconds(50)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { try await authorizer.prepareAuthorization(for: endpoint, session: .shared) }
            }
            try await group.waitForAll()
        }
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token"])
    }

    @Test("In-memory token storage is safe from several tasks")
    func storageIsThreadSafe() async {
        let storage = InMemoryTokenStorage()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    if index.isMultiple(of: 3) {
                        storage.clear()
                    } else {
                        storage.save(
                            OAuthAccessToken(
                                value: "\(index)", tokenType: "Bearer", expiresAt: nil, scopes: [],
                                authorizationServer: nil, refreshToken: nil))
                    }
                    _ = storage.load()
                }
            }
        }
    }
}
