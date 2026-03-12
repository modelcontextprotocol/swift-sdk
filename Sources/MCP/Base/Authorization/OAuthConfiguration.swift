import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Configuration for OAuth 2.1 authorization used by ``HTTPClientTransport``.
///
/// Authorization is optional and disabled by default. Configure this type and pass it
/// to `HTTPClientTransport(oauth:)` to enable automatic Bearer token acquisition for HTTP
/// transports.
///
/// Supports both `authorization_code` (interactive, browser-based) and `client_credentials`
/// (machine-to-machine) grant types via the ``grantType`` property.
public struct OAuthConfiguration: Sendable {
    /// The OAuth 2.1 grant type to use for token acquisition.
    public enum GrantType: Sendable {
        /// OAuth 2.1 authorization_code flow with PKCE.
        case authorizationCode

        /// OAuth 2.1 client_credentials flow.
        case clientCredentials
    }

    /// How the client authenticates to the OAuth token endpoint.
    public enum TokenEndpointAuthentication: Sendable, Equatable {
        /// `client_secret_basic` authentication using the Authorization header.
        case clientSecretBasic(clientID: String, clientSecret: String)

        /// `client_secret_post` authentication using form parameters.
        case clientSecretPost(clientID: String, clientSecret: String)

        /// Public client authentication (`token_endpoint_auth_method=none`).
        case none(clientID: String)

        /// `private_key_jwt` authentication.
    ///
    /// The built-in ``OAuthConfiguration/makePrivateKeyJWTAssertion(clientID:tokenEndpoint:privateKeyPEM:signingAlgorithm:audience:issuedAt:expiresIn:)``
    /// helper generates ES256 (P-256 ECDSA) assertions only. To use other algorithms
    /// (e.g., RS256, ES384), provide a custom ``OAuthConfiguration/JWTAssertionFactory`` closure.
        case privateKeyJWT(clientID: String, assertionFactory: JWTAssertionFactory)

        var clientID: String {
            switch self {
            case .clientSecretBasic(let clientID, _), .clientSecretPost(let clientID, _),
                .none(let clientID), .privateKeyJWT(let clientID, _):
                return clientID
            }
        }

        /// The token endpoint auth method name per RFC 7591.
        var methodName: String {
            switch self {
            case .clientSecretBasic: return OAuthTokenEndpointAuthMethod.clientSecretBasic
            case .clientSecretPost: return OAuthTokenEndpointAuthMethod.clientSecretPost
            case .none: return OAuthTokenEndpointAuthMethod.none
            case .privateKeyJWT: return OAuthTokenEndpointAuthMethod.privateKeyJWT
            }
        }

        func apply(
            to request: inout URLRequest,
            bodyParameters: inout [String: String],
            tokenEndpoint: URL
        ) async throws {
            switch self {
            case .clientSecretBasic(let clientID, let clientSecret):
                let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
                request.setValue("Basic \(basic)", forHTTPHeaderField: HTTPHeaderName.authorization)
            case .clientSecretPost(let clientID, let clientSecret):
                bodyParameters[OAuthParameterName.clientID] = clientID
                bodyParameters[OAuthParameterName.clientSecret] = clientSecret
            case .none(let clientID):
                bodyParameters[OAuthParameterName.clientID] = clientID
            case .privateKeyJWT(let clientID, let assertionFactory):
                bodyParameters[OAuthParameterName.clientID] = clientID
                bodyParameters[OAuthParameterName.clientAssertionType] =
                    OAuthClientAssertionType.jwtBearer
                bodyParameters[OAuthParameterName.clientAssertion] =
                    try await assertionFactory(tokenEndpoint, clientID)
            }
        }
    }

    /// Closure used to generate a `private_key_jwt` assertion.
    public typealias JWTAssertionFactory = @Sendable (_ tokenEndpoint: URL, _ clientID: String)
        async throws -> String

    /// Supported signing algorithms for SDK-generated `private_key_jwt` assertions.
    public enum PrivateKeyJWTSigningAlgorithm: String, Sendable {
        case ES256
    }

    /// Errors thrown while creating SDK-generated `private_key_jwt` assertions.
    public enum PrivateKeyJWTAssertionError: LocalizedError, Sendable {
        case invalidLifetime(TimeInterval)
        case cryptographyUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidLifetime(let lifetime):
                return "private_key_jwt assertion lifetime must be greater than zero seconds, got \(lifetime)"
            case .cryptographyUnavailable:
                return "private_key_jwt assertion signing requires CryptoKit support"
            }
        }
    }

    /// Creates a signed `private_key_jwt` client assertion (RFC 7523).
    ///
    /// Use this helper to build a `JWTAssertionFactory` closure when configuring
    /// ``TokenEndpointAuthentication/privateKeyJWT(clientID:assertionFactory:)``:
    ///
    /// ```swift
    /// let factory: OAuthConfiguration.JWTAssertionFactory = { tokenEndpoint, clientID in
    ///     try OAuthConfiguration.makePrivateKeyJWTAssertion(
    ///         clientID: clientID,
    ///         tokenEndpoint: tokenEndpoint,
    ///         privateKeyPEM: myPEMString
    ///     )
    /// }
    /// ```
    ///
    /// The assertion is a compact-serialized JWS signed with the specified private key.
    /// Only ES256 (P-256 ECDSA) is supported by this helper; the algorithm requires CryptoKit.
    /// To use other algorithms, supply a custom ``JWTAssertionFactory`` closure directly to
    /// ``TokenEndpointAuthentication/privateKeyJWT(clientID:assertionFactory:)``.
    ///
    /// - Parameters:
    ///   - clientID: The OAuth client identifier, used as both `iss` and `sub` claims.
    ///   - tokenEndpoint: Token endpoint URL, used as the default `aud` claim.
    ///   - privateKeyPEM: PEM-encoded EC private key for signing.
    ///   - signingAlgorithm: The JWS signing algorithm. Currently only `.ES256` is supported.
    ///   - audience: Explicit `aud` claim override. Defaults to `tokenEndpoint.absoluteString`.
    ///   - issuedAt: The `iat` claim. Defaults to `Date()`.
    ///   - expiresIn: Lifetime of the assertion in seconds. Defaults to 300 (5 minutes). Must be > 0.
    /// - Returns: A compact-serialized JWT string (`header.payload.signature`).
    /// - Throws: ``PrivateKeyJWTAssertionError/invalidLifetime(_:)`` if `expiresIn` ≤ 0,
    ///   or ``PrivateKeyJWTAssertionError/cryptographyUnavailable`` on platforms without CryptoKit.
    public static func makePrivateKeyJWTAssertion(
        clientID: String,
        tokenEndpoint: URL,
        privateKeyPEM: String,
        signingAlgorithm: PrivateKeyJWTSigningAlgorithm = .ES256,
        audience: String? = nil,
        issuedAt: Date = Date(),
        expiresIn: TimeInterval = 300
    ) throws -> String {
        guard expiresIn > 0 else {
            throw PrivateKeyJWTAssertionError.invalidLifetime(expiresIn)
        }

        let header = try JSONSerialization.data(withJSONObject: [
            JWTClaimName.algorithm: signingAlgorithm.rawValue,
            JWTClaimName.type: JWTClaimName.typeValue,
        ])

        let issuedAtUnix = Int(issuedAt.timeIntervalSince1970)
        let lifetimeSeconds = max(1, Int(expiresIn.rounded(.down)))
        let payload = try JSONSerialization.data(withJSONObject: [
            JWTClaimName.issuer: clientID,
            JWTClaimName.subject: clientID,
            JWTClaimName.audience: audience ?? tokenEndpoint.absoluteString,
            JWTClaimName.issuedAt: issuedAtUnix,
            JWTClaimName.expiration: issuedAtUnix + lifetimeSeconds,
            JWTClaimName.jwtID: UUID().uuidString,
        ])

        let signingInput = "\(header.base64URLEncodedString()).\(payload.base64URLEncodedString())"

        #if canImport(CryptoKit)
            switch signingAlgorithm {
            case .ES256:
                let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
                let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
                return "\(signingInput).\(signature.base64URLEncodedString())"
            }
        #else
            throw PrivateKeyJWTAssertionError.cryptographyUnavailable
        #endif
    }

    static func defaultAuthorizationRedirectURI() -> URL {
        let port = Int.random(in: 49152...65535)
        return URL(string: "http://\(OAuthLoopbackHost.ipv4):\(port)/callback")!
    }

    // MARK: - Retry Policy

    /// Controls retry behavior for authorization challenges.
    public struct RetryPolicy: Sendable {
        /// Maximum number of authentication retries for a single MCP request.
        public let maxAuthorizationAttempts: Int

        /// Maximum number of scope step-up attempts for a resource and operation.
        public let maxScopeUpgradeAttempts: Int

        /// Creates a retry policy.
        ///
        /// Both values are clamped to a minimum of `1` to prevent infinite loops
        /// or zero-retry configurations.
        ///
        /// - Parameters:
        ///   - maxAuthorizationAttempts: Maximum authorization retries per request. Defaults to 3.
        ///   - maxScopeUpgradeAttempts: Maximum scope step-up attempts per resource+operation. Defaults to 2.
        public init(
            maxAuthorizationAttempts: Int = 3,
            maxScopeUpgradeAttempts: Int = 2
        ) {
            self.maxAuthorizationAttempts = max(1, maxAuthorizationAttempts)
            self.maxScopeUpgradeAttempts = max(1, maxScopeUpgradeAttempts)
        }

        public static let `default` = RetryPolicy()
    }

    // MARK: - Endpoint Overrides

    /// Optional endpoint overrides for discovery.
    public struct EndpointOverrides: Sendable {
        /// Optional override for the protected resource metadata URL.
        public let protectedResourceMetadataURL: URL?

        /// Optional override for the authorization server issuer URL.
        public let authorizationServerURL: URL?

        /// Optional override for the token endpoint.
        public let tokenEndpoint: URL?

        /// Optional override for the resource indicator used in token requests.
        public let resource: URL?

        public init(
            protectedResourceMetadataURL: URL? = nil,
            authorizationServerURL: URL? = nil,
            tokenEndpoint: URL? = nil,
            resource: URL? = nil
        ) {
            self.protectedResourceMetadataURL = protectedResourceMetadataURL
            self.authorizationServerURL = authorizationServerURL
            self.tokenEndpoint = tokenEndpoint
            self.resource = resource
        }

        public static let none = EndpointOverrides()
    }

    // MARK: - Access Token Provider

    /// Context supplied to ``AccessTokenProvider`` after SDK discovery is complete.
    public struct AccessTokenProviderContext: Sendable {
        /// HTTP status code that triggered authorization handling (typically 401 or 403).
        public let statusCode: Int
        /// Target MCP endpoint URL.
        public let endpoint: URL
        /// Canonical RFC8707 resource URI for token audience binding.
        public let resource: URL
        /// Selected authorization server issuer URL, if discovered.
        public let authorizationServer: URL?
        /// Authorization endpoint from AS metadata, if available.
        public let authorizationEndpoint: URL?
        /// Token endpoint from AS metadata (or configuration override), if available.
        public let tokenEndpoint: URL?
        /// Dynamic registration endpoint from AS metadata, if available.
        public let registrationEndpoint: URL?
        /// `scope` value from the latest challenge header, when present.
        public let challengedScope: String?
        /// `scopes_supported` from protected resource metadata, when present.
        public let scopesSupported: [String]?
        /// Scope set selected by SDK for the pending authorization attempt.
        public let requestedScopes: Set<String>?

        public init(
            statusCode: Int,
            endpoint: URL,
            resource: URL,
            authorizationServer: URL?,
            authorizationEndpoint: URL?,
            tokenEndpoint: URL?,
            registrationEndpoint: URL?,
            challengedScope: String?,
            scopesSupported: [String]?,
            requestedScopes: Set<String>?
        ) {
            self.statusCode = statusCode
            self.endpoint = endpoint
            self.resource = resource
            self.authorizationServer = authorizationServer
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.registrationEndpoint = registrationEndpoint
            self.challengedScope = challengedScope
            self.scopesSupported = scopesSupported
            self.requestedScopes = requestedScopes
        }
    }

    /// Optional provider for externally acquired access tokens.
    public typealias AccessTokenProvider = @Sendable (
        _ context: AccessTokenProviderContext,
        _ session: URLSession
    ) async throws -> String?

    // MARK: - Properties

    /// The grant type used for token acquisition.
    public let grantType: GrantType

    /// The configured token endpoint authentication method.
    public var authentication: TokenEndpointAuthentication

    /// Controls retry behavior for authorization challenges.
    public let retryPolicy: RetryPolicy

    /// Optional endpoint overrides for discovery.
    public let endpointOverrides: EndpointOverrides

    /// Package-scoped compatibility option for local environments.
    package var allowLoopbackHTTPAuthorizationServerEndpoints: Bool

    /// Redirect URI used for authorization requests.
    public let authorizationRedirectURI: URL

    /// Additional form fields to include in token requests.
    public let additionalTokenRequestParameters: [String: String]

    /// The `client_name` sent during dynamic client registration (RFC 7591).
    /// Defaults to `"mcp-swift-sdk"`. Override with your application's name.
    public let clientName: String

    /// Optional provider for externally acquired access tokens.
    public let accessTokenProvider: AccessTokenProvider?

    /// Optional delegate for browser-based authorization code flows.
    public let authorizationDelegate: (any OAuthAuthorizationDelegate)?

    /// How many seconds before token expiry ``OAuthAuthorizer`` proactively refreshes a token
    /// when `prepareAuthorization(for:session:)` is called.
    ///
    /// Set to `0` to disable proactive refresh. Defaults to 60 seconds.
    /// Must be greater than ``OAuthTokenExpirySkew/defaultSeconds`` (30 s) to have any effect,
    /// since tokens within the default skew window are already treated as expired.
    public let proactiveRefreshWindowSeconds: TimeInterval

    /// Creates an OAuth configuration.
    ///
    /// - Parameters:
    ///   - grantType: The OAuth 2.1 grant type. Defaults to `.clientCredentials`.
    ///   - authentication: How the client authenticates to the token endpoint. **Required.**
    ///   - retryPolicy: Controls how many retries are allowed for authorization challenges.
    ///   - endpointOverrides: Optional URL overrides that bypass automatic discovery.
    ///   - authorizationRedirectURI: Redirect URI for the `authorization_code` flow.
    ///     Defaults to a random loopback URI (`http://127.0.0.1:<port>/callback`).
    ///   - clientName: The `client_name` sent during dynamic client registration. Defaults to `"mcp-swift-sdk"`.
    ///   - additionalTokenRequestParameters: Extra form fields appended to every token request.
    ///   - accessTokenProvider: Optional closure invoked after discovery, allowing the host app
    ///     to supply an externally acquired token (e.g., from a system credential store).
    ///   - authorizationDelegate: Optional delegate that presents the authorization URL to the
    ///     user for interactive `authorization_code` flows.
    ///   - proactiveRefreshWindowSeconds: Seconds before expiry at which a token is proactively
    ///     refreshed. Defaults to 60. Set to 0 to disable proactive refresh.
    public init(
        grantType: GrantType = .clientCredentials,
        authentication: TokenEndpointAuthentication,
        retryPolicy: RetryPolicy = .default,
        endpointOverrides: EndpointOverrides = .none,
        authorizationRedirectURI: URL? = nil,
        clientName: String = "mcp-swift-sdk",
        additionalTokenRequestParameters: [String: String] = [:],
        accessTokenProvider: AccessTokenProvider? = nil,
        authorizationDelegate: (any OAuthAuthorizationDelegate)? = nil,
        proactiveRefreshWindowSeconds: TimeInterval = 60
    ) {
        self.grantType = grantType
        self.authentication = authentication
        self.retryPolicy = retryPolicy
        self.endpointOverrides = endpointOverrides
        self.allowLoopbackHTTPAuthorizationServerEndpoints = false
        self.authorizationRedirectURI =
            authorizationRedirectURI ?? Self.defaultAuthorizationRedirectURI()
        self.clientName = clientName
        self.additionalTokenRequestParameters = additionalTokenRequestParameters
        self.accessTokenProvider = accessTokenProvider
        self.authorizationDelegate = authorizationDelegate
        self.proactiveRefreshWindowSeconds = proactiveRefreshWindowSeconds
    }
}

extension OAuthConfiguration.TokenEndpointAuthentication {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.clientSecretBasic(let li, let ls), .clientSecretBasic(let ri, let rs)):
            return li == ri && ls == rs
        case (.clientSecretPost(let li, let ls), .clientSecretPost(let ri, let rs)):
            return li == ri && ls == rs
        case (.none(let li), .none(let ri)):
            return li == ri
        case (.privateKeyJWT(let li, _), .privateKeyJWT(let ri, _)):
            return li == ri
        default:
            return false
        }
    }
}

/// Delegate that handles user-facing authorization steps for the authorization_code flow.
public protocol OAuthAuthorizationDelegate: Sendable {
    /// Presents the authorization URL to the user and returns the redirect URL containing
    /// the authorization code.
    func presentAuthorizationURL(_ url: URL) async throws -> URL
}
