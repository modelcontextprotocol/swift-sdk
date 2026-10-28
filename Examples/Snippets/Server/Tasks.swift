import Foundation
import MCP

// Snippets for docs/server.md: tasks (SEP-1686 at 2025-11-25, SEP-2663 at 2026-07-28).

// snippet: tasks-server
/// A server whose `report` tool runs as a task when the client can use one.
func makeReportServer(tasks: TaskManager = TaskManager()) async -> Server {
    let server = Server(name: "reports", version: "1.0.0", capabilities: .init(tools: .init()))
    await server.withTasks(tasks)
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "report", description: "Builds a report", inputSchema: ["type": "object"],
                execution: .init(taskSupport: .optional))
        ])
    }
    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "report" else { throw MCPError.invalidParams("Unknown tool: \(params.name)") }
        return try await Server.runAsTask { task in
            await task.setStatusMessage("Collecting data")
            let answer = try await task.elicit(
                message: "Include drafts?",
                requestedSchema: .init(properties: ["drafts": ["type": "boolean"]], required: ["drafts"]))
            try await task.reportProgress(1, total: 1)
            let drafts = answer.action == .accept && answer.content?["drafts"]?.boolValue == true
            return CallTool.Result(content: [.text(text: drafts ? "Report with drafts" : "Report")])
        }
    }
    return server
}
// endsnippet

// snippet: tasks-manager
/// One manager for every server of the process, so a task outlives the
/// session that created it. `authenticatedUser` reads the identity your
/// authentication established, such as the subject of a verified bearer
/// token.
func makeTaskManager(authenticatedUser: @escaping @Sendable (HTTPRequest) -> String?) -> TaskManager {
    TaskManager(
        configuration: .init(
            defaultTTL: .seconds(600),  // when the client asks for none
            maximumTTL: .seconds(3600),  // a longer requested ttl is shortened
            pollInterval: .seconds(2),
            maxActiveTasks: 200,
            maxActiveTasksPerPrincipal: 10)
    ) { context in
        // Never a header the client sets itself, such as X-User-ID.
        context.httpContext.flatMap(authenticatedUser)
    }
}
// endsnippet

// snippet: tasks-external
/// Hands the work to a job system, which completes the task when the job ends.
func startExternalJob(
    _ name: String, manager: TaskManager,
    submit: @escaping @Sendable (_ name: String, _ done: @escaping @Sendable (String) async -> Void) -> Void
) async throws -> CallTool.Result {
    try await Server.runAsTask { task in
        guard let id = task.taskID else {
            throw MCPError.invalidRequest("\(name) runs only as a task")
        }
        submit(name) { output in
            try? await manager.complete(id, with: CallTool.Result(content: [.text(text: output)]))
        }
        return try await task.untilFinished()
    }
}
// endsnippet
