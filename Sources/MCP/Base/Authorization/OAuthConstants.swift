import Foundation

// MARK: - OAuth Grant Types

enum OAuthGrantTypeValue {
    static let clientCredentials = "client_credentials"
    static let authorizationCode = "authorization_code"
    static let refreshToken = "refresh_token"
}

// MARK: - OAuth Parameter Names

enum OAuthParameterName {
    static let grantType = "grant_type"
    static let resource = "resource"
    static let scope = "scope"
    static let code = "code"
    static let codeVerifier = "code_verifier"
    static let codeChallenge = "code_challenge"
    static let codeChallengeMethod = "code_challenge_method"
    static let redirectURI = "redirect_uri"
    static let responseType = "response_type"
    static let clientID = "client_id"
    static let clientSecret = "client_secret"
    static let clientAssertion = "client_assertion"
    static let clientAssertionType = "client_assertion_type"
    static let refreshToken = "refresh_token"
    static let state = "state"
}

// MARK: - OAuth Well-Known Paths

enum OAuthWellKnownPath {
    static let protectedResource = "/.well-known/oauth-protected-resource"
    static let authorizationServer = "/.well-known/oauth-authorization-server"
    static let openIDConfiguration = "/.well-known/openid-configuration"
}

// MARK: - OAuth Token Type

enum OAuthTokenType {
    static let bearer = "Bearer"
}

// MARK: - OAuth Code Challenge Method

enum OAuthCodeChallengeMethod {
    static let s256 = "S256"
}

// MARK: - OAuth Token Endpoint Auth Method

enum OAuthTokenEndpointAuthMethod {
    static let clientSecretBasic = "client_secret_basic"
    static let clientSecretPost = "client_secret_post"
    static let none = "none"
    static let privateKeyJWT = "private_key_jwt"
}

// MARK: - URL Scheme

enum OAuthURLScheme {
    static let http = "http"
    static let https = "https"
}

// MARK: - Default Ports

enum OAuthDefaultPort {
    static let http = 80
    static let https = 443
}

// MARK: - Loopback Hosts

enum OAuthLoopbackHost {
    static let localhost = "localhost"
    static let ipv4 = "127.0.0.1"
    static let ipv6 = "::1"

    static func isLoopback(_ host: String) -> Bool {
        host == localhost || host == ipv4 || host == ipv6
    }
}

// MARK: - Token Expiry Skew

/// Clock skew tolerance applied when checking token expiry.
///
/// ``OAuthAccessToken/isExpired(now:skewSeconds:)`` treats a token as expired
/// when `now + skewSeconds >= expiresAt`, giving the client a safety margin to
/// refresh tokens before they actually expire on the server.
public enum OAuthTokenExpirySkew {
    /// Default clock skew buffer: 30 seconds.
    public static let defaultSeconds: TimeInterval = 30
}

// MARK: - JWT Claim Names

enum JWTClaimName {
    static let algorithm = "alg"
    static let type = "typ"
    static let typeValue = "JWT"
    static let issuer = "iss"
    static let subject = "sub"
    static let audience = "aud"
    static let issuedAt = "iat"
    static let expiration = "exp"
    static let jwtID = "jti"
}

// MARK: - Client Assertion Type

enum OAuthClientAssertionType {
    static let jwtBearer = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
}

// MARK: - HTTPHeaderName Extensions

extension HTTPHeaderName {
    static let location = "Location"
}

// MARK: - ContentType Extensions

extension ContentType {
    static let formURLEncoded = "application/x-www-form-urlencoded"
}

// MARK: - Data Base64URL Extension

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
