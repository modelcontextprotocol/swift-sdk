import MCP

// Snippets for docs/protocol.md, section "Lifecycle".

/// A server with one tool that reports what the SDK knows about the caller.
func makeLifecycleServer(configuration: Server.Configuration = .default) async -> Server {
    let server = Server(
        name: "example", version: "1.0.0",
        capabilities: .init(tools: .init()),
        configuration: configuration)
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [Tool(name: "whoami", description: "Describe the caller", inputSchema: ["type": "object"])])
    }
    // snippet: lifecycle-handler-context
    await server.withMethodHandler(CallTool.self) { params in
        let context = Server.currentHandlerContext
        let version = context?.protocolVersion ?? "unknown"
        let caller = context?.clientInfo?.name ?? "anonymous"
        let stateless = context?.isStateless ?? false
        return .init(content: [.text(text: "\(caller) at \(version), stateless: \(stateless)", annotations: nil, _meta: nil)])
    }
    // endsnippet
    return server
}

/// Connects with the `initialize` handshake. Returns the negotiated version.
func connectWithHandshake(server: Server) async throws -> String {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    // snippet: lifecycle-handshake
    let client = Client(name: "example-client", version: "1.0.0")  // protocolMode: .handshake
    let result = try await client.connect(transport: clientTransport)
    print(result.protocolVersion)  // 2025-11-25
    print(await client.isStateless)  // false
    // endsnippet
    await client.disconnect()
    await server.stop()
    return result.protocolVersion
}

/// Starts a server that refuses one client name during `initialize`.
func startWithInitializeHook(_ server: Server, transport: any Transport) async throws {
    // snippet: lifecycle-initialize-hook
    try await server.start(transport: transport) { clientInfo, capabilities in
        guard clientInfo.name != "blocked" else {
            throw MCPError.invalidRequest("Client not allowed")
        }
    }
    // endsnippet
}

/// Connects with `server/discover`. Returns the negotiated version.
func connectAutomatically(server: Server) async throws -> String {
    // snippet: lifecycle-automatic
    let client = Client(
        name: "example-client", version: "1.0.0",
        configuration: .init(protocolMode: .automatic))

    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let result = try await client.connect(transport: clientTransport)

    print(result.protocolVersion)  // 2026-07-28
    print(await client.isStateless)  // true
    print(await client.serverInfo?.name ?? "")  // example
    // endsnippet
    // snippet: lifecycle-shutdown
    await client.disconnect()
    await server.stop()
    // endsnippet
    return result.protocolVersion
}

/// The `_meta` envelope of a stateless request, built by hand.
func statelessEnvelope() -> Request<ServerDiscover> {
    // snippet: lifecycle-meta-keys
    var meta = Metadata()
    meta.protocolVersion = Version.v2026_07_28
    meta.clientCapabilities = Client.Capabilities()
    meta.clientInfo = Client.Info(name: "raw-client", version: "1.0.0")
    meta.logLevel = .info
    let request = ServerDiscover.request(.init(), _meta: meta)

    print(request._meta?[MetaKey.protocolVersion] ?? "")  // "2026-07-28"
    // endsnippet
    return request
}

/// A server that serves only these revisions.
func narrowedServer() -> Server {
    // snippet: lifecycle-server-versions
    let server = Server(
        name: "example", version: "1.0.0",
        configuration: .init(protocolVersions: [Version.v2026_07_28, Version.v2025_11_25]))
    // endsnippet
    return server
}

/// Connects at a stateless revision the server does not serve.
/// Returns the versions the server lists in the -32022 error.
func connectToHandshakeOnlyServer() async throws -> [String] {
    let server = Server(
        name: "legacy", version: "1.0.0",
        configuration: .init(protocolVersions: Version.handshake))
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    defer { Task { await server.stop() } }
    // snippet: lifecycle-unsupported-version
    let client = Client(
        name: "example-client", version: "1.0.0",
        configuration: .init(protocolMode: .stateless(Version.v2026_07_28)))
    do {
        try await client.connect(transport: clientTransport)
    } catch let MCPError.unsupportedProtocolVersion(supported, requested) {
        // -32022: data.supported lists what the server serves.
        print("not served: \(requested ?? "?"); server serves \(supported)")
        return supported
    }
    // endsnippet
    await client.disconnect()
    return []
}
