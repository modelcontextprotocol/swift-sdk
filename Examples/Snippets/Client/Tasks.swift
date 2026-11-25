import Foundation
import MCP

// Snippets for docs/client.md: tasks (SEP-1686 at 2025-11-25, SEP-2663 at 2026-07-28).

/// Calls a tool the server may run as a task.
func buildReport(transport: any Transport, mode: Client.ProtocolMode) async throws -> (Client, [Tool.Content]) {
    // snippet: client-tasks
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(elicitation: .init()),
        configuration: .init(
            protocolMode: mode,
            tasks: .init(augmentation: .whenSupported, requestedTTL: .seconds(600))))

    // Answers the task's questions at both revisions.
    await client.withElicitationHandler { _ in
        .init(action: .accept, content: ["drafts": true])
    }
    try await client.connect(transport: transport)

    // At 2025-11-25 the client asks for a task only for tools it has listed.
    _ = try await client.listTools()
    // Returns the task's result, however long it runs.
    let content = try await client.callTool(name: "report").content
    // endsnippet
    return (client, content)
}

/// Starts a tool call as a task and follows it.
func followReport(client: Client) async throws -> (String?, CallTool.Result) {
    // snippet: client-task-handle
    let created = try await client.startToolCall(name: "report").value
    guard let snapshot = created.task else {
        return (nil, created)  // The server ran the call inline.
    }
    // Keep the id to resume after a restart with client.task(id:).
    let task = client.task(snapshot)
    let status = try await task.snapshot().status
    print("Task \(task.id) is \(status)")
    do {
        return (task.id, try await task.result())
    } catch is TaskCancelledError {
        return (task.id, CallTool.Result(content: [.text(text: "Cancelled")], isError: true))
    }
    // endsnippet
}
