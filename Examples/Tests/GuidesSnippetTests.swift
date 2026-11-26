import Foundation
import Testing

@testable import GuidesSnippets
@testable import MCP

// Runs the snippets of docs/protocol_versions.md, migration.md, testing.md,
// troubleshooting.md and rough_edges.md, and checks the behavior those
// guides describe. Regions marked `snippet:` are woven into docs/testing.md.

// MARK: - Helpers

/// A server with the era tool and the given configuration.
private func eraServer(_ configuration: Server.Configuration = .init()) async -> Server {
    let server = Server(
        name: "eras", version: "1.0.0", capabilities: .init(tools: .init()),
        configuration: configuration)
    await registerEraTool(on: server)
    return server
}

private func firstText(_ content: [Tool.Content]) -> String? {
    guard case .text(let text, _, _)? = content.first else { return nil }
    return text
}

/// Sends one raw JSON-RPC message to `server` and returns the first message
/// it sends back.
private func rawExchange(_ server: Server, _ json: String) async throws -> Value {
    let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverEnd)
    try await clientEnd.connect()
    let replies = await clientEnd.receive()
    try await clientEnd.send(Data(json.utf8))
    for try await data in replies {
        return try JSONDecoder().decode(Value.self, from: data)
    }
    throw MCPError.connectionClosed
}

private func errorCode(_ reply: Value) -> Int? {
    reply.objectValue?["error"]?.objectValue?["code"]?.intValue
}

private func body(_ response: HTTPResponse) throws -> Value {
    try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
}

private let statelessMeta =
    #"{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

@Suite("Guide snippets")
struct GuidesSnippetTests {
    // MARK: protocol_versions.md

    @Test("Version lists have the documented values")
    func versionListValues() {
        let lists = versionLists()
        #expect(lists.handshake == ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        #expect(lists.stateless == ["2026-07-28"])
        #expect(lists.supported == Set(Version.handshake + Version.stateless))
        #expect(lists.latest == "2025-11-25")
        #expect(Server.Configuration().protocolVersions == Version.stateless + Version.handshake)
        #expect(Client.Configuration().protocolMode == .automatic)
    }

    @Test("Profiles flip at 2026-07-28")
    func profiles() {
        let stateless = Version.profile(for: Version.v2026_07_28)
        #expect(stateless.usesRequestMeta && stateless.usesResultType && stateless.usesSubscriptionsListen)
        #expect(stateless.usesStandardHeaders)
        #expect(!stateless.usesInitializeHandshake && !stateless.usesSessions)
        #expect(!stateless.allowsServerRequests && !stateless.allowsPrimingEvents)
        let handshake = Version.profile(for: Version.v2025_11_25)
        #expect(handshake.usesInitializeHandshake && handshake.usesSessions)
        #expect(handshake.allowsServerRequests && handshake.allowsPrimingEvents)
        #expect(!handshake.usesRequestMeta && !handshake.usesStandardHeaders)
        #expect(!Version.profile(for: Version.v2024_11_05).allowsPrimingEvents)
        // Unknown later versions get the newest profile before them.
        #expect(Version.profile(for: "2099-01-01").usesRequestMeta)
    }

    @Test("Handlers see the era", arguments: [
        (Client.ProtocolMode.handshake, "2025-11-25 (handshake)"),
        (Client.ProtocolMode.automatic, "2026-07-28 (stateless)"),
    ])
    func handlerEra(mode: Client.ProtocolMode, expected: String) async throws {
        let server = await eraServer()
        let client = try await connectInMemory(to: server, mode: mode)
        let content = try await client.callTool(name: "era").content
        #expect(firstText(content) == expected)
        await client.disconnect()
        await server.stop()
    }

    @Test("Server requests are allowed only in the handshake era", arguments: [
        (Client.ProtocolMode.handshake, "true"), (Client.ProtocolMode.automatic, "false"),
    ])
    func serverRequestsAllowed(mode: Client.ProtocolMode, expected: String) async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.text(text: "\(canSendServerRequests())")])
        }
        let client = try await connectInMemory(to: server, mode: mode)
        #expect(firstText(try await client.callTool(name: "x").content) == expected)
        await client.disconnect()
        await server.stop()
    }

    @Test("Automatic mode connects statelessly to a default server")
    func automaticConnects() async throws {
        let server = await eraServer(bothEras)
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let (client, version, stateless) = try await connectAutomatically(over: clientEnd)
        #expect(version == Version.v2026_07_28)
        #expect(stateless)
        #expect(await client.negotiatedProtocolVersion == version)
        await client.disconnect()
        await server.stop()
    }

    @Test("Automatic mode falls back to initialize on a handshake-only server")
    func automaticFallsBack() async throws {
        let server = await eraServer(handshakeOnly)
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let (client, version, stateless) = try await connectAutomatically(over: clientEnd)
        #expect(version == Version.v2025_11_25)
        #expect(!stateless)
        await client.disconnect()
        await server.stop()
    }

    @Test("Pinned mode fails on a handshake-only server")
    func pinnedFails() async throws {
        let server = await eraServer(handshakeOnly)
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: pinnedMode)
        await #expect(throws: MCPError.unsupportedProtocolVersion(
            supported: Version.handshake, requested: Version.v2026_07_28)
        ) {
            try await client.connect(transport: clientEnd)
        }
        await server.stop()
    }

    @Test("Pinned mode fails when the server does not serve the version")
    func pinnedDoesNotRetry() async throws {
        let server = await eraServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .init(protocolMode: .stateless("2099-01-01")))
        do {
            try await client.connect(transport: clientEnd)
            Issue.record("connect should fail")
        } catch MCPError.unsupportedProtocolVersion(let supported, let requested) {
            #expect(requested == "2099-01-01")
            #expect(supported.contains(Version.v2026_07_28))
        }
        await client.disconnect()
        await server.stop()
    }


    @Test("Handshake mode stays on initialize with any server")
    func handshakeModeStays() async throws {
        let server = await eraServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: handshakeMode)
        #expect(try await client.connect(transport: clientEnd).protocolVersion == Version.v2025_11_25)
        await client.disconnect()
        await server.stop()
    }

    @Test("server/discover lists the configured versions")
    func discoverLists() async throws {
        let server = await eraServer(recentOnly)
        let client = try await connectInMemory(to: server, mode: .automatic)
        let discovered = try await client.send(ServerDiscover.request(.init())).value
        #expect(discovered.supportedVersions == ["2026-07-28", "2025-11-25", "2025-06-18"])
        await client.disconnect()
        await server.stop()
    }

    @Test("A stateless-only server refuses initialize")
    func statelessOnlyServer() async throws {
        let refusing = await eraServer(statelessOnly)
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await refusing.start(transport: serverEnd)
        let legacy = Client(name: "c", version: "1", configuration: handshakeMode)
        await #expect(throws: MCPError.unsupportedProtocolVersion(
            supported: Version.stateless, requested: Version.v2025_11_25)
        ) {
            try await legacy.connect(transport: clientEnd)
        }
        await refusing.stop()

        // A request that names no version is missing a required `_meta`
        // field: -32602, not -32022.
        let strict = await eraServer(statelessOnly)
        let reply = try await rawExchange(strict, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(errorCode(reply) == -32602)

        let modern = await eraServer(statelessOnly)
        let client = try await connectInMemory(to: modern, mode: .automatic)
        #expect(await client.negotiatedProtocolVersion == Version.v2026_07_28)
        await client.disconnect()
        await modern.stop()
    }

    @Test("Stateless requests to a handshake-only server get -32022")
    func handshakeOnlyRejectsStateless() async throws {
        let reply = try await rawExchange(
            await eraServer(handshakeOnly),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":\#(statelessMeta)}}"#)
        #expect(errorCode(reply) == -32022)
        let data = reply.objectValue?["error"]?.objectValue?["data"]?.objectValue
        #expect(data?["supported"] == .array(Version.handshake.map(Value.string)))
    }

    // MARK: migration.md

    @Test("Migrated error handling")
    func migratedErrors() throws {
        #expect(describeError(.serverError(code: -32050, message: "Busy", data: nil)) == "-32050 Busy ")
        #expect(describeError(.resourceNotFound(uri: "file:///x")) == "No resource at file:///x")
        #expect(throws: MCPError.serverError(code: -32050, message: "Quota exceeded", data: ["retryAfterSeconds": 30])) {
            try throwQuotaExceeded()
        }
        let wire = try JSONEncoder().encode(
            MCPError.serverError(code: -32050, message: "Quota exceeded", data: ["retryAfterSeconds": 30]))
        let decoded = try JSONDecoder().decode(Value.self, from: wire)
        #expect(decoded.objectValue?["data"]?.objectValue?["retryAfterSeconds"] == 30)

        // Codes the previous release decoded differently.
        let closed = try JSONDecoder().decode(MCPError.self, from: Data(#"{"code":-32000,"message":"closed"}"#.utf8))
        #expect(closed == .serverError(code: -32000, message: "closed", data: nil))
        let missing = try JSONDecoder().decode(
            MCPError.self, from: Data(#"{"code":-32602,"message":"Gone","data":{"uri":"file:///x"}}"#.utf8))
        #expect(missing == .resourceNotFound(uri: "file:///x", message: "Gone"))
    }

    @Test("Migrated capabilities, responses and configuration")
    func migratedTypes() throws {
        #expect(migratedCapabilities.experimental?["com.example/feature"]?.objectValue?["level"] == 2)
        #expect(responseBody(.data(Data("x".utf8))) == Data("x".utf8))
        #expect(responseBody(.error(statusCode: 404, .methodNotFound(nil))) == Data("404 -32601".utf8))

        let saved = try JSONDecoder().decode(Server.Configuration.self, from: Data(#"{"strict":true}"#.utf8))
        #expect(saved.strict)
        #expect(saved.protocolVersions == Version.stateless + Version.handshake)
        let client = try JSONDecoder().decode(Client.Configuration.self, from: Data(#"{"strict":true}"#.utf8))
        #expect(client.strict)
    }

    @Test("Migrated servers and clients")
    func migratedEndpoints() async throws {
        let server = makeHandshakeOnlyServer()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = makeHandshakeClient()
        #expect(try await client.connect(transport: clientEnd).protocolVersion == Version.v2025_11_25)
        await client.disconnect()
        await server.stop()

        let both = await eraServer()
        let (bothClientEnd, bothServerEnd) = await InMemoryTransport.createConnectedPair()
        try await both.start(transport: bothServerEnd)
        let handshake = makeHandshakeClient()
        #expect(try await handshake.connect(transport: bothClientEnd).protocolVersion == Version.v2025_11_25)
        #expect(await handshake.isStateless == false)
        await handshake.disconnect()
        await both.stop()
    }

    @Test("Invalid params now fail with -32602")
    func invalidParams() async throws {
        let server = await eraServer()
        let reply = try await rawExchange(
            server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"arguments":{}}}"#)
        #expect(errorCode(reply) == -32602)
    }

    // MARK: testing.md

    // snippet: testing-in-memory-test
    @Test("The calculator adds")
    func calculatorAdds() async throws {
        let server = await makeCalculatorServer()
        let client = try await connectInMemory(to: server)

        let result = try await client.callTool(name: "add", arguments: ["a": 2, "b": 3])
        #expect(result.isError == nil)
        #expect(result.content == [.text(text: "5")])

        await client.disconnect()
        await server.stop()
    }
    // endsnippet

    // snippet: testing-context-test
    @Test("A handler that reads its context")
    func contextHandler() async throws {
        let context = Server.HandlerContext(
            id: 1, httpContext: nil, protocolVersion: Version.v2026_07_28,
            clientInfo: .init(name: "tester", version: "1"), isStateless: true)
        let result = try await Server.$currentHandlerContext.withValue(context) {
            try await whoAmI(.init(name: "whoami"))
        }
        #expect(result.content == [.text(text: "tester")])
    }
    // endsnippet

    // snippet: testing-handler-test
    @Test("The add handler, called directly")
    func addHandler() async throws {
        let result = try await addNumbers(.init(name: "add", arguments: ["a": 2, "b": 3]))
        #expect(result.structuredContent == ["sum": 5])

        let invalid = try await addNumbers(.init(name: "add", arguments: ["a": "two"]))
        #expect(invalid.isError == true)

        await #expect(throws: MCPError.self) {
            try await addNumbers(.init(name: "subtract"))
        }
    }
    // endsnippet

    // snippet: testing-both-eras
    @Test("The calculator works in both eras", arguments: [
        Client.ProtocolMode.handshake, .automatic,
    ])
    func calculatorEras(mode: Client.ProtocolMode) async throws {
        let server = await makeCalculatorServer()
        let client = try await connectInMemory(to: server, mode: mode)
        #expect(await client.isStateless == (mode == .automatic))

        let content = try await client.callTool(name: "add", arguments: ["a": 1, "b": 1]).content
        #expect(content == [.text(text: "2")])

        await client.disconnect()
        await server.stop()
    }
    // endsnippet

    // snippet: testing-http-test
    @Test("The calculator over stateless HTTP")
    func calculatorOverHTTP() async throws {
        let server = await makeCalculatorServer()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)

        let call = try statelessPOST(
            id: 1, method: "tools/call", params: ["name": "add", "arguments": ["a": 2, "b": 2]])
        let response = await transport.handleRequest(call)
        #expect(response.statusCode == 200)
        let reply = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        #expect(reply.objectValue?["result"]?.objectValue?["structuredContent"] == ["sum": 4])

        // Methods of undeclared capabilities are -32601, sent as HTTP 404.
        let prompts = await transport.handleRequest(try statelessPOST(id: 2, method: "prompts/list"))
        #expect(prompts.statusCode == 404)

        await server.stop()
    }
    // endsnippet

    // MARK: troubleshooting.md

    @Test("WireLog records the discovery")
    func wireLog() async throws {
        let server = await makeCalculatorServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let log = WireLog(clientEnd, logger: makeDebugLogger())
        let client = Client(name: "c", version: "1")
        try await client.connect(transport: log)
        let lines = await log.lines
        #expect(lines.first?.hasPrefix("send: ") == true)
        #expect(lines.first?.contains(#"discover""#) == true)
        #expect(lines.contains { $0.hasPrefix("receive: ") && $0.contains("supportedVersions") })
        await client.disconnect()
        await server.stop()
        _ = await makeLoggedTransports()
    }

    @Test("Undeclared capabilities give -32601 in both eras", arguments: [
        (Client.ProtocolMode.handshake, "Unknown method: prompts/list"),
        (Client.ProtocolMode.automatic, "capability not declared by the server"),
    ])
    func undeclared(mode: Client.ProtocolMode, detail: String) async throws {
        let server = await makeCalculatorServer()
        let client = try await connectInMemory(to: server, mode: mode)
        let report = await listPromptsReportingErrors(client)
        #expect(report.hasPrefix("[-32601]"))
        #expect(report.contains(detail))
        await client.disconnect()
        await server.stop()
    }

    @Test("Methods removed at 2026-07-28 are -32601", arguments: ["ping", "logging/setLevel", "initialize", "resources/subscribe"])
    func removedMethods(method: String) async throws {
        let reply = try await rawExchange(
            await eraServer(),
            #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{"_meta":\#(statelessMeta)}}"#)
        #expect(errorCode(reply) == -32601)
    }

    @Test("Stateless-only methods are -32601 in the handshake era")
    func statelessOnlyMethods() async throws {
        let reply = try await rawExchange(
            await eraServer(), #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}"#)
        #expect(errorCode(reply) == -32601)
    }

    @Test("Malformed stateless _meta is -32602")
    func malformedMeta() async throws {
        let reply = try await rawExchange(
            await eraServer(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        #expect(errorCode(reply) == -32602)
    }

    @Test("A slow call times out")
    func timeout() async throws {
        let server = Server(name: "slow", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            try await Task.sleep(for: .seconds(30))
            return .init(content: [])
        }
        let client = try await connectInMemory(to: server)
        await #expect(throws: CancellationError.self) {
            try await callTool("slow", on: client, timeout: .milliseconds(100))
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("Input requests work in both eras", arguments: [Client.ProtocolMode.handshake, .automatic])
    func eraNeutralInput(mode: Client.ProtocolMode) async throws {
        let server = Server(name: "files", version: "1", capabilities: .init(tools: .init()))
        await registerConfirmTool(on: server)
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(
            name: "c", version: "1", capabilities: .init(elicitation: .init()),
            configuration: .init(protocolMode: mode))
        await client.withElicitationHandler { _ in .init(action: .accept) }
        try await client.connect(transport: clientEnd)
        #expect(firstText(try await client.callTool(name: "delete").content) == "Deleted")
        await client.disconnect()
        await server.stop()
    }

    @Test("Missing client capabilities at 2026-07-28 are -32021")
    func missingCapabilities() async throws {
        let server = Server(name: "files", version: "1", capabilities: .init(tools: .init()))
        await registerConfirmTool(on: server)
        let client = try await connectInMemory(to: server, mode: .automatic)
        await #expect(throws: MCPError.missingRequiredClientCapabilities(
            .init(elicitation: .init(form: .init())),
            message: "tools/call needs client capabilities for elicitation/create")
        ) {
            try await client.callTool(name: "delete")
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("A handshake client without the elicitation capability gets -32021")
    func missingCapabilityAtHandshake() async throws {
        let server = Server(name: "files", version: "1", capabilities: .init(tools: .init()))
        await registerConfirmTool(on: server)
        let client = try await connectInMemory(to: server)
        do {
            _ = try await client.callTool(name: "delete")
            Issue.record("expected an error")
        } catch let error as MCPError {
            #expect(error.code == -32021)
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("Server requests at 2026-07-28 are -32600")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func serverRequestAtStateless() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            _ = try await server?.requestSampling(messages: [], maxTokens: 10)
            return .init(content: [])
        }
        let client = try await connectInMemory(to: server, mode: .automatic)
        do {
            _ = try await client.callTool(name: "x")
            Issue.record("expected an error")
        } catch let error as MCPError {
            #expect(error.code == -32600)
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("A forged requestState is -32602")
    func forgedState() async throws {
        let server = Server(name: "files", version: "1", capabilities: .init(tools: .init()))
        await registerConfirmTool(on: server)
        let client = try await connectInMemory(to: server, mode: .automatic)
        await #expect(throws: MCPError.invalidParams("Invalid or expired requestState")) {
            try await client.send(CallTool.request(.init(name: "delete", requestState: "forged"))).value
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("HTTP status codes of the stateless transport")
    func httpStatus() async throws {
        let server = await makeCalculatorServer()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)

        var wrongMethod = try statelessPOST(id: 1, method: "tools/list")
        var headers = wrongMethod.headers
        headers[MCPRequestHeaders.method] = "tools/call"
        wrongMethod = HTTPRequest(method: "POST", headers: headers, body: wrongMethod.body)
        let mismatch = await transport.handleRequest(wrongMethod)
        #expect(mismatch.statusCode == 400)
        #expect(errorCode(try body(mismatch)) == -32020)

        headers = try statelessPOST(id: 2, method: "tools/list").headers
        headers["MCP-Protocol-Version"] = "2099-01-01"
        let unsupported = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: headers, body: try statelessPOST(id: 2, method: "tools/list").body))
        #expect(unsupported.statusCode == 400)
        #expect(errorCode(try body(unsupported)) == -32022)

        let get = await transport.handleRequest(HTTPRequest(method: "GET"))
        #expect(get.statusCode == 405)
        #expect(get.headers["Allow"] == "POST")

        var jsonOnly = try statelessPOST(id: 3, method: "tools/list").headers
        jsonOnly["Accept"] = "text/html"
        let notAcceptable = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: jsonOnly, body: try statelessPOST(id: 3, method: "tools/list").body))
        #expect(notAcceptable.statusCode == 406)

        await server.stop()
    }

    @Test("The stateful transport answers stateless requests with 400 and -32022")
    func statefulRejectsStateless() async throws {
        let server = await makeCalculatorServer()
        let transport = StatefulHTTPServerTransport()
        try await server.start(transport: transport)
        let response = await transport.handleRequest(try statelessPOST(id: 1, method: "tools/list"))
        #expect(response.statusCode == 400)
        #expect(errorCode(try body(response)) == -32022)
        await server.stop()
    }

    // MARK: rough_edges.md

    @Test("Cache hints are filled at 2026-07-28 only", arguments: [
        (Client.ProtocolMode.handshake, false), (Client.ProtocolMode.automatic, true),
    ])
    func cacheHints(mode: Client.ProtocolMode, filled: Bool) async throws {
        let server = await makeCalculatorServer()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
        let client = try await connectInMemory(to: server, mode: mode)
        let result = try await client.listTools()
        #expect((result.ttlMs == 0) == filled)
        #expect((result.cacheScope == .private) == filled)
        #expect((result._meta?.serverInfo?.name == "calculator") == filled)
        await client.disconnect()
        await server.stop()
    }

    @Test("Rough edges in errors and the stateless transport")
    func roughErrors() async throws {

        // -32603 keeps the message of a peer that sends no `data.detail`.
        let decodedInternal = try JSONDecoder().decode(
            MCPError.self, from: Data(#"{"code":-32603,"message":"boom"}"#.utf8))
        #expect(decodedInternal == .internalError("boom"))

        // One server behind the stateless transport answers every initialize.
        let server = await makeCalculatorServer()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        let initialize = HTTPRequest(
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: Data(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
                    .utf8))
        #expect(await transport.handleRequest(initialize).statusCode == 200)
        let second = await transport.handleRequest(initialize)
        #expect(second.statusCode == 200)
        #expect(errorCode(try body(second)) == nil)
        await server.stop()
    }
}
