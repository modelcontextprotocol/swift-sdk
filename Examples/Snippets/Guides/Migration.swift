import Foundation
import MCP

// Snippets for docs/migration.md. See scripts/weave.swift.

// snippet: migration-error-switch
/// Describes an error. A `switch` over `MCPError` needs the new cases, or a
/// `default`, and three bindings for `serverError`.
func describeError(_ error: MCPError) -> String {
    switch error {
    case .serverError(let code, let message, let data):
        return "\(code) \(message) \(data.map { "\($0)" } ?? "")"
    case .resourceNotFound(let uri, _):
        return "No resource at \(uri)"
    case .headerMismatch, .missingRequiredClientCapabilities, .unsupportedProtocolVersion:
        return "Protocol error \(error.code): \(error.localizedDescription)"
    default:
        return error.localizedDescription
    }
}
// endsnippet

// snippet: migration-error-data
/// Throws an implementation-defined error with structured `data`.
func throwQuotaExceeded() throws -> Never {
    throw MCPError.serverError(
        code: -32050, message: "Quota exceeded", data: ["retryAfterSeconds": 30])
}
// endsnippet

// snippet: migration-experimental
/// `experimental` takes JSON values; `extensions` is new.
let migratedCapabilities = Client.Capabilities(
    experimental: ["com.example/feature": ["enabled": true, "level": 2]],
    extensions: ["com.example/extension": [:]])
// endsnippet

// snippet: migration-http-response
/// Reads the body of a response; `.data` and `.error` have new associated values.
func responseBody(_ response: HTTPResponse) -> Data? {
    switch response {
    case .data(let data, _, _):
        return data
    case .error(let statusCode, let error, _, _, _):
        return Data("\(statusCode) \(error.code)".utf8)
    default:
        return response.bodyData
    }
}
// endsnippet

// snippet: migration-handshake-only
/// Keeps the previous behavior: serve `initialize` clients only.
func makeHandshakeOnlyServer() -> Server {
    Server(
        name: "legacy", version: "1.0.0", capabilities: .init(tools: .init()),
        configuration: .init(protocolVersions: Version.handshake))
}
// endsnippet

// snippet: migration-handshake-client
/// Keeps the previous behavior: connect with `initialize` only.
func makeHandshakeClient() -> Client {
    Client(
        name: "app", version: "1.0.0",
        configuration: .init(protocolMode: .handshake))
}
// endsnippet

// snippet: migration-oauth-error
/// Reads an authorization failure. A static member matches a code; the details
/// are properties.
func describeAuthorizationError(_ error: any Error) -> String {
    switch error {
    case OAuthAuthorizationError.dpopRequired:
        return "Set OAuthConfiguration.dpop"
    case let error as OAuthAuthorizationError where error.code == .tokenRequestFailed:
        return "Token request failed: \(error.statusCode ?? 0) \(error.oauthError ?? "")"
    default:
        return error.localizedDescription
    }
}
// endsnippet

// snippet: migration-open-struct
/// A `switch` over an open struct needs a `default`.
func describeGrant(_ grantType: OAuthConfiguration.GrantType) -> String {
    switch grantType {
    case .authorizationCode: return "interactive"
    case .clientCredentials, .jwtBearer: return "machine to machine"
    default: return grantType.rawValue
    }
}
// endsnippet

// snippet: migration-client-results
/// The convenience methods return the request's result.
func callAndList(_ client: Client) async throws -> (text: [String], nextCursor: String?) {
    let result = try await client.callTool(name: "echo", arguments: ["text": "hi"])
    let text = result.content.compactMap { block -> String? in
        if case .text(let text, _, _) = block { return text }
        return nil
    }
    let page = try await client.listTools()
    return (text, page.nextCursor)
}
// endsnippet

// snippet: migration-connection-info
/// `connect` returns a `Client.ConnectionInfo`; `serverInfo` is optional.
func describeServer(_ client: Client, transport: any Transport) async throws -> String {
    let connection = try await client.connect(transport: transport)
    let name = connection.serverInfo?.name ?? "unnamed server"
    return "\(name) at \(connection.protocolVersion)"
}
// endsnippet

// snippet: migration-content
/// `annotations` and `_meta` default to `nil`.
let greeting: [Tool.Content] = [
    .text(text: "Hello"),
    .image(data: "iVBORw0KGgo=", mimeType: "image/png"),
]
// endsnippet

// snippet: migration-http-errors
/// HTTP and OAuth failures are typed errors inside `transportError`.
func describeFailure(_ error: any Error) -> String {
    switch error {
    case MCPError.transportError(let status as HTTPStatusError) where status.isSessionExpired:
        return "The session expired; connect again"
    case MCPError.transportError(let status as HTTPStatusError):
        return "HTTP \(status.statusCode), retry after \(status.value(forHeader: "Retry-After") ?? "?")"
    case MCPError.transportError(let oauth as OAuthAuthorizationError):
        return "Authorization failed: \(oauth.code)"
    default:
        return error.localizedDescription
    }
}
// endsnippet
