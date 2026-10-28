import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClientSnippets
@testable import MCP
@testable import ServerSnippets

// Runs the docs/client.md snippets against an in-process server.

// MARK: - Demo server

private let demoTools: [Tool] = [
    Tool(
        name: "echo", description: "Echoes text",
        inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]]),
    Tool(
        name: "weather", description: "Current weather",
        inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]],
        outputSchema: [
            "type": "object",
            "properties": ["temperature": ["type": "number"], "conditions": ["type": "string"]],
        ]),
    Tool(
        name: "search", description: "Searches one region",
        inputSchema: [
            "type": "object",
            "properties": [
                "region": ["type": "string", "x-mcp-header": "Region"],
                "query": ["type": "string"],
            ],
        ]),
    // An object cannot be mirrored into a header: dropped at 2026-07-28.
    Tool(
        name: "bad-header", description: "Invalid annotation",
        inputSchema: [
            "type": "object", "properties": ["filter": ["type": "object", "x-mcp-header": "Filter"]],
        ]),
    Tool(name: "deploy", description: "Deploys after a confirmation", inputSchema: ["type": "object"]),
    Tool(name: "summarize", description: "Asks the client's model", inputSchema: ["type": "object"]),
    Tool(name: "where", description: "Reports the client's roots", inputSchema: ["type": "object"]),
    Tool(name: "open-docs", description: "Asks the user to open a URL", inputSchema: ["type": "object"]),
    Tool(name: "connect-calendar", description: "Needs a URL elicitation", inputSchema: ["type": "object"]),
    Tool(name: "slow", description: "Sleeps", inputSchema: ["type": "object"]),
    Tool(name: "index", description: "Reports progress", inputSchema: ["type": "object"]),
]

private func text(_ string: String) -> Tool.Content {
    .text(text: string)
}

private func texts(_ content: [Tool.Content]) -> [String] {
    content.compactMap {
        if case .text(let text, _, _) = $0 { return text }
        return nil
    }
}

private func makeDemoServer(
    capabilities: Server.Capabilities = .init(
        completions: .init(), logging: .init(), prompts: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true), tools: .init(listChanged: true),
        extensions: ["com.example/audit": [:]]),
    configuration: Server.Configuration = .default
) async -> Server {
    let server = Server(
        name: "demo", version: "1.0", capabilities: capabilities, configuration: configuration)

    // Two pages of tools.
    await server.withMethodHandler(ListTools.self) { params in
        params.cursor == nil
            ? .init(tools: Array(demoTools.prefix(4)), nextCursor: "page-2")
            : .init(tools: Array(demoTools.dropFirst(4)))
    }
    await server.withMethodHandler(CallTool.self) { [server] params in
        let responses = params.inputResponses ?? [:]
        switch params.name {
        case "echo":
            return .init(content: [text(params.arguments?["text"]?.stringValue ?? "")])
        case "weather":
            return try .init(
                content: [text("21.5 C, sunny")],
                structuredContent: Weather(temperature: 21.5, conditions: "sunny"))
        case "deploy":
            guard let answer = responses["confirm"]?.elicitation else {
                return .inputRequired(
                    [
                        "confirm": .elicitation(
                            message: "Deploy to prod?",
                            requestedSchema: .init(properties: ["confirm": ["type": "boolean"]]))
                    ],
                    requestState: "deploy")
            }
            return .init(content: [text(answer.action == .accept ? "deployed" : "not deployed")])
        case "summarize":
            guard let completion = responses["summary"]?.sampling else {
                return .inputRequired([
                    "summary": .sampling(.init(messages: [.user(.text("Summarize this"))], maxTokens: 100))
                ])
            }
            return .init(content: completion.content.asArray.compactMap {
                if case .text(let string) = $0 { return text(string) }
                return nil
            })
        case "where":
            guard let roots = responses["roots"]?.roots else {
                return .inputRequired(["roots": .listRoots])
            }
            return .init(content: roots.map { text($0.uri) })
        case "open-docs":
            guard let answer = responses["open"]?.elicitation else {
                return .inputRequired([
                    "open": .elicitation(
                        .url(.init(message: "Read the docs", url: "https://example.com/docs", elicitationId: "docs")))
                ])
            }
            return .init(content: [text(answer.action.rawValue)])
        case "connect-calendar":
            throw MCPError.urlElicitationRequired(
                message: "Connect your calendar",
                elicitations: [
                    URLElicitationInfo(
                        elicitationId: "calendar", url: "https://example.com/connect", message: "Sign in")
                ])
        case "slow":
            try await Task.sleep(for: .seconds(30))
            return .init(content: [text("done")])
        case "index":
            if let token = params._meta?.progressToken {
                for step in 1...2 {
                    try await server.notify(
                        ProgressNotification.message(.init(progressToken: token, progress: Double(step), total: 2)))
                }
            }
            return .init(content: [text("indexed")])
        default:
            throw MCPError.invalidParams("Unknown tool \(params.name)")
        }
    }
    await server.withMethodHandler(ListPrompts.self) { _ in
        .init(prompts: [
            Prompt(name: "greeting", arguments: [.init(name: "name", required: true)]),
            Prompt(name: "review", arguments: [.init(name: "language")]),
        ])
    }
    await server.withMethodHandler(GetPrompt.self) { params in
        .init(
            description: "A greeting",
            messages: [.user(.text(text: "Hello, \(params.arguments?["name"] ?? "you")"))])
    }
    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: [Resource(name: "notes", uri: "file:///notes.txt", mimeType: "text/plain")])
    }
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        .init(templates: [Resource.Template(uriTemplate: "file:///logs/{date}", name: "logs")])
    }
    await server.withMethodHandler(ReadResource.self) { params in
        guard params.uri == "file:///notes.txt" else { throw MCPError.resourceNotFound(uri: params.uri) }
        return .init(contents: [.text("Buy milk", uri: params.uri)])
    }
    await server.withMethodHandler(Complete.self) { params in
        let languages = ["swift", "python", "go"]
        return .init(completion: .init(values: languages.filter { $0.hasPrefix(params.argument.value) }))
    }
    // Methods that exist only before 2026-07-28.
    await server.withMethodHandler(SetLoggingLevel.self) { _ in Empty() }
    await server.withMethodHandler(ResourceSubscribe.self) { _ in Empty() }
    await server.withMethodHandler(ResourceUnsubscribe.self) { _ in Empty() }
    return server
}

/// Starts `server` and returns the client end of an in-memory pair.
private func start(_ server: Server) async throws -> any Transport {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    return clientTransport
}

/// A demo server and a client connected to it in `mode`.
private func connected(
    _ mode: Client.ProtocolMode, capabilities: Client.Capabilities = .init()
) async throws -> (Server, Client) {
    let server = await makeDemoServer()
    let client = Client(
        name: "test", version: "1.0", capabilities: capabilities,
        configuration: .init(protocolMode: mode))
    try await client.connect(transport: try await start(server))
    return (server, client)
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private let bothEras: [Client.ProtocolMode] = [.handshake, .automatic]

// MARK: - Tests

@Suite("Client snippets")
struct ClientSnippetTests {
    // MARK: Connecting

    @Test("connect discovers 2026-07-28 by default")
    func connect() async throws {
        let server = await makeDemoServer()
        let (client, result) = try await connectWithDefaults(transport: try await start(server))
        #expect(result.protocolVersion == Version.v2026_07_28)
        #expect(result.serverInfo?.name == "demo")
        #expect(await client.isStateless)
        try await pingAndDisconnect(client)
        await server.stop()
    }

    @Test("connect falls back to initialize by default")
    func connectDefaultFallback() async throws {
        let server = await makeDemoServer(configuration: .init(protocolVersions: Version.handshake))
        let (client, result) = try await connectWithDefaults(transport: try await start(server))
        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(await client.isStateless == false)
        await client.disconnect()
        await server.stop()
    }

    @Test("automatic mode discovers 2026-07-28")
    func connectAutomatic() async throws {
        let server = await makeDemoServer()
        let client = try await connectAutomatically(transport: try await start(server))
        #expect(await client.negotiatedProtocolVersion == Version.v2026_07_28)
        #expect(await client.isStateless)
        #expect(await client.serverInfo?.name == "demo")
        try await pingAndDisconnect(client)
        await server.stop()
    }

    @Test("automatic mode falls back to initialize")
    func connectAutomaticFallback() async throws {
        let server = await makeDemoServer(configuration: .init(protocolVersions: Version.handshake))
        let client = try await connectAutomatically(transport: try await start(server))
        #expect(await client.negotiatedProtocolVersion == Version.v2025_11_25)
        #expect(await client.isStateless == false)
        await client.disconnect()
        await server.stop()
    }

    @Test("stateless mode reports the versions a handshake-only server serves")
    func connectStateless() async throws {
        let server = await makeDemoServer(configuration: .init(protocolVersions: Version.handshake))
        do {
            _ = try await connectStatelessOnly(transport: try await start(server))
            Issue.record("connect should fail")
        } catch MCPError.unsupportedProtocolVersion(let supported, _) {
            #expect(supported == Version.handshake)
        }
        await server.stop()
    }

    @Test("strict mode checks capabilities before sending")
    func strict() async throws {
        let server = await makeDemoServer(capabilities: .init(tools: .init()))
        let client = try await listPromptsStrictly(transport: try await start(server))
        await client.disconnect()
        await server.stop()
    }

    // MARK: Tools

    @Test("tools: pagination, content and structured content", arguments: bothEras)
    func tools(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        let tools = try await listAllTools(client)
        // The server drops the invalid annotation at 2026-07-28.
        #expect(tools.contains { $0.name == "bad-header" } == (mode == .handshake))
        #expect(tools.count == demoTools.count - (mode == .handshake ? 0 : 1))
        #expect(try await callEchoTool(client) == "hello")
        #expect(try await callStructuredTool(client) == Weather(temperature: 21.5, conditions: "sunny"))
        await client.disconnect()
        await server.stop()
    }

    @Test("header parameters come from x-mcp-header annotations")
    func headerParameters() async throws {
        let (server, client) = try await connected(.automatic)
        let mirrored = try await describeHeaderParameters(client)
        #expect(mirrored["search"] == ["Mcp-Param-Region <- region"])
        #expect(mirrored["echo"] == [])
        #expect(mirrored["bad-header"] == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("prompts, resources and completions", arguments: bothEras)
    func promptsAndResources(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        #expect(try await renderGreeting(client) == ["user: Hello, Ada"])
        #expect(try await readNotes(client) == "Buy milk")
        #expect(try await completeLanguage(client) == ["swift"])
        await client.disconnect()
        await server.stop()
    }

    // MARK: Client features

    @Test("roots at 2025-11-25: server request and list-changed notification")
    func rootsHandshake() async throws {
        let server = await makeDemoServer(configuration: .init(protocolVersions: Version.handshake))
        let changed = Flag()
        await server.onNotification(RootsListChangedNotification.self) { _ in await changed.set() }
        let workspace = Workspace()
        let client = try await connectWithRoots(transport: try await start(server), workspace: workspace)
        #expect(await eventually { await changed.isSet })
        #expect(try await server.listRoots().map(\.uri) == ["file:///Users/me/project", "file:///Users/me/scratch"])
        await client.disconnect()
        await server.stop()
    }

    @Test("a tool that asks for roots")
    func rootsInputRequired() async throws {
        let server = await makeDemoServer()
        let workspace = Workspace()
        let client = try await connectWithRoots(transport: try await start(server), workspace: workspace)
        let content = try await client.callTool(name: "where").content
        #expect(texts(content) == ["file:///Users/me/project", "file:///Users/me/scratch"])
        await client.disconnect()
        await server.stop()
    }

    @Test("sampling handler answers the server")
    func sampling() async throws {
        let server = await makeDemoServer()
        let client = try await connectWithSampling(transport: try await start(server))
        let content = try await client.callTool(name: "summarize").content
        #expect(texts(content) == ["Summary of 14 characters"])
        await client.disconnect()
        await server.stop()
    }

    @Test("elicitation handler answers form and URL requests")
    func elicitation() async throws {
        let server = await makeDemoServer()
        let client = try await connectWithElicitation(transport: try await start(server))
        let deployed = try await client.callTool(name: "deploy").content
        #expect(texts(deployed) == ["deployed"])
        let opened = try await client.callTool(name: "open-docs").content
        #expect(texts(opened) == ["accept"])
        #expect(try await callAfterURLElicitation(client).map(\.url) == ["https://example.com/connect"])
        await client.disconnect()
        await server.stop()
    }

    // MARK: Multi round-trip

    @Test("the automatic loop uses the same handlers at both eras", arguments: bothEras)
    func multiRoundTrip(mode: Client.ProtocolMode) async throws {
        let server = await makeDemoServer()
        let (client, content) = try await deployWithConfirmation(transport: try await start(server), mode: mode)
        #expect(texts(content) == ["deployed"])
        #expect(await client.isStateless == (mode != .handshake))
        await client.disconnect()
        await server.stop()
    }

    @Test("the manual loop retries with responses and state")
    func multiRoundTripManual() async throws {
        let server = await makeDemoServer()
        let result = try await deployManually(transport: try await start(server))
        #expect(result.resultType == .complete)
        #expect(texts(result.content) == ["deployed"])
        await server.stop()
    }

    @Test("with the loop disabled, callTool throws for input-required results")
    func multiRoundTripDisabled() async throws {
        let server = await makeDemoServer()
        let client = Client(
            name: "test", version: "1.0", capabilities: .init(elicitation: .init()),
            configuration: .init(protocolMode: .automatic, multiRoundTrip: .init(isEnabled: false)))
        try await client.connect(transport: try await start(server))
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "deploy")
        }
        await client.disconnect()
        await server.stop()
    }

    // MARK: Notifications and subscriptions

    @Test("list-changed handlers refetch at both eras", arguments: bothEras)
    func listChanged(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        let cache = ToolCache()
        await watchToolList(client, cache: cache)
        if mode != .handshake {
            // The handler opened a listen stream in the background.
            #expect(await eventually { await server.openSubscriptionCount == 1 })
        }
        try await server.notify(ToolListChangedNotification.message())
        #expect(await eventually { await cache.refreshes == 1 })
        #expect(await cache.tools.contains { $0.name == "echo" })
        await client.disconnect()
        await server.stop()
    }

    @Test("listen returns the honored filter")
    func listen() async throws {
        let (server, client) = try await connected(.automatic)
        let honored = try await listenForChanges(client)
        #expect(honored == SubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///notes.txt"]))
        await client.disconnect()
        await server.stop()
    }

    @Test("listen requires 2026-07-28")
    func listenHandshake() async throws {
        let (server, client) = try await connected(.handshake)
        await #expect(throws: MCPError.self) { _ = try await listenForChanges(client) }
        await client.disconnect()
        await server.stop()
    }

    @Test("resource subscriptions at both eras", arguments: bothEras)
    func subscribeResource(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        let subscribed = try await watchNotes(client)
        #expect(subscribed == (mode == .handshake ? [] : ["file:///notes.txt"]))
        #expect(await client.subscribedResourceURIs.isEmpty)
        await client.disconnect()
        await server.stop()
    }

    // MARK: Logging, cancellation, progress

    @Test("log messages reach the handler at 2025-11-25")
    func logging() async throws {
        let (server, client) = try await connected(.handshake)
        let inbox = LogInbox()
        try await receiveLogs(client, into: inbox)
        try await server.log(level: .info, logger: "indexer", data: "started")
        #expect(await eventually { await inbox.lines.count == 1 })
        await client.disconnect()
        await server.stop()
    }

    @Test("setLoggingLevel changes the _meta level at 2026-07-28")
    func loggingStateless() async throws {
        let (server, client) = try await connected(.automatic)
        try await receiveLogs(client, into: LogInbox())
        #expect(await client.logLevel == .info)
        #expect(await client.configuration.logLevel == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("cancelRequest ends the call with CancellationError", arguments: bothEras)
    func cancel(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        #expect(try await cancelLongCall(client, timeout: .milliseconds(100)))
        await client.disconnect()
        await server.stop()
    }

    @Test("progress notifications carry the request's token", arguments: bothEras)
    func progress(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        let updates = ProgressInbox()
        let content = try await callWithProgress(client, into: updates)
        #expect(texts(content) == ["indexed"])
        #expect(await updates.values == [1, 2])
        await client.disconnect()
        await server.stop()
    }

    // MARK: Batching, capabilities, errors

    @Test("a batch of tool calls at 2025-11-25")
    func batch() async throws {
        let (server, client) = try await connected(.handshake)
        let results = try await callInBatch(client)
        #expect(results.map { texts($0.content) } == [["one"], ["two"], ["three"]])
        await client.disconnect()
        await server.stop()
    }

    @Test("capabilities and extensions")
    func capabilities() async throws {
        let server = await makeDemoServer()
        let (client, extensions) = try await connectWithCapabilities(transport: try await start(server))
        #expect(extensions?["com.example/audit"] != nil)
        #expect(await client.capabilities.extensions?["com.example/audit"] == ["level": "full"])
        await client.disconnect()
        await server.stop()
    }

    @Test("errors decode into MCPError cases", arguments: bothEras)
    func errors(mode: Client.ProtocolMode) async throws {
        let (server, client) = try await connected(mode)
        do {
            _ = try await client.readResource(uri: "file:///missing.txt")
            Issue.record("readResource should fail")
        } catch {
            #expect(describe(error) == "no resource at file:///missing.txt")
        }
        #expect(describe(CancellationError()).hasPrefix("not an MCP error"))
        await client.disconnect()
        await server.stop()
    }

    // MARK: Tasks

    @Test("tasks: callTool returns the task's result at both eras", arguments: bothEras)
    func tasks(mode: Client.ProtocolMode) async throws {
        let server = await makeReportServer(tasks: TaskManager(configuration: .init(pollInterval: .milliseconds(10))))
        let (client, content) = try await buildReport(transport: try await start(server), mode: mode)
        #expect(texts(content) == ["Report with drafts"])
        let (id, result) = try await followReport(client: client)
        #expect(id != nil)
        #expect(texts(result.content) == ["Report with drafts"])
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Client skill snippets")
struct ClientSkillSnippetTests {
    @Test("A skill loaded and its template read", arguments: bothEras)
    func refunds(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "billing", version: "1", capabilities: .init(resources: .init()))
        await server.withSkills(InMemorySkillCatalog([try makeRefundsSkill()]))
        let client = Client(name: "test", version: "1.0", configuration: .init(protocolMode: mode))
        try await client.connect(transport: try await start(server))
        let answer = try #require(try await answerRefund(client))
        #expect(answer.contains("Answer with the template") && answer.contains("your refund is on its way"))
        await client.disconnect()
        await server.stop()
    }
}

/// Answers every request with the same Server Card, or 404 for a path other
/// than /mcp/server-card.
private final class FixedCardProtocol: URLProtocol, @unchecked Sendable {
    static let card = ServerCard(
        name: "com.example/weather", version: "1.2.0", description: "Current weather for a city.",
        remotes: [
            .init(
                type: .streamableHTTP, url: "https://{tenant}.example.com/mcp",
                variables: ["tenant": .init(isRequired: true)], supportedProtocolVersions: ["2026-07-28"])
        ])

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let found = request.url?.path == "/mcp/server-card"
        let body = found ? ((try? JSONEncoder().encode(Self.card)) ?? Data()) : Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": ServerCard.mediaType])!
        // swift-corelibs-foundation traps when a stopped protocol calls its client.
        guard !lock.withLock({ stopped }) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

@Suite("Client Server Card snippets")
struct ClientServerCardSnippetTests {
    @Test("Read a card, fill in its URL, and check it against the live server")
    func serverCard() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedCardProtocol.self]
        let card = try await readCard(
            of: URL(string: "https://example.com/mcp")!, session: URLSession(configuration: configuration))
        #expect(card == FixedCardProtocol.card)
        #expect(try connectionURL(from: card, tenant: "acme")?.absoluteString == "https://acme.example.com/mcp")

        let (server, client) = try await connected(.automatic)
        defer { Task { await client.disconnect(); await server.stop() } }
        // The demo server has another name and version than the card.
        #expect(try await checkCard(card, with: client).map(\.field) == [.name, .version])
    }
}
