import Foundation
import Testing

@testable import MCP
@testable import ServerSnippets

// Runs the snippets of docs/server.md against a client over an in-memory
// pair, in both protocol eras.

private let eras: [Client.ProtocolMode] = [.handshake, .automatic]

private func connect(
    _ server: Server,
    mode: Client.ProtocolMode,
    name: String = "probe",
    capabilities: Client.Capabilities = .init(),
    configuration: Client.Configuration? = nil,
    configure: (Client) async -> Void = { _ in }
) async throws -> Client {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    var config = configuration ?? Client.Configuration()
    config.protocolMode = mode
    let client = Client(name: name, version: "1.0", capabilities: capabilities, configuration: config)
    await configure(client)
    try await client.connect(transport: clientTransport)
    return client
}

private func text(_ content: [Tool.Content]) -> String? {
    if case .text(let text, _, _)? = content.first { return text }
    return nil
}

private func code(of body: () async throws -> Void) async -> Int? {
    do {
        try await body()
        return nil
    } catch let error as MCPError {
        return error.code
    } catch {
        return nil
    }
}

private actor Inbox<T: Sendable> {
    private(set) var items: [T] = []
    func add(_ item: T) { items.append(item) }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite("Server snippets")
struct ServerSnippetTests {
    @Test("Tools: list, call, isError, protocol errors and structured content", arguments: eras)
    func tools(mode: Client.ProtocolMode) async throws {
        let server = makeServer()
        await registerToolList(on: server)
        await registerToolCall(on: server)
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }

        let tools = try await client.listTools().tools
        #expect(tools.map(\.name) == ["get_weather", "get_forecast", "run_query"])

        let ok = try await client.callTool(name: "get_weather", arguments: ["city": "Paris"])
        #expect(text(ok.content) == "18 degrees (metric), clear, in Paris")
        #expect(ok.isError == nil)

        let failed = try await client.callTool(name: "get_weather")
        #expect(failed.isError == true)

        #expect(await code { _ = try await client.callTool(name: "nope") } == -32602)

        let forecast = try await client.send(
            CallTool.request(.init(name: "get_forecast", arguments: ["city": "Lyon"]))
        ).value
        #expect(forecast.structuredContent?.objectValue?["city"] == "Lyon")
        #expect(text(forecast.content)?.contains("\"celsius\"") == true)
    }

    @Test("Tools: content blocks and header annotations")
    func toolContentAndHeaders() async throws {
        let result = chartResult(png: Data([1, 2, 3]))
        #expect(result.content.count == 4)
        #expect(try headerFields(of: [weatherTool, queryTool]) == ["get_weather": [], "run_query": ["Mcp-Param-Region"]])

        let invalid = Tool(
            name: "bad", description: nil,
            inputSchema: ["type": "object", "properties": ["x": ["type": "object", "x-mcp-header": "X"]]])
        #expect(throws: MCPRequestHeaders.InvalidAnnotation.self) { try headerFields(of: [invalid]) }

        // Stateless tools/list leaves the invalid tool out; handshake lists it.
        for (mode, count) in [(Client.ProtocolMode.handshake, 2), (.automatic, 1)] {
            let server = Server(name: "headers", version: "1.0", capabilities: .init(tools: .init()))
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: [queryTool, invalid]) }
            let client = try await connect(server, mode: mode)
            #expect(try await client.listTools().tools.count == count)
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Prompts: arguments and errors", arguments: eras)
    func prompts(mode: Client.ProtocolMode) async throws {
        let server = makeServer()
        await registerPrompts(on: server)
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }

        #expect(try await client.listPrompts().prompts == [reviewPrompt])
        let prompt = try await client.getPrompt(name: "code_review", arguments: ["language": "Swift"])
        #expect(prompt.description == "Review of a Swift change")
        #expect(prompt.messages.first == .user(.text(text: "Review this Swift change. Focus on correctness.")))
        #expect(await code { _ = try await client.getPrompt(name: "code_review") } == -32602)
        #expect(reviewMessages(diff: "-a\n+b", screenshot: Data([1])).count == 4)
    }

    @Test("Resources: list, templates, text, binary and not found", arguments: eras)
    func resources(mode: Client.ProtocolMode) async throws {
        let server = makeServer()
        await registerResources(on: server)
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }

        #expect(try await client.listResources().resources.count == 2)
        #expect(try await client.listResourceTemplates().templates.first?.uriTemplate == "file:///project/{path}")
        let readme = try await client.readResource(uri: "file:///project/README.md").contents
        #expect(readme.first?.text == "# Project\n")
        let logo = try await client.readResource(uri: "file:///project/logo.png").contents
        #expect(logo.first?.blob == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        let file = try await client.readResource(uri: "file:///project/notes.txt").contents
        #expect(file.first?.text == "Contents of notes.txt")
        do {
            _ = try await client.readResource(uri: "other://x")
            Issue.record("Expected resourceNotFound")
        } catch let error as MCPError {
            #expect(error.code == -32602)
            #expect(error.data == ["uri": "other://x"])
        }
    }

    @Test("Resources: subscriptions in both eras")
    func resourceSubscriptions() async throws {
        // Handshake: the handlers see resources/subscribe.
        let server = makeServer()
        let watched = WatchedResources()
        await registerSubscriptions(on: server, watched: watched)
        let legacy = try await connect(server, mode: .handshake)
        try await legacy.subscribeToResource(uri: "file:///project/README.md")
        #expect(await watched.uris == ["file:///project/README.md"])
        try await legacy.unsubscribeFromResource(uri: "file:///project/README.md")
        #expect(await watched.uris.isEmpty)
        await legacy.disconnect()
        await server.stop()

        // 2026-07-28: subscriptions/listen, served by the SDK.
        let stateless = makeServer()
        let inbox = Inbox<String>()
        let client = try await connect(stateless, mode: .automatic) { client in
            await client.onNotification(ResourceUpdatedNotification.self) { await inbox.add($0.params.uri) }
        }
        defer { Task { await client.disconnect(); await stateless.stop() } }
        #expect(await client.isStateless)
        try await client.subscribeToResource(uri: "file:///project/README.md")
        try await resourceDidChange("file:///project/other.md", on: stateless)
        try await resourceDidChange("file:///project/README.md", on: stateless)
        #expect(await eventually { await inbox.items == ["file:///project/README.md"] })
    }

    @Test("List-changed notifications reach both eras")
    func listChanged() async throws {
        for mode in eras {
            let (server, catalog) = await makeDynamicServer()
            let inbox = Inbox<String>()
            let client = try await connect(server, mode: mode)
            await client.onNotification(ToolListChangedNotification.self) { _ in await inbox.add("tools") }
            if await client.isStateless {
                let subscription = try await client.listen(.init(toolsListChanged: true))
                #expect(subscription.notifications.toolsListChanged == true)
            }
            try await catalog.add(weatherTool)
            #expect(await eventually { await !inbox.items.isEmpty })
            #expect(try await client.listTools().tools.map(\.name) == ["get_weather"])
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Multi round-trip: one handler serves both eras", arguments: eras)
    func multiRoundTrip(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "deployer", version: "1.0", capabilities: .init(tools: .init()))
        await registerDeployTool(on: server)
        let client = try await connect(server, mode: mode, capabilities: .init(elicitation: .init())) { client in
            await client.withElicitationHandler { _ in .init(action: .accept, content: ["confirm": true]) }
        }
        defer { Task { await client.disconnect(); await server.stop() } }

        let result = try await client.callTool(name: "deploy", arguments: ["environment": "production"])
        #expect(text(result.content) == "Deployed build-1234 to production")
    }

    @Test("Multi round-trip: several requests in one round", arguments: eras)
    @available(*, deprecated, message: "Tests the deprecated roots and sampling APIs (SEP-2577)")
    func multiRoundTripSeveral(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "workspace", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { summarizeWorkspace($0) }
        let client = try await connect(
            server, mode: mode, capabilities: .init(sampling: .init(), roots: .init())
        ) { client in
            await client.withRootsHandler { [Root(uri: "file:///work", name: "work")] }
            await client.withSamplingHandler { _ in .init(model: "test-model", role: .assistant, content: .text("ok")) }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "summarize").content) == "1 roots. Model: test-model")
    }

    @Test("Multi round-trip: sampling with tools", arguments: eras)
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func multiRoundTripSamplingTools(mode: Client.ProtocolMode) async throws {
        for maxRounds in [4, 1] {
            let server = Server(name: "travel", version: "1.0", capabilities: .init(tools: .init()))
            await server.withMethodHandler(CallTool.self) { try adviseTravel($0, maxRounds: maxRounds) }
            let choices = Inbox<String>()
            let client = try await connect(
                server, mode: mode, capabilities: .init(sampling: .init(tools: .init()))
            ) { client in
                await client.withSamplingHandler { params in
                    await choices.add(params.toolChoice?.mode?.rawValue ?? "-")
                    // Call the tool first; answer once the result is there.
                    if case .toolResult(let result)? = params.messages.last?.content.asArray.first,
                        case .text(let weather)? = result.content.first
                    {
                        return .init(model: "m", stopReason: .endTurn, role: .assistant, content: .text("Go to \(weather)"))
                    }
                    if params.toolChoice?.mode == CreateSamplingMessage.ToolChoice.Mode.none {
                        return .init(model: "m", stopReason: .endTurn, role: .assistant, content: .text("Either"))
                    }
                    return .init(
                        model: "m", stopReason: .toolUse, role: .assistant,
                        content: .single(.toolUse(.init(id: "1", name: "get_weather", input: ["city": "Paris"]))))
                }
            }
            let answer = text(try await client.callTool(name: "advise").content)
            if maxRounds == 1 {
                #expect(answer == "Either")
                #expect(await choices.items == ["none"])
            } else {
                #expect(answer == "Go to Paris: 18°C, partly cloudy")
                #expect(await choices.items == ["-", "-"])
            }
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Multi round-trip: capability checks")
    func multiRoundTripCapabilities() async throws {
        let server = Server(name: "deployer", version: "1.0", capabilities: .init(tools: .init()))
        await registerDeployTool(on: server)
        let client = try await connect(server, mode: .automatic)
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await code { _ = try await client.callTool(name: "deploy") } == -32021)

        let checked = Server(name: "checked", version: "1.0", capabilities: .init(tools: .init()))
        await checked.withMethodHandler(CallTool.self) { _ in confirmation("Proceed?") }
        let other = try await connect(checked, mode: .automatic)
        defer { Task { await other.disconnect(); await checked.stop() } }
        #expect(try await other.callTool(name: "x").isError == true)
    }

    @Test("Multi round-trip: state protection variants")
    func requestStateProtection() async throws {
        let key = { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }
        let servers: [(Server, (String) -> Bool)] = [
            (try makeClusteredServer(currentKey: key(), previousKey: key(), authenticatedUser: { _ in nil }), { $0.hasPrefix("v1.") }),
            (makeServerWithStoredState(), { UUID(uuidString: $0) != nil }),
            (makeServerWithPlainState(), { $0 == "build-1234" }),
        ]
        for (server, expectedToken) in servers {
            await registerDeployTool(on: server)
            let client = try await connect(
                server, mode: .automatic, capabilities: .init(elicitation: .init()),
                configuration: .init(multiRoundTrip: .init(isEnabled: false)))
            let first = try await client.send(CallTool.request(.init(name: "deploy"))).value
            let token = try #require(first.requestState)
            #expect(expectedToken(token))
            let second = try await client.send(
                CallTool.request(
                    .init(
                        name: "deploy",
                        inputResponses: ["confirm": .elicitation(.init(action: .accept, content: ["confirm": true]))],
                        requestState: token))
            ).value
            #expect(text(second.content) == "Deployed build-1234 to staging")
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Requests to the client work at handshake only", arguments: eras)
    func serverRequests(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "cleaner", version: "1.0", capabilities: .init(tools: .init()))
        await registerCleanTool(on: server)
        let client = try await connect(server, mode: mode, capabilities: .init(elicitation: .init())) { client in
            await client.withElicitationHandler { _ in .init(action: .accept, content: ["confirm": true]) }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        if await client.isStateless {
            #expect(await code { _ = try await client.callTool(name: "clean") } == -32600)
        } else {
            #expect(text(try await client.callTool(name: "clean").content) == "true")
        }
    }

    @Test("Roots are fetched once in a handler, and again after they changed")
    @available(*, deprecated, message: "Tests the deprecated roots API (SEP-2577)")
    func rootsInHandler() async throws {
        let server = Server(name: "cleaner", version: "1.0", capabilities: .init(tools: .init()))
        let cache = RootsCache()
        await watchRoots(on: server, cache: cache)
        await registerRootsTool(on: server, roots: cache)
        let fetches = Inbox<Bool>()
        let client = try await connect(
            server, mode: .handshake, capabilities: .init(roots: .init(listChanged: true))
        ) { client in
            await client.withRootsHandler {
                await fetches.add(true)
                return [Root(uri: "file:///work", name: "work")]
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(text(try await client.callTool(name: "roots").content) == "1 roots")
        #expect(text(try await client.callTool(name: "roots").content) == "1 roots")
        #expect(await fetches.items.count == 1)
        try await client.notifyRootsChanged()
        #expect(
            await eventually {
                _ = try? await client.callTool(name: "roots")
                return await fetches.items.count == 2
            })
    }

    @Test("RootsCache keeps no roots fetched before an invalidation")
    @available(*, deprecated, message: "Tests the deprecated roots API (SEP-2577)")
    func rootsCacheInvalidation() async throws {
        let server = Server(name: "cleaner", version: "1.0", capabilities: .init(tools: .init()))
        let cache = RootsCache()
        let fetches = Inbox<Bool>()
        let release = Inbox<Bool>()
        let client = try await connect(server, mode: .handshake, capabilities: .init(roots: .init())) { client in
            await client.withRootsHandler {
                await fetches.add(true)
                // The first fetch waits until the cache was invalidated.
                if await fetches.items.count == 1 {
                    _ = await eventually { await !release.items.isEmpty }
                }
                return [Root(uri: "file:///work", name: "work")]
            }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        let first = Task { try await cache.roots(of: server) }
        #expect(await eventually { await fetches.items.count == 1 })
        await cache.invalidate()
        await release.add(true)
        _ = try await first.value
        _ = try await cache.roots(of: server)
        #expect(await fetches.items.count == 2)
    }

    @Test("Cacheable results: configuration and handler hints")
    func caching() async throws {
        for mode in eras {
            let server = makeCachingServer()
            await registerToolList(on: server)
            await registerCachedRead(on: server)
            let client = try await connect(server, mode: mode)
            let tools = try await client.send(ListTools.request(.init())).value
            let read = try await client.send(ReadResource.request(.init(uri: "test://a"))).value
            if await client.isStateless {
                #expect(tools.ttlMs == 60_000 && tools.cacheScope == .public)
            } else {
                #expect(tools.ttlMs == nil && tools.cacheScope == nil)
            }
            // A handler's own hints are sent in both eras.
            #expect(read.ttlMs == 1_000 && read.cacheScope == .private)
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Completion", arguments: eras)
    func completion(mode: Client.ProtocolMode) async throws {
        let server = makeServerWithExtension()
        await registerCompletions(on: server)
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }
        let languages = try await client.complete(promptName: "code_review", argumentName: "language", argumentValue: "s")
        #expect(languages.values == ["swift"])
        let files = try await client.complete(
            resourceURI: "file:///project/{path}", argumentName: "path", argumentValue: "p")
        #expect(files.values == ["Package.swift"])
        #expect(await client.serverCapabilities?.extensions?[auditExtension] == ["retentionDays": 30])
    }

    @Test("Logging honors the level of each era", arguments: eras)
    @available(*, deprecated, message: "Tests the deprecated logging API (SEP-2577)")
    func logging(mode: Client.ProtocolMode) async throws {
        let server = await makeLoggingServer()
        let inbox = Inbox<LogLevel>()
        let client = try await connect(server, mode: mode) { client in
            await client.onNotification(LogMessageNotification.self) { await inbox.add($0.params.level) }
        }
        defer { Task { await client.disconnect(); await server.stop() } }
        try await client.setLoggingLevel(.warning)
        _ = try await client.callTool(name: "work")
        #expect(await eventually { await inbox.items == [.error] })
    }

    @Test("Handler context reports the era", arguments: eras)
    func handlerContext(mode: Client.ProtocolMode) async throws {
        let server = makeServer()
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.text(text: describeCaller())])
        }
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }
        let description = try #require(text(try await client.callTool(name: "whoami").content))
        let expected = await client.isStateless ? "2026-07-28 (stateless)" : "2025-11-25 (handshake)"
        #expect(description.contains(expected))
        #expect(description.contains("client: probe"))
        #expect(describeCaller() == "not in a handler")
        #expect(bearerToken() == nil)
    }

    @Test("Pagination", arguments: eras)
    func pagination(mode: Client.ProtocolMode) async throws {
        let server = makeServer()
        let tools = (0..<120).map { Tool(name: "tool\($0)", description: nil, inputSchema: ["type": "object"]) }
        await registerPagedTools(on: server, tools: tools)
        let client = try await connect(server, mode: mode)
        defer { Task { await client.disconnect(); await server.stop() } }

        var names: [String] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            names += page.tools.map(\.name)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(names == tools.map(\.name))
        #expect(await code { _ = try await client.listTools(cursor: "bogus") } == -32602)
    }

    @Test("Lifecycle: initialize hook, strict handshake-only server")
    func lifecycle() async throws {
        let blockedServer = makeServer()
        let (blockedClientTransport, blockedServerTransport) = await InMemoryTransport.createConnectedPair()
        let running = Task { try await serve(blockedServer, on: blockedServerTransport) }
        try await Task.sleep(for: .milliseconds(50))
        let blocked = Client(
            name: "blocked-client", version: "1.0", configuration: .init(protocolMode: .handshake))
        #expect(await code { _ = try await blocked.connect(transport: blockedClientTransport) } == -32600)
        running.cancel()
        _ = await running.result

        // A handshake-only server: an automatic client falls back to initialize.
        let legacy = makeHandshakeOnlyServer()
        await registerToolList(on: legacy)
        let client = try await connect(legacy, mode: .automatic)
        defer { Task { await client.disconnect(); await legacy.stop() } }
        #expect(await !client.isStateless)
        #expect(try await client.listTools().tools.count == 3)
    }

    // MARK: Tasks

    @Test("Tasks: the report tool runs as a task, and inline for a client without tasks", arguments: eras)
    func tasks(mode: Client.ProtocolMode) async throws {
        for configured in [true, false] {
            let server = await makeReportServer(tasks: TaskManager(configuration: .init(pollInterval: .milliseconds(10))))
            let client = try await connect(
                server, mode: mode, capabilities: .init(elicitation: .init()),
                configuration: .init(tasks: configured ? .init(minimumPollInterval: .milliseconds(5), augmentation: .whenSupported) : nil)
            ) { client in
                await client.withElicitationHandler { _ in .init(action: .accept, content: ["drafts": true]) }
            }
            _ = try await client.listTools()
            if !configured, mode != .handshake {
                // Inline at 2026-07-28 the work cannot ask for input.
                #expect(await code { _ = try await client.callTool(name: "report") } == -32021)
            } else {
                let created = try await client.startToolCall(name: "report").value
                #expect((created.task != nil) == configured, "configured: \(configured)")
                #expect(text(try await client.callTool(name: "report").content) == "Report with drafts")
            }
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Tasks: a principal binds tasks to callers; an external job completes its task")
    func taskManagerAndExternalJob() async throws {
        let manager = makeTaskManager { request in request.header("Authorization") }
        #expect(manager.configuration.maxActiveTasksPerPrincipal == 10)
        #expect(manager.bindsPrincipals)
        let context = Server.HandlerContext(
            id: 1, httpContext: HTTPRequest(method: "POST", headers: ["Authorization": "alice"]))
        #expect(manager.owner(of: context) == "alice")

        let jobs = TaskManager()
        let server = Server(name: "jobs", version: "1", capabilities: .init(tools: .init()))
        await server.withTasks(jobs)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "export", description: nil, inputSchema: [:], execution: .init(taskSupport: .required))])
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await startExternalJob(params.name, manager: jobs) { name, done in
                Task { await done("\(name) exported") }
            }
        }
        let client = try await connect(
            server, mode: .automatic,
            configuration: .init(tasks: .init(minimumPollInterval: .milliseconds(5))))
        #expect(text(try await client.callTool(name: "export").content) == "export exported")
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Server Card snippets")
struct ServerCardSnippetTests {
    @Test("The card is answered before the MCP endpoint")
    func serverCard() async throws {
        let card = try makeServerCard()
        let mcp = StatelessHTTPServerTransport()
        let response = await route(
            HTTPRequest(method: "GET", headers: [:], body: nil, path: "/mcp/server-card"), card: card, mcp: mcp)
        #expect(response.statusCode == 200)
        let served = try JSONDecoder().decode(ServerCard.self, from: try #require(response.bodyData))
        #expect(served.name == "com.example/weather")
        #expect(served.remotes?.first?.url == "https://mcp.example.com/mcp")
        // Other requests go to the MCP endpoint, which serves only POST.
        let other = await route(HTTPRequest(method: "GET", headers: [:], body: nil, path: "/mcp"), card: card, mcp: mcp)
        #expect(other.statusCode == 405)
    }
}

@Suite("MCP Apps snippets")
struct AppSnippetTests {
    @Test("The view is listed and read; the tool refers to it; the result has text", arguments: eras)
    func weatherApp(mode: Client.ProtocolMode) async throws {
        let server = try await makeWeatherAppServer()
        let client = try await connect(server, mode: mode)
        let tools = try await client.listTools().tools
        #expect(tools.map(\.name) == ["get_weather", "refresh_dashboard"])
        #expect(tools.map(\.isVisibleToModel) == [true, false])
        let uri = try #require(tools.first?.ui?.resourceUri)
        #expect(try await client.listResources().resources.map(\.uri) == [uri])
        let view = try await client.readAppResource(uri: uri)
        #expect(view.html.hasPrefix("<!DOCTYPE html>"))
        #expect(view.contentSecurityPolicy.contains("connect-src 'self' https://api.weather.example"))
        let result = try await client.callTool(name: "get_weather", arguments: ["city": "Paris"])
        #expect(text(result.content) == "Paris: sunny, 21 °C")
        #expect(result.structuredContent?.objectValue?["celsius"] == 21)
        let capabilities = try #require(await client.serverCapabilities)
        #expect(capabilities.extensions?[ExtensionID.ui] == [:])
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Skill snippets")
struct SkillSnippetTests {
    @Test("Skills from a directory: listed, loaded and read", arguments: eras)
    func directory(mode: Client.ProtocolMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("pdf-processing")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("---\nname: pdf-processing\ndescription: Fill PDF forms\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("Fields".utf8).write(to: skill.appendingPathComponent("references/FORMS.md"))
        try Data("not a skill".utf8).write(to: root.appendingPathComponent("README.md"))

        let server = try await makeSkillsServer(directory: root)
        let client = try await connect(server, mode: mode)
        let skills = try await client.listAllSkills()
        #expect(skills.map(\.uri) == ["skill://pdf-processing/SKILL.md"])
        let loaded = try await client.loadSkill(try #require(skills.first))
        #expect(try await loaded.read("references/FORMS.md") == Data("Fields".utf8))
        let directory = try await client.readResourceDirectory(uri: "skill://pdf-processing")
        #expect(directory.resources.map(\.name) == ["SKILL.md", "references"])
        await client.disconnect()
        await server.stop()
    }

    @Test("A package in memory and a generated skill", arguments: eras)
    func packageAndCatalog(mode: Client.ProtocolMode) async throws {
        let refunds = try makeRefundsSkill()
        #expect(refunds.skill.uri == "skill://acme/billing/refunds/SKILL.md")

        let server = Server(name: "reports", version: "1", capabilities: .init(resources: .init()))
        await server.withSkills(DailyReportSkill())
        let client = try await connect(server, mode: mode)
        #expect(try await client.listAllSkills().isEmpty)
        let entry = try await client.getSkill(uri: DailyReportSkill.uri)
        #expect(entry.resources == .dynamic)
        await #expect(throws: SkillVerificationError.self) { try await client.loadSkill(entry) }
        let loaded = try await client.loadSkill(entry, options: .init(allowsDynamic: true))
        #expect(loaded.content.contains("Sales:"))
        await client.disconnect()
        await server.stop()
    }
}
