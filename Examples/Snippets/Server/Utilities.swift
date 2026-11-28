import MCP

// Snippets for docs/server.md: completion and logging.

// snippet: completion
func registerCompletions(on server: Server) async {
    let languages = ["go", "python", "rust", "swift", "typescript"]
    let files = ["README.md", "Package.swift", "Sources/App/main.swift"]
    await server.withMethodHandler(Complete.self) { params in
        let prefix = params.argument.value.lowercased()
        let candidates: [String]
        switch params.ref {
        case .prompt(let prompt) where prompt.name == "code_review" && params.argument.name == "language":
            candidates = languages
        case .resource(let template) where template.uri == "file:///project/{path}":
            candidates = files
        default:
            candidates = []
        }
        let matches = candidates.filter { $0.lowercased().hasPrefix(prefix) }
        // At most 100 values per result.
        return Complete.Result(
            completion: .init(values: Array(matches.prefix(100)), total: matches.count, hasMore: matches.count > 100))
    }
}
// endsnippet

// snippet: logging-level
/// A server that logs. With the `logging` capability, `log` applies the
/// level the client chose, in either era.
@available(*, deprecated, message: "Uses the deprecated logging API (SEP-2577)")
func makeLoggingServer() async -> Server {
    let server = Server(
        name: "deployer", version: "1.0.0",
        capabilities: .init(logging: .init(), tools: .init()))
    // The server keeps its handlers: a strong capture would keep it alive.
    await server.withMethodHandler(CallTool.self) { [weak server] _ in
        guard let server else { return .init(content: [.text(text: "Server stopped")], isError: true) }
        try await server.log(level: .info, logger: "deploy", data: ["message": "starting"])
        try await server.log(level: .error, logger: "deploy", data: ["message": "failed"])
        return .init(content: [])
    }
    return server
}
// endsnippet
