import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif


// MARK: - HTTPClientAuthorizer Protocol

/// Abstraction used by ``HTTPClientTransport`` to handle OAuth authorization challenges.
///
/// Implement this protocol to provide custom token acquisition strategies,
/// or use the built-in ``OAuthAuthorizer`` for a full OAuth 2.1 implementation.
///
/// ``HTTPClientTransport`` calls these methods automatically when it receives
/// `401 Unauthorized` or `403 Forbidden` responses from the server.
public protocol HTTPClientAuthorizer: AnyObject, Sendable {
    /// The maximum number of authorization retries permitted for a single request.
    ///
    /// ``HTTPClientTransport`` will not call ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)``
    /// more than this many times for a single outgoing request.
    var maxAuthorizationAttempts: Int { get }

    /// Validates that the MCP endpoint URL satisfies the security requirements for OAuth.
    ///
    /// Called once before the first request is sent. Throw ``OAuthAuthorizationError/insecureOAuthEndpoint(context:url:)``
    /// if the URL does not meet the requirements (e.g., non-HTTPS non-loopback).
    /// - Parameter endpoint: The MCP endpoint URL to validate.
    func validateEndpointSecurity(for endpoint: URL) throws

    /// Returns the headers that authorize a request, if a valid token is available.
    ///
    /// ``HTTPClientTransport`` calls this for every request, after its
    /// `requestModifier`, with the final URL and method; the returned headers
    /// replace any of the same name.
    ///
    /// - Parameters:
    ///   - url: The request URL.
    ///   - method: The HTTP method, such as `POST` or `GET`.
    /// - Returns: `Authorization` (`Bearer <token>` or `DPoP <token>`) and, for
    ///   a DPoP-bound token, a `DPoP` proof; empty if no valid token is cached.
    func authorizationHeaders(for url: URL, method: String) throws -> [String: String]

    /// Handles an authorization challenge received from the server and attempts to acquire a new token.
    ///
    /// Called by ``HTTPClientTransport`` when a `401` or `403` response is received.
    /// The implementation should attempt to obtain a valid access token and store it
    /// so that a subsequent call to ``authorizationHeaders(for:method:)`` returns it.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code (401 or 403).
    ///   - headers: All response headers from the challenge response.
    ///   - endpoint: The MCP endpoint that returned the challenge.
    ///   - operationKey: An optional identifier for the MCP operation (e.g., the JSON-RPC method),
    ///     used to track step-up attempts per operation.
    ///   - session: The `URLSession` to use for discovery and token requests.
    /// - Returns: `true` if a new token was acquired and the original request should be retried;
    ///   `false` if the challenge cannot be handled.
    func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        session: URLSession
    ) async throws -> Bool

    /// Handles an authorization challenge, knowing the `Authorization` value
    /// the challenged request carried.
    ///
    /// ``HTTPClientTransport`` calls this method. With the sent value, an
    /// implementation can tell a challenge for a token that another request
    /// has already replaced from a challenge for the current token. The
    /// result also says whether the retry only answers a DPoP `use_dpop_nonce`
    /// challenge (RFC 9449 §9), which the transport allows once per request
    /// without counting it against ``maxAuthorizationAttempts``.
    ///
    /// The default implementation calls
    /// ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)``
    /// and reports a DPoP nonce retry when it returns `true` for a `401`
    /// whose `DPoP` challenge, read with ``DefaultOAuthWWWAuthenticateParser``,
    /// has the error `use_dpop_nonce`, and that carries a `DPoP-Nonce` header.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code (401 or 403).
    ///   - headers: All response headers from the challenge response.
    ///   - endpoint: The MCP endpoint that returned the challenge.
    ///   - operationKey: An optional identifier for the MCP operation (e.g., the JSON-RPC method).
    ///   - sentAuthorization: The `Authorization` header of the challenged request,
    ///     or `nil` when it had none.
    ///   - session: The `URLSession` to use for discovery and token requests.
    /// - Returns: Whether to retry the original request, and whether that
    ///   retry is a DPoP nonce retry.
    func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        sentAuthorization: String?,
        session: URLSession
    ) async throws -> HTTPChallengeResult

    /// Proactively refreshes the access token if it is close to expiry.
    ///
    /// Called by ``HTTPClientTransport`` before sending each request and before opening
    /// an SSE stream, allowing the token to be silently renewed without a 401 round-trip.
    /// Implementations should swallow refresh errors — if refresh fails, the normal
    /// ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)`` path recovers.
    ///
    /// - Parameters:
    ///   - endpoint: The MCP endpoint about to be contacted.
    ///   - session: The `URLSession` to use for token refresh requests.
    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws

    /// Inspects the headers of a response, before any challenge handling.
    ///
    /// ``HTTPClientTransport`` calls this for every response with the URL the
    /// request was sent to. ``OAuthAuthorizer`` records a `DPoP-Nonce` here
    /// (RFC 9449 §8). The default does nothing.
    ///
    /// - Parameters:
    ///   - headers: The response headers.
    ///   - url: The request URL.
    func didReceiveResponse(headers: [String: String], for url: URL)
}

extension HTTPClientAuthorizer {
    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {}

    /// Calls ``handleChallenge(statusCode:headers:endpoint:operationKey:session:)``,
    /// ignoring `sentAuthorization`, and reports a DPoP nonce retry for a
    /// retried `401` `use_dpop_nonce` challenge with a `DPoP-Nonce` header.
    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        sentAuthorization: String?,
        session: URLSession
    ) async throws -> HTTPChallengeResult {
        let retry = try await handleChallenge(
            statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
            session: session)
        return HTTPChallengeResult(
            retry: retry,
            isDPoPNonceRetry: retry
                && HTTPChallengeResult.isDPoPNonceChallenge(statusCode: statusCode, headers: headers))
    }

    public func didReceiveResponse(headers: [String: String], for url: URL) {}
}

// MARK: - OAuthAuthorizer

/// Full OAuth 2.1 implementation of ``HTTPClientAuthorizer``.
///
/// `OAuthAuthorizer` orchestrates the complete MCP authorization flow on behalf of an HTTP client:
///
/// 1. **Protected Resource Metadata discovery** (RFC 9728) — fetches
///    `/.well-known/oauth-protected-resource` to locate the authorization server.
/// 2. **Authorization Server Metadata discovery** (RFC 8414 / OIDC Discovery 1.0) — fetches
///    `/.well-known/oauth-authorization-server` or `/.well-known/openid-configuration`.
/// 3. **Dynamic Client Registration** (RFC 7591) — registers the client if no credentials are
///    pre-configured and the AS advertises a registration endpoint.
/// 4. **Token acquisition** — performs the configured grant flow (`authorization_code` with PKCE,
///    or `client_credentials`), binding tokens to the resource indicator (RFC 8707).
/// 5. **Token refresh** — attempts a `refresh_token` grant before a full re-authorization.
/// 6. **Scope step-up** — handles `403 insufficient_scope` challenges by re-requesting with
///    the union of existing and required scopes.
/// 7. **DPoP** (RFC 9449) — with ``OAuthConfiguration/dpop``, signs a proof for every token
///    and MCP request, presents bound tokens with the `DPoP` scheme, and retries
///    `use_dpop_nonce` errors with the server's nonce.
///
/// Pass an instance to `HTTPClientTransport(authorizer:)` to enable automatic authorization:
///
/// ```swift
/// let config = OAuthConfiguration(
///     grantType: .clientCredentials,
///     authentication: .clientSecretBasic(clientID: "my-app", clientSecret: "s3cr3t")
/// )
/// let authorizer = OAuthAuthorizer(configuration: config)
/// let transport = HTTPClientTransport(endpoint: serverURL, authorizer: authorizer)
/// ```
///
/// - Important: Requests of one transport run concurrently. `handleChallenge`
///   and `prepareAuthorization` run one at a time: a challenge that arrives
///   while another is handled waits for it, and retries with the token it
///   obtained instead of starting another flow. Each piece of state is read
///   and written under a lock. One authorizer serves one resource; do not
///   share it between transports for different servers.
public final class OAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {

    // MARK: - Mutable State

    /// Guards every stored property below that has an underscore.
    private let stateLock = NSLock()
    /// Runs `handleChallenge` and `prepareAuthorization` one at a time.
    let gate = AsyncGate()

    private var _configuration: OAuthConfiguration
    private var _selectedAuthorizationServer: URL?
    private var _protectedResourceMetadata: OAuthProtectedResourceMetadata?
    private var _authorizationServerMetadata: OAuthAuthorizationServerMetadata?
    private var _cachedProtectedResourceMetadataURL: URL?
    private var _stepUpAttempts: [String: Int] = [:]
    private var _clientRegistrationAttempted = false
    private var _clientSecretExpiresAt: Date?
    private var _registrationIssuer: URL?
    private var _registrationAttemptIssuer: URL?
    private var _refreshedTokenValue: String?
    private var _completedChallenges = 0
    private var _lastChallengeError: (any Error)?
    private var _storedTokenLifetime: (value: String, seconds: TimeInterval)?
    private var _proactivelyRenewedToken: String?

    private var configuration: OAuthConfiguration {
        get { stateLock.withLock { _configuration } }
        set { stateLock.withLock { _configuration = newValue } }
    }
    private var selectedAuthorizationServer: URL? {
        get { stateLock.withLock { _selectedAuthorizationServer } }
        set { stateLock.withLock { _selectedAuthorizationServer = newValue } }
    }
    private var protectedResourceMetadata: OAuthProtectedResourceMetadata? {
        get { stateLock.withLock { _protectedResourceMetadata } }
        set { stateLock.withLock { _protectedResourceMetadata = newValue } }
    }
    private var authorizationServerMetadata: OAuthAuthorizationServerMetadata? {
        get { stateLock.withLock { _authorizationServerMetadata } }
        set { stateLock.withLock { _authorizationServerMetadata = newValue } }
    }
    private var cachedProtectedResourceMetadataURL: URL? {
        get { stateLock.withLock { _cachedProtectedResourceMetadataURL } }
        set { stateLock.withLock { _cachedProtectedResourceMetadataURL = newValue } }
    }
    private var stepUpAttempts: [String: Int] {
        get { stateLock.withLock { _stepUpAttempts } }
        set { stateLock.withLock { _stepUpAttempts = newValue } }
    }
    private var clientRegistrationAttempted: Bool {
        get { stateLock.withLock { _clientRegistrationAttempted } }
        set { stateLock.withLock { _clientRegistrationAttempted = newValue } }
    }
    private var clientSecretExpiresAt: Date? {
        get { stateLock.withLock { _clientSecretExpiresAt } }
        set { stateLock.withLock { _clientSecretExpiresAt = newValue } }
    }
    /// The authorization server that issued registered credentials (SEP-2352).
    private var registrationIssuer: URL? {
        get { stateLock.withLock { _registrationIssuer } }
        set { stateLock.withLock { _registrationIssuer = newValue } }
    }
    /// The authorization server of the last registration attempt.
    private var registrationAttemptIssuer: URL? {
        get { stateLock.withLock { _registrationAttemptIssuer } }
        set { stateLock.withLock { _registrationAttemptIssuer = newValue } }
    }
    /// The access token the last refresh returned. When the resource rejects
    /// it, the next challenge reads the resource metadata again before
    /// refreshing at the same server.
    private var refreshedTokenValue: String? {
        get { stateLock.withLock { _refreshedTokenValue } }
        set { stateLock.withLock { _refreshedTokenValue = newValue } }
    }
    /// The number of challenges handled to the end, and the error the last
    /// one ended with (`nil` when it succeeded). Cancelled ones are not
    /// counted.
    private var lastChallenge: (count: Int, error: (any Error)?) {
        stateLock.withLock { (_completedChallenges, _lastChallengeError) }
    }
    private func recordChallenge(error: (any Error)?) {
        stateLock.withLock {
            _completedChallenges += 1
            _lastChallengeError = error
        }
    }
    /// The `expires_in` of the token this authorizer stored last.
    private var storedTokenLifetime: (value: String, seconds: TimeInterval)? {
        get { stateLock.withLock { _storedTokenLifetime } }
        set { stateLock.withLock { _storedTokenLifetime = newValue } }
    }
    /// The access token `prepareAuthorization` last tried to replace. It is
    /// tried once: a failed renewal is left to the 401 path.
    private var proactivelyRenewedToken: String? {
        get { stateLock.withLock { _proactivelyRenewedToken } }
        set { stateLock.withLock { _proactivelyRenewedToken = newValue } }
    }

    private let tokenStorage: TokenStorage
    /// The authentication configured at creation, restored when registered
    /// credentials no longer apply.
    private let configuredAuthentication: OAuthConfiguration.TokenEndpointAuthentication

    // MARK: - Composable Dependencies

    private let scopeSelector: any OAuthScopeSelecting
    private let challengeParser: any OAuthWWWAuthenticateParsing
    private let urlValidator: any OAuthURLValidating
    private let discoveryClient: any OAuthDiscoveryFetching
    private let tokenEndpointClient: any OAuthTokenRequesting
    private let clientRegistrar: any OAuthClientRegistering
    private let authCodeFlow: any OAuthAuthorizationCodeFlowing
    /// Signs DPoP proofs when ``OAuthConfiguration/dpop`` is set.
    private let dpopSigner: DPoPProofSigner?

    /// Creates an `OAuthAuthorizer` with the given configuration and optional injectable dependencies.
    ///
    /// - Parameters:
    ///   - configuration: OAuth 2.1 configuration controlling the grant type, authentication method,
    ///     endpoint discovery overrides, and retry policy.
    ///   - tokenStorage: Stores acquired access tokens. Defaults to ``InMemoryTokenStorage``,
    ///     which loses tokens when the process exits. Supply a Keychain-backed implementation
    ///     to persist tokens across sessions.
    ///   - scopeSelector: Strategy for selecting OAuth scopes from challenge and metadata hints.
    ///     Defaults to ``DefaultOAuthScopeSelector``.
    ///   - challengeParser: Parses `WWW-Authenticate: Bearer` challenge headers.
    ///     Defaults to ``DefaultOAuthWWWAuthenticateParser``.
    ///   - metadataDiscovery: Constructs well-known discovery URLs and validates resource URI matching.
    ///     Defaults to ``DefaultOAuthMetadataDiscovery``.
    public convenience init(
        configuration: OAuthConfiguration,
        tokenStorage: TokenStorage = InMemoryTokenStorage(),
        scopeSelector: any OAuthScopeSelecting = DefaultOAuthScopeSelector(),
        challengeParser: any OAuthWWWAuthenticateParsing = DefaultOAuthWWWAuthenticateParser(),
        metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()
    ) {
        let urlValidator = OAuthURLValidator(
            allowLoopbackHTTPForAuthorizationServer:
                configuration.allowLoopbackHTTPAuthorizationServerEndpoints
        )
        self.init(
            configuration: configuration,
            tokenStorage: tokenStorage,
            scopeSelector: scopeSelector,
            challengeParser: challengeParser,
            urlValidator: urlValidator,
            discoveryClient: OAuthDiscoveryClient(
                metadataDiscovery: metadataDiscovery,
                urlValidator: urlValidator
            ),
            tokenEndpointClient: OAuthTokenEndpointClient(urlValidator: urlValidator),
            clientRegistrar: OAuthClientRegistrar(urlValidator: urlValidator),
            authCodeFlow: OAuthAuthorizationCodeFlow()
        )
    }

    init(
        configuration: OAuthConfiguration,
        tokenStorage: TokenStorage = InMemoryTokenStorage(),
        scopeSelector: any OAuthScopeSelecting = DefaultOAuthScopeSelector(),
        challengeParser: any OAuthWWWAuthenticateParsing = DefaultOAuthWWWAuthenticateParser(),
        urlValidator: any OAuthURLValidating,
        discoveryClient: any OAuthDiscoveryFetching,
        tokenEndpointClient: any OAuthTokenRequesting,
        clientRegistrar: any OAuthClientRegistering,
        authCodeFlow: any OAuthAuthorizationCodeFlowing
    ) {
        self._configuration = configuration
        self.configuredAuthentication = configuration.authentication
        self.tokenStorage = tokenStorage
        self.scopeSelector = scopeSelector
        self.challengeParser = challengeParser
        self.urlValidator = urlValidator
        self.discoveryClient = discoveryClient
        self.tokenEndpointClient = tokenEndpointClient
        self.clientRegistrar = clientRegistrar
        self.authCodeFlow = authCodeFlow
        self.dpopSigner = configuration.dpop.map(DPoPProofSigner.init)
    }

    // MARK: - HTTPClientAuthorizer

    public var maxAuthorizationAttempts: Int {
        configuration.retryPolicy.maxAuthorizationAttempts
    }

    public func validateEndpointSecurity(for endpoint: URL) throws {
        try urlValidator.validateHTTPSOrLoopback(endpoint, context: "MCP endpoint")
    }

    public func authorizationHeaders(for url: URL, method: String) throws -> [String: String] {
        guard let accessToken = tokenStorage.load() else { return [:] }
        if let tokenAuthorizationServer = accessToken.authorizationServer,
            let selectedAuthorizationServer,
            !authorizationServersMatch(tokenAuthorizationServer, selectedAuthorizationServer)
        {
            clearStoredToken(accessToken)
            return [:]
        }
        // A DPoP-bound token, expired or not, is usable only with the key it
        // is bound to, and so is its refresh token (RFC 9449 §5).
        if isBoundToAnotherKey(accessToken) {
            clearStoredToken(accessToken)
            return [:]
        }
        if accessToken.isExpired() {
            return [:]
        }
        guard let dpopSigner, accessToken.isDPoPBound else {
            return [HTTPHeaderName.authorization: "\(OAuthTokenType.bearer) \(accessToken.value)"]
        }
        return [
            HTTPHeaderName.authorization: "\(OAuthTokenType.dpop) \(accessToken.value)",
            HTTPHeaderName.dpop: try dpopSigner.proof(
                method: method, url: url, accessToken: accessToken.value, server: .resourceServer),
        ]
    }

    /// Whether `token` is DPoP-bound to another key than the configured one,
    /// or DPoP-bound while ``OAuthConfiguration/dpop`` is not set.
    private func isBoundToAnotherKey(_ token: OAuthAccessToken) -> Bool {
        guard token.isDPoPBound else { return false }
        guard let dpopSigner else { return true }
        return token.keyThumbprint != dpopSigner.thumbprint
    }

    /// Clears the stored token if it is still `token`. Runs outside the gate:
    /// a challenge may have saved a new token since `token` was loaded.
    private func clearStoredToken(_ token: OAuthAccessToken) {
        guard tokenStorage.load()?.value == token.value else { return }
        tokenStorage.clear()
    }

    public func didReceiveResponse(headers: [String: String], for url: URL) {
        dpopSigner?.recordNonce(from: headers, for: url, server: .resourceServer)
    }

    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String? = nil,
        session: URLSession
    ) async throws -> Bool {
        // The sent token is not known: take the stored one, before waiting
        // for a challenge in progress.
        let stored = tokenStorage.load()
        return try await handleChallenge(
            statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
            sentToken: stored?.value, sentDPoP: stored?.isDPoPBound == true, session: session
        ).retry
    }

    /// Handles a challenge for the request that carried `sentAuthorization`.
    /// A challenge for a token that another challenge has already replaced
    /// retries with the new token.
    ///
    /// The result is a DPoP nonce retry when the challenge, read with the
    /// authorizer's `challengeParser`, is a `401` with a `use_dpop_nonce`
    /// error and a `DPoP-Nonce` header, and a valid token bound to the
    /// configured DPoP key is stored (RFC 9449 §9). Of a `Bearer` and a
    /// `DPoP` challenge, the one for the scheme of `sentAuthorization` is
    /// answered (RFC 9449 §7.2).
    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String? = nil,
        sentAuthorization: String?,
        session: URLSession
    ) async throws -> HTTPChallengeResult {
        // The scheme and the credentials after it ("Bearer <token>").
        let sent = sentAuthorization.map { value -> (scheme: String, token: String) in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { return ("", trimmed) }
            return (String(trimmed[..<space]), trimmed[space...].trimmingCharacters(in: .whitespaces))
        }
        return try await handleChallenge(
            statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
            sentToken: sent?.token,
            sentDPoP: sent?.scheme.caseInsensitiveCompare(OAuthTokenType.dpop) == .orderedSame,
            session: session)
    }

    private func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        sentToken: String?,
        sentDPoP: Bool,
        session: URLSession
    ) async throws -> HTTPChallengeResult {
        try validateEndpointSecurity(for: endpoint)
        let completedBefore = lastChallenge.count
        return try await gate.run {
            // A challenge that ended while this one waited failed (a user who
            // cancelled the authorization, a refused grant) and left no
            // token other than the one this request carried, which the
            // resource rejected: fail with it instead of starting the same
            // flow again.
            let last = lastChallenge
            if last.count > completedBefore, let error = last.error,
                tokenStorage.load().map({ $0.isExpired() || $0.value == sentToken }) ?? true
            {
                throw error
            }
            do {
                let handled = try await handleChallengeAlone(
                    statusCode: statusCode, headers: headers, endpoint: endpoint, operationKey: operationKey,
                    sentToken: sentToken, sentDPoP: sentDPoP, session: session)
                recordChallenge(error: nil)
                return handled
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordChallenge(error: error)
                throw error
            }
        }
    }

    private func handleChallengeAlone(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        sentToken: String?,
        sentDPoP: Bool,
        session: URLSession
    ) async throws -> HTTPChallengeResult {
        let bearerChallenge = challengeParser.parseBearer(from: headers)
        let dpopChallenge = challengeParser.parseChallenge(scheme: OAuthTokenType.dpop, from: headers)
        // RFC 9449 §7.2: a resource that offers both schemes reports the error
        // in the challenge of the scheme the request used.
        let challenge = Self.challenge(
            preferring: sentDPoP ? dpopChallenge : bearerChallenge,
            other: sentDPoP ? bearerChallenge : dpopChallenge)

        if let dpopSigner {
            let nonce = dpopSigner.recordNonce(from: headers, for: endpoint, server: .resourceServer)
            // RFC 9449 §9: the token is valid; retry with the server's nonce.
            if statusCode == 401, dpopChallenge?.error == OAuthErrorCode.useDPoPNonce, nonce != nil,
                let token = tokenStorage.load(), token.isDPoPBound,
                token.keyThumbprint == dpopSigner.thumbprint, !token.isExpired()
            {
                return HTTPChallengeResult(retry: true, isDPoPNonceRetry: true)
            }
        }

        return HTTPChallengeResult(
            retry: try await answerChallenge(
                statusCode: statusCode, challenge: challenge, endpoint: endpoint, operationKey: operationKey,
                sentToken: sentToken, session: session))
    }

    /// The `preferred` challenge, or `other` when there is none. The
    /// `resource_metadata` of `other` fills in a missing one: it names the
    /// resource's metadata (RFC 9728 §5.1), whichever the scheme.
    private static func challenge(
        preferring preferred: OAuthBearerChallenge?, other: OAuthBearerChallenge?
    ) -> OAuthBearerChallenge? {
        guard let preferred else { return other }
        guard preferred.parameters["resource_metadata"] == nil,
            let resourceMetadata = other?.parameters["resource_metadata"]
        else { return preferred }
        var parameters = preferred.parameters
        parameters["resource_metadata"] = resourceMetadata
        return OAuthBearerChallenge(parameters: parameters)
    }

    /// Answers a challenge that a DPoP nonce alone does not: returns whether
    /// to retry with a new or refreshed token.
    private func answerChallenge(
        statusCode: Int,
        challenge: OAuthBearerChallenge?,
        endpoint: URL,
        operationKey: String?,
        sentToken: String?,
        session: URLSession
    ) async throws -> Bool {
        switch statusCode {
        case 401:
            // Another challenge replaced the token meanwhile: retry with it.
            if let current = tokenStorage.load(), current.value != sentToken, !current.isExpired() {
                return true
            }
            let movedMetadata =
                challenge?.resourceMetadataURL.map { $0 != cachedProtectedResourceMetadataURL } ?? false
            var triedRefresh = false
            if let rejected = tokenStorage.load(), let refreshToken = rejected.refreshToken,
                !movedMetadata, rejected.value != refreshedTokenValue,
                let asMetadata = authorizationServerMetadata
            {
                triedRefresh = true
                // Refresh first, at the server that issued the token; read the
                // resource metadata again only when that does not help.
                let resource = try canonicalResource(for: endpoint)
                let requestedScopes = scopeSelector.selectScopes(
                    challengeScope: challenge?.scope,
                    scopesSupported: protectedResourceMetadata?.scopesSupported
                )
                if try await refreshAccessToken(
                    rejected, refreshToken: refreshToken, resource: resource, requestedScopes: requestedScopes,
                    asMetadata: asMetadata, session: session)
                {
                    return true
                }
            }
            // A rejected token: the resource may have moved to another
            // authorization server, so read its metadata again (SEP-2352).
            // A failed read falls back to the cached copy; with none, it
            // throws and the token is kept. A refreshed token is refreshed
            // again only after this read.
            let rejected = tokenStorage.load()
            let current = try await discoverProtectedResourceMetadata(
                endpoint: endpoint, challenge: challenge, refresh: rejected != nil, session: session)
            if !triedRefresh, let rejected, let refreshToken = rejected.refreshToken {
                let asMetadata: OAuthAuthorizationServerMetadata?
                do {
                    asMetadata = try await resolveAuthorizationServerMetadata(metadata: current, session: session)
                } catch let error where error is OAuthMetadataUnavailable || error is CancellationError {
                    // Says nothing about the server: keep the token.
                    throw error
                } catch {
                    asMetadata = nil
                }
                if let asMetadata,
                    try await refreshAccessToken(
                        rejected, refreshToken: refreshToken, resource: try canonicalResource(for: endpoint),
                        requestedScopes: scopeSelector.selectScopes(
                            challengeScope: challenge?.scope, scopesSupported: current.scopesSupported),
                        asMetadata: asMetadata, session: session)
                {
                    return true
                }
            }
            tokenStorage.clear()

            let metadata = try await discoverProtectedResourceMetadata(
                endpoint: endpoint,
                challenge: challenge,
                session: session
            )
            let requestedScopes = scopeSelector.selectScopes(
                challengeScope: challenge?.scope,
                scopesSupported: metadata.scopesSupported
            )

            let providerContext = try await makeAccessTokenProviderContext(
                statusCode: statusCode,
                endpoint: endpoint,
                challenge: challenge,
                metadata: metadata,
                requestedScopes: requestedScopes,
                session: session
            )
            if let externalToken = try await fetchAccessTokenFromProvider(
                context: providerContext,
                session: session
            ) {
                storeExternalAccessToken(
                    externalToken,
                    requestedScopes: providerContext.requestedScopes,
                    authorizationServer: providerContext.authorizationServer
                )
                return true
            }

            try await acquireToken(
                endpoint: endpoint,
                metadata: metadata,
                requestedScopes: requestedScopes,
                session: session
            )
            return true

        case 403:
            guard challenge?.error?.lowercased() == "insufficient_scope" else { return false }

            let metadata = try await discoverProtectedResourceMetadata(
                endpoint: endpoint,
                challenge: challenge,
                session: session
            )
            let requiredScopes =
                scopeSelector.selectScopes(
                    challengeScope: challenge?.scope,
                    scopesSupported: metadata.scopesSupported
                ) ?? []

            // Another challenge obtained a token with these scopes meanwhile: retry with it.
            if let current = tokenStorage.load(), current.value != sentToken, !current.isExpired(),
                current.scopes.isSuperset(of: requiredScopes)
            {
                return true
            }

            let existingScopes = tokenStorage.load()?.scopes ?? []
            let upgradedScopes = existingScopes.union(requiredScopes)
            let resourceKey = try discoveryClient.metadataDiscovery.canonicalResourceURI(
                from: endpoint
            ).absoluteString
            let operationAttemptKey = normalizedOperationKey(operationKey)
            let attemptKey =
                "\(resourceKey)|\(operationAttemptKey)|\(upgradedScopes.sorted().joined(separator: " "))"
            let attempts = stepUpAttempts[attemptKey, default: 0]
            guard attempts < configuration.retryPolicy.maxScopeUpgradeAttempts else {
                return false
            }
            stepUpAttempts[attemptKey] = attempts + 1

            let providerRequestedScopes = upgradedScopes.isEmpty ? nil : upgradedScopes
            let providerContext = try await makeAccessTokenProviderContext(
                statusCode: statusCode,
                endpoint: endpoint,
                challenge: challenge,
                metadata: metadata,
                requestedScopes: providerRequestedScopes,
                session: session
            )
            if let externalToken = try await fetchAccessTokenFromProvider(
                context: providerContext,
                session: session
            ) {
                storeExternalAccessToken(
                    externalToken,
                    requestedScopes: providerContext.requestedScopes,
                    authorizationServer: providerContext.authorizationServer
                )
                return true
            }

            try await acquireToken(
                endpoint: endpoint,
                metadata: metadata,
                requestedScopes: upgradedScopes,
                session: session
            )
            return true

        default:
            return false
        }
    }

    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        guard configuration.proactiveRefreshWindowSeconds > 0 else { return }
        guard let token = tokenStorage.load(), isDueForRenewal(token) else { return }
        try await gate.run {
            // Read again: a refresh may have run while this one waited.
            guard let token = tokenStorage.load(), isDueForRenewal(token) else { return }
            guard let asMeta = authorizationServerMetadata,
                configuration.endpointOverrides.tokenEndpoint != nil || asMeta.tokenEndpoint != nil
            else { return }
            guard let refreshToken = token.refreshToken else {
                // Grants without user interaction get a new token before
                // this one expires; a failure leaves the 401 path to recover.
                guard configuration.grantType == .jwtBearer || configuration.grantType == .clientCredentials,
                    let metadata = protectedResourceMetadata
                else { return }
                proactivelyRenewedToken = token.value
                try? await acquireToken(
                    endpoint: endpoint, metadata: metadata,
                    requestedScopes: token.scopes.isEmpty ? nil : token.scopes, session: session)
                // A cancelled attempt is not a try: the next request makes it.
                if Task.isCancelled { proactivelyRenewedToken = nil }
                return
            }

            let resource: URL
            do {
                resource = try canonicalResource(for: endpoint)
            } catch {
                return
            }

            let requestedScopes = token.scopes.isEmpty ? nil : token.scopes
            proactivelyRenewedToken = token.value
            _ = try? await refreshAccessToken(
                token,
                refreshToken: refreshToken,
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMeta,
                session: session
            )
            if Task.isCancelled { proactivelyRenewedToken = nil }
        }
    }

    /// Whether `prepareAuthorization` replaces `token`: it expires within
    /// `proactiveRefreshWindowSeconds`, and it was not tried already. For a
    /// token this authorizer stored with a lifetime shorter than the window,
    /// the window shrinks to half the time the token is sent (until
    /// ``OAuthTokenExpirySkew/defaultSeconds`` before it expires), so it is
    /// not replaced on every request; a token that is never sent is left to
    /// the 401 path.
    private func isDueForRenewal(_ token: OAuthAccessToken) -> Bool {
        guard token.value != proactivelyRenewedToken else { return false }
        var window = configuration.proactiveRefreshWindowSeconds
        if let stored = storedTokenLifetime, stored.value == token.value, stored.seconds < window {
            let skew = OAuthTokenExpirySkew.defaultSeconds
            guard stored.seconds > skew else { return false }
            window = (stored.seconds + skew) / 2
        }
        return token.isExpired(skewSeconds: window)
    }

    // MARK: - Discovery

    /// The resource's metadata: the cached copy, or a fetched one when there
    /// is none, when the challenge names another metadata URL, or when
    /// `refresh` is set. A failed or synthesized refetch keeps a fetched
    /// copy. When the selected authorization server is no longer listed, the
    /// selection and the stored token are dropped, unless
    /// `endpointOverrides.authorizationServerURL` configures the server.
    private func discoverProtectedResourceMetadata(
        endpoint: URL,
        challenge: OAuthBearerChallenge?,
        refresh: Bool = false,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        let cached = protectedResourceMetadata
        let moved = challenge?.resourceMetadataURL.map { $0 != cachedProtectedResourceMetadataURL } ?? false
        if let cached, !moved, !refresh { return cached }

        var candidates: [URL] = []

        if let challengeURL = challenge?.resourceMetadataURL {
            try urlValidator.validateHTTPSOrLoopback(
                challengeURL, context: "Protected resource metadata URL")
            if let host = URLComponents(url: challengeURL, resolvingAgainstBaseURL: false)?.host?
                .lowercased(), urlValidator.isPrivateIPHost(host)
            {
                throw OAuthAuthorizationError.privateIPAddressBlocked(
                    context: "Protected resource metadata URL",
                    url: challengeURL.absoluteString
                )
            }
            candidates.append(challengeURL)
        }
        if let configuredURL = configuration.endpointOverrides.protectedResourceMetadataURL,
            !candidates.contains(configuredURL)
        {
            try urlValidator.validateHTTPSOrLoopback(
                configuredURL,
                context: "Configured protected resource metadata URL"
            )
            candidates.append(configuredURL)
        }

        for fallback in discoveryClient.metadataDiscovery.protectedResourceMetadataURLs(
            for: endpoint)
        where !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        // Synthesized metadata only on first discovery, never in place of a
        // fetched copy.
        let fallbackIssuer =
            cached.map { $0.isFallback } ?? true
            ? try? discoveryClient.metadataDiscovery.authorizationServerFallbackIssuer(from: endpoint) : nil
        let metadata: OAuthProtectedResourceMetadata
        do {
            metadata = try await discoveryClient.fetchProtectedResourceMetadata(
                candidates: candidates, fallbackIssuer: fallbackIssuer, session: session)
        } catch let error where !moved && !(error is CancellationError) {
            guard let cached else { throw error }
            return cached
        }
        try validateProtectedResource(metadata: metadata, endpoint: endpoint)

        // A configured authorization server is used whatever the resource
        // lists, so the resource cannot move away from it.
        if configuration.endpointOverrides.authorizationServerURL == nil,
            let selected = selectedAuthorizationServer,
            !metadata.authorizationServers.contains(where: { authorizationServersMatch($0, selected) })
        {
            // Another server: the token, and its refresh token, belong to the old one.
            selectedAuthorizationServer = nil
            authorizationServerMetadata = nil
            tokenStorage.clear()
        }
        self.protectedResourceMetadata = metadata
        self.cachedProtectedResourceMetadataURL = candidates.first
        return metadata
    }

    private func validateProtectedResource(
        metadata: OAuthProtectedResourceMetadata, endpoint: URL
    ) throws {
        guard let resource = metadata.resource?.trimmingCharacters(in: .whitespacesAndNewlines),
            !resource.isEmpty
        else {
            return
        }

        guard let resourceURL = URL(string: resource) else {
            throw OAuthAuthorizationError.invalidResourceURI(
                "Protected resource metadata contains an invalid resource URI: \(resource)"
            )
        }

        let expected = try discoveryClient.metadataDiscovery.canonicalResourceURI(from: endpoint)
        let actual = try discoveryClient.metadataDiscovery.canonicalResourceURI(from: resourceURL)
        guard discoveryClient.metadataDiscovery.protectedResourceMatches(
            resource: actual, endpoint: expected)
        else {
            throw OAuthAuthorizationError.protectedResourceMismatch(
                expected: expected.absoluteString,
                actual: actual.absoluteString
            )
        }
    }

    private func resolveAuthorizationServerMetadata(
        metadata: OAuthProtectedResourceMetadata,
        session: URLSession
    ) async throws -> OAuthAuthorizationServerMetadata {
        if let cached = authorizationServerMetadata {
            return cached
        }

        let candidates: [URL]
        if let override = configuration.endpointOverrides.authorizationServerURL {
            try urlValidator.validateAuthorizationServer(
                override, context: "Authorization server issuer")
            candidates = [override]
        } else if let selected = selectedAuthorizationServer {
            candidates = [selected]
        } else {
            // A jwt-bearer assertion goes to a server the MCP server names
            // only after the opt-in: fail before any request to one.
            if configuration.grantType == .jwtBearer, configuration.endpointOverrides.tokenEndpoint == nil,
                !configuration.allowsDiscoveredAuthorizationServer
            {
                throw OAuthAuthorizationError.authorizationServerNotConfigured
            }
            guard !metadata.authorizationServers.isEmpty else {
                throw OAuthAuthorizationError.missingAuthorizationServer
            }
            candidates = metadata.authorizationServers
        }

        // The issuer of a jwt-bearer server is checked even when configured:
        // it is the audience of the assertion (RFC 7523 §3), and the ID-JAG
        // draft (§9.5) forbids metadata whose issuer differs (RFC 8414 §3.3).
        let trustedIssuer =
            configuration.grantType == .jwtBearer ? nil : configuration.endpointOverrides.authorizationServerURL
        let server: URL
        let asMetadata: OAuthAuthorizationServerMetadata
        do {
            (server, asMetadata) = try await discoveryClient.fetchAuthorizationServerMetadata(
                candidates: candidates, trustedIssuer: trustedIssuer, session: session)
        } catch OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed
            where metadata.isFallback && configuration.endpointOverrides.authorizationServerURL == nil
                // The jwt-bearer grant postdates 2025-03-26.
                && configuration.grantType != .jwtBearer
        {
            // 2025-03-26: a server without metadata serves the endpoints at its root.
            guard let origin = candidates.first else { throw OAuthAuthorizationError.missingAuthorizationServer }
            (server, asMetadata) = (origin, .defaultEndpoints(issuer: origin))
        }
        if let previous = selectedAuthorizationServer, !authorizationServersMatch(previous, server) {
            tokenStorage.clear()
        }
        self.selectedAuthorizationServer = server
        self.authorizationServerMetadata = asMetadata
        return asMetadata
    }

    // MARK: - Token Acquisition

    private func acquireToken(
        endpoint: URL,
        metadata: OAuthProtectedResourceMetadata,
        requestedScopes: Set<String>?,
        session: URLSession
    ) async throws {
        let asMetadata = try await resolveAuthorizationServerMetadata(
            metadata: metadata, session: session)
        try checkDPoPSupport(metadata: metadata, asMetadata: asMetadata)
        try await maybeRegisterClient(asMetadata: asMetadata, session: session)
        let resource = try canonicalResource(for: endpoint)

        switch configuration.grantType {
        case .clientCredentials:
            try await acquireTokenViaClientCredentials(
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMetadata,
                session: session
            )
        case .authorizationCode:
            try await acquireTokenViaAuthorizationCode(
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMetadata,
                session: session
            )
        case .jwtBearer:
            try await acquireTokenViaJWTBearer(
                resource: resource,
                requestedScopes: requestedScopes,
                asMetadata: asMetadata,
                session: session
            )
        }
    }

    /// RFC 7523 §2.1: presents the provider's JWT. A failed request throws:
    /// the grant is not retried and no other grant is tried.
    private func acquireTokenViaJWTBearer(
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        guard let assertionProvider = configuration.assertionProvider else {
            throw OAuthAuthorizationError.assertionProviderMissing
        }
        let overrides = configuration.endpointOverrides
        let pinned = overrides.authorizationServerURL != nil || overrides.tokenEndpoint != nil
        guard pinned || configuration.allowsDiscoveredAuthorizationServer else {
            throw OAuthAuthorizationError.authorizationServerNotConfigured
        }
        let tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        guard let audience = asMetadata.issuer ?? selectedAuthorizationServer else {
            throw OAuthAuthorizationError.missingAuthorizationServer
        }
        let assertion = try await assertionProvider(
            OAuthConfiguration.AssertionContext(
                audience: audience, resource: resource, tokenEndpoint: tokenEndpoint,
                requestedScopes: requestedScopes),
            session)
        // A server the MCP server chose gets only an assertion meant for it,
        // which it can tell only from a readable `aud`.
        if !pinned {
            let claimed = Self.audiences(of: assertion) ?? []
            let expected = [audience.absoluteString, tokenEndpoint.absoluteString]
            guard claimed.contains(where: { claim in expected.contains { OAuthIssuer.matches(claim, $0) } }) else {
                throw OAuthAuthorizationError.assertionAudienceMismatch(expected: expected, actual: claimed)
            }
        }

        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.jwtBearer
        bodyParameters[OAuthParameterName.assertion] = assertion
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }
        let decoded = try await tokenEndpointClient.request(
            parameters: &bodyParameters,
            endpoint: tokenEndpoint,
            authentication: configuration.authentication,
            dpop: dpopSigner,
            session: session
        )
        try storeTokenResponse(decoded, requestedScopes: requestedScopes)
    }

    /// The `aud` claim of a JWT (the strings of an array), or `nil` when
    /// `token` is not a JWT with one. A padded payload is read too.
    static func audiences(of token: String) -> [String]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
        while encoded.hasSuffix("=") { encoded.removeLast() }
        guard let payload = Data(base64URLEncoded: encoded),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let single = claims["aud"] as? String { return [single] }
        let strings = (claims["aud"] as? [Any])?.compactMap { $0 as? String } ?? []
        return strings.isEmpty ? nil : strings
    }

    private func acquireTokenViaClientCredentials(
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        let tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.clientCredentials
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }
        let decoded = try await tokenEndpointClient.request(
            parameters: &bodyParameters,
            endpoint: tokenEndpoint,
            authentication: configuration.authentication,
            dpop: dpopSigner,
            session: session
        )
        try storeTokenResponse(decoded, requestedScopes: requestedScopes)
    }

    private func acquireTokenViaAuthorizationCode(
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        guard let authorizationEndpoint = asMetadata.authorizationEndpoint else {
            throw OAuthAuthorizationError.tokenEndpointMissing
        }
        try urlValidator.validateAuthorizationServer(
            authorizationEndpoint, context: "Authorization endpoint")
        if let host = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)?
            .host?.lowercased(), urlValidator.isPrivateIPHost(host)
        {
            throw OAuthAuthorizationError.privateIPAddressBlocked(
                context: "Authorization endpoint",
                url: authorizationEndpoint.absoluteString
            )
        }
        try urlValidator.validateRedirectURI(configuration.authorizationRedirectURI)
        try PKCE.checkSupport(in: asMetadata)

        let verifier = PKCE.makeVerifier()
        let challenge = try PKCE.makeChallenge(from: verifier)
        let state = UUID().uuidString

        let authorizationURL = try authCodeFlow.buildURL(
            authorizationEndpoint: authorizationEndpoint,
            resource: resource,
            redirectURI: configuration.authorizationRedirectURI,
            clientID: configuration.authentication.clientID,
            codeChallenge: challenge,
            scopes: requestedScopes,
            state: state,
            scopeSerializer: scopeSelector
        )

        let issuer = (asMetadata.issuer ?? selectedAuthorizationServer).map {
            OAuthAuthorizationCodeFlow.ExpectedIssuer(
                issuer: $0.absoluteString,
                isRequired: asMetadata.authorizationResponseIssParameterSupported == true)
        }
        let authorizationCode = try await authCodeFlow.perform(
            authorizationURL: authorizationURL,
            redirectURI: configuration.authorizationRedirectURI,
            state: state,
            issuer: issuer,
            delegate: configuration.authorizationDelegate,
            session: session
        )

        let tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.authorizationCode
        bodyParameters[OAuthParameterName.code] = authorizationCode
        bodyParameters[OAuthParameterName.codeVerifier] = verifier
        bodyParameters[OAuthParameterName.redirectURI] =
            configuration.authorizationRedirectURI.absoluteString
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }

        let decoded = try await tokenEndpointClient.request(
            parameters: &bodyParameters,
            endpoint: tokenEndpoint,
            authentication: configuration.authentication,
            dpop: dpopSigner,
            session: session
        )
        try storeTokenResponse(decoded, requestedScopes: requestedScopes)
    }

    /// RFC 9449 §5.1, §5.2: the resource may require DPoP, and the
    /// authorization server must accept ES256 proofs.
    private func checkDPoPSupport(
        metadata: OAuthProtectedResourceMetadata,
        asMetadata: OAuthAuthorizationServerMetadata
    ) throws {
        guard dpopSigner != nil else {
            if metadata.dpopBoundAccessTokensRequired == true {
                throw OAuthAuthorizationError.dpopRequired
            }
            return
        }
        if let algorithms = asMetadata.dpopSigningAlgValuesSupported,
            !algorithms.contains(DPoPProofSigner.algorithm)
        {
            throw OAuthAuthorizationError.dpopAlgorithmUnsupported(supported: algorithms)
        }
    }

    // MARK: - Token Refresh

    /// Refreshes `token` at the selected server, only if that server issued
    /// it. A token without a recorded server is refreshed only at a
    /// configured server or token endpoint. Returns `false` when the refresh
    /// is not possible or the server refuses it.
    private func refreshAccessToken(
        _ token: OAuthAccessToken,
        refreshToken: String,
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> Bool {
        // RFC 9449 §5: a public client presents a DPoP proof of the key the
        // refresh token was obtained with; the authorizer does not hold it.
        guard !isBoundToAnotherKey(token) else { return false }
        if let issuer = token.authorizationServer {
            guard let selectedAuthorizationServer, authorizationServersMatch(issuer, selectedAuthorizationServer)
            else { return false }
        } else {
            let overrides = configuration.endpointOverrides
            guard overrides.authorizationServerURL != nil || overrides.tokenEndpoint != nil else { return false }
        }
        let tokenEndpoint: URL
        do {
            tokenEndpoint = try resolveTokenEndpoint(asMetadata: asMetadata)
        } catch {
            return false
        }

        var bodyParameters: [String: String] = configuration.additionalTokenRequestParameters
        bodyParameters[OAuthParameterName.grantType] = OAuthGrantTypeValue.refreshToken
        bodyParameters[OAuthParameterName.refreshToken] = refreshToken
        bodyParameters[OAuthParameterName.resource] = resource.absoluteString
        if let scope = requestedScopes.flatMap(scopeSelector.serialize) {
            bodyParameters[OAuthParameterName.scope] = scope
        }

        do {
            let decoded = try await tokenEndpointClient.request(
                parameters: &bodyParameters,
                endpoint: tokenEndpoint,
                authentication: configuration.authentication,
                dpop: dpopSigner,
                session: session
            )
            try storeTokenResponse(decoded, requestedScopes: requestedScopes, refreshing: token)
            refreshedTokenValue = decoded.accessToken
            return true
        } catch let error as OAuthAuthorizationError {
            if case .tokenRequestFailed(let statusCode, _) = error,
                (400..<500).contains(statusCode)
            {
                return false
            }
            throw error
        }
    }

    // MARK: - Client Registration

    private func maybeRegisterClient(
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws {
        if let expiry = clientSecretExpiresAt, Date() >= expiry {
            clientSecretExpiresAt = nil
            clientRegistrationAttempted = false
            // Register again: the expired client ID is not reused.
            configuration.authentication = .none(clientID: "")
        }
        // Registered credentials belong to the server that issued them (SEP-2352).
        if let registrationIssuer, let selectedAuthorizationServer,
            !authorizationServersMatch(registrationIssuer, selectedAuthorizationServer)
        {
            self.registrationIssuer = nil
            clientSecretExpiresAt = nil
            clientRegistrationAttempted = false
            configuration.authentication = configuredAuthentication
        } else if clientRegistrationAttempted, registrationIssuer == nil, let selectedAuthorizationServer,
            let attempted = registrationAttemptIssuer,
            !authorizationServersMatch(attempted, selectedAuthorizationServer)
        {
            // Registration was not possible at the previous server; try the new one.
            clientRegistrationAttempted = false
        }

        guard !clientRegistrationAttempted else { return }
        guard case .none = configuration.authentication else { return }
        // The assertion identifies the client: nothing to register.
        guard configuration.grantType != .jwtBearer else { return }

        clientRegistrationAttempted = true
        registrationAttemptIssuer = selectedAuthorizationServer

        let result: (OAuthClientRegistrationResponse, OAuthConfiguration.TokenEndpointAuthentication)?
        do {
            result = try await clientRegistrar.register(
                configuration: configuration,
                asMetadata: asMetadata,
                session: session
            )
        } catch {
            // Registration failed rather than being unavailable: the next flow tries again.
            clientRegistrationAttempted = false
            registrationAttemptIssuer = nil
            throw error
        }
        if let (registration, updatedAuth) = result {
            configuration.authentication = updatedAuth
            registrationIssuer = selectedAuthorizationServer
            if let expiresAt = registration.clientSecretExpiresAt, expiresAt > 0 {
                clientSecretExpiresAt = Date(timeIntervalSince1970: Double(expiresAt))
            }
        }
    }

    // MARK: - State Helpers

    /// Stores a token response. `previous` is the token a refresh replaces.
    /// A Bearer token for a resource whose metadata requires DPoP-bound tokens
    /// is refused with `dpopRequired`, as the resource would reject it.
    private func storeTokenResponse(
        _ decoded: OAuthTokenResponse,
        requestedScopes: Set<String>?,
        refreshing previous: OAuthAccessToken? = nil
    ) throws {
        // A Bearer answer to a DPoP request is a downgrade (RFC 9449 §5): use it as Bearer.
        let boundKey =
            decoded.tokenType.caseInsensitiveCompare(OAuthTokenType.dpop) == .orderedSame
            ? dpopSigner?.thumbprint : nil
        // RFC 9728 §2: such a resource always requires DPoP-bound tokens.
        if boundKey == nil, protectedResourceMetadata?.dpopBoundAccessTokensRequired == true {
            throw OAuthAuthorizationError.dpopRequired
        }
        let scopeSet: Set<String>
        if let scope = decoded.scope {
            scopeSet = scopeSelector.parseScopeString(scope)
        } else {
            // RFC 6749 §5.1, §6: an omitted scope is the one requested, or
            // the one granted before when the refresh named none.
            scopeSet = requestedScopes ?? previous?.scopes ?? []
        }
        let expiresAt = decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        storedTokenLifetime = decoded.expiresIn.map { (decoded.accessToken, TimeInterval($0)) }
        // A stored token is new, even with the value of the one tried.
        proactivelyRenewedToken = nil
        tokenStorage.save(OAuthAccessToken(
            value: decoded.accessToken,
            tokenType: boundKey == nil ? OAuthTokenType.bearer : OAuthTokenType.dpop,
            expiresAt: expiresAt,
            scopes: scopeSet,
            authorizationServer: selectedAuthorizationServer,
            // RFC 6749 §6: without a new refresh token, the old one stays valid.
            refreshToken: decoded.refreshToken ?? previous?.refreshToken,
            clientID: nonEmptyClientID(),
            keyThumbprint: boundKey
        ))
    }

    /// Returns the configured `client_id` or `nil` if the authorizer has not yet been assigned one.
    private func nonEmptyClientID() -> String? {
        let id = configuration.authentication.clientID
        return id.isEmpty ? nil : id
    }

    private func resolveTokenEndpoint(
        asMetadata: OAuthAuthorizationServerMetadata
    ) throws -> URL {
        if let configuredEndpoint = configuration.endpointOverrides.tokenEndpoint {
            try urlValidator.validateAuthorizationServer(
                configuredEndpoint, context: "Configured token endpoint")
            return configuredEndpoint
        }

        guard let tokenEndpoint = asMetadata.tokenEndpoint else {
            throw OAuthAuthorizationError.tokenEndpointMissing
        }
        try urlValidator.validateAuthorizationServer(tokenEndpoint, context: "Token endpoint")
        if let host = URLComponents(url: tokenEndpoint, resolvingAgainstBaseURL: false)?.host?
            .lowercased(), urlValidator.isPrivateIPHost(host)
        {
            throw OAuthAuthorizationError.privateIPAddressBlocked(
                context: "Token endpoint",
                url: tokenEndpoint.absoluteString
            )
        }
        return tokenEndpoint
    }

    private func canonicalResource(for endpoint: URL) throws -> URL {
        let endpointCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
            from: endpoint)

        if let configuredResource = configuration.endpointOverrides.resource {
            let configuredCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
                from: configuredResource)
            guard discoveryClient.metadataDiscovery.protectedResourceMatches(
                resource: configuredCanonical, endpoint: endpointCanonical)
            else {
                throw OAuthAuthorizationError.protectedResourceMismatch(
                    expected: endpointCanonical.absoluteString,
                    actual: configuredCanonical.absoluteString
                )
            }
            return configuredCanonical
        }

        if let prmResourceString = protectedResourceMetadata?.resource,
            let prmResourceURL = URL(string: prmResourceString)
        {
            let prmCanonical = try discoveryClient.metadataDiscovery.canonicalResourceURI(
                from: prmResourceURL)
            guard discoveryClient.metadataDiscovery.protectedResourceMatches(
                resource: prmCanonical, endpoint: endpointCanonical)
            else {
                throw OAuthAuthorizationError.protectedResourceMismatch(
                    expected: endpointCanonical.absoluteString,
                    actual: prmCanonical.absoluteString
                )
            }
            return prmCanonical
        }

        return endpointCanonical
    }

    private func authorizationServersMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedAuthorizationServer(lhs) == normalizedAuthorizationServer(rhs)
    }

    private func normalizedAuthorizationServer(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            scheme == OAuthURLScheme.http || scheme == OAuthURLScheme.https
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url
    }

    // MARK: - External Token Provider

    private func fetchAccessTokenFromProvider(
        context: OAuthConfiguration.AccessTokenProviderContext,
        session: URLSession
    ) async throws -> String? {
        guard let provider = configuration.accessTokenProvider else { return nil }
        guard let token = try await provider(context, session), !token.isEmpty else { return nil }
        return token
    }

    private func storeExternalAccessToken(
        _ token: String,
        requestedScopes: Set<String>?,
        authorizationServer: URL?
    ) {
        proactivelyRenewedToken = nil
        tokenStorage.save(OAuthAccessToken(
            value: token,
            tokenType: OAuthTokenType.bearer,
            expiresAt: nil,
            scopes: requestedScopes ?? [],
            authorizationServer: authorizationServer,
            refreshToken: nil,
            clientID: nonEmptyClientID()
        ))
    }

    private func makeAccessTokenProviderContext(
        statusCode: Int,
        endpoint: URL,
        challenge: OAuthBearerChallenge?,
        metadata: OAuthProtectedResourceMetadata,
        requestedScopes: Set<String>?,
        session: URLSession
    ) async throws -> OAuthConfiguration.AccessTokenProviderContext {
        // A grant that cannot run fails before the authorization server is asked.
        if configuration.grantType == .jwtBearer, configuration.assertionProvider == nil,
            configuration.accessTokenProvider == nil
        {
            throw OAuthAuthorizationError.assertionProviderMissing
        }
        let asMetadata = try await resolveAuthorizationServerMetadata(
            metadata: metadata, session: session)
        let resource = try canonicalResource(for: endpoint)
        let authorizationServer = configuration.endpointOverrides.authorizationServerURL
            ?? selectedAuthorizationServer
            ?? metadata.authorizationServers.first
        let tokenEndpoint = configuration.endpointOverrides.tokenEndpoint ?? asMetadata.tokenEndpoint

        return OAuthConfiguration.AccessTokenProviderContext(
            statusCode: statusCode,
            endpoint: endpoint,
            resource: resource,
            authorizationServer: authorizationServer,
            authorizationEndpoint: asMetadata.authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: asMetadata.registrationEndpoint,
            challengedScope: challenge?.scope,
            scopesSupported: metadata.scopesSupported,
            requestedScopes: requestedScopes
        )
    }

    private func normalizedOperationKey(_ operationKey: String?) -> String {
        guard let operationKey else { return "<unknown>" }
        let normalized = operationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "<unknown>" : normalized
    }
}

/// Runs async operations one at a time, in arrival order. A waiting task
/// that is cancelled stops waiting and throws `CancellationError`.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var nextWaiter = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []

    /// The number of tasks waiting for the gate.
    var waiterCount: Int { lock.withLock { waiters.count } }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        let id: Int? = lock.withLock {
            if busy {
                nextWaiter += 1
                return nextWaiter
            }
            busy = true
            return nil
        }
        guard let id else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Result<Void, any Error>? = lock.withLock {
                    // Checked under the lock: a cancellation either finds
                    // this waiter or is seen here.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if busy {
                        waiters.append((id, continuation))
                        return nil
                    }
                    busy = true
                    return .success(())
                }
                if let resumeNow { continuation.resume(with: resumeNow) }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, any Error>? = lock.withLock {
            if waiters.isEmpty {
                busy = false
                return nil
            }
            return waiters.removeFirst().continuation
        }
        next?.resume()
    }
}
