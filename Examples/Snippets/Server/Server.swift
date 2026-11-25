import MCP

// Snippets for docs/server.md: creating a server and its lifecycle.
// See scripts/weave.swift.

// snippet: create-server
func makeServer() -> Server {
    Server(
        name: "weather",
        version: "1.0.0",
        title: "Weather",
        instructions: "Use get_weather for current conditions.",
        capabilities: .init(
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: true)))
}
// endsnippet

// snippet: configuration
/// A server for `initialize` clients only, that rejects requests sent
/// before `initialize`.
func makeHandshakeOnlyServer() -> Server {
    Server(
        name: "legacy",
        version: "1.0.0",
        capabilities: .init(tools: .init()),
        configuration: .init(
            strict: true,
            protocolVersions: Version.handshake))
}
// endsnippet

// snippet: lifecycle-run
/// Serves until the transport closes or the calling task is cancelled.
func serve(_ server: Server, on transport: any Transport) async throws {
    try await server.start(transport: transport) { clientInfo, capabilities in
        // Runs for `initialize` only. 2026-07-28 clients never send it.
        guard clientInfo.name != "blocked-client" else {
            throw MCPError.invalidRequest("This client is not allowed")
        }
    }
    await withTaskCancellationHandler {
        await server.waitUntilCompleted()
    } onCancel: {
        Task { await server.stop() }
    }
}
// endsnippet
