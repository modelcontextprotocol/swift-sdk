import MCP

// SEP-2322 fixtures: tools and a prompt that return input-required results.

private let emptySchema: Value = ["type": "object", "properties": [:]]

/// The tools of the `input-required-result-*` scenarios.
let inputRequiredTools: [Tool] = [
    Tool(name: "test_input_required_result_elicitation", description: "Asks for the user's name (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_sampling", description: "Asks the client's model a question (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_list_roots", description: "Asks for the client's roots (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_request_state", description: "Round-trips requestState (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_multiple_inputs", description: "Asks for elicitation, sampling and roots at once (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_multi_round", description: "Asks for input over two rounds (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_tampered_state", description: "Rejects modified requestState (SEP-2322)", inputSchema: emptySchema),
    Tool(name: "test_input_required_result_capabilities", description: "Asks only for declared client capabilities (SEP-2322)", inputSchema: emptySchema),
]

/// The prompt of the `input-required-result-non-tool-request` scenario.
let inputRequiredPrompt = Prompt(
    name: "test_input_required_result_prompt", description: "Asks for context before it is returned (SEP-2322)")

private func text(_ value: String) -> CallTool.Result {
    .init(content: [.text(text: value)], isError: false)
}

private func ask(_ message: String, field: String, type: String = "string") -> InputRequest {
    .elicitation(
        message: message,
        requestedSchema: .init(properties: [field: ["type": .string(type)]], required: [field]))
}

private let askName = ask("What is your name?", field: "name")
private let askCapital = InputRequest.sampling(
    .init(messages: [.user(.text("What is the capital of France?"))], maxTokens: 100))
private let askGreeting = InputRequest.sampling(
    .init(messages: [.user(.text("Generate a greeting"))], maxTokens: 50))

private func sampledText(_ response: InputResponse?) -> String? {
    response?.sampling?.content.asArray.compactMap { block -> String? in
        if case .text(let text) = block { return text }
        return nil
    }.joined(separator: " ")
}

/// Handles the SEP-2322 tools; `nil` for any other tool.
func callInputRequiredTool(_ params: CallTool.Parameters) throws -> CallTool.Result? {
    let responses = params.inputResponses ?? [:]
    switch params.name {
    case "test_input_required_result_elicitation":
        guard let name = responses["user_name"]?.elicitation?.content?["name"]?.stringValue else {
            return .inputRequired(["user_name": askName])
        }
        return text("Hello, \(name)!")

    case "test_input_required_result_sampling":
        guard let answer = sampledText(responses["capital_question"]) else {
            return .inputRequired(["capital_question": askCapital])
        }
        return text("The model answered: \(answer)")

    case "test_input_required_result_list_roots":
        guard let roots = responses["client_roots"]?.roots else {
            return .inputRequired(["client_roots": .listRoots])
        }
        return text("Roots: \(roots.map(\.uri).joined(separator: ", "))")

    case "test_input_required_result_request_state":
        guard params.requestState == "confirm-pending", responses["confirm"]?.elicitation != nil else {
            return .inputRequired(
                ["confirm": ask("Please confirm", field: "ok", type: "boolean")], requestState: "confirm-pending")
        }
        return text("state-ok: confirmed")

    case "test_input_required_result_multiple_inputs":
        var missing: [String: InputRequest] = [:]
        if responses["user_name"]?.elicitation == nil { missing["user_name"] = askName }
        if responses["greeting"]?.sampling == nil { missing["greeting"] = askGreeting }
        if responses["client_roots"]?.roots == nil { missing["client_roots"] = .listRoots }
        guard missing.isEmpty else { return .inputRequired(missing, requestState: "multiple-pending") }
        let name = responses["user_name"]?.elicitation?.content?["name"]?.stringValue ?? "?"
        return text("\(sampledText(responses["greeting"]) ?? "Hello"), \(name)!")

    case "test_input_required_result_multi_round":
        switch params.requestState {
        case "round-1":
            guard let name = responses["step1"]?.elicitation?.content?["name"]?.stringValue else { break }
            return .inputRequired(
                ["step2": ask("Step 2: What is your favorite color?", field: "color")],
                requestState: "round-2:\(name)")
        case let state? where state.hasPrefix("round-2:"):
            guard let color = responses["step2"]?.elicitation?.content?["color"]?.stringValue else { break }
            return text("\(state.dropFirst("round-2:".count)) likes \(color)")
        default:
            break
        }
        return .inputRequired(["step1": ask("Step 1: What is your name?", field: "name")], requestState: "round-1")

    case "test_input_required_result_tampered_state":
        guard params.requestState == "integrity-checked", responses["confirm"] != nil else {
            return .inputRequired(
                ["confirm": ask("Please confirm", field: "ok", type: "boolean")], requestState: "integrity-checked")
        }
        return text("State verified")

    case "test_input_required_result_capabilities":
        guard responses.isEmpty else { return text("Received \(responses.keys.sorted().joined(separator: ", "))") }
        let declared = Server.currentHandlerContext?.clientCapabilities ?? .init()
        var requests: [String: InputRequest] = [:]
        if declared.elicitation != nil { requests["user_name"] = askName }
        if declared.sampling != nil { requests["capital_question"] = askCapital }
        if declared.roots != nil { requests["client_roots"] = .listRoots }
        guard !requests.isEmpty else { return text("The client declared no input capabilities") }
        return .inputRequired(requests)

    default:
        return nil
    }
}

/// Handles the SEP-2322 prompt.
func getInputRequiredPrompt(_ params: GetPrompt.Parameters) -> GetPrompt.Result {
    guard let context = params.inputResponses?["user_context"]?.elicitation?.content?["context"]?.stringValue else {
        return .inputRequired(["user_context": ask("What context should the prompt use?", field: "context")])
    }
    return .init(
        description: "Prompt built from elicited context",
        messages: [.user(.text(text: "Use this context: \(context)"))])
}
