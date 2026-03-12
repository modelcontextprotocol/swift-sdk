import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
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

    /// Returns the `Authorization` header value to attach to the next request, if a valid token is available.
    ///
    /// - Parameter endpoint: The MCP endpoint being requested.
    /// - Returns: A `"Bearer <token>"` string, or `nil` if no valid token is cached.
    func authorizationHeader(for endpoint: URL) -> String?

    /// Handles an authorization challenge received from the server and attempts to acquire a new token.
    ///
    /// Called by ``HTTPClientTransport`` when a `401` or `403` response is received.
    /// The implementation should attempt to obtain a valid access token and store it
    /// so that a subsequent call to ``authorizationHeader(for:)`` returns the new value.
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
}

extension HTTPClientAuthorizer {
    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {}
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
/// - Important: This type is `@unchecked Sendable`. All mutable state is accessed
///   exclusively through the `HTTPClientTransport` actor, which serializes every call.
///   Do **not** share a single `OAuthAuthorizer` instance across multiple transports —
///   doing so would violate the isolation contract and risk concurrent mutation.
public final class OAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {

    // MARK: - Mutable State

    private var configuration: OAuthConfiguration
    private let tokenStorage: TokenStorage
    private var selectedAuthorizationServer: URL?
    private var protectedResourceMetadata: OAuthProtectedResourceMetadata?
    private var authorizationServerMetadata: OAuthAuthorizationServerMetadata?
    private var cachedProtectedResourceMetadataURL: URL?
    private var stepUpAttempts: [String: Int] = [:]
    private var clientRegistrationAttempted = false
    private var clientSecretExpiresAt: Date?

    // MARK: - Composable Dependencies

    private let scopeSelector: any OAuthScopeSelecting
    private let challengeParser: any OAuthWWWAuthenticateParsing
    private let urlValidator: any OAuthURLValidating
    private let discoveryClient: any OAuthDiscoveryFetching
    private let tokenEndpointClient: any OAuthTokenRequesting
    private let clientRegistrar: any OAuthClientRegistering
    private let authCodeFlow: any OAuthAuthorizationCodeFlowing

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
        self.configuration = configuration
        self.tokenStorage = tokenStorage
        self.scopeSelector = scopeSelector
        self.challengeParser = challengeParser
        self.urlValidator = urlValidator
        self.discoveryClient = discoveryClient
        self.tokenEndpointClient = tokenEndpointClient
        self.clientRegistrar = clientRegistrar
        self.authCodeFlow = authCodeFlow
    }

    // MARK: - HTTPClientAuthorizer

    public var maxAuthorizationAttempts: Int {
        configuration.retryPolicy.maxAuthorizationAttempts
    }

    public func validateEndpointSecurity(for endpoint: URL) throws {
        try urlValidator.validateHTTPSOrLoopback(endpoint, context: "MCP endpoint")
    }

    public func authorizationHeader(for endpoint: URL) -> String? {
        guard let accessToken = tokenStorage.load() else { return nil }
        if let tokenAuthorizationServer = accessToken.authorizationServer,
            let selectedAuthorizationServer,
            !authorizationServersMatch(tokenAuthorizationServer, selectedAuthorizationServer)
        {
            tokenStorage.clear()
            return nil
        }
        if accessToken.isExpired() {
            tokenStorage.clear()
            return nil
        }
        return "\(OAuthTokenType.bearer) \(accessToken.value)"
    }

    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String? = nil,
        session: URLSession
    ) async throws -> Bool {
        try validateEndpointSecurity(for: endpoint)
        let challenge = challengeParser.parseBearer(from: headers)

        switch statusCode {
        case 401:
            if let refreshToken = tokenStorage.load()?.refreshToken {
                tokenStorage.clear()
                let metadata = try await discoverProtectedResourceMetadata(
                    endpoint: endpoint,
                    challenge: challenge,
                    session: session
                )
                let asMetadata = try await resolveAuthorizationServerMetadata(
                    metadata: metadata,
                    session: session
                )
                let resource = try canonicalResource(for: endpoint)
                let requestedScopes = scopeSelector.selectScopes(
                    challengeScope: challenge?.scope,
                    scopesSupported: metadata.scopesSupported
                )
                if try await refreshAccessToken(
                    refreshToken: refreshToken,
                    resource: resource,
                    requestedScopes: requestedScopes,
                    asMetadata: asMetadata,
                    session: session
                ) {
                    return true
                }
            } else {
                tokenStorage.clear()
            }

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
        guard let token = tokenStorage.load() else { return }
        guard !token.isExpired() else { return }
        guard token.isExpired(skewSeconds: configuration.proactiveRefreshWindowSeconds) else {
            return
        }
        guard let refreshToken = token.refreshToken else { return }
        guard let asMeta = authorizationServerMetadata, asMeta.tokenEndpoint != nil else { return }

        let resource: URL
        do {
            resource = try canonicalResource(for: endpoint)
        } catch {
            return
        }

        let requestedScopes = token.scopes.isEmpty ? nil : token.scopes
        _ = try? await refreshAccessToken(
            refreshToken: refreshToken,
            resource: resource,
            requestedScopes: requestedScopes,
            asMetadata: asMeta,
            session: session
        )
    }

    // MARK: - Discovery

    private func discoverProtectedResourceMetadata(
        endpoint: URL,
        challenge: OAuthBearerChallenge?,
        session: URLSession
    ) async throws -> OAuthProtectedResourceMetadata {
        if let protectedResourceMetadata {
            let incomingURL = challenge?.resourceMetadataURL
            if let incomingURL, incomingURL != cachedProtectedResourceMetadataURL {
                self.protectedResourceMetadata = nil
                self.authorizationServerMetadata = nil
                self.selectedAuthorizationServer = nil
                self.cachedProtectedResourceMetadataURL = nil
            } else {
                return protectedResourceMetadata
            }
        }

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

        let metadata = try await discoveryClient.fetchProtectedResourceMetadata(
            candidates: candidates, session: session)
        try validateProtectedResource(metadata: metadata, endpoint: endpoint)

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
            guard !metadata.authorizationServers.isEmpty else {
                throw OAuthAuthorizationError.missingAuthorizationServer
            }
            candidates = metadata.authorizationServers
        }

        let (server, asMetadata) = try await discoveryClient.fetchAuthorizationServerMetadata(
            candidates: candidates, session: session)
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
        }
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
            session: session
        )
        storeTokenResponse(decoded, requestedScopes: requestedScopes)
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

        let authorizationCode = try await authCodeFlow.perform(
            authorizationURL: authorizationURL,
            redirectURI: configuration.authorizationRedirectURI,
            state: state,
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
            session: session
        )
        storeTokenResponse(decoded, requestedScopes: requestedScopes)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(
        refreshToken: String,
        resource: URL,
        requestedScopes: Set<String>?,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> Bool {
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
                session: session
            )
            storeTokenResponse(decoded, requestedScopes: requestedScopes)
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
            configuration.authentication = .none(clientID: configuration.authentication.clientID)
        }

        guard !clientRegistrationAttempted else { return }
        guard case .none = configuration.authentication else { return }

        clientRegistrationAttempted = true

        if let (registration, updatedAuth) = try await clientRegistrar.register(
            configuration: configuration,
            asMetadata: asMetadata,
            session: session
        ) {
            configuration.authentication = updatedAuth
            if let expiresAt = registration.clientSecretExpiresAt, expiresAt > 0 {
                clientSecretExpiresAt = Date(timeIntervalSince1970: Double(expiresAt))
            }
        }
    }

    // MARK: - State Helpers

    private func storeTokenResponse(
        _ decoded: OAuthTokenResponse,
        requestedScopes: Set<String>?
    ) {
        let scopeSet: Set<String>
        if let scope = decoded.scope {
            scopeSet = scopeSelector.parseScopeString(scope)
        } else {
            scopeSet = requestedScopes ?? []
        }
        let expiresAt = decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        tokenStorage.save(OAuthAccessToken(
            value: decoded.accessToken,
            tokenType: OAuthTokenType.bearer,
            expiresAt: expiresAt,
            scopes: scopeSet,
            authorizationServer: selectedAuthorizationServer,
            refreshToken: decoded.refreshToken
        ))
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
        tokenStorage.save(OAuthAccessToken(
            value: token,
            tokenType: OAuthTokenType.bearer,
            expiresAt: nil,
            scopes: requestedScopes ?? [],
            authorizationServer: authorizationServer,
            refreshToken: nil
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
