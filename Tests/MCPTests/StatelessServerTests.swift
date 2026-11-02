import Foundation
import Testing

@testable import MCP

private let statelessMeta =
    #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

private func statelessParams(_ extra: String = "") -> String {
    extra.isEmpty ? "{\(statelessMeta)}" : "{\(extra),\(statelessMeta)}"
}

private func makeServer(
    capabilities: Server.Capabilities = .init(logging: .init(), resources: .init(), tools: .init()),
    configuration: Server.Configuration = .default
) async -> Server {
    let server = Server(
        name: "stateless", version: "2.0.0", instructions: "Use the tools.",
        capabilities: capabilities, configuration: configuration)
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [Tool(name: "echo", description: nil, inputSchema: ["type": "object"])])
    }
    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: [], ttlMs: 5_000, cacheScope: .public)
    }
    return server
}

@Suite("Stateless Server Tests")
struct StatelessServerTests {
    @Test("server/discover returns versions, capabilities and server identity")
    func testDiscover() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":\#(statelessParams())}"#)
        expectWire(
            reply[0],
            matches: try wireJSON(
                #"""
                {"jsonrpc":"2.0","id":1,"result":{
                  "supportedVersions":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"],
                  "capabilities":{"logging":{},"resources":{},"tools":{}},
                  "instructions":"Use the tools.",
                  "resultType":"complete","ttlMs":0,"cacheScope":"private",
                  "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"stateless","version":"2.0.0"}}}}
                """#))
    }

    @Test("Stateless results carry resultType, serverInfo and cache hints")
    func testStatelessAnnotations() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let tools = try await wire.send(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":\#(statelessParams())}"#)
        expectWire(
            tools[0],
            matches: try wireJSON(
                #"{"result":{"resultType":"complete","ttlMs":0,"cacheScope":"private","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"stateless"}}}}"#
            ))

        // Hints set by the handler win.
        let resources = try await wire.send(
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list","params":\#(statelessParams())}"#)
        expectWire(resources[0], matches: try wireJSON(#"{"result":{"ttlMs":5000,"cacheScope":"public"}}"#))
    }

    @Test("serverInfo keeps a data: icon as written")
    func testServerInfoDataIcon() throws {
        let info = Server.Info(
            name: "stateless", version: "2.0.0", icons: [Icon(src: "data:,hi", mimeType: "text/plain")])
        let annotated = StatelessRequests.annotate(
            .object([:]), method: ListTools.name, serverInfo: info, cacheHint: .init(ttlMs: 0, scope: .private))
        let icon = annotated.objectValue?["_meta"]?.objectValue?[MetaKey.serverInfo]?.objectValue?["icons"]?
            .arrayValue?.first?.objectValue
        #expect(icon?["src"] == .string("data:,hi"))
    }

    @Test("Legacy results are not annotated")
    func testLegacyNotAnnotated() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#)
        let result = try #require(reply[0].objectValue?["result"])
        expectWireLacks(result, "resultType", "ttlMs", "cacheScope", "_meta")
    }

    @Test("Configured cache hints apply per method")
    func testConfiguredCacheHints() async throws {
        let configuration = Server.Configuration(
            cacheHints: [ListTools.name: CacheHint(ttlMs: 60_000, scope: .public)])
        let wire = WireExchange(server: await makeServer(configuration: configuration))
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":\#(statelessParams())}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"result":{"ttlMs":60000,"cacheScope":"public"}}"#))
    }

    @Test("Missing or invalid _meta members are -32602")
    func testInvalidMeta() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let noCapabilities = try await wire.send(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        )
        expectWire(noCapabilities[0], matches: try wireJSON(#"{"id":6,"error":{"code":-32602}}"#))

        let badInfo = try await wire.send(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":"bad"}}}"#
        )
        expectWire(badInfo[0], matches: try wireJSON(#"{"id":7,"error":{"code":-32602}}"#))

        let badVersion = try await wire.send(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":42}}}"#
        )
        expectWire(badVersion[0], matches: try wireJSON(#"{"id":8,"error":{"code":-32602}}"#))
    }

    @Test("Unsupported version is -32022 with the served versions")
    func testUnsupportedVersion() async throws {
        let configuration = Server.Configuration(protocolVersions: ["2026-07-28", "2025-11-25"])
        let wire = WireExchange(server: await makeServer(configuration: configuration))
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        )
        expectWire(
            reply[0],
            matches: try wireJSON(
                #"{"id":9,"error":{"code":-32022,"data":{"supported":["2026-07-28","2025-11-25"],"requested":"2099-01-01"}}}"#
            ))
    }

    @Test("An unserved version is -32022 before the other _meta members are checked")
    func testUnsupportedVersionWithoutCapabilities() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let unserved = try await wire.send(
            #"{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#
        )
        expectWire(
            unserved[0],
            matches: try wireJSON(#"{"id":10,"error":{"code":-32022,"data":{"requested":"2099-01-01"}}}"#))
        let supported = try #require(unserved[0].objectValue?["error"]?.objectValue?["data"]?.objectValue?["supported"])
        #expect(supported.arrayValue?.isEmpty == false)

        let served = try await wire.send(
            #"{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        )
        expectWire(served[0], matches: try wireJSON(#"{"id":11,"error":{"code":-32602}}"#))
    }

    @Test("Removed methods are -32601 at 2026-07-28", arguments: [
        "initialize", "ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe",
    ])
    func testRemovedMethods(method: String) async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":10,"method":"\#(method)","params":\#(statelessParams())}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"id":10,"error":{"code":-32601}}"#))
    }

    @Test("server/discover is -32601 on handshake connections")
    func testDiscoverRequiresStateless() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(#"{"jsonrpc":"2.0","id":11,"method":"server/discover","params":{}}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"id":11,"error":{"code":-32601}}"#))
    }

    @Test("Methods of undeclared capabilities are -32601")
    func testUndeclaredCapability() async throws {
        let server = await makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListPrompts.self) { _ in .init(prompts: []) }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        let prompts = try await wire.send(
            #"{"jsonrpc":"2.0","id":12,"method":"prompts/list","params":\#(statelessParams())}"#)
        expectWire(prompts[0], matches: try wireJSON(#"{"id":12,"error":{"code":-32601}}"#))

        // Handshake requests keep the previous behavior.
        let legacy = try await wire.send(#"{"jsonrpc":"2.0","id":13,"method":"prompts/list","params":{}}"#)
        expectWire(legacy[0], matches: try wireJSON(#"{"id":13,"result":{"prompts":[]}}"#))
    }

    @Test("A handshake version in _meta is served as a handshake request")
    func testHandshakeVersionInMeta() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":14,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25"}}}"#
        )
        expectWire(reply[0], matches: try wireJSON(#"{"id":14,"result":{}}"#))
    }

    @Test("Handlers see the per-request client context")
    func testHandlerContext() async throws {
        let server = await makeServer()
        let recorder = ContextRecorder()
        await server.withMethodHandler(CallTool.self) { _ in
            await recorder.record(Server.currentHandlerContext)
            return .init(content: [])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        try await wire.send(
            #"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"sampling":{}},"io.modelcontextprotocol/clientInfo":{"name":"probe","version":"9"},"io.modelcontextprotocol/logLevel":"error"}}}"#
        )
        let context = try #require(await recorder.context)
        #expect(context.isStateless)
        #expect(context.protocolVersion == "2026-07-28")
        #expect(context.clientCapabilities?.sampling != nil)
        #expect(context.clientInfo?.name == "probe")
        #expect(context.logLevel == .error)
        #expect(context.profile?.usesResultType == true)
    }

    @Test("Log notifications follow the request log level")
    func testLogGate() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            try await server?.log(level: .info, data: "info")
            try await server?.log(level: .error, data: "error")
            return .init(content: [])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        let silent = try await wire.send(
            #"{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"echo",\#(statelessMeta)}}"#)
        #expect(silent.count == 1)
        expectWire(silent[0], matches: try wireJSON(#"{"id":16}"#))

        let filtered = try await wire.send(
            #"{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"warning"}}}"#,
            expecting: 2)
        #expect(filtered.count == 2)
        expectWire(
            filtered[0],
            matches: try wireJSON(#"{"method":"notifications/message","params":{"level":"error"}}"#))
        expectWire(filtered[1], matches: try wireJSON(#"{"id":17}"#))
    }

    @Test("Server-to-client requests fail at 2026-07-28")
    func testNoServerRequests() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            _ = try await server?.listRoots()
            return .init(content: [])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"echo",\#(statelessMeta)}}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"id":18,"error":{"code":-32600}}"#))
    }

    @Test("Undecodable parameters are -32602")
    func testInvalidParams() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { _ in .init(content: []) }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(#"{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":7}}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"id":19,"error":{"code":-32602}}"#))
    }

    @Test("initialize negotiates among configured handshake versions")
    func testInitializeHonorsConfiguration() async throws {
        let configuration = Server.Configuration(protocolVersions: ["2026-07-28", "2025-06-18"])
        let wire = WireExchange(server: await makeServer(configuration: configuration))
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":20,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        )
        expectWire(reply[0], matches: try wireJSON(#"{"id":20,"result":{"protocolVersion":"2025-06-18"}}"#))
    }
}

private actor ContextRecorder {
    var context: Server.HandlerContext?
    func record(_ context: Server.HandlerContext?) { self.context = context }
}

// MARK: - HTTP

private func statelessRequest(
    _ body: String, version: String? = "2026-07-28", accept: String = "application/json, text/event-stream"
) -> HTTPRequest {
    var headers = ["Content-Type": "application/json", "Accept": accept]
    if let version { headers["MCP-Protocol-Version"] = version }
    return HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8), path: "/mcp")
}

private func bodyJSON(_ response: HTTPResponse) throws -> Value {
    try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
}

@Suite("Stateless HTTP Tests")
struct StatelessHTTPTests {
    private func start(_ server: Server) async throws -> StatelessHTTPServerTransport {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator(),
            ]))
        try await server.start(transport: transport)
        return transport
    }

    @Test("Routing helper recognizes stateless protocol versions")
    func testStatelessProtocolVersion() {
        #expect(statelessRequest("{}").statelessProtocolVersion == "2026-07-28")
        #expect(statelessRequest("{}", version: "2099-01-01").statelessProtocolVersion == "2099-01-01")
        #expect(statelessRequest("{}", version: "2025-11-25").statelessProtocolVersion == nil)
        #expect(statelessRequest("{}", version: nil).statelessProtocolVersion == nil)
    }

    @Test("Results keep the client's id; errors map to HTTP status")
    func testStatusMapping() async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let ok = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":\#(statelessParams())}"#))
        #expect(ok.statusCode == 200)
        expectWire(try bodyJSON(ok), matches: try wireJSON(#"{"id":1,"result":{"resultType":"complete"}}"#))

        let missing = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":2,"method":"nope","params":\#(statelessParams())}"#))
        #expect(missing.statusCode == 404)
        expectWire(try bodyJSON(missing), matches: try wireJSON(#"{"id":2,"error":{"code":-32601}}"#))

        let removed = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":3,"method":"ping","params":\#(statelessParams())}"#))
        #expect(removed.statusCode == 404)

        let noCapabilities = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
            ))
        #expect(noCapabilities.statusCode == 400)
        expectWire(try bodyJSON(noCapabilities), matches: try wireJSON(#"{"id":4,"error":{"code":-32602}}"#))
    }

    @Test("Legacy requests keep HTTP 200 for JSON-RPC errors")
    func testLegacyStatus() async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":5,"method":"nope","params":{}}"#, version: nil))
        #expect(response.statusCode == 200)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":5,"error":{"code":-32601}}"#))
    }

    @Test("Header and _meta versions must agree", arguments: [
        (#"{"io.modelcontextprotocol/protocolVersion":"2025-11-25","io.modelcontextprotocol/clientCapabilities":{}}"#, "2026-07-28", -32020),
        (#"{"io.modelcontextprotocol/clientCapabilities":{}}"#, "2026-07-28", -32602),
        (#"{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#, nil, -32020),
    ] as [(String, String?, Int)])
    func testHeaderChecks(meta: String, header: String?, code: Int) async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"h","method":"tools/list","params":{"_meta":\#(meta)}}"#, version: header))
        #expect(response.statusCode == 400)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"h","error":{"code":\#(code)}}"#))
    }

    @Test("Unknown header version is -32022 with the request id")
    func testUnknownHeaderVersion() async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":30,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
                version: "2099-01-01"))
        #expect(response.statusCode == 400)
        expectWire(
            try bodyJSON(response),
            matches: try wireJSON(#"{"id":30,"error":{"code":-32022,"data":{"requested":"2099-01-01"}}}"#))
    }

    @Test("Notifications before the result produce an SSE stream")
    func testSSEWhenNotifying() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            if let token = params._meta?.progressToken {
                try await server?.notify(
                    ProgressNotification.message(.init(progressToken: token, progress: 1, total: 2)))
            }
            return .init(content: [.text(text: "done", annotations: nil, _meta: nil)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let body =
            #"{"jsonrpc":"2.0","id":"p","method":"tools/call","params":{"name":"echo","_meta":{"progressToken":"t","io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let response = await transport.handleRequest(statelessRequest(body))
        guard case .stream(let stream, let headers) = response else {
            Issue.record("Expected an SSE stream, got \(response.statusCode)")
            return
        }
        #expect(headers[HTTPHeaderName.contentType] == "text/event-stream")
        var text = ""
        for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
        let progress = try #require(text.range(of: "notifications/progress"))
        let result = try #require(text.range(of: #""id":"p""#))
        #expect(progress.lowerBound < result.lowerBound)

        // A JSON-only client gets the result alone.
        let json = await transport.handleRequest(statelessRequest(body, accept: "application/json"))
        expectWire(try bodyJSON(json), matches: try wireJSON(#"{"id":"p","result":{"content":[{"text":"done"}]}}"#))
    }

    @Test("Concurrent requests with the same id do not collide")
    func testDuplicateClientIDs() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { params in
            if params.arguments?["slow"] == true { try await Task.sleep(for: .milliseconds(100)) }
            return .init(content: [.text(text: params.arguments?["tag"]?.stringValue ?? "", annotations: nil, _meta: nil)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        func call(_ tag: String, slow: Bool) -> HTTPRequest {
            statelessRequest(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"tag":"\#(tag)","slow":\#(slow)},\#(statelessMeta)}}"#
            )
        }
        async let first = transport.handleRequest(call("first", slow: true))
        async let second = transport.handleRequest(call("second", slow: false))
        let (a, b) = await (first, second)
        expectWire(try bodyJSON(a), matches: try wireJSON(#"{"id":1,"result":{"content":[{"text":"first"}]}}"#))
        expectWire(try bodyJSON(b), matches: try wireJSON(#"{"id":1,"result":{"content":[{"text":"second"}]}}"#))
    }

    @Test("Validation errors carry the request id")
    func testValidationErrorID() async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST", headers: ["Content-Type": "text/plain", "Accept": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":77,"method":"tools/list"}"#.utf8)))
        #expect(response.statusCode == 415)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":77,"error":{"code":-32600}}"#))
    }

    @Test("Stateful transport rejects stateless requests with -32022")
    func testStatefulRejectsStateless() async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let response = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":8,"method":"server/discover","params":\#(statelessParams())}"#))
        #expect(response.statusCode == 400)
        expectWire(
            try bodyJSON(response),
            matches: try wireJSON(
                #"{"id":8,"error":{"code":-32022,"data":{"supported":["2025-11-25","2025-06-18","2025-03-26","2024-11-05"],"requested":"2026-07-28"}}}"#
            ))
    }
}
