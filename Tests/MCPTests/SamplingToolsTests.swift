import Foundation
import Testing

@testable import MCP

// Sampling with tools (SEP-1577): the message rules, the capability checks
// at both eras, and the tool loop of the specification on the wire.

// MARK: - Fixtures

private let question = "What's the weather like in Paris and London?"

/// The tool of the specification's example.
private let weatherTool = Tool(
    name: "get_weather",
    description: "Get current weather for a city",
    inputSchema: [
        "type": "object",
        "properties": ["city": ["type": "string", "description": "City name"]],
        "required": ["city"],
    ])

private func weather(_ city: String) -> String {
    switch city {
    case "Paris": return "Weather in Paris: 18°C, partly cloudy"
    case "London": return "Weather in London: 15°C, rainy"
    default: return "Unknown city: \(city)"
    }
}

private func use(_ id: String, _ city: String) -> Sampling.Message.Content.ContentBlock {
    .toolUse(.init(id: id, name: "get_weather", input: ["city": .string(city)]))
}

private func result(_ id: String, _ text: String = "ok") -> Sampling.Message.Content.ContentBlock {
    .toolResult(.init(toolUseId: id, content: [.text(text)]))
}

/// The user message with one tool result for each tool use in `content`.
private func toolResults(for content: Sampling.Message.Content) -> Sampling.Message {
    let results = content.asArray.compactMap { block -> Sampling.Message.Content.ContentBlock? in
        guard case .toolUse(let call) = block else { return nil }
        return result(call.id, weather(call.input["city"]?.stringValue ?? ""))
    }
    return .user(.multiple(results))
}

/// The answer the client's model gives in the specification's example:
/// two tool uses, then text.
private func modelAnswer(_ params: CreateSamplingMessage.Parameters) -> CreateSamplingMessage.Result {
    if case .multiple(let blocks) = params.messages.last?.content,
        case .toolResult = blocks.first
    {
        return .init(model: "test-model", stopReason: .endTurn, role: .assistant, content: .text("Paris is warmer."))
    }
    return .init(
        model: "test-model", stopReason: .toolUse, role: .assistant,
        content: .multiple([use("call_abc123", "Paris"), use("call_def456", "London")]))
}

/// A server with two tools:
/// - `direct` calls `requestSampling` twice (2025-11-25 and earlier).
/// - `agent` runs the same loop with input requests (both eras), keeping the
///   history in `requestState`.
@available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
private func makeServer(configuration: Server.Configuration = .default) async -> Server {
    let server = Server(
        name: "sampler", version: "1.0", capabilities: .init(tools: .init()), configuration: configuration)
    await server.withMethodHandler(CallTool.self) { [weak server] params in
        guard let server else { throw MCPError.internalError("gone") }
        switch params.name {
        case "direct":
            var history: [Sampling.Message] = [.user(.text(question))]
            let first = try await server.requestSampling(
                messages: history, maxTokens: 1000, tools: [weatherTool], toolChoice: .init(mode: .auto))
            history.append(.assistant(first.content))
            history.append(toolResults(for: first.content))
            let second = try await server.requestSampling(messages: history, maxTokens: 1000, tools: [weatherTool])
            return .init(content: [.text(text: second.content.asArray.first.flatMap(textOf) ?? "")])
        case "agent":
            var history: [Sampling.Message] = [.user(.text(question))]
            if let state = params.requestState {
                history = try JSONDecoder().decode([Sampling.Message].self, from: Data(state.utf8))
            }
            if let reply = params.inputResponses?["model"]?.sampling {
                guard reply.stopReason == .toolUse else {
                    return .init(content: [.text(text: reply.content.asArray.first.flatMap(textOf) ?? "")])
                }
                history.append(.assistant(reply.content))
                history.append(toolResults(for: reply.content))
            }
            let state = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
            return .inputRequired(
                [
                    "model": .sampling(
                        .init(
                            messages: history, maxTokens: 1000, tools: [weatherTool],
                            toolChoice: history.count == 1 ? .init(mode: .auto) : nil))
                ],
                requestState: state)
        case "sample":
            let raw = params.arguments?["params"] ?? [:]
            let sampling = try CreateSamplingMessage.Parameters(decoding: raw)
            _ = try await server.requestSampling(
                messages: sampling.messages, includeContext: sampling.includeContext,
                maxTokens: sampling.maxTokens, tools: sampling.tools, toolChoice: sampling.toolChoice)
            return .init(content: [.text(text: "sent")])
        case "ask":
            let raw = params.arguments?["params"] ?? [:]
            return .inputRequired(["model": .sampling(try CreateSamplingMessage.Parameters(decoding: raw))])
        default:
            throw MCPError.invalidParams("Unknown tool \(params.name)")
        }
    }
    return server
}

private func textOf(_ block: Sampling.Message.Content.ContentBlock) -> String? {
    if case .text(let text) = block { return text }
    return nil
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
private func connect(
    _ server: Server, mode: Client.ProtocolMode, capabilities: Client.Capabilities,
    samplings: Counter = Counter()
) async throws -> Client {
    let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverEnd)
    let client = Client(
        name: "c", version: "1", capabilities: capabilities, configuration: .init(protocolMode: mode))
    await client.withSamplingHandler { params in
        await samplings.increment()
        return modelAnswer(params)
    }
    try await client.connect(transport: clientEnd)
    return client
}

private func callText(_ result: CallTool.Result) -> String? {
    if case .text(let text, _, _)? = result.content.first { return text }
    return nil
}

private func sampleArguments(_ params: CreateSamplingMessage.Parameters) throws -> [String: Value] {
    ["params": try Value(params)]
}

private let toolsCapability = Client.Capabilities(sampling: .init(tools: .init()))

// MARK: - Message rules

@Suite("Sampling with tools: message rules")
struct SamplingToolMessageRuleTests {
    private func problem(_ messages: [Sampling.Message]) -> String? {
        CreateSamplingMessage.Parameters(messages: messages, maxTokens: 10).toolMessageProblem()
    }

    @Test("Histories that follow the rules")
    func valid() {
        #expect(problem([.user("Hi")]) == nil)
        #expect(problem([.user("Hi"), .assistant("Hello"), .user("Bye")]) == nil)
        // The specification's follow-up request.
        #expect(
            problem([
                .user(.text(question)),
                .assistant(.multiple([use("a", "Paris"), use("b", "London")])),
                .user(.multiple([result("a"), result("b")])),
            ]) == nil)
        // One tool use and one tool result, as single blocks; then text again.
        #expect(
            problem([
                .user("Hi"), .assistant(.single(use("a", "Paris"))), .user(.single(result("a"))),
                .assistant("Done"), .user("Thanks"),
            ]) == nil)
        // Text with a tool use in the assistant message is allowed.
        #expect(problem([.user("Hi"), .assistant(.multiple([.text("Let me check."), use("a", "Paris")])), .user(.single(result("a")))]) == nil)
        // A block of a type from a later revision is not counted as other content.
        let later = Sampling.Message.Content.ContentBlock.unknown(type: "later", ["type": "later"])
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris"))), .user(.multiple([result("a"), later]))])
                == nil)
    }

    @Test("Histories that break the rules")
    func invalid() {
        // A user message with tool results holds only tool results.
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris"))), .user(.multiple([.text("Here:"), result("a")]))])
                == "messages[2] has tool results and other content")
        // Every tool use has a result in the next message.
        #expect(
            problem([.user("Hi"), .assistant(.multiple([use("a", "Paris"), use("b", "London")])), .user(.single(result("a")))])
                == "messages[2] has no result for tool use b")
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris"))), .user("No results")])
                == "messages[2] must be a user message with the results of the tool uses in messages[1]")
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris"))), .assistant("Done")])
                == "messages[2] must be a user message with the results of the tool uses in messages[1]")
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris")))])
                == "messages[1] has tool uses, and no message with their results follows it")
        // Every tool result answers a tool use in the message before it.
        #expect(
            problem([.user("Hi"), .user(.single(result("x")))])
                == "messages[1] has a result for tool use x, which is not in the message before it")
        #expect(
            problem([.user(.single(result("x")))])
                == "messages[0] has a result for tool use x, which is not in the message before it")
        #expect(
            problem([.user("Hi"), .assistant(.single(use("a", "Paris"))), .user(.multiple([result("a"), result("z")]))])
                == "messages[2] has a result for tool use z, which is not in the message before it")
        // Tool uses are in assistant messages, tool results in user messages.
        #expect(
            problem([.user(.single(use("a", "Paris"))), .user(.single(result("a")))])
                == "messages[0] has tool uses, which belong in an assistant message")
        #expect(
            problem([.user("Hi"), .assistant(.single(result("x")))])
                == "messages[1] has tool results, which belong in a user message")
    }

    @Test("ToolChoice(mode: nil) is the auto mode, also after a round trip")
    @available(*, deprecated, message: "Tests the deprecated ToolChoice(mode: Mode?)")
    func toolChoiceNil() throws {
        typealias ToolChoice = CreateSamplingMessage.ToolChoice
        let choice = ToolChoice(mode: nil as ToolChoice.Mode?)
        #expect(choice == ToolChoice(mode: .auto))
        #expect(choice.mode == .auto)
        let data = try JSONEncoder().encode(choice)
        #expect(try JSONDecoder().decode(Value.self, from: data) == [:])
        #expect(try JSONDecoder().decode(ToolChoice.self, from: data) == choice)
        #expect(ToolChoice(mode: ToolChoice.Mode?.some(.none)).mode == ToolChoice.Mode.none)
    }

    @Test("ToolChoice(mode: .none) is the none mode, not the default")
    func toolChoiceNone() throws {
        #expect(CreateSamplingMessage.ToolChoice(mode: .none).mode == CreateSamplingMessage.ToolChoice.Mode.none)
        #expect(try Value(CreateSamplingMessage.ToolChoice(mode: .none)) == ["mode": "none"])
        #expect(try Value(CreateSamplingMessage.ToolChoice(mode: .required)) == ["mode": "required"])
        #expect(try Value(CreateSamplingMessage.ToolChoice()) == [:])
    }

    @Test("Tools and context need their sub-capabilities")
    func capabilities() throws {
        let plain = InputRequest.sampling(.init(messages: [.user("Hi")], maxTokens: 10))
        let tools = InputRequest.sampling(.init(messages: [.user("Hi")], maxTokens: 10, tools: [weatherTool]))
        let choice = InputRequest.sampling(.init(messages: [.user("Hi")], maxTokens: 10, toolChoice: .init(mode: .none)))
        let thisServer = try #require(Sampling.ContextInclusion(rawValue: "thisServer"))
        let context = InputRequest.sampling(.init(messages: [.user("Hi")], includeContext: thisServer, maxTokens: 10))
        let none = InputRequest.sampling(.init(messages: [.user("Hi")], includeContext: Sampling.ContextInclusion.none, maxTokens: 10))

        let sampling = Client.Capabilities(sampling: .init())
        #expect(plain.isSupported(by: sampling) && none.isSupported(by: sampling))
        #expect(!tools.isSupported(by: sampling) && !choice.isSupported(by: sampling) && !context.isSupported(by: sampling))
        #expect(tools.isSupported(by: toolsCapability) && choice.isSupported(by: toolsCapability))
        #expect(context.isSupported(by: .init(sampling: .init(context: .init()))))

        var missing = Client.Capabilities()
        tools.require(in: &missing)
        context.require(in: &missing)
        #expect(missing == .init(sampling: .init(tools: .init(), context: .init())))
    }
}

// MARK: - The tool loop on the wire

@Suite("Sampling with tools: wire")
struct SamplingToolWireTests {
    /// The specification's first request, without `jsonrpc` and `id`.
    /// `toolChoice` is `{}`: the SDK sends `auto`, the default, as no mode.
    private let firstRequest = #"""
        {"messages":[{"role":"user","content":{"type":"text","text":"What's the weather like in Paris and London?"}}],
         "tools":[{"name":"get_weather","description":"Get current weather for a city",
                   "inputSchema":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}],
         "toolChoice":{},"maxTokens":1000}
        """#

    /// The specification's tool-use response.
    private let toolUseResult = #"""
        {"role":"assistant","content":[
           {"type":"tool_use","id":"call_abc123","name":"get_weather","input":{"city":"Paris"}},
           {"type":"tool_use","id":"call_def456","name":"get_weather","input":{"city":"London"}}],
         "model":"claude-3-sonnet-20240307","stopReason":"toolUse"}
        """#

    /// The specification's follow-up request with the tool results.
    private let followUpRequest = #"""
        {"messages":[
           {"role":"user","content":{"type":"text","text":"What's the weather like in Paris and London?"}},
           {"role":"assistant","content":[
              {"type":"tool_use","id":"call_abc123","name":"get_weather","input":{"city":"Paris"}},
              {"type":"tool_use","id":"call_def456","name":"get_weather","input":{"city":"London"}}]},
           {"role":"user","content":[
              {"type":"tool_result","toolUseId":"call_abc123","content":[{"type":"text","text":"Weather in Paris: 18°C, partly cloudy"}]},
              {"type":"tool_result","toolUseId":"call_def456","content":[{"type":"text","text":"Weather in London: 15°C, rainy"}]}]}],
         "tools":[{"name":"get_weather","description":"Get current weather for a city",
                   "inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],
         "maxTokens":1000}
        """#

    private let finalResult = #"""
        {"role":"assistant","content":{"type":"text","text":"Paris is warmer."},"model":"claude-3-sonnet-20240307","stopReason":"endTurn"}
        """#

    private func json(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func response(to request: Value, result: String) throws -> String {
        let id = try #require(request.objectValue?["id"])
        return try json(["jsonrpc": "2.0", "id": id, "result": try wireJSON(result)])
    }

    private func initialize(_ wire: WireExchange) async throws {
        try await wire.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"sampling":{"tools":{}}},"clientInfo":{"name":"c","version":"1"}}}"#
        )
        try await wire.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, expecting: 0)
    }

    @Test("2025-11-25: requestSampling sends the specification's tool loop", arguments: ["direct", "agent"])
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func handshakeLoop(tool: String) async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }
        try await initialize(wire)

        let first = try await wire.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)"}}"#)
        expectWire(
            first[0],
            matches: ["jsonrpc": "2.0", "id": "<any>", "method": "sampling/createMessage", "params": try wireJSON(firstRequest)])
        let firstParams = try #require(first[0].objectValue?["params"]?.objectValue)
        #expect(firstParams["toolChoice"]?.objectValue?["mode"] == nil)

        let second = try await wire.send(try response(to: first[0], result: toolUseResult))
        expectWire(
            second[0],
            matches: ["jsonrpc": "2.0", "id": "<any>", "method": "sampling/createMessage", "params": try wireJSON(followUpRequest)])
        #expect(second[0].objectValue?["params"]?.objectValue?["toolChoice"] == nil)

        let done = try await wire.send(try response(to: second[0], result: finalResult))
        expectWire(done[0], matches: try wireJSON(#"{"id":1,"result":{"content":[{"type":"text","text":"Paris is warmer."}]}}"#))
    }

    @Test("2026-07-28: the tool loop as input requests")
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func statelessLoop() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }
        let metaObject = #"{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"sampling":{"tools":{}}},"io.modelcontextprotocol/clientInfo":{"name":"c","version":"1"}}"#
        let meta = #""_meta":"# + metaObject

        let first = try await wire.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"agent",\#(meta)}}"#)
        expectWire(
            first[0],
            matches: [
                "id": 1,
                "result": [
                    "resultType": "input_required", "requestState": "<any>",
                    "inputRequests": ["model": ["method": "sampling/createMessage", "params": try wireJSON(firstRequest)]],
                ],
            ])
        let state1 = try #require(first[0].objectValue?["result"]?.objectValue?["requestState"])

        let retry1 = try json([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": [
                "name": "agent", "requestState": state1,
                "inputResponses": ["model": try wireJSON(toolUseResult)],
                "_meta": try wireJSON(metaObject),
            ],
        ])
        let second = try await wire.send(retry1)
        expectWire(
            second[0],
            matches: [
                "id": 2,
                "result": [
                    "resultType": "input_required",
                    "inputRequests": ["model": ["method": "sampling/createMessage", "params": try wireJSON(followUpRequest)]],
                ],
            ])
        let state2 = try #require(second[0].objectValue?["result"]?.objectValue?["requestState"])

        let retry2 = try json([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": [
                "name": "agent", "requestState": state2,
                "inputResponses": ["model": try wireJSON(finalResult)],
                "_meta": try wireJSON(metaObject),
            ],
        ])
        let done = try await wire.send(retry2)
        expectWire(
            done[0],
            matches: try wireJSON(#"{"id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"Paris is warmer."}]}}"#))
    }
}

// MARK: - Capabilities and refusals

@Suite("Sampling with tools: capabilities", .timeLimit(.minutes(1)))
struct SamplingToolCapabilityTests {
    @Test("The tool loop runs end to end", arguments: [Client.ProtocolMode.handshake, .automatic])
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func loop(mode: Client.ProtocolMode) async throws {
        let server = await makeServer()
        let samplings = Counter()
        let client = try await connect(server, mode: mode, capabilities: toolsCapability, samplings: samplings)
        defer { Task { await client.disconnect(); await server.stop() } }
        if mode == .handshake {
            #expect(callText(try await client.callTool(name: "direct")) == "Paris is warmer.")
        }
        #expect(callText(try await client.callTool(name: "agent")) == "Paris is warmer.")
        #expect(await samplings.value == (mode == .handshake ? 4 : 2))
    }

    @Test("2025-11-25: requestSampling with tools fails before sending when the client did not declare sampling.tools")
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func handshakeToolsNeedCapability() async throws {
        for configuration in [Server.Configuration.default, .strict] {
            let server = await makeServer(configuration: configuration)
            let samplings = Counter()
            let client = try await connect(
                server, mode: .handshake, capabilities: .init(sampling: .init()), samplings: samplings)
            for params in [
                CreateSamplingMessage.Parameters(messages: [.user("Hi")], maxTokens: 10, tools: [weatherTool]),
                CreateSamplingMessage.Parameters(messages: [.user("Hi")], maxTokens: 10, toolChoice: .init(mode: .required)),
            ] {
                await #expect(throws: MCPError.methodNotFound("Sampling with tools is not supported by the client")) {
                    _ = try await client.callTool(name: "sample", arguments: try sampleArguments(params))
                }
            }
            #expect(await samplings.value == 0)
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("2025-11-25: includeContext without sampling.context fails in strict mode only")
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func handshakeContext() async throws {
        let thisServer = try #require(Sampling.ContextInclusion(rawValue: "thisServer"))
        let params = CreateSamplingMessage.Parameters(messages: [.user("Hi")], includeContext: thisServer, maxTokens: 10)
        for strict in [false, true] {
            let server = await makeServer(configuration: strict ? .strict : .default)
            let samplings = Counter()
            let client = try await connect(
                server, mode: .handshake, capabilities: .init(sampling: .init()), samplings: samplings)
            if strict {
                await #expect(throws: MCPError.methodNotFound("Sampling with context is not supported by the client")) {
                    _ = try await client.callTool(name: "sample", arguments: try sampleArguments(params))
                }
                #expect(await samplings.value == 0)
            } else {
                #expect(callText(try await client.callTool(name: "sample", arguments: try sampleArguments(params))) == "sent")
                #expect(await samplings.value == 1)
            }
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("requestSampling refuses messages that break the rules", arguments: [false, true])
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func handshakeMessageRules(strict: Bool) async throws {
        let server = await makeServer(configuration: strict ? .strict : .default)
        let samplings = Counter()
        let client = try await connect(server, mode: .handshake, capabilities: toolsCapability, samplings: samplings)
        defer { Task { await client.disconnect(); await server.stop() } }
        let params = CreateSamplingMessage.Parameters(
            messages: [.user("Hi"), .assistant(.single(use("a", "Paris"))), .user("No results")],
            maxTokens: 10, tools: [weatherTool])
        await #expect(
            throws: MCPError.invalidParams("messages[2] must be a user message with the results of the tool uses in messages[1]")
        ) {
            _ = try await client.callTool(name: "sample", arguments: try sampleArguments(params))
        }
        #expect(await samplings.value == 0)
    }

    @Test("Input requests with tools or context need the sub-capability: -32021 at both eras",
        arguments: [Client.ProtocolMode.handshake, .automatic])
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func inputRequestCapabilities(mode: Client.ProtocolMode) async throws {
        let server = await makeServer()
        let samplings = Counter()
        let client = try await connect(server, mode: mode, capabilities: .init(sampling: .init()), samplings: samplings)
        defer { Task { await client.disconnect(); await server.stop() } }
        let thisServer = try #require(Sampling.ContextInclusion(rawValue: "thisServer"))
        let cases: [(CreateSamplingMessage.Parameters, Client.Capabilities)] = [
            (.init(messages: [.user("Hi")], maxTokens: 10, tools: [weatherTool]), toolsCapability),
            (.init(messages: [.user("Hi")], includeContext: thisServer, maxTokens: 10), .init(sampling: .init(context: .init()))),
        ]
        for (params, required) in cases {
            do {
                _ = try await client.callTool(name: "ask", arguments: try sampleArguments(params))
                Issue.record("Expected -32021")
            } catch let error as MCPError {
                guard case .missingRequiredClientCapabilities(let capabilities, _) = error else {
                    Issue.record("Expected -32021, got \(error)")
                    continue
                }
                #expect(capabilities == required)
            }
        }
        #expect(await samplings.value == 0)
    }

    @Test("An input request that breaks the message rules is a server error", arguments: [Client.ProtocolMode.handshake, .automatic])
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func inputRequestMessageRules(mode: Client.ProtocolMode) async throws {
        let server = await makeServer()
        let samplings = Counter()
        let client = try await connect(server, mode: mode, capabilities: toolsCapability, samplings: samplings)
        defer { Task { await client.disconnect(); await server.stop() } }
        let params = CreateSamplingMessage.Parameters(messages: [.user(.single(result("x")))], maxTokens: 10)
        do {
            _ = try await client.callTool(name: "ask", arguments: try sampleArguments(params))
            Issue.record("Expected -32603")
        } catch let error as MCPError {
            guard case .internalError(let detail?) = error else {
                Issue.record("Expected -32603, got \(error)")
                return
            }
            #expect(detail.contains("messages[0] has a result for tool use x"))
        }
        #expect(await samplings.value == 0)
    }
}

// MARK: - The client refuses

/// A handshake client whose server is driven by the test, for requests a
/// `Server` would not send.
private struct ScriptedServer {
    let client: Client
    let samplings: Counter
    private let end: InMemoryTransport
    private var incoming: AsyncThrowingStream<Data, Error>.AsyncIterator

    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    static func connect(capabilities: Client.Capabilities) async throws -> ScriptedServer {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await serverEnd.connect()
        var incoming = await serverEnd.receive().makeAsyncIterator()
        let samplings = Counter()
        let client = Client(name: "c", version: "1", capabilities: capabilities, configuration: .handshake)
        await client.withSamplingHandler { params in
            await samplings.increment()
            return modelAnswer(params)
        }
        let connecting = Task { try await client.connect(transport: clientEnd) }
        let initialize = try JSONDecoder().decode(Value.self, from: try #require(try await incoming.next()))
        let id = try #require(initialize.objectValue?["id"])
        try await serverEnd.send(
            JSONEncoder().encode(
                [
                    "jsonrpc": "2.0", "id": id,
                    "result": [
                        "protocolVersion": "2025-11-25", "capabilities": [:], "serverInfo": ["name": "s", "version": "1"],
                    ],
                ] as Value))
        _ = try await connecting.value
        _ = try await incoming.next()  // notifications/initialized
        return ScriptedServer(client: client, samplings: samplings, end: serverEnd, incoming: incoming)
    }

    /// Sends a `sampling/createMessage` request and returns the reply.
    mutating func sample(_ params: String) async throws -> Value {
        try await end.send(Data(#"{"jsonrpc":"2.0","id":"s1","method":"sampling/createMessage","params":\#(params)}"#.utf8))
        return try JSONDecoder().decode(Value.self, from: try #require(try await incoming.next()))
    }
}

@Suite("Sampling with tools: client", .timeLimit(.minutes(1)))
struct SamplingToolClientTests {
    @Test("The client refuses tools it did not declare, before the handler runs")
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func refusesUndeclaredTools() async throws {
        var server = try await ScriptedServer.connect(capabilities: .init(sampling: .init()))
        let client = server.client
        defer { Task { await client.disconnect() } }
        for params in [
            #"{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10,"tools":[{"name":"t","inputSchema":{"type":"object"}}]}"#,
            #"{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10,"toolChoice":{"mode":"none"}}"#,
        ] {
            let reply = try await server.sample(params)
            expectWire(reply, matches: try wireJSON(#"{"id":"s1","error":{"code":-32602}}"#))
        }
        #expect(await server.samplings.value == 0)

        // Without tools the same client answers.
        let reply = try await server.sample(#"{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10}"#)
        expectWire(reply, matches: try wireJSON(#"{"id":"s1","result":{"stopReason":"toolUse"}}"#))
        #expect(await server.samplings.value == 1)
    }

    @Test("The client refuses messages that break the rules, before the handler runs")
    @available(*, deprecated, message: "Uses the deprecated sampling API (SEP-2577)")
    func refusesBrokenMessages() async throws {
        var server = try await ScriptedServer.connect(capabilities: toolsCapability)
        let client = server.client
        defer { Task { await client.disconnect() } }
        let mixed = #"""
            {"messages":[{"role":"user","content":{"type":"text","text":"Hi"}},
                         {"role":"assistant","content":{"type":"tool_use","id":"a","name":"t","input":{}}},
                         {"role":"user","content":[{"type":"text","text":"Here:"},{"type":"tool_result","toolUseId":"a","content":[]}]}],
             "maxTokens":10}
            """#
        let missing = #"""
            {"messages":[{"role":"user","content":{"type":"text","text":"Hi"}},
                         {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"t","input":{}},{"type":"tool_use","id":"b","name":"t","input":{}}]},
                         {"role":"user","content":{"type":"tool_result","toolUseId":"a","content":[]}}],
             "maxTokens":10,"tools":[{"name":"t","inputSchema":{"type":"object"}}]}
            """#
        let userToolUse = #"""
            {"messages":[{"role":"user","content":{"type":"tool_use","id":"a","name":"t","input":{}}},
                         {"role":"user","content":{"type":"tool_result","toolUseId":"a","content":[]}}],
             "maxTokens":10,"tools":[{"name":"t","inputSchema":{"type":"object"}}]}
            """#
        for (params, message) in [
            (mixed, "messages[2] has tool results and other content"),
            (missing, "messages[2] has no result for tool use b"),
            (userToolUse, "messages[0] has tool uses, which belong in an assistant message"),
        ] {
            let reply = try await server.sample(params)
            expectWire(reply, matches: ["id": "s1", "error": ["code": -32602, "message": .string("Invalid params: \(message)")]])
        }
        #expect(await server.samplings.value == 0)
    }

    @Test("2026-07-28: an input request with undeclared tools fails the call; the handler does not run")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func statelessRefusal() async throws {
        // A server built on another SDK could ask anyway; the Swift server
        // answers -32021 first, so decode the input request here.
        let client = Client(name: "c", version: "1", capabilities: .init(sampling: .init()))
        let samplings = Counter()
        await client.withSamplingHandler { params in
            await samplings.increment()
            return modelAnswer(params)
        }
        let request = InputRequest.sampling(.init(messages: [.user("Hi")], maxTokens: 10, tools: [weatherTool]))
        await #expect(throws: MCPError.self) { _ = try await client.fulfillInputRequests(["model": request]) }
        #expect(await samplings.value == 0)
    }
}
