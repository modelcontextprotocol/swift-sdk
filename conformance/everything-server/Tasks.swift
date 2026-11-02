import MCP

// SEP-2663 fixtures: the tools of the `tasks-*` scenarios.

/// Shared by every server of the process. Tasks are bound to the HTTP
/// session that created them, when there is one, which also lets
/// 2025-11-25 clients list their tasks. Callers without a session (stdio,
/// 2026-07-28) share one principal: a caller without one gets no tasks.
let conformanceTasks = TaskManager(configuration: .init(pollInterval: .milliseconds(500))) { context in
    context.httpContext?.header(HTTPHeaderName.sessionID) ?? "sessionless"
}

private func schema(_ properties: [String: Value] = [:]) -> Value {
    ["type": "object", "properties": .object(properties)]
}

private func tool(_ name: String, _ description: String, _ support: TaskSupport?, _ properties: [String: Value] = [:])
    -> Tool
{
    Tool(
        name: name, description: description, inputSchema: schema(properties),
        execution: support.map { .init(taskSupport: $0) })
}

/// The tools of the tasks scenarios.
let taskTools: [Tool] = [
    tool("greet", "Says hello; never a task", nil, ["name": ["type": "string"]]),
    tool(
        "slow_compute", "Sleeps for `seconds`, then answers", .optional,
        ["seconds": ["type": "number"], "label": ["type": "string"]]),
    tool("failing_job", "Reports a tool error after a second", .required),
    tool("protocol_error_job", "Fails with a protocol error", .optional),
    tool("confirm_delete", "Asks to confirm deleting `filename`", .optional, ["filename": ["type": "string"]]),
    tool("multi_input", "Asks two questions at once", .optional),
    tool("test_tool_with_task", "Asks for a name, then greets it in a task", .required),
]

private func text(_ value: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: value)], isError: isError)
}

private let confirmSchema = Elicitation.RequestSchema(
    properties: ["confirm": ["type": "boolean"]], required: ["confirm"])
private let nameSchema = Elicitation.RequestSchema(properties: ["name": ["type": "string"]], required: ["name"])

/// Handles the tasks tools; `nil` for any other tool.
func callTaskTool(_ params: CallTool.Parameters) async throws -> CallTool.Result? {
    let arguments = params.arguments ?? [:]
    switch params.name {
    case "greet":
        return text("Hello, \(arguments["name"]?.stringValue ?? "World")!")

    case "slow_compute":
        let seconds = arguments["seconds"]?.numberValue ?? 0
        let label = arguments["label"]?.stringValue ?? "task"
        return try await Server.runAsTask { _ in
            if seconds > 0 { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
            return text("Computed \(label) in \(seconds)s")
        }

    case "failing_job":
        return try await Server.runAsTask { _ in
            try await Task.sleep(for: .seconds(1))
            return text("The job failed", isError: true)
        }

    case "protocol_error_job":
        return try await Server.runAsTask { _ in
            throw MCPError.internalError("The job crashed")
        }

    case "confirm_delete":
        let filename = arguments["filename"]?.stringValue ?? "the file"
        return try await Server.runAsTask { task in
            let answer = try await task.elicit(message: "Delete \(filename)?", requestedSchema: confirmSchema)
            let confirmed = answer.action == .accept && answer.content?["confirm"]?.boolValue == true
            return text(confirmed ? "Deleted \(filename)" : "Kept \(filename)")
        }

    case "multi_input":
        return try await Server.runAsTask { task in
            async let first = task.requestInput(["first": .elicitation(message: "First name?", requestedSchema: nameSchema)])
            async let second = task.requestInput(["second": .elicitation(message: "Second name?", requestedSchema: nameSchema)])
            let names = try await [first["first"], second["second"]].map {
                $0?.elicitation?.content?["name"]?.stringValue ?? "?"
            }
            return text("Received \(names.joined(separator: " and "))")
        }

    case "test_tool_with_task":
        guard let name = params.inputResponses?["user_name"]?.elicitation?.content?["name"]?.stringValue else {
            return .inputRequired(["user_name": .elicitation(message: "What is your name?", requestedSchema: nameSchema)])
        }
        return try await Server.runAsTask { _ in text("Hello, \(name)!") }

    default:
        return nil
    }
}
