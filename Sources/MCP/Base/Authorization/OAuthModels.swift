import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct HTTPAuthenticationChallengeError: Error {
    let statusCode: Int
    let headers: [String: String]
}

/// Parsed representation of a `WWW-Authenticate: Bearer` challenge header.
///
/// Servers return this challenge in `401 Unauthorized` and `403 Forbidden` responses
/// to indicate that a Bearer token is required or that the presented token lacks
/// sufficient scope.
///
/// The ``OAuthWWWAuthenticateParsing`` protocol produces instances of this type.
public struct OAuthBearerChallenge: Sendable {
    /// Raw key-value parameters extracted from the `Bearer` challenge.
    public let parameters: [String: String]

    /// Creates a challenge from raw parsed parameters.
    /// - Parameter parameters: Key-value pairs from the `WWW-Authenticate` header.
    public init(parameters: [String: String]) {
        self.parameters = parameters
    }

    /// The `resource_metadata` parameter, parsed as a URL.
    ///
    /// Points to the server's RFC 9728 Protected Resource Metadata document.
    /// When present, ``OAuthAuthorizer`` uses this URL as the highest-priority
    /// discovery candidate.
    public var resourceMetadataURL: URL? {
        guard let value = parameters["resource_metadata"] else { return nil }
        return URL(string: value)
    }

    /// The `scope` parameter from the Bearer challenge.
    ///
    /// Specifies the scopes required or recommended for this resource.
    /// ``OAuthAuthorizer`` uses this value as the highest-priority scope hint.
    public var scope: String? {
        parameters["scope"]
    }

    /// The `error` parameter from the Bearer challenge (e.g., `"invalid_token"`, `"insufficient_scope"`).
    public var error: String? {
        parameters["error"]
    }

    /// The `error_description` parameter from the Bearer challenge.
    public var errorDescription: String? {
        parameters["error_description"]
    }
}

/// RFC9728 OAuth Protected Resource metadata (client-side, decode-only).
struct OAuthProtectedResourceMetadata: Decodable, Sendable, Equatable {
    let resource: String?
    let authorizationServers: [URL]
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

/// RFC8414/OIDC authorization server metadata.
struct OAuthAuthorizationServerMetadata: Decodable, Sendable, Equatable {
    let issuer: URL?
    let authorizationEndpoint: URL?
    let tokenEndpoint: URL?
    let registrationEndpoint: URL?
    let codeChallengeMethodsSupported: [String]?
    let tokenEndpointAuthMethodsSupported: [String]?
    let clientIDMetadataDocumentSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
    }
}

struct OAuthTokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let scope: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case refreshToken = "refresh_token"
    }
}

struct OAuthTokenErrorResponse: Decodable {
    let error: String
}

/// An OAuth 2.1 access token and its associated metadata.
///
/// Stored by ``TokenStorage`` and produced by ``OAuthAuthorizer`` after a successful
/// token request. Use ``isExpired(now:skewSeconds:)`` to check validity before use.
public struct OAuthAccessToken: Sendable {
    /// The raw bearer token string for use in the `Authorization` header.
    public let value: String

    /// The token type returned by the authorization server (should be `"Bearer"`).
    public let tokenType: String

    /// The UTC date after which the token is considered expired, or `nil` if no expiry was specified.
    public let expiresAt: Date?

    /// The set of OAuth scopes granted with this token.
    public let scopes: Set<String>

    /// The issuer URL of the authorization server that issued this token.
    ///
    /// Used to detect when the active authorization server changes between requests,
    /// triggering a token invalidation.
    public let authorizationServer: URL?

    /// The refresh token, if the authorization server issued one alongside the access token.
    public let refreshToken: String?

    /// Creates a new access token record.
    public init(
        value: String,
        tokenType: String,
        expiresAt: Date?,
        scopes: Set<String>,
        authorizationServer: URL?,
        refreshToken: String?
    ) {
        self.value = value
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.authorizationServer = authorizationServer
        self.refreshToken = refreshToken
    }

    /// Returns `true` if the token has expired or will expire within the skew window.
    ///
    /// - Parameters:
    ///   - now: The reference time to compare against. Defaults to `Date()`.
    ///   - skewSeconds: Clock skew buffer in seconds. Defaults to ``OAuthTokenExpirySkew/defaultSeconds`` (30 s).
    ///     Tokens are considered expired when `now + skewSeconds >= expiresAt`.
    /// - Returns: `false` if `expiresAt` is `nil` (no expiry).
    public func isExpired(now: Date = Date(), skewSeconds: TimeInterval = OAuthTokenExpirySkew.defaultSeconds) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(skewSeconds) >= expiresAt
    }
}

/// Token introspection result passed from the caller's token validator to ``BearerTokenValidator``.
///
/// The validator uses this to enforce expiry and audience checks before allowing a request through.
/// Produce an instance in your ``BearerTokenValidator/TokenValidator`` closure after verifying
/// the token's signature and extracting its claims.
public struct BearerTokenInfo: Sendable, Equatable {
    /// Audience values from the token (`aud` JWT claim or introspection response).
    ///
    /// `nil` indicates an opaque token whose audience cannot be inspected;
    /// ``BearerTokenValidator`` skips the audience check in that case.
    public let audience: [String]?

    /// Scopes granted by the token.
    public let scopes: Set<String>?

    /// UTC date after which the token is considered expired.
    ///
    /// `nil` means no expiry information is available and the expiry check is skipped.
    public let expiresAt: Date?

    public init(
        audience: [String]? = nil,
        scopes: Set<String>? = nil,
        expiresAt: Date? = nil
    ) {
        self.audience = audience
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

struct OAuthClientRegistrationResponse: Decodable {
    let clientID: String
    let clientSecret: String?
    let tokenEndpointAuthMethod: String?
    /// Unix timestamp after which `clientSecret` is no longer valid, per RFC 7591 §3.2.
    /// A value of `0` means the secret does not expire.
    let clientSecretExpiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case clientSecretExpiresAt = "client_secret_expires_at"
    }
}

/// Server-side encodable RFC 9728 Protected Resource Metadata.
///
/// Use this type to construct the metadata document that MCP servers **MUST** serve
/// at `/.well-known/oauth-protected-resource` per the MCP authorization specification.
///
/// Pair with ``ProtectedResourceMetadataValidator`` to automatically serve this
/// document in the server's validation pipeline.
public struct OAuthProtectedResourceServerMetadata: Codable, Sendable {
    /// The canonical resource identifier (RFC 8707).
    public let resource: String

    /// One or more authorization server URLs that protect this resource.
    public let authorizationServers: [URL]

    /// The scopes supported by this resource server.
    public let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(
        resource: String,
        authorizationServers: [URL],
        scopesSupported: [String]? = nil
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}
