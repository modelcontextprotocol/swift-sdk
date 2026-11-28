import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import Crypto

/// Configuration for OAuth 2.1 authorization used by ``HTTPClientTransport``.
///
/// Authorization is optional and disabled by default. Pass an
/// `OAuthAuthorizer(configuration:)` to `HTTPClientTransport(endpoint:authorizer:)` to
/// enable automatic Bearer token acquisition.
///
/// Supports the `authorization_code` (interactive, browser-based), `client_credentials`
/// (machine-to-machine) and RFC 7523 `jwt-bearer` grant types via the ``grantType`` property.
public struct OAuthConfiguration: Sendable {
    /// The OAuth 2.1 grant type to use for token acquisition.
    ///
    /// New grant types can appear in a minor release, so a `switch` needs a `default`.
    public struct GrantType: Hashable, Sendable, CustomStringConvertible {
        /// The `grant_type` value of the token request.
        public let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// OAuth 2.1 authorization_code flow with PKCE.
        public static let authorizationCode = GrantType(rawValue: OAuthGrantTypeValue.authorizationCode)

        /// OAuth 2.1 client_credentials flow.
        public static let clientCredentials = GrantType(rawValue: OAuthGrantTypeValue.clientCredentials)

        /// RFC 7523 JWT bearer grant (`urn:ietf:params:oauth:grant-type:jwt-bearer`).
        ///
        /// The token request presents the JWT that ``OAuthConfiguration/assertionProvider``
        /// returns: an identity assertion (ID-JAG) for enterprise-managed authorization
        /// (SEP-990), or a workload identity token (SEP-1933). No client registration
        /// happens.
        public static let jwtBearer = GrantType(rawValue: OAuthGrantTypeValue.jwtBearer)
    }

    /// How the client authenticates to the OAuth token endpoint.
    ///
    /// Create one with a static member, such as
    /// ``clientSecretBasic(clientID:clientSecret:)``. New methods can appear in a minor
    /// release.
    public struct TokenEndpointAuthentication: Sendable, Equatable {
        enum Method: Sendable {
            case clientSecretBasic(clientSecret: String)
            case clientSecretPost(clientSecret: String)
            case none
            case privateKeyJWT(JWTAssertionFactory)
        }

        /// The client ID.
        public let clientID: String

        let method: Method

        init(clientID: String, method: Method) {
            self.clientID = clientID
            self.method = method
        }

        /// `client_secret_basic` authentication using the Authorization header.
        public static func clientSecretBasic(clientID: String, clientSecret: String) -> Self {
            Self(clientID: clientID, method: .clientSecretBasic(clientSecret: clientSecret))
        }

        /// `client_secret_post` authentication using form parameters.
        public static func clientSecretPost(clientID: String, clientSecret: String) -> Self {
            Self(clientID: clientID, method: .clientSecretPost(clientSecret: clientSecret))
        }

        /// Public client authentication (`token_endpoint_auth_method=none`). An empty client
        /// ID asks for dynamic client registration.
        public static func none(clientID: String) -> Self {
            Self(clientID: clientID, method: .none)
        }

        /// `private_key_jwt` authentication.
        ///
        /// The built-in ``OAuthConfiguration/makePrivateKeyJWTAssertion(clientID:tokenEndpoint:privateKeyPEM:signingAlgorithm:audience:issuedAt:expiresIn:)``
        /// helper generates ES256 (P-256 ECDSA) assertions only. To use other algorithms
        /// (e.g., RS256, ES384), provide a custom ``OAuthConfiguration/JWTAssertionFactory`` closure.
        public static func privateKeyJWT(clientID: String, assertionFactory: @escaping JWTAssertionFactory) -> Self {
            Self(clientID: clientID, method: .privateKeyJWT(assertionFactory))
        }

        /// The `token_endpoint_auth_method` (RFC 7591), for example `client_secret_basic`.
        public var methodName: String {
            switch method {
            case .clientSecretBasic: return OAuthTokenEndpointAuthMethod.clientSecretBasic
            case .clientSecretPost: return OAuthTokenEndpointAuthMethod.clientSecretPost
            case .none: return OAuthTokenEndpointAuthMethod.none
            case .privateKeyJWT: return OAuthTokenEndpointAuthMethod.privateKeyJWT
            }
        }

        /// The same method for another client ID, and another secret when one is given.
        func registered(clientID: String, clientSecret: String?) -> Self {
            switch method {
            case .clientSecretBasic(let current):
                return .clientSecretBasic(clientID: clientID, clientSecret: clientSecret ?? current)
            case .clientSecretPost(let current):
                return .clientSecretPost(clientID: clientID, clientSecret: clientSecret ?? current)
            case .none, .privateKeyJWT:
                return Self(clientID: clientID, method: method)
            }
        }

        func apply(
            to request: inout URLRequest,
            bodyParameters: inout [String: String],
            tokenEndpoint: URL
        ) async throws {
            switch method {
            case .clientSecretBasic(let clientSecret):
                // RFC 6749 §2.3.1: percent-encode client_id and client_secret with
                // application/x-www-form-urlencoded before concatenation.
                let encodedID = clientID.rfc6749PercentEncoded()
                let encodedSecret = clientSecret.rfc6749PercentEncoded()
                let basic = Data("\(encodedID):\(encodedSecret)".utf8).base64EncodedString()
                request.setValue("Basic \(basic)", forHTTPHeaderField: HTTPHeaderName.authorization)
            case .clientSecretPost(let clientSecret):
                bodyParameters[OAuthParameterName.clientID] = clientID
                bodyParameters[OAuthParameterName.clientSecret] = clientSecret
            case .none:
                // An empty ID asks for registration; it is not sent.
                if !clientID.isEmpty {
                    bodyParameters[OAuthParameterName.clientID] = clientID
                }
            case .privateKeyJWT(let assertionFactory):
                bodyParameters[OAuthParameterName.clientID] = clientID
                bodyParameters[OAuthParameterName.clientAssertionType] =
                    OAuthClientAssertionType.jwtBearer
                bodyParameters[OAuthParameterName.clientAssertion] =
                    try await assertionFactory(tokenEndpoint, clientID)
            }
        }

        /// Whether both use the same method, client ID and secret. Two `private_key_jwt`
        /// values with the same client ID are equal: closures cannot be compared.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.clientID == rhs.clientID else { return false }
            switch (lhs.method, rhs.method) {
            case (.clientSecretBasic(let l), .clientSecretBasic(let r)), (.clientSecretPost(let l), .clientSecretPost(let r)):
                return l == r
            case (.none, .none), (.privateKeyJWT, .privateKeyJWT):
                return true
            default:
                return false
            }
        }
    }

    /// Closure used to generate a `private_key_jwt` assertion.
    public typealias JWTAssertionFactory = @Sendable (_ tokenEndpoint: URL, _ clientID: String)
        async throws -> String

    /// Supported signing algorithms for SDK-generated `private_key_jwt` assertions.
    ///
    /// New algorithms can appear in a minor release.
    public struct PrivateKeyJWTSigningAlgorithm: Hashable, Sendable, CustomStringConvertible {
        /// The JWS `alg` value.
        public let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// ECDSA with P-256 and SHA-256.
        public static let ES256 = PrivateKeyJWTSigningAlgorithm(rawValue: "ES256")
    }

    /// Errors thrown while creating SDK-generated `private_key_jwt` assertions.
    ///
    /// Frozen: no case is added in 1.x (the two ways the helper can fail).
    public enum PrivateKeyJWTAssertionError: LocalizedError, Sendable {
        /// The requested lifetime, in seconds, is not greater than zero.
        case invalidLifetime(TimeInterval)
        /// Not thrown: signing uses swift-crypto on every platform.
        case cryptographyUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidLifetime(let lifetime):
                return "private_key_jwt assertion lifetime must be greater than zero seconds, got \(lifetime)"
            case .cryptographyUnavailable:
                return "private_key_jwt assertion signing is unavailable"
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
    /// Only ES256 (P-256 ECDSA) is supported by this helper.
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
    ///   or the error of `P256.Signing.PrivateKey(pemRepresentation:)` for an invalid key.
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

        // ES256 is the only algorithm: the initializer is internal.
        precondition(signingAlgorithm == .ES256, "Unsupported signing algorithm \(signingAlgorithm)")
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(signature.base64URLEncodedString())"
    }

    /// Returns a loopback redirect URI with a random ephemeral port.
    ///
    /// - Warning: The random port is selected from the ephemeral range (49152–65535) but is
    ///   not bound immediately. Between URI generation and the callback server binding the
    ///   port, another process could claim the same port and intercept the authorization code.
    ///   For production deployments, prefer a fixed port or platform-specific custom URL scheme.
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

        /// The default policy: 3 authorization attempts and 2 scope step-up attempts.
        public static let `default` = RetryPolicy()
    }

    // MARK: - Endpoint Overrides

    /// Optional endpoint overrides for discovery.
    public struct EndpointOverrides: Sendable {
        /// Optional override for the protected resource metadata URL.
        public let protectedResourceMetadataURL: URL?

        /// Optional override for the authorization server issuer URL.
        ///
        /// Its metadata is used whatever `issuer` it names, except with the
        /// ``GrantType/jwtBearer`` grant: the issuer is the audience of the
        /// assertion, so it must be this URL (RFC 8414 §3.3), or the grant
        /// fails with
        /// ``OAuthAuthorizationError/authorizationServerIssuerMismatch(expected:actual:)``.
        public let authorizationServerURL: URL?

        /// Optional override for the token endpoint.
        ///
        /// Token requests, and with them the assertion of the
        /// ``GrantType/jwtBearer`` grant and the client credentials, go only
        /// here. The authorization server is still discovered from the
        /// protected resource metadata unless ``authorizationServerURL`` is
        /// set, and its issuer is the
        /// ``AssertionContext/audience`` the assertion provider is asked for;
        /// set ``authorizationServerURL`` too to fix both.
        public let tokenEndpoint: URL?

        /// Optional override for the resource indicator used in token requests.
        public let resource: URL?

        /// Creates endpoint overrides. A `nil` value is not overridden.
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

        /// No overrides.
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

        /// Creates an access token provider context.
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
    ///
    /// The provider runs while the authorizer handles a challenge, and other
    /// challenges of the transport wait for it: it must not send requests
    /// through the transport it authorizes.
    public typealias AccessTokenProvider = @Sendable (
        _ context: AccessTokenProviderContext,
        _ session: URLSession
    ) async throws -> String?

    // MARK: - JWT Bearer Assertions

    /// What ``AssertionProvider`` knows when a ``GrantType/jwtBearer`` token
    /// request is about to be sent.
    public struct AssertionContext: Sendable {
        /// The issuer of the authorization server: the audience of the assertion.
        public let audience: URL
        /// The canonical RFC 8707 resource URI of the MCP server.
        public let resource: URL
        /// The token endpoint the assertion is sent to.
        public let tokenEndpoint: URL
        /// The scopes the token request asks for, if any.
        public let requestedScopes: Set<String>?

        /// Creates an assertion context.
        public init(audience: URL, resource: URL, tokenEndpoint: URL, requestedScopes: Set<String>?) {
            self.audience = audience
            self.resource = resource
            self.tokenEndpoint = tokenEndpoint
            self.requestedScopes = requestedScopes
        }
    }

    /// Returns the JWT presented by a ``GrantType/jwtBearer`` token request.
    ///
    /// Called for every token request; return a fresh assertion each time.
    /// An error thrown here fails the authorization attempt.
    public typealias AssertionProvider = @Sendable (
        _ context: AssertionContext,
        _ session: URLSession
    ) async throws -> String

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

    /// The OpenID Connect `application_type` sent during dynamic client
    /// registration (SEP-837).
    ///
    /// Frozen: no case is added in 1.x (OpenID Connect Dynamic Registration defines `native` and `web`).
    public enum ApplicationType: String, Hashable, Sendable {
        /// An app on the user's device: loopback or custom-scheme redirects.
        case native
        /// A web-hosted client: `https` redirects on a non-loopback host.
        case web
    }

    /// The `application_type` sent during dynamic client registration.
    /// `nil` infers it: `web` for the authorization code grant with an
    /// `https` redirect URI on a non-loopback host, otherwise `native`.
    public let applicationType: ApplicationType?

    /// The `application_type` to register with.
    var registrationApplicationType: ApplicationType {
        if let applicationType { return applicationType }
        guard grantType == .authorizationCode,
            authorizationRedirectURI.scheme?.lowercased() == OAuthURLScheme.https,
            let host = authorizationRedirectURI.host?.lowercased(),
            !OAuthLoopbackHost.isLoopback(host)
        else { return .native }
        return .web
    }

    /// Optional provider for externally acquired access tokens.
    public let accessTokenProvider: AccessTokenProvider?

    /// The assertion source of the ``GrantType/jwtBearer`` grant. Required for
    /// that grant, ignored by the others.
    public let assertionProvider: AssertionProvider?

    /// For the ``GrantType/jwtBearer`` grant, whether the authorization server
    /// named in the MCP server's metadata may receive the assertion.
    ///
    /// Off by default: the assertion goes only to
    /// ``EndpointOverrides/authorizationServerURL`` or
    /// ``EndpointOverrides/tokenEndpoint``, and the grant fails with
    /// ``OAuthAuthorizationError/authorizationServerNotConfigured`` without
    /// them. When on, the MCP server chooses where the assertion goes; an
    /// assertion whose `aud` is neither that server's issuer nor its token
    /// endpoint is not sent, and neither is one that is not a JWT with an
    /// `aud` claim.
    public let allowsDiscoveredAuthorizationServer: Bool

    /// Sender-constrained tokens (RFC 9449). `nil` uses Bearer tokens.
    /// Tokens from ``accessTokenProvider`` are always used as Bearer tokens.
    public var dpop: DPoP?

    /// Optional delegate for browser-based authorization code flows.
    public let authorizationDelegate: (any OAuthAuthorizationDelegate)?

    /// How many seconds before token expiry ``OAuthAuthorizer`` proactively refreshes a token
    /// when `prepareAuthorization(for:session:)` is called.
    ///
    /// Set to `0` to disable proactive refresh. Defaults to 60 seconds. A token
    /// issued with a shorter lifetime is refreshed halfway between its issue
    /// and ``OAuthTokenExpirySkew/defaultSeconds`` before its expiry, and one
    /// that lives no longer than that skew is not refreshed proactively. Each
    /// token is tried once: when the refresh fails, the next 401 recovers.
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
    ///   - applicationType: The `application_type` sent during dynamic client registration
    ///     (SEP-837). `nil` infers it from the redirect URI.
    ///   - additionalTokenRequestParameters: Extra form fields appended to every token request.
    ///   - accessTokenProvider: Optional closure invoked after discovery, allowing the host app
    ///     to supply an externally acquired token (e.g., from a system credential store).
    ///   - assertionProvider: The JWT source of the `.jwtBearer` grant.
    ///   - dpop: Sender-constrained tokens with DPoP. `nil` uses Bearer tokens.
    ///   - authorizationDelegate: Optional delegate that presents the authorization URL to the
    ///     user for interactive `authorization_code` flows.
    ///   - proactiveRefreshWindowSeconds: Seconds before expiry at which a token is proactively
    ///     refreshed. Defaults to 60. Set to 0 to disable proactive refresh.
    ///   - allowsDiscoveredAuthorizationServer: Whether the `.jwtBearer` grant may send its
    ///     assertion to the authorization server named in the MCP server's metadata.
    public init(
        grantType: GrantType = .clientCredentials,
        authentication: TokenEndpointAuthentication,
        retryPolicy: RetryPolicy = .default,
        endpointOverrides: EndpointOverrides = .none,
        authorizationRedirectURI: URL? = nil,
        clientName: String = "mcp-swift-sdk",
        applicationType: ApplicationType? = nil,
        additionalTokenRequestParameters: [String: String] = [:],
        accessTokenProvider: AccessTokenProvider? = nil,
        assertionProvider: AssertionProvider? = nil,
        dpop: DPoP? = nil,
        authorizationDelegate: (any OAuthAuthorizationDelegate)? = nil,
        proactiveRefreshWindowSeconds: TimeInterval = 60,
        allowsDiscoveredAuthorizationServer: Bool = false
    ) {
        self.assertionProvider = assertionProvider
        self.allowsDiscoveredAuthorizationServer = allowsDiscoveredAuthorizationServer
        self.dpop = dpop
        self.grantType = grantType
        self.authentication = authentication
        self.retryPolicy = retryPolicy
        self.endpointOverrides = endpointOverrides
        self.allowLoopbackHTTPAuthorizationServerEndpoints = false
        self.authorizationRedirectURI =
            authorizationRedirectURI ?? Self.defaultAuthorizationRedirectURI()
        self.clientName = clientName
        self.applicationType = applicationType
        self.additionalTokenRequestParameters = additionalTokenRequestParameters
        self.accessTokenProvider = accessTokenProvider
        self.authorizationDelegate = authorizationDelegate
        self.proactiveRefreshWindowSeconds = proactiveRefreshWindowSeconds
    }
}

/// Delegate that handles user-facing authorization steps for the authorization_code flow.
public protocol OAuthAuthorizationDelegate: Sendable {
    /// Presents the authorization URL to the user and returns the redirect URL containing
    /// the authorization code.
    ///
    /// The method runs while the authorizer handles a challenge, and other
    /// challenges of the transport wait for it: it must not send requests
    /// through the transport it authorizes. When it throws (for example, the
    /// user cancelled), challenges that waited for it fail with the same error.
    func presentAuthorizationURL(_ url: URL) async throws -> URL
}

// MARK: - RFC 6749 Percent-Encoding

extension String {
    /// Percent-encodes the string per RFC 6749 §2.3.1 (application/x-www-form-urlencoded).
    ///
    /// Only unreserved characters (A-Z, a-z, 0-9, `-`, `.`, `_`, `~`) are left unencoded.
    func rfc6749PercentEncoded() -> String {
        // CharacterSet for RFC 3986 unreserved characters.
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
