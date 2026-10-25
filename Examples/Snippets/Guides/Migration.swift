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

// snippet: migration-opt-in-client
/// Opts a client in to 2026-07-28, with a fallback for older servers.
func makeAutomaticClient() -> Client {
    Client(
        name: "app", version: "1.0.0",
        configuration: .init(protocolMode: .automatic, logLevel: .warning))
}
// endsnippet
