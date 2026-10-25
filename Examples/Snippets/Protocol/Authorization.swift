import Foundation
import MCP

// Snippets for docs/protocol.md, sections "Authorization" and "Security".

/// A machine-to-machine client.
func clientCredentialsTransport(endpoint: URL, secret: String) -> HTTPClientTransport {
    // snippet: auth-client-credentials
    let configuration = OAuthConfiguration(
        grantType: .clientCredentials,
        authentication: .clientSecretBasic(clientID: "reporting-service", clientSecret: secret))
    let authorizer = OAuthAuthorizer(configuration: configuration)
    let transport = HTTPClientTransport(endpoint: endpoint, authorizer: authorizer)
    // endsnippet
    return transport
}

// snippet: auth-delegate
/// Opens the authorization URL and returns the redirect URL.
struct BrowserAuthorization: OAuthAuthorizationDelegate {
    let open: @Sendable (URL) async throws -> URL

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        // The returned URL must carry the `code`, `state` and (RFC 9207) `iss`
        // query parameters exactly as the authorization server sent them.
        try await open(url)
    }
}
// endsnippet

/// An interactive client that identifies itself with a Client ID Metadata Document.
func authorizationCodeTransport(
    endpoint: URL, open: @escaping @Sendable (URL) async throws -> URL
) -> HTTPClientTransport {
    // snippet: auth-authorization-code
    let configuration = OAuthConfiguration(
        grantType: .authorizationCode,
        // An https URL with a path is used as a Client ID Metadata Document
        // when the server supports it. An empty ID, or a URL the server does
        // not accept as a metadata document, registers dynamically; a plain
        // ID is pre-registered.
        authentication: .none(clientID: "https://app.example.com/oauth/client.json"),
        authorizationRedirectURI: URL(string: "http://127.0.0.1:8765/callback")!,
        clientName: "Example App",
        applicationType: .native,  // nil infers it from the redirect URI
        authorizationDelegate: BrowserAuthorization(open: open))
    let transport = HTTPClientTransport(
        endpoint: endpoint, authorizer: OAuthAuthorizer(configuration: configuration))
    // endsnippet
    return transport
}

/// A client in an enterprise that manages access to MCP servers (SEP-990).
func enterpriseConfiguration(signIn: @escaping @Sendable () async throws -> String) -> OAuthConfiguration {
    // snippet: auth-enterprise
    let configuration = OAuthConfiguration.enterpriseManaged(
        // The client's credentials at the MCP authorization server.
        authentication: .clientSecretBasic(clientID: "chat-app", clientSecret: "app-secret"),
        // Pinned: the MCP server cannot send the identity assertion elsewhere.
        authorizationServer: URL(string: "https://auth.example.com")!,
        identityProvider: .init(
            endpoint: .issuer(URL(string: "https://login.example.com")!),
            authentication: .clientSecretPost(clientID: "chat-app-idp", clientSecret: "idp-secret")),
        // The user's ID token, from the app's sign-in at the identity provider.
        idToken: { _ in try await signIn() })
    // endsnippet
    return configuration
}

/// A workload that authenticates with its platform identity (SEP-1933).
func workloadConfiguration(readToken: @escaping @Sendable () throws -> String) -> OAuthConfiguration {
    // snippet: auth-workload-identity
    let configuration = OAuthConfiguration(
        grantType: .jwtBearer,
        authentication: .none(clientID: ""),
        // Pinned: the workload's JWT goes only to this authorization server.
        endpointOverrides: .init(authorizationServerURL: URL(string: "https://auth.example.com")!),
        assertionProvider: { context, _ in
            // A JWT for `context.audience`, issued by the workload's platform,
            // for example read from a projected service account token file.
            try readToken()
        })
    // endsnippet
    return configuration
}

// snippet: auth-token-storage
/// Keeps the access token across launches. Replace the dictionary with the Keychain.
final class PersistentTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func save(_ token: OAuthAccessToken) {
        lock.withLock { stored = try? JSONEncoder().encode(token) }
    }

    func load() -> OAuthAccessToken? {
        lock.withLock { stored.flatMap { try? JSONDecoder().decode(OAuthAccessToken.self, from: $0) } }
    }

    func clear() {
        lock.withLock { stored = nil }
    }
}
// endsnippet

/// An authorizer that uses the persistent storage above.
func authorizerWithStorage(configuration: OAuthConfiguration) -> OAuthAuthorizer {
    // snippet: auth-authorizer-storage
    let authorizer = OAuthAuthorizer(
        configuration: configuration,
        tokenStorage: PersistentTokenStorage())
    // endsnippet
    return authorizer
}

/// Checks a token. A real server verifies a JWT signature or calls introspection.
func verifyToken(_ token: String) -> (subject: String, audience: [String], expiresAt: Date, scopes: Set<String>)? {
    guard token == "valid-token" else { return nil }
    return ("user-1", ["https://mcp.example.com/mcp"], Date().addingTimeInterval(3600), ["tools:read"])
}

/// A validation pipeline for a protected stateful transport.
func protectedPipeline() -> StandardValidationPipeline {
    // snippet: auth-server-pipeline
    let resource = URL(string: "https://mcp.example.com/mcp")!
    let metadataURL = URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource")!

    let metadata = ProtectedResourceMetadataValidator(
        metadata: OAuthProtectedResourceServerMetadata(
            resource: resource.absoluteString,
            authorizationServers: [URL(string: "https://auth.example.com")!],
            scopesSupported: ["tools:read", "tools:write"]))

    let bearer = BearerTokenValidator(
        resourceMetadataURL: metadataURL,
        resourceIdentifier: resource,
        tokenValidator: { token, request, context in
            guard let claims = verifyToken(token) else {
                return .invalidToken(errorDescription: "Unknown token")
            }
            guard claims.scopes.contains("tools:read") else {
                return .insufficientScope(requiredScopes: ["tools:read"])
            }
            // The validator rejects expired tokens and tokens for another audience.
            return .valid(BearerTokenInfo(
                audience: claims.audience, scopes: claims.scopes, expiresAt: claims.expiresAt))
        })

    let pipeline = StandardValidationPipeline(validators: [
        metadata,  // before the bearer check: discovery is unauthenticated
        bearer,
        OriginValidator(allowedHosts: ["mcp.example.com"], allowedOrigins: ["https://app.example.com"]),
        AcceptHeaderValidator(mode: .sseRequired),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
        SessionValidator(),
    ])
    // endsnippet
    return pipeline
}

/// A protected stateful transport.
func protectedTransport() -> StatefulHTTPServerTransport {
    // snippet: auth-server-transport
    let transport = StatefulHTTPServerTransport(validationPipeline: protectedPipeline())
    // endsnippet
    return transport
}

/// Reads the bearer token in a handler, to act on behalf of the user.
func registerUserAwareTool(on server: Server) async {
    // snippet: security-session-binding
    await server.withMethodHandler(CallTool.self) { params in
        // The pipeline has already validated the token for this request.
        guard let authorization = Server.currentHandlerContext?.httpContext?.header("Authorization"),
            let claims = verifyToken(String(authorization.dropFirst("Bearer ".count)))
        else {
            throw MCPError.invalidRequest("Unauthenticated")
        }
        // Use claims.subject to scope data access. Never forward the token itself.
        return .init(content: [.text(text: "Hello, \(claims.subject)", annotations: nil, _meta: nil)])
    }
    // endsnippet
}

/// A server whose sealed `requestState` survives restarts and multiple instances.
func serverWithSharedRequestStateKey(key: Data) throws -> Server {
    // snippet: security-request-state
    let server = Server(
        name: "example", version: "1.0.0",
        requestStateProtection: try RequestStateProtection(
            keys: [key],  // at least 32 random bytes, shared by every instance
            principal: { context in  // bind state to the authenticated user
                context.httpContext?.header("Authorization")
                    .flatMap { verifyToken(String($0.dropFirst("Bearer ".count)))?.subject }
            }))
    // endsnippet
    return server
}
