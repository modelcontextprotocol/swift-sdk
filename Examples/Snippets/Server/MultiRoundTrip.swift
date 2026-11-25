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

// snippet: mrtr-sampling-tools
/// Lets the client's model call `get_weather` before it answers. The
/// history goes in requestState. On the last round the model must answer
/// without tools.
func adviseTravel(_ params: CallTool.Parameters, maxRounds: Int = 4) throws -> CallTool.Result {
    var history: [Sampling.Message] = [.user("Paris or London for a walk today?")]
    if let state = params.requestState {
        history = try JSONDecoder().decode([Sampling.Message].self, from: Data(state.utf8))
    }
    if let reply = params.inputResponses?["model"]?.sampling {
        guard reply.stopReason == .toolUse else {
            let answer = reply.content.asArray.compactMap { block -> Tool.Content? in
                if case .text(let text) = block { return .text(text: text) }
                return nil
            }
            return CallTool.Result(content: answer)
        }
        history.append(.assistant(reply.content))
        // One tool result for each tool use, and no other content.
        let results = reply.content.asArray.compactMap { block -> Sampling.Message.Content.ContentBlock? in
            guard case .toolUse(let call) = block else { return nil }
            let city = call.input["city"]?.stringValue ?? ""
            return .toolResult(.init(toolUseId: call.id, content: [.text(currentWeather(in: city))]))
        }
        history.append(.user(.multiple(results)))
    }
    let round = (history.count + 1) / 2
    let request = CreateSamplingMessage.Parameters(
        messages: history, maxTokens: 500, tools: [weatherTool],
        toolChoice: round >= maxRounds ? .init(mode: .none) : nil)
    let state = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
    return .inputRequired(["model": .sampling(request)], requestState: state)
}
// endsnippet

func currentWeather(in city: String) -> String {
    city == "Paris" ? "Paris: 18°C, partly cloudy" : "\(city): 15°C, rainy"
}

// snippet: server-requests
/// Asks the client while it handles `clean`, so the request belongs to that
/// `tools/call` (SEP-2260). 2025-11-25 and earlier only: at 2026-07-28 this
/// call throws -32600; return input requests instead.
func registerCleanTool(on server: Server) async {
    await server.withMethodHandler(CallTool.self) { [weak server] _ in
        guard let server else { throw MCPError.internalError("Server is gone") }
        let answer = try await server.requestElicitation(
            message: "Clean the workspace?",
            requestedSchema: .init(properties: ["confirm": ["type": "boolean"]], required: ["confirm"]))
        let confirmed = answer.action == .accept && answer.content?["confirm"]?.boolValue == true
        return CallTool.Result(content: [.text(text: "\(confirmed)")])
    }
}
// endsnippet

// snippet: server-roots
/// Reports the client's roots while it handles `roots`, from the cache.
@available(*, deprecated, message: "Uses the deprecated roots API (SEP-2577)")
func registerRootsTool(on server: Server, roots: RootsCache) async {
    await server.withMethodHandler(CallTool.self) { [weak server] _ in
        guard let server else { throw MCPError.internalError("Server is gone") }
        let current = try await roots.roots(of: server)
        return CallTool.Result(content: [.text(text: "\(current.count) roots")])
    }
}

/// The client's roots, fetched in the first handler that needs them and
/// again after the client says they changed.
actor RootsCache {
    private var cached: [Root]?
    /// Changed by `invalidate()`: roots fetched before it are not kept.
    private var generation = 0

    /// Marks the roots stale: the next handler fetches them.
    func invalidate() {
        cached = nil
        generation += 1
    }

    /// The roots. Call it from a handler.
    @available(*, deprecated, message: "Uses the deprecated roots API (SEP-2577)")
    func roots(of server: Server) async throws -> [Root] {
        if let cached { return cached }
        let started = generation
        let roots = try await server.listRoots()
        if generation == started { cached = roots }
        return roots
    }
}

func watchRoots(on server: Server, cache: RootsCache) async {
    await server.onNotification(RootsListChangedNotification.self) { _ in
        await cache.invalidate()
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
