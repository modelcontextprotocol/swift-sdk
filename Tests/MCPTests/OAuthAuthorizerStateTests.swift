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
        let refreshToken: String?
        let scope: String?
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
            recorded.append(
                Call(
                    endpoint: endpoint, grantType: grant, refreshToken: parameters[OAuthParameterName.refreshToken],
                    scope: parameters[OAuthParameterName.scope]))
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

/// An authorization code flow that waits for `release()` and then returns
/// a code, or throws `error` when set.
final class GatedAuthCodeFlow: OAuthAuthorizationCodeFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private var performs = 0
    private let (released, releaseSink) = AsyncStream<Void>.makeStream()
    private let enteredSink: AsyncStream<Void>.Continuation
    /// Yields when a flow starts.
    let entered: AsyncStream<Void>
    var error: (any Error)?

    init() {
        (entered, enteredSink) = AsyncStream<Void>.makeStream()
    }

    var performCount: Int { lock.withLock { performs } }

    func release() { releaseSink.finish() }

    func buildURL(
        authorizationEndpoint: URL, resource: URL, redirectURI: URL, clientID: String, codeChallenge: String,
        scopes: Set<String>?, state: String, scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL {
        authorizationEndpoint
    }

    func perform(
        authorizationURL: URL, redirectURI: URL, state: String, issuer: OAuthAuthorizationCodeFlow.ExpectedIssuer?,
        delegate: (any OAuthAuthorizationDelegate)?, session: URLSession
    ) async throws -> String {
        lock.withLock { performs += 1 }
        enteredSink.yield()
        for await _ in released {}
        if let error { throw error }
        return "code"
    }
}

/// Counts the endpoint checks each challenge starts with.
final class CountingURLValidator: OAuthURLValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0

    var endpointChecks: Int { lock.withLock { checks } }

    func validateHTTPSOrLoopback(_ url: URL, context: String) throws { lock.withLock { checks += 1 } }
    func validateAuthorizationServer(_ url: URL, context: String) throws {}
    func validateRedirectURI(_ url: URL) throws {}
    func isPrivateIPHost(_ host: String) -> Bool { false }
}

/// Fails the first registration, then registers `registered`.
final class FlakyClientRegistrar: OAuthClientRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var registerCallCount: Int { lock.withLock { calls } }

    func register(
        configuration: OAuthConfiguration, asMetadata: OAuthAuthorizationServerMetadata, session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        let call: Int = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { throw URLError(.timedOut) }
        return (
            OAuthClientRegistrationResponse(
                clientID: "registered", clientSecret: "secret", tokenEndpointAuthMethod: "client_secret_basic",
                clientSecretExpiresAt: nil),
            .clientSecretBasic(clientID: "registered", clientSecret: "secret")
        )
    }
}

struct UserCancelledAuthorization: Error {}

/// Waits until `condition` holds, for at most `limit`.
private func waitUntil(within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Condition not met within \(limit)")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
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
        overrides: OAuthConfiguration.EndpointOverrides = .none,
        grantType: OAuthConfiguration.GrantType = .clientCredentials,
        authentication: OAuthConfiguration.TokenEndpointAuthentication = .clientSecretBasic(
            clientID: "client", clientSecret: "secret"),
        urlValidator: any OAuthURLValidating = MockURLValidator(),
        registrar: any OAuthClientRegistering = MockClientRegistrar(),
        authCodeFlow: any OAuthAuthorizationCodeFlowing = MockAuthCodeFlow()
    ) -> OAuthAuthorizer {
        OAuthAuthorizer(
            configuration: OAuthConfiguration(
                grantType: grantType,
                authentication: authentication,
                endpointOverrides: overrides),
            tokenStorage: storage,
            urlValidator: urlValidator,
            discoveryClient: discovery,
            tokenEndpointClient: tokens,
            clientRegistrar: registrar,
            authCodeFlow: authCodeFlow)
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

    /// A challenge for a request sent with `sent` as its `Authorization` value.
    func challenge(
        _ authorizer: OAuthAuthorizer, sent: String?, status: Int = 401, headers: [String: String]? = nil
    ) async throws -> Bool {
        try await authorizer.handleChallenge(
            statusCode: status, headers: headers ?? challenge, endpoint: endpoint, operationKey: "tools/call",
            sentAuthorization: sent, session: .shared)
    }

    @Test("A 401 for a token another challenge already refreshed retries with the new token")
    func lateChallengeKeepsRefreshedToken() async throws {
        let storage = InMemoryTokenStorage()
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery(listing: serverA), tokens: tokens, storage: storage)
        #expect(try await challenge(authorizer, sent: nil))
        #expect(try await challenge(authorizer, sent: "Bearer token-1"))  // refresh

        // A request sent with token-1 before the refresh gets its 401 now.
        #expect(try await challenge(authorizer, sent: "Bearer token-1"))
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token"])
        #expect(storage.load()?.value == "token-2")
        #expect(storage.load()?.refreshToken == "refresh-2")
    }

    @Test("A refreshed token rejected later is refreshed again after the resource metadata is read")
    func refreshedTokenIsRefreshedAgain() async throws {
        let storage = InMemoryTokenStorage()
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens, storage: storage)
        #expect(try await challenge(authorizer, sent: nil))
        #expect(try await challenge(authorizer, sent: "Bearer token-1"))  // refresh
        let fetches = discovery.fetchProtectedResourceMetadataCallCount

        #expect(try await challenge(authorizer, sent: "Bearer token-2"))
        #expect(discovery.fetchProtectedResourceMetadataCallCount == fetches + 1)
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token", "refresh_token"])
        #expect(tokens.calls.last?.refreshToken == "refresh-2")
        #expect(storage.load()?.value == "token-3")
    }

    @Test("A transient failure to read the authorization server metadata keeps the stored tokens")
    func transientServerMetadataFailureKeepsToken() async throws {
        let storage = InMemoryTokenStorage()
        storage.save(
            OAuthAccessToken(
                value: "persisted", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(-60), scopes: [],
                authorizationServer: serverA, refreshToken: "persisted-refresh"))
        let discovery = discovery(listing: serverA)
        discovery.authorizationServerMetadataError = OAuthMetadataUnavailable(url: serverA, reason: "HTTP 503")
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery, tokens: tokens, storage: storage)

        await #expect(throws: OAuthMetadataUnavailable.self) {
            _ = try await challenge(authorizer, sent: "Bearer persisted")
        }
        #expect(storage.load()?.value == "persisted")
        #expect(storage.load()?.refreshToken == "persisted-refresh")
        #expect(tokens.calls.isEmpty)

        // Once the server answers, the token is refreshed.
        discovery.authorizationServerMetadataError = nil
        #expect(try await challenge(authorizer, sent: "Bearer persisted"))
        #expect(tokens.calls.map(\.refreshToken) == ["persisted-refresh"])
    }

    @Test("Challenges waiting for an authorization that fails fail with its error", .timeLimit(.minutes(1)))
    func waitersShareFailedAuthorization() async throws {
        let flow = GatedAuthCodeFlow()
        flow.error = UserCancelledAuthorization()
        let validator = CountingURLValidator()
        let authorizer = makeAuthorizer(
            discovery: discovery(listing: serverA), tokens: RecordingTokenClient(), grantType: .authorizationCode,
            urlValidator: validator, authCodeFlow: flow)
        var entered = flow.entered.makeAsyncIterator()

        let first = Task { try await challenge(authorizer, sent: nil) }
        await entered.next()
        let waiting = (0..<2).map { _ in Task { try await challenge(authorizer, sent: nil) } }
        try await waitUntil { validator.endpointChecks == 3 && authorizer.gate.waiterCount == 2 }
        flow.release()

        for task in [first] + waiting {
            await #expect(throws: UserCancelledAuthorization.self) { _ = try await task.value }
        }
        #expect(flow.performCount == 1)

        // A later challenge starts a new flow.
        flow.error = nil
        #expect(try await challenge(authorizer, sent: nil))
        #expect(flow.performCount == 2)
    }

    @Test(
        "Concurrent 403 step-ups for a token whose step-up the user cancelled ask once and fail",
        .timeLimit(.minutes(1)))
    func waitersShareCancelledStepUp() async throws {
        let storage = InMemoryTokenStorage()
        storage.save(
            OAuthAccessToken(
                value: "narrow", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3600), scopes: ["read"],
                authorizationServer: nil, refreshToken: nil))
        let flow = GatedAuthCodeFlow()
        flow.error = UserCancelledAuthorization()
        let authorizer = makeAuthorizer(
            discovery: discovery(listing: serverA), tokens: RecordingTokenClient(), storage: storage,
            grantType: .authorizationCode, authCodeFlow: flow)
        let insufficient = ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="admin""#]
        var entered = flow.entered.makeAsyncIterator()

        let first = Task { try await challenge(authorizer, sent: "Bearer narrow", status: 403, headers: insufficient) }
        await entered.next()
        let waiting = Task {
            try await challenge(authorizer, sent: "Bearer narrow", status: 403, headers: insufficient)
        }
        try await waitUntil { authorizer.gate.waiterCount == 1 }
        flow.release()

        // The narrower token is still stored and valid, but it is the one
        // the waiting request carried.
        for task in [first, waiting] {
            await #expect(throws: UserCancelledAuthorization.self) { _ = try await task.value }
        }
        #expect(flow.performCount == 1)
        #expect(storage.load()?.value == "narrow")
    }

    @Test("Concurrent 403 step-ups for the same scopes run one token request", .timeLimit(.minutes(1)))
    func concurrentStepUps() async throws {
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(discovery: discovery(listing: serverA), tokens: tokens)
        #expect(try await challenge(authorizer, sent: nil))
        tokens.delay = .milliseconds(50)
        let insufficient = ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="admin""#]
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await challenge(authorizer, sent: "Bearer token-1", status: 403, headers: insufficient)
                }
            }
            for try await handled in group { #expect(handled) }
        }
        #expect(tokens.calls.count == 2)
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer token-2")
    }

    @Test("A registration that failed is tried again by the next challenge")
    func failedRegistrationIsRetried() async throws {
        let registrar = FlakyClientRegistrar()
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(
            discovery: discovery(listing: serverA), tokens: tokens, authentication: .none(clientID: ""),
            registrar: registrar)
        await #expect(throws: URLError.self) { _ = try await challenge(authorizer, sent: nil) }
        #expect(tokens.calls.isEmpty)

        #expect(try await challenge(authorizer, sent: nil))
        #expect(registrar.registerCallCount == 2)
        #expect(tokens.calls.count == 1)
    }

    @Test("A challenge waiting for another one stops waiting when cancelled", .timeLimit(.minutes(1)))
    func waitingChallengeIsCancellable() async throws {
        let flow = GatedAuthCodeFlow()
        let validator = CountingURLValidator()
        let authorizer = makeAuthorizer(
            discovery: discovery(listing: serverA), tokens: RecordingTokenClient(), grantType: .authorizationCode,
            urlValidator: validator, authCodeFlow: flow)
        var entered = flow.entered.makeAsyncIterator()

        let first = Task { try await challenge(authorizer, sent: nil) }
        await entered.next()
        let waiting = Task { try await challenge(authorizer, sent: nil) }
        try await waitUntil { validator.endpointChecks == 2 && authorizer.gate.waiterCount == 1 }
        waiting.cancel()

        // The cancelled challenge returns while the first still holds the gate.
        let (outcomes, sink) = AsyncStream<String>.makeStream()
        let observer = Task {
            do {
                _ = try await waiting.value
                sink.yield("returned")
            } catch is CancellationError {
                sink.yield("cancelled")
            } catch {
                sink.yield("\(error)")
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(5))
            sink.yield("timed out")
        }
        var iterator = outcomes.makeAsyncIterator()
        let outcome = await iterator.next()
        timer.cancel()
        flow.release()
        #expect(outcome == "cancelled")

        #expect(try await first.value)
        await observer.value
        #expect(flow.performCount == 1)
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer token-1")
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

    @Test("With a configured authorization server, a 401 keeps the token when the resource lists another server")
    func configuredServerKeepsTokenOn401() async throws {
        let storage = InMemoryTokenStorage()
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(
            discovery: discovery, tokens: tokens, storage: storage, overrides: .init(authorizationServerURL: serverA))
        #expect(try await challenge(authorizer, sent: nil))
        #expect(try await challenge(authorizer, sent: "Bearer token-1"))  // refresh

        // The refreshed token is rejected, so the resource metadata is read
        // again; it lists B. The server metadata cannot be read again now.
        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil, authorizationServers: [serverB], scopesSupported: nil)
        discovery.authorizationServerMetadataError = OAuthMetadataUnavailable(url: serverA, reason: "HTTP 503")
        #expect(try await challenge(authorizer, sent: "Bearer token-2"))
        #expect(tokens.calls.map(\.grantType) == ["client_credentials", "refresh_token", "refresh_token"])
        #expect(tokens.calls.allSatisfy { $0.endpoint.host == serverA.host })
        #expect(storage.load()?.value == "token-3")
    }

    @Test("With a configured authorization server, a 403 step-up keeps the token and its scopes")
    func configuredServerKeepsTokenOnStepUp() async throws {
        let storage = InMemoryTokenStorage()
        let discovery = discovery(listing: serverA)
        let tokens = RecordingTokenClient()
        let authorizer = makeAuthorizer(
            discovery: discovery, tokens: tokens, storage: storage, overrides: .init(authorizationServerURL: serverA))
        #expect(try await challenge(authorizer, sent: nil, headers: ["WWW-Authenticate": #"Bearer scope="read""#]))

        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil, authorizationServers: [serverB], scopesSupported: nil)
        let moved = [
            "WWW-Authenticate":
                #"Bearer error="insufficient_scope", scope="admin", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/other""#
        ]
        tokens.refusedGrants = ["client_credentials"]
        await #expect(throws: OAuthAuthorizationError.self) {
            _ = try await challenge(authorizer, sent: "Bearer token-1", status: 403, headers: moved)
        }
        let requested = tokens.calls.last?.scope?.split(separator: " ").map(String.init) ?? []
        #expect(Set(requested) == ["read", "admin"])
        #expect(tokens.calls.last?.endpoint.host == serverA.host)
        #expect(storage.load()?.value == "token-1")
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
