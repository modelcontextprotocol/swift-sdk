import Foundation
import MCP

#if canImport(System)
    import System
#endif

// Snippets for docs/client.md. See scripts/weave.swift.
//
// Each function takes a transport or a connected client, so that
// Examples/Tests/ClientSnippetTests.swift can run it against an in-process
// server.

// MARK: - Connecting

/// Connects with the default configuration: `server/discover` at 2026-07-28,
/// with a fallback to `initialize`.
func connectWithDefaults(transport: any Transport) async throws -> (Client, Initialize.Result) {
    // snippet: connect
    let client = Client(name: "my-client", version: "1.0.0")
    let result = try await client.connect(transport: transport)
    print("Connected to \(result.serverInfo.name) at \(result.protocolVersion)")
    if result.capabilities.tools != nil {
        let (tools, _) = try await client.listTools()
        print("Tools: \(tools.map(\.name))")
    }
    // endsnippet
    return (client, result)
}

/// Connects with `server/discover` when the server serves 2026-07-28.
func connectAutomatically(transport: any Transport) async throws -> Client {
    // snippet: connect-automatic
    let client = Client(
        name: "my-client", version: "1.0.0",
        configuration: .init(protocolMode: .automatic, logLevel: .warning))
    try await client.connect(transport: transport)

    let version = await client.negotiatedProtocolVersion  // "2026-07-28" or a handshake revision
    let stateless = await client.isStateless  // true at 2026-07-28
    let server = await client.serverInfo  // from initialize or server/discover
    let capabilities = await client.serverCapabilities
    print(version ?? "-", stateless, server?.name ?? "-", capabilities?.tools != nil)
    // endsnippet
    return client
}

/// Requires 2026-07-28 and reports the versions of a server that does not serve it.
func connectStatelessOnly(transport: any Transport) async throws -> Client {
    // snippet: connect-stateless
    let client = Client(
        name: "my-client", version: "1.0.0",
        configuration: .init(protocolMode: .stateless(Version.v2026_07_28)))
    do {
        try await client.connect(transport: transport)
    } catch let error as MCPError {
        if case .unsupportedProtocolVersion(let supported, let requested) = error {
            print("The server does not serve \(requested ?? "-"); it serves \(supported)")
        }
        throw error
    }
    // endsnippet
    return client
}

#if canImport(System) && os(macOS)
    /// Creates the two transports most clients use.
    func makeClientTransports() throws -> [any Transport] {
        // snippet: transports
        // A server launched as a subprocess: write to its stdin, read its stdout.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/my-mcp-server")
        let toServer = Pipe()
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        try process.run()
        let stdio = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))

        // A Streamable HTTP endpoint.
        let http = HTTPClientTransport(endpoint: URL(string: "http://localhost:8080/mcp")!)
        // endsnippet
        return [stdio, http]
    }
#endif

/// Strict mode: methods check the server's capabilities before sending.
@discardableResult
func listPromptsStrictly(transport: any Transport) async throws -> Client {
    // snippet: strict
    let client = Client(
        name: "my-client", version: "1.0.0",
        configuration: .strict)
    try await client.connect(transport: transport)
    do {
        _ = try await client.listPrompts()
    } catch MCPError.methodNotFound(let detail) {
        // Thrown before anything is sent: the server did not declare `prompts`.
        print(detail ?? "")
    }
    // endsnippet
    return client
}

/// Checks the server and closes the connection.
func pingAndDisconnect(_ client: Client) async throws {
    // snippet: ping-disconnect
    try await client.ping()  // `ping` at 2025-11-25, `server/discover` at 2026-07-28
    await client.disconnect()  // closes listen streams and fails pending requests
    // endsnippet
}
