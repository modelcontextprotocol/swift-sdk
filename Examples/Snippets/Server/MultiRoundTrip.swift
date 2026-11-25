import Foundation
import MCP

// Snippets for docs/server.md: multi round-trip requests (SEP-2322).

// snippet: mrtr-handler
func registerDeployTool(on server: Server) async {
    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "deploy" else {
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
        }
        let environment = params.arguments?["environment"]?.stringValue ?? "staging"

        // Round 2: the client sent the answer under the key of the request.
        if let answer = params.inputResponses?["confirm"]?.elicitation {
            guard answer.action == .accept, answer.content?["confirm"]?.boolValue == true else {
                return CallTool.Result(content: [.text(text: "Cancelled")])
            }
            // requestState is the plaintext this handler returned in round 1.
            let build = params.requestState ?? "unknown"
            return CallTool.Result(content: [
                .text(text: "Deployed \(build) to \(environment)")
            ])
        }

        // Round 1: ask, and keep what round 2 needs in requestState.
        return .inputRequired(
            [
                "confirm": .elicitation(
                    message: "Deploy to \(environment)?",
                    requestedSchema: .init(properties: ["confirm": ["type": "boolean"]], required: ["confirm"]))
            ],
            requestState: "build-1234")
    }
}
// endsnippet

// snippet: mrtr-several
/// Asks for the client's roots and a model summary in the same round.
func summarizeWorkspace(_ params: CallTool.Parameters) -> CallTool.Result {
    let responses = params.inputResponses ?? [:]
    guard let roots = responses["roots"]?.roots, let summary = responses["summary"]?.sampling else {
        return .inputRequired([
            "roots": .listRoots,
            "summary": .sampling(
                .init(messages: [.user(.text("Summarize the workspace layout."))], maxTokens: 200)),
        ])
    }
    let text = "\(roots.count) roots. Model: \(summary.model)"
    return CallTool.Result(content: [.text(text: text)])
}
// endsnippet

// snippet: mrtr-capabilities
/// Asks for confirmation only when the client can answer.
func confirmation(_ message: String) -> CallTool.Result {
    guard Server.currentHandlerContext?.clientCapabilities?.elicitation != nil else {
        // Returning the input request anyway fails with -32021 at 2026-07-28.
        return CallTool.Result(
            content: [.text(text: "This tool needs a client with elicitation")],
            isError: true)
    }
    return .inputRequired(["confirm": .elicitation(message: message)])
}
// endsnippet

// snippet: server-requests
/// Asks the client directly. 2025-11-25 and earlier only: at 2026-07-28
/// these calls throw -32600; return input requests instead.
func confirmDirectly(on server: Server) async throws -> Bool {
    let roots = try await server.listRoots()
    let answer = try await server.requestElicitation(
        message: "Clean \(roots.count) workspace roots?",
        requestedSchema: .init(properties: ["confirm": ["type": "boolean"]], required: ["confirm"]))
    return answer.action == .accept && answer.content?["confirm"]?.boolValue == true
}

func watchRoots(on server: Server, changed: @escaping @Sendable () async -> Void) async {
    await server.onNotification(RootsListChangedNotification.self) { _ in
        await changed()
    }
}
// endsnippet

// snippet: mrtr-shared-keys
/// Several instances behind a load balancer: every instance gets the same
/// keys, so a retry may reach any of them. `authenticatedUser` reads the
/// identity your authentication established, such as the subject of a
/// verified bearer token.
func makeClusteredServer(
    currentKey: Data, previousKey: Data,
    authenticatedUser: @escaping @Sendable (HTTPRequest) -> String?
) throws -> Server {
    Server(
        name: "deployer",
        version: "1.0.0",
        capabilities: .init(tools: .init()),
        requestStateProtection: try RequestStateProtection(
            keys: [currentKey, previousKey],  // keys[0] seals; every key verifies
            timeToLive: .seconds(300),
            // Never a header the client sets itself, such as X-User-ID.
            principal: { context in context.httpContext.flatMap(authenticatedUser) }))
}
// endsnippet

// snippet: mrtr-codec
/// Keeps the state on the server and gives the client a random handle.
/// Remove entries after the time-to-live in production.
final class StoredRequestState: RequestStateCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [String: Data] = [:]

    func seal(_ payload: Data) throws -> String {
        let handle = UUID().uuidString
        lock.withLock { payloads[handle] = payload }
        return handle
    }

    func unseal(_ token: String) throws -> Data {
        guard let payload = lock.withLock({ payloads[token] }) else {
            throw InvalidRequestState("unknown handle")
        }
        return payload
    }
}

func makeServerWithStoredState() -> Server {
    Server(
        name: "deployer", version: "1.0.0", capabilities: .init(tools: .init()),
        requestStateProtection: RequestStateProtection(codec: StoredRequestState()))
}
// endsnippet

// snippet: mrtr-unprotected
/// The state goes to the client as written and comes back unchecked.
/// Only for state that cannot affect authorization, resource access or
/// business logic, such as a page number.
func makeServerWithPlainState() -> Server {
    Server(
        name: "pager", version: "1.0.0", capabilities: .init(tools: .init()),
        requestStateProtection: nil)
}
// endsnippet
