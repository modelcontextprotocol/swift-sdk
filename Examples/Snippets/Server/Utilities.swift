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
/// The level a handshake client chose with logging/setLevel.
actor LogThreshold {
    private(set) var level: LogLevel = .info
    func set(_ level: LogLevel) { self.level = level }
}

func registerLogging(on server: Server, threshold: LogThreshold) async {
    // 2025-11-25 and earlier. The SDK neither stores nor applies this level.
    await server.withMethodHandler(SetLoggingLevel.self) { params in
        await threshold.set(params.level)
        return Empty()
    }
}

/// Sends a log message at the level each era asks for.
func log(_ level: LogLevel, _ message: String, server: Server, threshold: LogThreshold) async throws {
    // A stateless request carries its own level, and server.log applies it.
    if Server.currentHandlerContext?.isStateless != true {
        guard level >= (await threshold.level) else { return }
    }
    try await server.log(level: level, logger: "deploy", data: ["message": .string(message)])
}
// endsnippet
