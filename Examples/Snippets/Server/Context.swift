import MCP

// Snippets for docs/server.md: handler context, capabilities, pagination.

// snippet: handler-context
func describeCaller() -> String {
    guard let context = Server.currentHandlerContext else { return "not in a handler" }
    let era = context.isStateless ? "stateless" : "handshake"
    return [
        "protocol: \(context.protocolVersion ?? "none") (\(era))",
        "client: \(context.clientInfo?.name ?? "anonymous")",
        "elicitation: \(context.clientCapabilities?.elicitation != nil)",
        "log level: \(context.logLevel?.rawValue ?? "none")",
        "server requests: \(context.profile?.allowsServerRequests ?? true)",
    ].joined(separator: "\n")
}
// endsnippet

// snippet: http-context
/// The bearer token of the HTTP request being handled, if any.
func bearerToken() -> String? {
    guard let header = Server.currentHandlerContext?.httpContext?.header(HTTPHeaderName.authorization),
        header.hasPrefix("Bearer ")
    else { return nil }
    return String(header.dropFirst("Bearer ".count))
}

/// Detached tasks do not inherit task-locals: capture the context first.
func audit(_ tool: String, record: @escaping @Sendable (String, String?) async -> Void) {
    let context = Server.currentHandlerContext
    Task.detached {
        await record(tool, context?.clientInfo?.name)
    }
}
// endsnippet

// snippet: capabilities
let auditExtension = "com.example/audit"

func makeServerWithExtension() -> Server {
    Server(
        name: "audited", version: "1.0.0",
        capabilities: .init(
            completions: .init(),
            tools: .init(listChanged: true),
            experimental: ["com.example/beta": true],
            extensions: [auditExtension: ["retentionDays": 30]]))
}

/// Whether the client declared the audit extension, for this request.
func clientSupportsAudit() -> Bool {
    Server.currentHandlerContext?.clientCapabilities?.extensions?[auditExtension] != nil
}
// endsnippet

// snippet: pagination
func registerPagedTools(on server: Server, tools: [Tool], pageSize: Int = 50) async {
    await server.withMethodHandler(ListTools.self) { params in
        // The cursor is opaque to clients. Here it is the index of the next tool.
        let start = params.cursor.map { Int($0) ?? -1 } ?? 0
        guard (0...tools.count).contains(start) else {
            throw MCPError.invalidParams("Invalid cursor")
        }
        let end = min(start + pageSize, tools.count)
        return ListTools.Result(
            tools: Array(tools[start..<end]),
            nextCursor: end < tools.count ? String(end) : nil)
    }
}
// endsnippet
