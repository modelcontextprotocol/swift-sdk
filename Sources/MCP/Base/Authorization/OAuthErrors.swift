import Foundation

/// Errors thrown during OAuth 2.1 authorization by ``OAuthAuthorizer``.
///
/// These errors surface when the authorizer is unable to complete the authorization flow,
/// either due to discovery failures, token exchange problems, security policy violations,
/// or authorization code flow issues.
///
/// ``code`` says what failed; the other properties carry the details that code has. New codes
/// can appear in a minor release, so a `switch` needs a `default`. A static member such as
/// ``dpopRequired`` or ``tokenRequestFailed`` matches every error with its code.
/// ``HTTPClientTransport`` throws it wrapped in ``MCPError/transportError(_:)``:
///
/// ```swift
/// do {
///     try await client.connect(transport: transport)
/// } catch MCPError.transportError(let error as OAuthAuthorizationError) {
///     switch error {
///     case .dpopRequired: break  // set OAuthConfiguration.dpop
///     case .tokenRequestFailed: print(error.statusCode ?? 0, error.oauthError ?? "")
///     case .privateIPAddressBlocked: break  // any blocked URL
///     default: print(error.localizedDescription)
///     }
/// }
/// ```
public struct OAuthAuthorizationError: LocalizedError, Hashable, Sendable {
    /// What failed.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// No authorization server URL could be found in the Protected Resource Metadata.
        public static let missingAuthorizationServer = Code(rawValue: "missingAuthorizationServer")
        /// All Protected Resource Metadata discovery candidates returned errors or invalid documents.
        public static let metadataDiscoveryFailed = Code(rawValue: "metadataDiscoveryFailed")
        /// All Authorization Server Metadata discovery candidates (RFC 8414 / OIDC) returned errors.
        public static let authorizationServerMetadataDiscoveryFailed = Code(
            rawValue: "authorizationServerMetadataDiscoveryFailed")
        /// The authorization server metadata does not include a `token_endpoint`.
        public static let tokenEndpointMissing = Code(rawValue: "tokenEndpointMissing")
        /// The token endpoint returned a non-2xx HTTP response: ``statusCode``, ``oauthError``.
        public static let tokenRequestFailed = Code(rawValue: "tokenRequestFailed")
        /// The token response has an empty `access_token`, or a token type other than `Bearer`
        /// (or `DPoP`, when the request carried a proof).
        public static let tokenResponseInvalid = Code(rawValue: "tokenResponseInvalid")
        /// A URL that must be a valid resource identifier (RFC 8707) failed validation: ``detail``.
        public static let invalidResourceURI = Code(rawValue: "invalidResourceURI")
        /// The client ID looks like a URL but is not an HTTPS URL with a path, as Client ID
        /// Metadata Documents require: ``clientID``.
        public static let invalidClientIDMetadataURL = Code(rawValue: "invalidClientIDMetadataURL")
        /// The `resource` of the Protected Resource Metadata is not the requested endpoint:
        /// ``expected``, ``actual``.
        public static let protectedResourceMismatch = Code(rawValue: "protectedResourceMismatch")
        /// The authorization server does not support dynamic registration and no pre-registered
        /// credentials were supplied.
        public static let registrationInformationRequired = Code(rawValue: "registrationInformationRequired")
        /// The authorization server supports neither Client ID Metadata Documents nor dynamic
        /// registration: ``clientID``.
        public static let cimdNotSupported = Code(rawValue: "cimdNotSupported")
        /// A URL resolves to a private or reserved IP address, blocked against SSRF:
        /// ``context``, ``url``.
        public static let privateIPAddressBlocked = Code(rawValue: "privateIPAddressBlocked")
        /// An endpoint is neither HTTPS nor loopback HTTP: ``context``, ``url``.
        public static let insecureOAuthEndpoint = Code(rawValue: "insecureOAuthEndpoint")
        /// An authorization server endpoint is not HTTPS: ``context``, ``url``.
        public static let insecureAuthorizationServerEndpoint = Code(
            rawValue: "insecureAuthorizationServerEndpoint")
        /// The redirect URI is neither HTTPS nor loopback HTTP, or has a fragment: ``url``.
        public static let invalidRedirectURI = Code(rawValue: "invalidRedirectURI")
        /// The authorization endpoint returned an HTTP error: ``statusCode``.
        public static let authorizationRequestFailed = Code(rawValue: "authorizationRequestFailed")
        /// The authorization response has no `Location` redirect header.
        public static let authorizationResponseMissingRedirectLocation = Code(
            rawValue: "authorizationResponseMissingRedirectLocation")
        /// The redirect URI of the authorization response is not the one requested:
        /// ``expected``, ``actual``.
        public static let authorizationResponseRedirectMismatch = Code(
            rawValue: "authorizationResponseRedirectMismatch")
        /// The authorization response has no `state` parameter.
        public static let authorizationResponseMissingState = Code(rawValue: "authorizationResponseMissingState")
        /// The `state` of the authorization response is not the one sent, which may indicate a
        /// CSRF attack: ``expected``, ``actual``.
        public static let authorizationResponseStateMismatch = Code(rawValue: "authorizationResponseStateMismatch")
        /// The authorization response has no `code` parameter.
        public static let authorizationResponseMissingCode = Code(rawValue: "authorizationResponseMissingCode")
        /// The authorization server metadata has no `code_challenge_methods_supported`, which
        /// PKCE (RFC 7636) requires.
        public static let pkceCodeChallengeMethodsMissing = Code(rawValue: "pkceCodeChallengeMethodsMissing")
        /// The authorization server does not advertise `S256`; plain PKCE is not accepted:
        /// ``actual`` lists the advertised methods.
        public static let pkceS256NotSupported = Code(rawValue: "pkceS256NotSupported")
        /// PKCE S256 challenge generation is unavailable. Not thrown: SHA-256 comes from
        /// swift-crypto on every platform.
        public static let pkceS256Unavailable = Code(rawValue: "pkceS256Unavailable")
        /// The `issuer` of the Authorization Server Metadata is not the URL it was resolved
        /// from (RFC 8414 §3): ``expected``, ``actual``.
        public static let authorizationServerIssuerMismatch = Code(rawValue: "authorizationServerIssuerMismatch")
        /// The `iss` parameter of the authorization response is not the issuer of the
        /// authorization server (RFC 9207, SEP-2468): ``expected``, ``actual``.
        public static let authorizationResponseIssuerMismatch = Code(
            rawValue: "authorizationResponseIssuerMismatch")
        /// The authorization server advertised `iss` in authorization responses, but the
        /// response has none (RFC 9207).
        public static let authorizationResponseMissingIssuer = Code(rawValue: "authorizationResponseMissingIssuer")
        /// The configuration uses ``OAuthConfiguration/GrantType/jwtBearer`` without an
        /// ``OAuthConfiguration/assertionProvider``.
        public static let assertionProviderMissing = Code(rawValue: "assertionProviderMissing")
        /// A token exchange (RFC 8693) issued another token type than the one requested:
        /// ``expected``, ``actual`` (empty when the response has no `issued_token_type`).
        public static let issuedTokenTypeMismatch = Code(rawValue: "issuedTokenTypeMismatch")
        /// The ``OAuthConfiguration/GrantType/jwtBearer`` grant has no configured
        /// authorization server or token endpoint, and
        /// ``OAuthConfiguration/allowsDiscoveredAuthorizationServer`` is off, so the assertion
        /// is not sent to a server the MCP server chose.
        public static let authorizationServerNotConfigured = Code(rawValue: "authorizationServerNotConfigured")
        /// The assertion of a ``OAuthConfiguration/GrantType/jwtBearer`` request is for
        /// another audience than the authorization server, or is not a JWT with an `aud`
        /// claim: ``expected`` (its issuer and token endpoint), ``actual`` (the `aud` claim;
        /// empty when it has none).
        public static let assertionAudienceMismatch = Code(rawValue: "assertionAudienceMismatch")
        /// The protected resource requires DPoP-bound tokens
        /// (`dpop_bound_access_tokens_required`), and ``OAuthConfiguration/dpop`` is not set
        /// or the authorization server issued a Bearer token.
        public static let dpopRequired = Code(rawValue: "dpopRequired")
        /// The authorization server does not accept ES256 DPoP proofs: ``actual`` lists its
        /// `dpop_signing_alg_values_supported`.
        public static let dpopAlgorithmUnsupported = Code(rawValue: "dpopAlgorithmUnsupported")
    }

    /// What failed.
    public let code: Code

    /// The HTTP status code of the response that failed, for ``Code/tokenRequestFailed`` and
    /// ``Code/authorizationRequestFailed``.
    public let statusCode: Int?

    /// The `error` field of the OAuth error response, for ``Code/tokenRequestFailed``.
    public let oauthError: String?

    /// Which URL or endpoint failed, for example `"Token endpoint"`.
    public let context: String?

    /// The URL that failed.
    public let url: String?

    /// The client ID that failed.
    public let clientID: String?

    /// Why the value failed, for ``Code/invalidResourceURI``.
    public let detail: String?

    /// What the SDK required: one value for most codes, several for
    /// ``Code/assertionAudienceMismatch``.
    public let expected: [String]

    /// What it found instead, or the values the server advertised.
    public let actual: [String]

    /// Creates an error, for example in a custom ``OAuthMetadataDiscovering`` or in tests.
    /// The static members build the errors the SDK throws.
    public init(
        code: Code,
        statusCode: Int? = nil,
        oauthError: String? = nil,
        context: String? = nil,
        url: String? = nil,
        clientID: String? = nil,
        detail: String? = nil,
        expected: [String] = [],
        actual: [String] = []
    ) {
        self.code = code
        self.statusCode = statusCode
        self.oauthError = oauthError
        self.context = context
        self.url = url
        self.clientID = clientID
        self.detail = detail
        self.expected = expected
        self.actual = actual
    }

    /// Whether `error` is an `OAuthAuthorizationError` with the code of `pattern`, so that
    /// `catch OAuthAuthorizationError.dpopRequired` and `case .dpopRequired:` match by code.
    ///
    /// Only the code is compared. A pattern built with values, such as
    /// `catch OAuthAuthorizationError.tokenRequestFailed(statusCode: 401, oauthError: nil)`,
    /// compiles and matches every `tokenRequestFailed` error; compare ``statusCode`` or
    /// ``oauthError`` in a `where` clause.
    public static func ~= (pattern: OAuthAuthorizationError, error: any Error) -> Bool {
        (error as? OAuthAuthorizationError)?.code == pattern.code
    }

    /// Whether `error` has the code of `pattern`. Only the code is compared: the values of a
    /// pattern built with values are ignored.
    public static func ~= (pattern: OAuthAuthorizationError, error: OAuthAuthorizationError) -> Bool {
        error.code == pattern.code
    }

    public var errorDescription: String? {
        let expected = expected.joined(separator: ", ")
        let actual = actual.joined(separator: ", ")
        let context = context ?? "URL"
        let url = url ?? ""
        switch code {
        case .missingAuthorizationServer:
            return "No authorization server was found in protected resource metadata"
        case .metadataDiscoveryFailed:
            return "Failed to discover protected resource metadata"
        case .authorizationServerMetadataDiscoveryFailed:
            return "Failed to discover authorization server metadata"
        case .tokenEndpointMissing:
            return "Authorization server metadata is missing token_endpoint"
        case .tokenRequestFailed:
            let status = statusCode.map(String.init) ?? "unknown"
            if let oauthError, !oauthError.isEmpty {
                return "Token request failed with status \(status) (oauth_error: \(oauthError))"
            }
            return "Token request failed with status \(status)"
        case .tokenResponseInvalid:
            return "Token response is invalid"
        case .invalidResourceURI:
            return "Invalid resource URI: \(detail ?? "")"
        case .invalidClientIDMetadataURL:
            return "Client ID metadata document URL must use https and include a path: \(clientID ?? "")"
        case .protectedResourceMismatch:
            return "Protected resource metadata resource mismatch. Expected \(expected), got \(actual)"
        case .registrationInformationRequired:
            return
                "No supported client registration mechanism was available; provide pre-registered client credentials"
        case .cimdNotSupported:
            return
                "Authorization server does not support Client ID Metadata Documents; configure pre-registered credentials or ensure the server advertises client_id_metadata_document_supported: \(clientID ?? "")"
        case .privateIPAddressBlocked:
            return
                "\(context) resolves to a private or reserved IP address which is blocked for SSRF protection: \(url)"
        case .insecureOAuthEndpoint:
            return "\(context) must use https or loopback http: \(url)"
        case .insecureAuthorizationServerEndpoint:
            return "\(context) must use https: \(url)"
        case .invalidRedirectURI:
            return "Redirect URI must use https or loopback http and must not include fragments: \(url)"
        case .authorizationRequestFailed:
            return "Authorization request failed with status \(statusCode.map(String.init) ?? "unknown")"
        case .authorizationResponseMissingRedirectLocation:
            return "Authorization response is missing redirect location"
        case .authorizationResponseRedirectMismatch:
            return "Authorization response redirect URI mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseMissingState:
            return "Authorization response is missing state"
        case .authorizationResponseStateMismatch:
            return "Authorization response state mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseMissingCode:
            return "Authorization response is missing the authorization code"
        case .pkceCodeChallengeMethodsMissing:
            return "Authorization server metadata must include code_challenge_methods_supported for PKCE"
        case .pkceS256NotSupported:
            return "Authorization server metadata must support PKCE S256 (advertised: \(actual))"
        case .pkceS256Unavailable:
            return "PKCE S256 code challenge generation is unavailable on this platform"
        case .authorizationServerIssuerMismatch:
            return "Authorization server issuer mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseIssuerMismatch:
            return "Authorization response issuer mismatch. Expected \(expected), got \(actual)"
        case .authorizationResponseMissingIssuer:
            return "Authorization response is missing the iss parameter the server advertised"
        case .assertionProviderMissing:
            return "The jwt-bearer grant requires an assertion provider"
        case .issuedTokenTypeMismatch:
            return "Token exchange issued \(actual.isEmpty ? "no token type" : actual), expected \(expected)"
        case .authorizationServerNotConfigured:
            return
                "The jwt-bearer grant needs endpointOverrides.authorizationServerURL or tokenEndpoint, or allowsDiscoveredAuthorizationServer"
        case .assertionAudienceMismatch:
            return "The assertion audience \(actual) is none of \(expected)"
        case .dpopRequired:
            return
                "The protected resource requires DPoP-bound tokens; set OAuthConfiguration.dpop and use an authorization server that issues them"
        case .dpopAlgorithmUnsupported:
            return "The authorization server does not accept ES256 DPoP proofs (supported: \(actual))"
        default:
            return "OAuth authorization failed: \(code)"
        }
    }
}

// MARK: - The errors the SDK throws

/// One static member per code. A pattern matches by code alone:
/// `catch OAuthAuthorizationError.tokenRequestFailed` catches every failed token request,
/// whatever its status. `==` compares every property.
extension OAuthAuthorizationError {
    /// See ``Code/missingAuthorizationServer``.
    public static let missingAuthorizationServer = Self(code: .missingAuthorizationServer)
    /// See ``Code/metadataDiscoveryFailed``.
    public static let metadataDiscoveryFailed = Self(code: .metadataDiscoveryFailed)
    /// See ``Code/authorizationServerMetadataDiscoveryFailed``.
    public static let authorizationServerMetadataDiscoveryFailed = Self(
        code: .authorizationServerMetadataDiscoveryFailed)
    /// See ``Code/tokenEndpointMissing``.
    public static let tokenEndpointMissing = Self(code: .tokenEndpointMissing)
    /// See ``Code/tokenResponseInvalid``.
    public static let tokenResponseInvalid = Self(code: .tokenResponseInvalid)
    /// See ``Code/registrationInformationRequired``.
    public static let registrationInformationRequired = Self(code: .registrationInformationRequired)
    /// See ``Code/authorizationResponseMissingRedirectLocation``.
    public static let authorizationResponseMissingRedirectLocation = Self(
        code: .authorizationResponseMissingRedirectLocation)
    /// See ``Code/authorizationResponseMissingState``.
    public static let authorizationResponseMissingState = Self(code: .authorizationResponseMissingState)
    /// See ``Code/authorizationResponseMissingCode``.
    public static let authorizationResponseMissingCode = Self(code: .authorizationResponseMissingCode)
    /// See ``Code/pkceCodeChallengeMethodsMissing``.
    public static let pkceCodeChallengeMethodsMissing = Self(code: .pkceCodeChallengeMethodsMissing)
    /// See ``Code/pkceS256Unavailable``.
    public static let pkceS256Unavailable = Self(code: .pkceS256Unavailable)
    /// See ``Code/authorizationResponseMissingIssuer``.
    public static let authorizationResponseMissingIssuer = Self(code: .authorizationResponseMissingIssuer)
    /// See ``Code/assertionProviderMissing``.
    public static let assertionProviderMissing = Self(code: .assertionProviderMissing)
    /// See ``Code/authorizationServerNotConfigured``.
    public static let authorizationServerNotConfigured = Self(code: .authorizationServerNotConfigured)
    /// See ``Code/dpopRequired``.
    public static let dpopRequired = Self(code: .dpopRequired)

    /// Every error with code ``Code/tokenRequestFailed``, for `catch` and `case` patterns.
    public static let tokenRequestFailed = Self(code: .tokenRequestFailed)

    /// See ``Code/tokenRequestFailed``.
    public static func tokenRequestFailed(statusCode: Int, oauthError: String?) -> Self {
        Self(code: .tokenRequestFailed, statusCode: statusCode, oauthError: oauthError)
    }

    /// Every error with code ``Code/invalidResourceURI``, for `catch` and `case` patterns.
    public static let invalidResourceURI = Self(code: .invalidResourceURI)

    /// See ``Code/invalidResourceURI``.
    public static func invalidResourceURI(_ detail: String) -> Self {
        Self(code: .invalidResourceURI, detail: detail)
    }

    /// Every error with code ``Code/invalidClientIDMetadataURL``, for `catch` and `case` patterns.
    public static let invalidClientIDMetadataURL = Self(code: .invalidClientIDMetadataURL)

    /// See ``Code/invalidClientIDMetadataURL``.
    public static func invalidClientIDMetadataURL(_ clientID: String) -> Self {
        Self(code: .invalidClientIDMetadataURL, clientID: clientID)
    }

    /// Every error with code ``Code/protectedResourceMismatch``, for `catch` and `case` patterns.
    public static let protectedResourceMismatch = Self(code: .protectedResourceMismatch)

    /// See ``Code/protectedResourceMismatch``.
    public static func protectedResourceMismatch(expected: String, actual: String) -> Self {
        Self(code: .protectedResourceMismatch, expected: [expected], actual: [actual])
    }

    /// Every error with code ``Code/cimdNotSupported``, for `catch` and `case` patterns.
    public static let cimdNotSupported = Self(code: .cimdNotSupported)

    /// See ``Code/cimdNotSupported``.
    public static func cimdNotSupported(clientID: String) -> Self {
        Self(code: .cimdNotSupported, clientID: clientID)
    }

    /// Every error with code ``Code/privateIPAddressBlocked``, for `catch` and `case` patterns.
    public static let privateIPAddressBlocked = Self(code: .privateIPAddressBlocked)

    /// See ``Code/privateIPAddressBlocked``.
    public static func privateIPAddressBlocked(context: String, url: String) -> Self {
        Self(code: .privateIPAddressBlocked, context: context, url: url)
    }

    /// Every error with code ``Code/insecureOAuthEndpoint``, for `catch` and `case` patterns.
    public static let insecureOAuthEndpoint = Self(code: .insecureOAuthEndpoint)

    /// See ``Code/insecureOAuthEndpoint``.
    public static func insecureOAuthEndpoint(context: String, url: String) -> Self {
        Self(code: .insecureOAuthEndpoint, context: context, url: url)
    }

    /// Every error with code ``Code/insecureAuthorizationServerEndpoint``, for `catch` and `case` patterns.
    public static let insecureAuthorizationServerEndpoint = Self(code: .insecureAuthorizationServerEndpoint)

    /// See ``Code/insecureAuthorizationServerEndpoint``.
    public static func insecureAuthorizationServerEndpoint(context: String, url: String) -> Self {
        Self(code: .insecureAuthorizationServerEndpoint, context: context, url: url)
    }

    /// Every error with code ``Code/invalidRedirectURI``, for `catch` and `case` patterns.
    public static let invalidRedirectURI = Self(code: .invalidRedirectURI)

    /// See ``Code/invalidRedirectURI``.
    public static func invalidRedirectURI(_ url: String) -> Self {
        Self(code: .invalidRedirectURI, url: url)
    }

    /// Every error with code ``Code/authorizationRequestFailed``, for `catch` and `case` patterns.
    public static let authorizationRequestFailed = Self(code: .authorizationRequestFailed)

    /// See ``Code/authorizationRequestFailed``.
    public static func authorizationRequestFailed(statusCode: Int) -> Self {
        Self(code: .authorizationRequestFailed, statusCode: statusCode)
    }

    /// Every error with code ``Code/authorizationResponseRedirectMismatch``, for `catch` and `case` patterns.
    public static let authorizationResponseRedirectMismatch = Self(code: .authorizationResponseRedirectMismatch)

    /// See ``Code/authorizationResponseRedirectMismatch``.
    public static func authorizationResponseRedirectMismatch(expected: String, actual: String) -> Self {
        Self(code: .authorizationResponseRedirectMismatch, expected: [expected], actual: [actual])
    }

    /// Every error with code ``Code/authorizationResponseStateMismatch``, for `catch` and `case` patterns.
    public static let authorizationResponseStateMismatch = Self(code: .authorizationResponseStateMismatch)

    /// See ``Code/authorizationResponseStateMismatch``.
    public static func authorizationResponseStateMismatch(expected: String, actual: String) -> Self {
        Self(code: .authorizationResponseStateMismatch, expected: [expected], actual: [actual])
    }

    /// Every error with code ``Code/pkceS256NotSupported``, for `catch` and `case` patterns.
    public static let pkceS256NotSupported = Self(code: .pkceS256NotSupported)

    /// See ``Code/pkceS256NotSupported``.
    public static func pkceS256NotSupported(advertisedMethods: [String]) -> Self {
        Self(code: .pkceS256NotSupported, expected: ["S256"], actual: advertisedMethods)
    }

    /// Every error with code ``Code/authorizationServerIssuerMismatch``, for `catch` and `case` patterns.
    public static let authorizationServerIssuerMismatch = Self(code: .authorizationServerIssuerMismatch)

    /// See ``Code/authorizationServerIssuerMismatch``.
    public static func authorizationServerIssuerMismatch(expected: String, actual: String) -> Self {
        Self(code: .authorizationServerIssuerMismatch, expected: [expected], actual: [actual])
    }

    /// Every error with code ``Code/authorizationResponseIssuerMismatch``, for `catch` and `case` patterns.
    public static let authorizationResponseIssuerMismatch = Self(code: .authorizationResponseIssuerMismatch)

    /// See ``Code/authorizationResponseIssuerMismatch``.
    public static func authorizationResponseIssuerMismatch(expected: String, actual: String) -> Self {
        Self(code: .authorizationResponseIssuerMismatch, expected: [expected], actual: [actual])
    }

    /// Every error with code ``Code/issuedTokenTypeMismatch``, for `catch` and `case` patterns.
    public static let issuedTokenTypeMismatch = Self(code: .issuedTokenTypeMismatch)

    /// See ``Code/issuedTokenTypeMismatch``.
    public static func issuedTokenTypeMismatch(expected: String, actual: String?) -> Self {
        Self(code: .issuedTokenTypeMismatch, expected: [expected], actual: actual.map { [$0] } ?? [])
    }

    /// Every error with code ``Code/assertionAudienceMismatch``, for `catch` and `case` patterns.
    public static let assertionAudienceMismatch = Self(code: .assertionAudienceMismatch)

    /// See ``Code/assertionAudienceMismatch``.
    public static func assertionAudienceMismatch(expected: [String], actual: [String]) -> Self {
        Self(code: .assertionAudienceMismatch, expected: expected, actual: actual)
    }

    /// Every error with code ``Code/dpopAlgorithmUnsupported``, for `catch` and `case` patterns.
    public static let dpopAlgorithmUnsupported = Self(code: .dpopAlgorithmUnsupported)

    /// See ``Code/dpopAlgorithmUnsupported``.
    public static func dpopAlgorithmUnsupported(supported: [String]) -> Self {
        Self(code: .dpopAlgorithmUnsupported, expected: ["ES256"], actual: supported)
    }
}
