import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// RFC 8693 token exchange.
///
/// Enterprise-managed authorization (SEP-990) uses it at the enterprise
/// identity provider: the client exchanges the user's ID token for an
/// identity assertion (ID-JAG), then presents the ID-JAG to the MCP
/// authorization server with the ``OAuthConfiguration/GrantType/jwtBearer``
/// grant. ``OAuthConfiguration/enterpriseManaged(authentication:authorizationServer:identityProvider:idToken:retryPolicy:additionalTokenRequestParameters:allowsDiscoveredAuthorizationServer:)``
/// combines both steps.
public enum OAuthTokenExchange {
    /// Token type identifiers (RFC 8693 section 3, SEP-990).
    public enum TokenType {
        /// An OAuth 2.0 access token.
        public static let accessToken = "urn:ietf:params:oauth:token-type:access_token"
        /// An OAuth 2.0 refresh token.
        public static let refreshToken = "urn:ietf:params:oauth:token-type:refresh_token"
        /// An OpenID Connect ID token.
        public static let idToken = "urn:ietf:params:oauth:token-type:id_token"
        /// A JWT (RFC 7519 section 9).
        public static let jwt = "urn:ietf:params:oauth:token-type:jwt"
        /// A base64url-encoded SAML 2.0 assertion.
        public static let saml2 = "urn:ietf:params:oauth:token-type:saml2"
        /// An Identity Assertion JWT Authorization Grant (SEP-990).
        public static let idJAG = "urn:ietf:params:oauth:token-type:id-jag"
    }

    /// The parameters of a token exchange request.
    public struct Request: Sendable, Hashable {
        /// The token to exchange, such as an ID token.
        public var subjectToken: String
        /// The type of ``subjectToken``, one of ``TokenType``.
        public var subjectTokenType: String
        /// The type of the token to issue, one of ``TokenType``.
        public var requestedTokenType: String
        /// Where the issued token will be used: for an ID-JAG, the issuer of
        /// the MCP authorization server.
        public var audience: String?
        /// The resource the issued token is for (RFC 8707).
        public var resource: URL?
        /// The scopes to request.
        public var scopes: Set<String>?

        /// Creates a token exchange request.
        public init(
            subjectToken: String,
            subjectTokenType: String,
            requestedTokenType: String,
            audience: String? = nil,
            resource: URL? = nil,
            scopes: Set<String>? = nil
        ) {
            self.subjectToken = subjectToken
            self.subjectTokenType = subjectTokenType
            self.requestedTokenType = requestedTokenType
            self.audience = audience
            self.resource = resource
            self.scopes = scopes
        }
    }

    /// A successful token exchange response (RFC 8693 section 2.2.1).
    public struct Response: Sendable, Hashable, Decodable {
        /// The issued token. For an ID-JAG, the JWT to present to the MCP
        /// authorization server.
        public let accessToken: String
        /// The type of ``accessToken``, one of ``TokenType``.
        public let issuedTokenType: String
        /// How the token is used; `N_A` for tokens that are not access tokens.
        /// Empty when the response has none; the SDK does not check it.
        public let tokenType: String
        /// Lifetime of the issued token, in seconds.
        public let expiresIn: Int?
        /// The granted scopes, space-separated.
        public let scope: String?
        /// A refresh token, if the server issued one.
        public let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case issuedTokenType = "issued_token_type"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case scope
            case refreshToken = "refresh_token"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            issuedTokenType = try container.decodeIfPresent(String.self, forKey: .issuedTokenType) ?? ""
            tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
            expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        }
    }

    /// Exchanges a token at `tokenEndpoint`.
    ///
    /// The request follows no redirects. The endpoint must be `https` (or
    /// loopback `http` when `urlValidator` allows it) and not a private IP
    /// literal.
    ///
    /// - Parameters:
    ///   - request: The tokens and their types, the audience, resource and scopes.
    ///   - tokenEndpoint: The token endpoint of the server that issues the token.
    ///   - authentication: How the client authenticates to that server.
    ///   - session: The URL session for the request.
    ///   - urlValidator: The URL checks to apply.
    /// - Returns: The issued token.
    /// - Throws: ``OAuthAuthorizationError/tokenRequestFailed(statusCode:oauthError:)``
    ///   for an error response, ``OAuthAuthorizationError/tokenResponseInvalid`` for a
    ///   response without a token, and
    ///   ``OAuthAuthorizationError/issuedTokenTypeMismatch(expected:actual:)`` when the
    ///   server issued another token type than requested.
    public static func exchange(
        _ request: Request,
        tokenEndpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession = .shared,
        urlValidator: OAuthURLValidator = OAuthURLValidator()
    ) async throws -> Response {
        try urlValidator.validateAuthorizationServerAndHost(tokenEndpoint, context: "Token exchange endpoint")

        var parameters: [String: String] = [
            OAuthParameterName.grantType: OAuthGrantTypeValue.tokenExchange,
            OAuthParameterName.subjectToken: request.subjectToken,
            OAuthParameterName.subjectTokenType: request.subjectTokenType,
            OAuthParameterName.requestedTokenType: request.requestedTokenType,
        ]
        if let audience = request.audience {
            parameters[OAuthParameterName.audience] = audience
        }
        if let resource = request.resource {
            parameters[OAuthParameterName.resource] = resource.absoluteString
        }
        if let scopes = request.scopes, !scopes.isEmpty {
            parameters[OAuthParameterName.scope] = scopes.sorted().joined(separator: " ")
        }

        var urlRequest = URLRequest(url: tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(ContentType.formURLEncoded, forHTTPHeaderField: HTTPHeaderName.contentType)
        urlRequest.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.accept)
        try await authentication.apply(
            to: &urlRequest, bodyParameters: &parameters, tokenEndpoint: tokenEndpoint)
        urlRequest.httpBody = OAuthFormEncoding.encode(parameters)

        let (data, response) = try await session.oauthData(
            for: urlRequest, redirects: .none, validator: urlValidator)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthAuthorizationError.tokenRequestFailed(statusCode: -1, oauthError: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let oauthError = (try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data))?.error
            throw OAuthAuthorizationError.tokenRequestFailed(
                statusCode: httpResponse.statusCode, oauthError: oauthError)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
            !decoded.accessToken.isEmpty
        else {
            throw OAuthAuthorizationError.tokenResponseInvalid
        }
        guard decoded.issuedTokenType == request.requestedTokenType else {
            throw OAuthAuthorizationError.issuedTokenTypeMismatch(
                expected: request.requestedTokenType,
                actual: decoded.issuedTokenType.isEmpty ? nil : decoded.issuedTokenType)
        }
        return decoded
    }

    /// Discovers the token endpoint of `issuer` from its authorization server
    /// metadata (RFC 8414) or OpenID configuration. The metadata's `issuer`
    /// must match.
    ///
    /// - Throws: ``OAuthAuthorizationError/insecureAuthorizationServerEndpoint(context:url:)``
    ///   or ``OAuthAuthorizationError/privateIPAddressBlocked(context:url:)`` when `issuer` is
    ///   refused, before any request;
    ///   ``OAuthAuthorizationError/authorizationServerIssuerMismatch(expected:actual:)``
    ///   when its metadata names another issuer;
    ///   ``OAuthAuthorizationError/authorizationServerMetadataDiscoveryFailed`` when every
    ///   metadata URL answers 404 or 410; an error naming the URL and the reason when a
    ///   metadata request fails otherwise (a network error, another status, or a body that is
    ///   not metadata); `CancellationError` when cancelled; and
    ///   ``OAuthAuthorizationError/tokenEndpointMissing`` when the metadata has no token
    ///   endpoint.
    public static func tokenEndpoint(
        issuer: URL,
        session: URLSession = .shared,
        urlValidator: OAuthURLValidator = OAuthURLValidator()
    ) async throws -> URL {
        let discovery = OAuthDiscoveryClient(
            metadataDiscovery: DefaultOAuthMetadataDiscovery(), urlValidator: urlValidator)
        let (_, metadata) = try await discovery.fetchAuthorizationServerMetadata(
            candidates: [issuer], session: session)
        guard let tokenEndpoint = metadata.tokenEndpoint else {
            throw OAuthAuthorizationError.tokenEndpointMissing
        }
        return tokenEndpoint
    }
}

// MARK: - Enterprise-managed authorization (SEP-990)

extension OAuthConfiguration {
    /// The enterprise identity provider that issues identity assertions
    /// (ID-JAGs) for enterprise-managed authorization (SEP-990).
    public struct EnterpriseIdentityProvider: Sendable {
        /// Where to send the token exchange.
        ///
        /// Frozen: no case is added in 1.x (a token endpoint, or an issuer to discover it from).
        public enum Endpoint: Sendable, Hashable {
            /// The token endpoint of the identity provider.
            case tokenEndpoint(URL)
            /// The issuer of the identity provider; its token endpoint is
            /// discovered from its metadata.
            case issuer(URL)
        }

        /// Where to send the token exchange.
        public var endpoint: Endpoint
        /// How the client authenticates to the identity provider.
        public var authentication: TokenEndpointAuthentication
        /// Accepts loopback `http` endpoints (local tests).
        package var allowsLoopbackHTTP = false

        /// Creates an identity provider description.
        public init(endpoint: Endpoint, authentication: TokenEndpointAuthentication) {
            self.endpoint = endpoint
            self.authentication = authentication
        }
    }

    /// Returns the user's ID token, the subject of the token exchange. The
    /// application obtains it by signing the user in at the identity provider.
    public typealias IDTokenProvider = @Sendable (_ session: URLSession) async throws -> String

    /// A configuration for enterprise-managed authorization (SEP-990).
    ///
    /// For each token request the authorizer:
    /// 1. asks `idToken` for the user's ID token;
    /// 2. exchanges it at the identity provider for an ID-JAG (RFC 8693), with
    ///    the authorization server's issuer as `audience`, the MCP server as
    ///    `resource` and the requested scopes;
    /// 3. presents the ID-JAG to the MCP authorization server with the
    ///    jwt-bearer grant (RFC 7523), authenticated with `authentication`.
    ///
    /// No client registration happens.
    ///
    /// - Parameters:
    ///   - authentication: The client's credentials at the MCP authorization
    ///     server, usually `.clientSecretBasic` or `.clientSecretPost`.
    ///   - authorizationServer: The issuer of the MCP authorization server, so that
    ///     the MCP server cannot direct the ID-JAG and the client credentials
    ///     elsewhere. Its metadata must name it as `issuer`. `nil` uses the
    ///     server named in the protected resource metadata, and needs
    ///     `allowsDiscoveredAuthorizationServer`.
    ///   - identityProvider: The identity provider and the client's credentials there.
    ///   - idToken: Returns the user's ID token.
    ///   - retryPolicy: Controls retries for authorization challenges.
    ///   - additionalTokenRequestParameters: Extra form fields for the jwt-bearer request.
    ///   - allowsDiscoveredAuthorizationServer: With `authorizationServer: nil`, lets the
    ///     MCP server's metadata choose the authorization server. Off by default.
    public static func enterpriseManaged(
        authentication: TokenEndpointAuthentication,
        authorizationServer: URL?,
        identityProvider: EnterpriseIdentityProvider,
        idToken: @escaping IDTokenProvider,
        retryPolicy: RetryPolicy = .default,
        additionalTokenRequestParameters: [String: String] = [:],
        allowsDiscoveredAuthorizationServer: Bool = false
    ) -> OAuthConfiguration {
        let validator = OAuthURLValidator(
            allowLoopbackHTTPForAuthorizationServer: identityProvider.allowsLoopbackHTTP)
        // The identity provider's token endpoint, found once.
        let resolved = ResolvedEndpoint()
        return OAuthConfiguration(
            grantType: .jwtBearer,
            authentication: authentication,
            retryPolicy: retryPolicy,
            endpointOverrides: EndpointOverrides(authorizationServerURL: authorizationServer),
            additionalTokenRequestParameters: additionalTokenRequestParameters,
            assertionProvider: { context, session in
                let subject = try await idToken(session)
                let tokenEndpoint: URL
                switch identityProvider.endpoint {
                case .tokenEndpoint(let url):
                    tokenEndpoint = url
                case .issuer(let issuer):
                    if let cached = resolved.url {
                        tokenEndpoint = cached
                    } else {
                        tokenEndpoint = try await OAuthTokenExchange.tokenEndpoint(
                            issuer: issuer, session: session, urlValidator: validator)
                        resolved.url = tokenEndpoint
                    }
                }
                do {
                    let response = try await OAuthTokenExchange.exchange(
                        OAuthTokenExchange.Request(
                            subjectToken: subject,
                            subjectTokenType: OAuthTokenExchange.TokenType.idToken,
                            requestedTokenType: OAuthTokenExchange.TokenType.idJAG,
                            audience: context.audience.absoluteString,
                            resource: context.resource,
                            scopes: context.requestedScopes),
                        tokenEndpoint: tokenEndpoint,
                        authentication: identityProvider.authentication,
                        session: session,
                        urlValidator: validator)
                    return response.accessToken
                } catch {
                    // The metadata may have changed: discover it again next
                    // time. A cancelled exchange says nothing about it.
                    if !(error is CancellationError), !Task.isCancelled { resolved.url = nil }
                    throw error
                }
            },
            allowsDiscoveredAuthorizationServer: allowsDiscoveredAuthorizationServer)
    }

    /// A URL shared by the calls of one assertion provider.
    private final class ResolvedEndpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?

        var url: URL? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
