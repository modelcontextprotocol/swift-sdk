import Foundation
import MCP

// Snippets for docs/client.md: multi round-trip requests (SEP-2322).

/// Calls a tool whose server asks for a confirmation first.
func deployWithConfirmation(transport: any Transport, mode: Client.ProtocolMode) async throws
    -> (Client, [Tool.Content])
{
    // snippet: mrtr-auto
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(elicitation: .init()),
        configuration: .init(protocolMode: mode, multiRoundTrip: .init(maxRounds: 5)))

    // This handler answers elicitation/create sent by a 2025-11-25 server and
    // the elicitation input requests of a 2026-07-28 input-required result.
    await client.withElicitationHandler { _ in
        .init(action: .accept, content: ["confirm": true])
    }
    try await client.connect(transport: transport)

    // One call, however many rounds the server needs.
    let (content, _) = try await client.callTool(name: "deploy", arguments: ["env": "prod"])
    // endsnippet
    return (client, content)
}

/// A stand-in for asking the user.
func askUser(_ params: CreateElicitation.Parameters) async -> CreateElicitation.Result {
    .init(action: .accept, content: ["confirm": true])
}

/// A stand-in for the application's model.
func runModel(_ params: CreateSamplingMessage.Parameters) async throws -> CreateSamplingMessage.Result {
    .init(model: "my-model", role: .assistant, content: .text("OK"))
}

/// Answers input-required results without the automatic loop.
func deployManually(transport: any Transport) async throws -> CallTool.Result {
    // snippet: mrtr-manual
    let client = Client(
        name: "my-client", version: "1.0.0",
        capabilities: .init(sampling: .init(), elicitation: .init(), roots: .init()),
        configuration: .init(multiRoundTrip: .init(isEnabled: false)))
    try await client.connect(transport: transport)

    var params = CallTool.Parameters(name: "deploy", arguments: ["env": "prod"])
    var result = try await client.send(CallTool.request(params)).value
    var rounds = 0
    while result.resultType == .inputRequired {
        rounds += 1
        guard rounds <= 5 else { throw MCPError.internalError("too many rounds") }
        var responses: [String: InputResponse] = [:]
        for (key, request) in result.inputRequests ?? [:] {
            switch request {
            case .elicitation(let params): responses[key] = .elicitation(await askUser(params))
            case .sampling(let params): responses[key] = .sampling(try await runModel(params))
            case .listRoots: responses[key] = .roots(.init(roots: []))
            }
        }
        if responses.isEmpty {
            // Only requestState: the server is not done yet. Wait before retrying.
            try await Task.sleep(for: .milliseconds(100))
        }
        // Same name and arguments, the responses, and the state echoed verbatim.
        params = CallTool.Parameters(
            name: params.name, arguments: params.arguments,
            inputResponses: responses.isEmpty ? nil : responses,
            requestState: result.requestState)
        result = try await client.send(CallTool.request(params)).value
    }
    // endsnippet
    return result
}
