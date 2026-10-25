import Foundation
import Logging
import MCP

// Snippets for docs/troubleshooting.md. See scripts/weave.swift.

// snippet: logging-logger
/// A logger for an SDK transport. Standard error keeps standard output free
/// for a stdio transport's messages.
func makeDebugLogger(label: String = "mcp") -> Logger {
    var logger = Logger(label: label) { StreamLogHandler.standardError(label: $0) }
    logger.logLevel = .trace
    return logger
}

func makeLoggedTransports() async -> (StdioTransport, InMemoryTransport, InMemoryTransport) {
    let logger = makeDebugLogger()
    let stdio = StdioTransport(logger: logger)
    let (client, server) = await InMemoryTransport.createConnectedPair(logger: logger)
    return (stdio, client, server)
}
// endsnippet

// snippet: logging-wire
/// Wraps a transport and records every message it sends and receives.
actor WireLog: Transport {
    nonisolated let logger: Logger
    private let base: any Transport
    private(set) var lines: [String] = []

    init(_ base: any Transport, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }

    func send(_ data: Data) async throws {
        record("send", data)
        try await base.send(data)
    }

    func send(_ data: Data, relatedRequestID: ID?) async throws {
        record("send", data)
        try await base.send(data, relatedRequestID: relatedRequestID)
    }

    /// Forwards the `Mcp-Param-*` headers of a `tools/call` at 2026-07-28.
    func send(_ data: Data, additionalHeaders: [String: String]) async throws {
        record("send", data)
        try await base.send(data, additionalHeaders: additionalHeaders)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        self.record("receive", data)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ direction: String, _ data: Data) {
        let line = "\(direction): \(String(decoding: data, as: UTF8.self))"
        lines.append(line)
        logger.debug("\(line)")
    }
}
// endsnippet

// snippet: errors-inspect
/// Lists prompts and reports a protocol error by its code.
func listPromptsReportingErrors(_ client: Client) async -> String {
    do {
        let prompts = try await client.listPrompts().prompts
        return "\(prompts.count) prompts"
    } catch let error as MCPError {
        // `code` and `data` are the JSON-RPC `code` and `data` members.
        return "[\(error.code)] \(error.localizedDescription) data: \(error.data.map { "\($0)" } ?? "none")"
    } catch {
        return "transport or local error: \(error)"
    }
}
// endsnippet

// snippet: timeout
/// Calls a tool, and cancels the request when it takes longer than `limit`.
/// A cancelled call throws `CancellationError`.
func callTool(
    _ name: String, on client: Client, timeout limit: Duration
) async throws -> CallTool.Result {
    let request = try await client.startToolCall(name: name)
    let timer = Task {
        try await Task.sleep(for: limit)
        try await client.cancelRequest(request.requestID, reason: "Timed out after \(limit)")
    }
    defer { timer.cancel() }
    return try await request.value
}
// endsnippet

// snippet: era-neutral-input
/// Asks the user for confirmation in both eras: at 2026-07-28 the client
/// answers the input request; for `initialize` clients the server sends
/// `elicitation/create` itself and calls the handler again.
func registerConfirmTool(on server: Server) async {
    await server.withMethodHandler(CallTool.self) { params in
        guard let answer = params.inputResponses?["confirm"]?.elicitation else {
            return .inputRequired(["confirm": .elicitation(message: "Delete the file?")])
        }
        let text = answer.action == .accept ? "Deleted" : "Kept"
        return CallTool.Result(content: [.text(text: text)])
    }
}
// endsnippet
