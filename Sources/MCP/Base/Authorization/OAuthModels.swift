import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct HTTPAuthenticationChallengeError: Error {
    let statusCode: Int
    let headers: [String: String]
}

/// Parsed representation of a `WWW-Authenticate` challenge (`Bearer`, or
/// `DPoP` per RFC 9449 §7.1).
///
/// Servers return this challenge in `401 Unauthorized` and `403 Forbidden` responses
/// to indicate that a token is required or that the presented token lacks
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
    /// Whether the resource accepts only DPoP-bound tokens (RFC 9449 §5.2).
    var dpopBoundAccessTokensRequired: Bool? = nil
    /// Whether this was synthesized because the server publishes no
    /// metadata: the authorization server is the server's origin.
    var isFallback = false

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case dpopBoundAccessTokensRequired = "dpop_bound_access_tokens_required"
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
    /// Whether authorization responses carry `iss` (RFC 9207).
    var authorizationResponseIssParameterSupported: Bool? = nil
    /// The JWS algorithms the server accepts in DPoP proofs (RFC 9449 §5.1).
    var dpopSigningAlgValuesSupported: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
        case dpopSigningAlgValuesSupported = "dpop_signing_alg_values_supported"
    }

    /// The endpoints a 2025-03-26 server without metadata serves at its root:
    /// `/authorize`, `/token` and `/register`.
    static func defaultEndpoints(issuer: URL) -> OAuthAuthorizationServerMetadata {
        OAuthAuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: issuer.appendingPathComponent("authorize"),
            tokenEndpoint: issuer.appendingPathComponent("token"),
            registrationEndpoint: issuer.appendingPathComponent("register"),
            codeChallengeMethodsSupported: [OAuthCodeChallengeMethod.s256],
            tokenEndpointAuthMethodsSupported: nil,
            clientIDMetadataDocumentSupported: nil)
    }
}

/// Issuer identifier comparison (RFC 8414 §3.3, RFC 9207 §2.4).
enum OAuthIssuer {
    /// Simple string comparison, except that a root issuer with and without
    /// its trailing slash (`https://as.example` and `https://as.example/`)
    /// name the same server.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let (shorter, longer) = lhs.count < rhs.count ? (lhs, rhs) : (rhs, lhs)
        // The shorter one must be a bare origin. Its parts are checked rather
        // than the origin rebuilt from them, so the result does not depend on
        // how a Foundation version spells an IPv6 host.
        guard longer == shorter + "/",
            let components = URLComponents(string: shorter), components.scheme != nil,
            components.host?.isEmpty == false, components.user == nil, components.password == nil,
            components.path.isEmpty, components.query == nil, components.fragment == nil
        else { return false }
        return true
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

extension OAuthTokenResponse {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        // `token_type` is compared case-insensitively; whitespace is dropped once here.
        tokenType = try container.decode(String.self, forKey: .tokenType)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
    }
}

struct OAuthTokenErrorResponse: Decodable {
    let error: String
}

/// An OAuth 2.1 access token and its associated metadata.
///
/// Stored by ``TokenStorage`` and produced by ``OAuthAuthorizer`` after a successful
/// token request. Use ``isExpired(now:skewSeconds:)`` to check validity before use.
public struct OAuthAccessToken: Sendable, Codable {
    /// The raw bearer token string for use in the `Authorization` header.
    public let value: String

    /// The token type returned by the authorization server: `"Bearer"` or `"DPoP"`.
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

    /// The OAuth `client_id` this token was issued to, if the authorizer had one at storage time.
    ///
    /// Captures the `client_id` held by the authorizer's ``OAuthConfiguration/authentication`` when
    /// the token was saved — including identifiers assigned by Dynamic Client Registration
    /// (RFC 7591). `nil` when no `client_id` was configured (for example, the placeholder used
    /// before registration completes).
    public let clientID: String?

    /// The JWK thumbprint of the key a DPoP-bound token is bound to
    /// (RFC 7638), or `nil` for a Bearer token.
    public let keyThumbprint: String?

    /// Creates a new access token record.
    public init(
        value: String,
        tokenType: String,
        expiresAt: Date?,
        scopes: Set<String>,
        authorizationServer: URL?,
        refreshToken: String?,
        clientID: String? = nil,
        keyThumbprint: String? = nil
    ) {
        self.value = value
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.authorizationServer = authorizationServer
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.keyThumbprint = keyThumbprint
    }

    /// Whether the token is DPoP-bound (`token_type` `DPoP`).
    public var isDPoPBound: Bool {
        tokenType.caseInsensitiveCompare(OAuthTokenType.dpop) == .orderedSame
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
