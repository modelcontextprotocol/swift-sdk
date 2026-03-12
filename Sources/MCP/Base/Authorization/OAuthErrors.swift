import Foundation

/// Errors thrown during OAuth 2.1 authorization by ``OAuthAuthorizer``.
///
/// These errors surface when the authorizer is unable to complete the authorization flow,
/// either due to discovery failures, token exchange problems, security policy violations,
/// or authorization code flow issues.
public enum OAuthAuthorizationError: LocalizedError {
    /// No authorization server URL could be found in the Protected Resource Metadata.
    case missingAuthorizationServer

    /// All Protected Resource Metadata discovery candidates returned errors or invalid documents.
    case metadataDiscoveryFailed

    /// All Authorization Server Metadata discovery candidates (RFC 8414 / OIDC) returned errors.
    case authorizationServerMetadataDiscoveryFailed

    /// The authorization server metadata does not include a `token_endpoint`.
    case tokenEndpointMissing

    /// The token endpoint returned a non-2xx HTTP response.
    ///
    /// - Parameters:
    ///   - statusCode: HTTP status code from the token endpoint.
    ///   - oauthError: The `error` field from the OAuth error response body, if present.
    case tokenRequestFailed(statusCode: Int, oauthError: String?)

    /// The token response body is missing `access_token`, has an empty token, or specifies
    /// a non-Bearer token type.
    case tokenResponseInvalid

    /// A URL that must be a valid resource identifier (RFC 8707) failed validation.
    case invalidResourceURI(String)

    /// The configured client ID looks like a URL but is not a valid HTTPS URL with a path,
    /// which is required for Client ID Metadata Documents.
    case invalidClientIDMetadataURL(String)

    /// The `resource` field in the Protected Resource Metadata does not match the requested endpoint.
    ///
    /// - Parameters:
    ///   - expected: The canonical URI derived from the endpoint.
    ///   - actual: The canonical URI derived from the metadata's `resource` field.
    case protectedResourceMismatch(expected: String, actual: String)

    /// The authorization server does not support dynamic registration and no pre-registered
    /// credentials were supplied.
    case registrationInformationRequired

    /// The authorization server does not support Client ID Metadata Documents and no dynamic
    /// registration endpoint is available.
    ///
    /// - Parameter clientID: The client ID URL that was provided as a CIMD URL.
    case cimdNotSupported(clientID: String)

    /// A URL received from a discovery response resolves to a private or reserved IP address,
    /// which is blocked to prevent SSRF attacks.
    ///
    /// - Parameters:
    ///   - context: Human-readable label identifying which URL was blocked.
    ///   - url: The blocked URL string.
    case privateIPAddressBlocked(context: String, url: String)

    /// An endpoint URL used during the OAuth flow does not satisfy the HTTPS-or-loopback requirement.
    ///
    /// - Parameters:
    ///   - context: Human-readable label identifying which endpoint failed (e.g., `"Token endpoint"`).
    ///   - url: The offending URL string.
    case insecureOAuthEndpoint(context: String, url: String)

    /// An authorization server endpoint does not satisfy the HTTPS-only requirement.
    ///
    /// - Parameters:
    ///   - context: Human-readable label identifying which endpoint failed.
    ///   - url: The offending URL string.
    case insecureAuthorizationServerEndpoint(context: String, url: String)

    /// The redirect URI supplied for the `authorization_code` flow is not a valid HTTPS or
    /// loopback HTTP URI, or it contains a fragment.
    case invalidRedirectURI(String)

    /// The authorization endpoint returned an HTTP error response during the authorization code flow.
    ///
    /// - Parameter statusCode: HTTP status code from the authorization endpoint.
    case authorizationRequestFailed(statusCode: Int)

    /// The authorization response did not include a `Location` redirect header.
    case authorizationResponseMissingRedirectLocation

    /// The redirect URI in the authorization response does not match the expected redirect URI.
    ///
    /// - Parameters:
    ///   - expected: The redirect URI supplied in the authorization request.
    ///   - actual: The redirect URI received in the authorization response.
    case authorizationResponseRedirectMismatch(expected: String, actual: String)

    /// The authorization response redirect URL is missing the `state` parameter.
    case authorizationResponseMissingState

    /// The `state` in the authorization response does not match the one sent in the request.
    ///
    /// This may indicate a CSRF attack.
    ///
    /// - Parameters:
    ///   - expected: The `state` value sent in the authorization request.
    ///   - actual: The `state` value received in the authorization response.
    case authorizationResponseStateMismatch(expected: String, actual: String)

    /// The authorization response redirect URL is missing the `code` parameter.
    case authorizationResponseMissingCode

    /// The authorization server metadata does not include `code_challenge_methods_supported`,
    /// which is required for PKCE (RFC 7636).
    case pkceCodeChallengeMethodsMissing

    /// The authorization server does not advertise `S256` in `code_challenge_methods_supported`.
    ///
    /// The MCP specification mandates S256; plain PKCE is not accepted.
    ///
    /// - Parameter advertisedMethods: The methods listed in the server metadata.
    case pkceS256NotSupported(advertisedMethods: [String])

    /// PKCE S256 challenge generation is unavailable because CryptoKit is not present on this platform.
    case pkceS256Unavailable

    /// The `issuer` field in the Authorization Server Metadata does not match the URL used to
    /// resolve the metadata document, as required by RFC 8414 §3.
    ///
    /// - Parameters:
    ///   - expected: The issuer URL derived from the discovery candidate.
    ///   - actual: The `issuer` field value found in the metadata document.
    case authorizationServerIssuerMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthorizationServer:
            return "No authorization server was found in protected resource metadata"
        case .metadataDiscoveryFailed:
            return "Failed to discover protected resource metadata"
        case .authorizationServerMetadataDiscoveryFailed:
            return "Failed to discover authorization server metadata"
        case .tokenEndpointMissing:
            return "Authorization server metadata is missing token_endpoint"
        case .tokenRequestFailed(let statusCode, let oauthError):
            if let oauthError, !oauthError.isEmpty {
                return "Token request failed with status \(statusCode) (oauth_error: \(oauthError))"
            }
            return "Token request failed with status \(statusCode)"
        case .tokenResponseInvalid:
            return "Token response is invalid"
        case .invalidResourceURI(let detail):
            return "Invalid resource URI: \(detail)"
        case .invalidClientIDMetadataURL(let value):
            return
                "Client ID metadata document URL must use https and include a path: \(value)"
        case .protectedResourceMismatch(let expected, let actual):
            return
                "Protected resource metadata resource mismatch. Expected \(expected), got \(actual)"
        case .registrationInformationRequired:
            return
                "No supported client registration mechanism was available; provide pre-registered client credentials"
        case .cimdNotSupported(let clientID):
            return
                "Authorization server does not support Client ID Metadata Documents; configure pre-registered credentials or ensure the server advertises client_id_metadata_document_supported: \(clientID)"
        case .privateIPAddressBlocked(let context, let url):
            return
                "\(context) resolves to a private or reserved IP address which is blocked for SSRF protection: \(url)"
        case .insecureOAuthEndpoint(let context, let url):
            return "\(context) must use https or loopback http: \(url)"
        case .insecureAuthorizationServerEndpoint(let context, let url):
            return "\(context) must use https: \(url)"
        case .invalidRedirectURI(let url):
            return
                "Redirect URI must use https or loopback http and must not include fragments: \(url)"
        case .authorizationRequestFailed(let statusCode):
            return "Authorization request failed with status \(statusCode)"
        case .authorizationResponseMissingRedirectLocation:
            return "Authorization response is missing redirect location"
        case .authorizationResponseRedirectMismatch(let expected, let actual):
            return
                "Authorization response redirect URI mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseMissingState:
            return "Authorization response is missing state"
        case .authorizationResponseStateMismatch(let expected, let actual):
            return "Authorization response state mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseMissingCode:
            return "Authorization response is missing the authorization code"
        case .pkceCodeChallengeMethodsMissing:
            return
                "Authorization server metadata must include code_challenge_methods_supported for PKCE"
        case .pkceS256NotSupported(let advertisedMethods):
            let methods = advertisedMethods.joined(separator: ", ")
            return
                "Authorization server metadata must support PKCE S256 (advertised: \(methods))"
        case .pkceS256Unavailable:
            return
                "PKCE S256 code challenge generation is unavailable on this platform"
        case .authorizationServerIssuerMismatch(let expected, let actual):
            return
                "Authorization server issuer mismatch. Expected \(expected), got \(actual)"
        }
    }
}
