import MCP

// Snippets for docs/server.md: list-changed notifications.

// snippet: list-changed
/// Tools that change at run time. Each change notifies the clients.
actor ToolCatalog {
    private var tools: [String: Tool] = [:]
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    var all: [Tool] { tools.values.sorted { $0.name < $1.name } }

    func add(_ tool: Tool) async throws {
        tools[tool.name] = tool
        try await server.notify(ToolListChangedNotification.message())
    }

    func remove(_ name: String) async throws {
        guard tools.removeValue(forKey: name) != nil else { return }
        try await server.notify(ToolListChangedNotification.message())
    }
}

func makeDynamicServer() async -> (Server, ToolCatalog) {
    let server = Server(
        name: "dynamic", version: "1.0.0",
        // listChanged: true, or listen streams do not carry tool changes.
        capabilities: .init(tools: .init(listChanged: true)))
    let catalog = ToolCatalog(server: server)
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: await catalog.all)
    }
    return (server, catalog)
}
// endsnippet
