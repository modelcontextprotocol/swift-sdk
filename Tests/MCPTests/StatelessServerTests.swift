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

        let emptyVersion = try await wire.send(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        )
        expectWire(emptyVersion[0], matches: try wireJSON(#"{"id":9,"error":{"code":-32602}}"#))
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
    @available(*, deprecated, message: "Tests the deprecated logging API (SEP-2577)")
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
    @available(*, deprecated, message: "Tests the deprecated roots API (SEP-2577)")
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

/// A POST of `body`. At stateless versions, `Mcp-Method` and `Mcp-Name` are
/// derived from the body unless `standardHeaders` is `false`; `extraHeaders`
/// are applied last.
private func statelessRequest(
    _ body: String, version: String? = "2026-07-28", accept: String = "application/json, text/event-stream",
    standardHeaders: Bool = true, extraHeaders: [String: String] = [:]
) -> HTTPRequest {
    var headers = ["Content-Type": "application/json", "Accept": accept]
    if let version { headers["MCP-Protocol-Version"] = version }
    if standardHeaders, let version, Version.profile(for: version).usesStandardHeaders,
        let message = try? JSONDecoder().decode(Value.self, from: Data(body.utf8)).objectValue,
        let method = message["method"]?.stringValue
    {
        headers[MCPRequestHeaders.method] = method
        if let name = MCPRequestHeaders.nameValue(method: method, params: message["params"]) {
            headers[MCPRequestHeaders.name] = MCPRequestHeaders.encode(name)
        }
    }
    headers.merge(extraHeaders) { $1 }
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

    @Test("An empty _meta version is -32602, as in Server", arguments: [
        // The header names a stateless revision: the transport answers.
        ("2026-07-28", 400),
        // No header: the server answers, with the handshake-era status for
        // JSON-RPC errors.
        (nil, 200),
    ] as [(String?, Int)])
    func testEmptyMetaVersion(header: String?, status: Int) async throws {
        let server = await makeServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"e","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
                version: header))
        #expect(response.statusCode == status)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"e","error":{"code":-32602}}"#))
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
            return .init(content: [.text(text: "done")])
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

    @Test("A handshake handler's list-changed notification goes on its request's stream")
    func testSessionlessListChanged() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            try await server?.notify(ToolListChangedNotification.message())
            return .init(content: [.text(text: "done", annotations: nil, _meta: nil)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let handshake = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"h","method":"tools/call","params":{"name":"echo"}}"#, version: "2025-11-25"))
        guard case .stream(let stream, _) = handshake else {
            Issue.record("Expected an SSE stream, got \(handshake.statusCode)")
            return
        }
        var text = ""
        for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
        let notification = try #require(text.range(of: "notifications/tools/list_changed"))
        let result = try #require(text.range(of: #""id":"h""#))
        #expect(notification.lowerBound < result.lowerBound)

        // At 2026-07-28 it goes only to listen streams.
        let stateless = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":\#(statelessParams(#""name":"echo""#))}"#))
        let body = try bodyJSON(stateless)
        #expect(body.objectValue?["id"] == "s")
        #expect(body.objectValue?["result"] != nil)
    }

    @Test("notify(_:to:) asks recipients about the handshake request whose stream it would use")
    func testSessionlessListChangedRecipients() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            try await server?.notify(ToolListChangedNotification.message()) {
                $0.httpContext?.header("X-Tenant") == "a"
            }
            return .init(content: [.text(text: "done", annotations: nil, _meta: nil)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        func call(tenant: String) async throws -> String {
            let response = await transport.handleRequest(
                statelessRequest(
                    #"{"jsonrpc":"2.0","id":"h","method":"tools/call","params":{"name":"echo"}}"#,
                    version: "2025-11-25", extraHeaders: ["X-Tenant": tenant]))
            guard case .stream(let stream, _) = response else {
                return String(decoding: try #require(response.bodyData), as: UTF8.self)
            }
            var text = ""
            for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
            return text
        }
        let accepted = try await call(tenant: "a")
        #expect(accepted.contains("notifications/tools/list_changed"))
        let refused = try await call(tenant: "b")
        #expect(!refused.contains("notifications/tools/list_changed"))
        #expect(refused.contains(#""id":"h""#))
    }

    @Test("Concurrent requests with the same id do not collide")
    func testDuplicateClientIDs() async throws {
        let server = await makeServer()
        await server.withMethodHandler(CallTool.self) { params in
            if params.arguments?["slow"] == true { try await Task.sleep(for: .milliseconds(100)) }
            return .init(content: [.text(text: params.arguments?["tag"]?.stringValue ?? "")])
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

    // MARK: Request headers (SEP-2243)

    private func headerServer() async -> Server {
        let server = await makeServer()
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(name: "echo", description: nil, inputSchema: ["type": "object"]),
                Tool(
                    name: "route", description: nil,
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "region": ["type": "string", "x-mcp-header": "Region"],
                            "count": ["type": "integer", "x-mcp-header": "Count"],
                            "note": ["type": "string"],
                        ],
                    ]),
                Tool(
                    name: "broken", description: nil,
                    inputSchema: ["type": "object", "properties": ["data": ["type": "object", "x-mcp-header": "Data"]]]),
            ])
        }
        await server.withMethodHandler(CallTool.self) { params in
            .init(content: [.text(text: params.name)])
        }
        return server
    }

    @Test("Mcp-Method and Mcp-Name must match the body", arguments: [
        (true, [:], 200),
        (false, [:], 400),
        (true, ["Mcp-Method": "TOOLS/CALL"], 400),
        (true, ["Mcp-Name": "other"], 400),
        (true, ["Mcp-Name": "  echo  "], 200),
        (true, ["Mcp-Name": "=?base64?ZWNobw==?="], 200),
        (false, ["Mcp-Method": "tools/call"], 400),
        (false, ["mcp-method": "tools/call", "MCP-NAME": "echo"], 200),
    ] as [(Bool, [String: String], Int)])
    func testStandardHeaders(standard: Bool, headers: [String: String], status: Int) async throws {
        let server = await headerServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":\#(statelessParams(#""name":"echo""#))}"#,
                standardHeaders: standard, extraHeaders: headers))
        #expect(response.statusCode == status)
        if status == 400 {
            expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"s","error":{"code":-32020}}"#))
        }
    }

    /// Duplicate member names resolve differently across parsers and
    /// platforms, so whichever member the header names, the request is
    /// either refused or served as the header says.
    @Test("Duplicate members are checked as they are dispatched", arguments: [
        (#""method":"tools/call","params":{"name":"echo","name":"route","#, "tools/call", "echo"),
        (#""method":"tools/call","params":{"name":"echo","name":"route","#, "tools/call", "route"),
        (#""method":"tools/call","method":"tools/list","params":{"name":"echo","#, "tools/call", "echo"),
        (#""method":"tools/list","method":"tools/call","params":{"name":"echo","#, "tools/call", "echo"),
        (#""method":"tools/call","method":"tools/list","params":{"name":"echo","#, "tools/list", nil),
        (#""method":"tools/list","method":"tools/call","params":{"name":"echo","#, "tools/list", nil),
    ] as [(String, String, String?)])
    func testDuplicateMembers(members: String, method: String, name: String?) async throws {
        let server = await headerServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        var headers = ["Mcp-Method": method]
        if let name { headers["Mcp-Name"] = name }
        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"d",\#(members)\#(statelessMeta)}}"#,
                standardHeaders: false, extraHeaders: headers))
        let result = try bodyJSON(response).objectValue?["result"]?.objectValue
        if response.statusCode == 400 {
            expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"d","error":{"code":-32020}}"#))
        } else if method == "tools/list" {
            #expect(response.statusCode == 200)
            #expect(result?["tools"] != nil)
        } else {
            #expect(response.statusCode == 200)
            #expect(result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == name)
        }
    }

    @Test("Messages are forwarded in the form the headers were checked against")
    func testForwardedAsChecked() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        var messages = await transport.receive().makeAsyncIterator()

        let progress = #""params":{"progressToken":"t","progress":0.1,\#(statelessMeta)}}"#
        let duplicate = #"{"jsonrpc":"2.0","method":"notifications/progress","method":"notifications/message",\#(progress)"#
        // Foundation keeps one of the two members: the first on Apple
        // platforms, the last with swift-corelibs-foundation. The header names
        // that one, so the check passes and the forwarded message must be it.
        let parsed = try JSONSerialization.jsonObject(with: Data(duplicate.utf8)) as? [String: Any]
        let kept = try #require(parsed?["method"] as? String)
        let checked = await transport.handleRequest(
            statelessRequest(duplicate, standardHeaders: false, extraHeaders: ["Mcp-Method": kept]))
        try #require(checked.statusCode == 202)
        let forwarded = String(decoding: try #require(try await messages.next()), as: UTF8.self)
        #expect(forwarded.components(separatedBy: #""method""#).count == 2)
        #expect(forwarded.contains(#""method":"\#(kept)""#))

        // Without a header check, a message is forwarded byte for byte.
        let legacy = #"{"jsonrpc":"2.0","method":"notifications/progress",\#(progress)"#
        let unchecked = await transport.handleRequest(statelessRequest(legacy, version: nil))
        #expect(unchecked.statusCode == 202)
        #expect(try #require(try await messages.next()) == Data(legacy.utf8))
    }

    @Test("Without a tools/list handler, calls with Mcp-Param headers are refused")
    func testParameterHeadersWithoutToolList() async throws {
        let server = Server(name: "stateless", version: "2.0.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { params in
            .init(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let body =
            #"{"jsonrpc":"2.0","id":"n","method":"tools/call","params":\#(statelessParams(#""name":"route","arguments":{"region":"us"}"#))}"#
        let refused = await transport.handleRequest(
            statelessRequest(body, extraHeaders: ["Mcp-Param-Region": "us"]))
        #expect(refused.statusCode == 400)
        expectWire(try bodyJSON(refused), matches: try wireJSON(#"{"id":"n","error":{"code":-32020}}"#))
        #expect(await transport.handleRequest(statelessRequest(body)).statusCode == 200)
    }

    @Test("Mcp-Param headers must match x-mcp-header arguments", arguments: [
        (#"{"region":"us"}"#, ["Mcp-Param-Region": "us"], 200),
        (#"{"region":"us"}"#, ["mcp-param-region": " us "], 200),
        (#"{"region":"us"}"#, [:], 400),
        (#"{}"#, ["Mcp-Param-Region": "us"], 400),
        (#"{"region":null}"#, [:], 200),
        (#"{"region":"Hello"}"#, ["Mcp-Param-Region": "=?base64?SGVsbG8=?="], 200),
        (#"{"region":"Hello"}"#, ["Mcp-Param-Region": "=?base64?SGVsbG8?="], 400),
        (#"{"region":"=?base64?SGVsbG8="}"#, ["Mcp-Param-Region": "=?base64?SGVsbG8="], 200),
        (#"{"region":"us","count":3}"#, ["Mcp-Param-Region": "us", "Mcp-Param-Count": "3"], 200),
        (#"{"region":"us","count":3}"#, ["Mcp-Param-Region": "us", "Mcp-Param-Count": "4"], 400),
        (#"{"note":"n"}"#, [:], 200),
    ] as [(String, [String: String], Int)])
    func testParameterHeaders(arguments: String, headers: [String: String], status: Int) async throws {
        let server = await headerServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"p","method":"tools/call","params":\#(statelessParams(#""name":"route","arguments":\#(arguments)"#))}"#,
                extraHeaders: headers))
        #expect(response.statusCode == status)
        if status == 400 {
            expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"p","error":{"code":-32020}}"#))
        }
    }

    @Test("Stateless tools/list omits tools with invalid x-mcp-header annotations")
    func testInvalidAnnotationsNotListed() async throws {
        let server = await headerServer()
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        func names(_ response: HTTPResponse) throws -> [String] {
            try bodyJSON(response).objectValue?["result"]?.objectValue?["tools"]?.arrayValue?
                .compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        }
        let stateless = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":\#(statelessParams())}"#))
        #expect(try names(stateless) == ["echo", "route"])

        let legacy = await transport.handleRequest(
            statelessRequest(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#, version: nil))
        #expect(try names(legacy) == ["echo", "route", "broken"])
    }

    // MARK: subscriptions/listen

    @Test("listen streams carry the client's id and end when the client goes away")
    func testListenOverHTTP() async throws {
        let server = Server(
            name: "listen", version: "1.0", capabilities: .init(tools: .init(listChanged: true)))
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"L1","method":"subscriptions/listen","params":\#(statelessParams(#""notifications":{"toolsListChanged":true,"promptsListChanged":true}"#))}"#
            ))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected an SSE stream, got \(response.statusCode)")
            return
        }

        func event(_ chunk: Data) throws -> Value {
            let text = String(decoding: chunk, as: UTF8.self)
            let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("data:") })
            return try JSONDecoder().decode(Value.self, from: Data(line.dropFirst(5).utf8))
        }

        let (received, receivedContinuation) = AsyncStream<Value>.makeStream()
        let reader = Task {
            for try await chunk in stream { receivedContinuation.yield(try event(chunk)) }
        }
        var events: [Value] = []
        for await value in received {
            events.append(value)
            if events.count == 1 { try await server.notify(ToolListChangedNotification.message()) }
            if events.count == 2 { break }
        }
        // The client goes away while the stream is open.
        reader.cancel()
        expectWire(
            events[0],
            matches: try wireJSON(
                #"{"method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/subscriptionId":"L1"}}}"#
            ))
        expectWire(
            events[1],
            matches: try wireJSON(
                #"{"method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"L1"}}}"#
            ))

        // The server's listen handler ends.
        var open = await server.openSubscriptionCount
        let deadline = ContinuousClock.now + .seconds(30)
        while open > 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            open = await server.openSubscriptionCount
        }
        #expect(open == 0)
    }

    @Test("listen without text/event-stream in Accept is refused with 406")
    func testListenNeedsSSE() async throws {
        let server = Server(
            name: "listen", version: "1.0", capabilities: .init(tools: .init(listChanged: true)))
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"L2","method":"subscriptions/listen","params":\#(statelessParams(#""notifications":{"toolsListChanged":true}"#))}"#,
                accept: "application/json"))
        #expect(response.statusCode == 406)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"L2","error":{"code":-32600}}"#))
        #expect(await server.openSubscriptionCount == 0)
    }

    @Test("Open SSE streams carry keep-alive comments")
    func testKeepAlive() async throws {
        let server = Server(
            name: "listen", version: "1.0", capabilities: .init(tools: .init(listChanged: true)))
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator(),
            ]),
            keepAliveInterval: .milliseconds(20))
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"L3","method":"subscriptions/listen","params":\#(statelessParams(#""notifications":{"toolsListChanged":true}"#))}"#
            ))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected an SSE stream, got \(response.statusCode)")
            return
        }
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(String(decoding: chunk, as: UTF8.self))
            if chunks.filter({ $0 == ": keep-alive\n\n" }).count == 2 { break }
        }
        #expect(chunks.first?.contains("notifications/subscriptions/acknowledged") == true)
        #expect(chunks.filter { $0 == ": keep-alive\n\n" }.count == 2)
    }
}

/// Counts `tools/list` handler calls.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Mcp-Param schema lookup")
struct ParameterHeaderLookupTests {
    private let routeSchema: Value = [
        "type": "object",
        "properties": ["region": ["type": "string", "x-mcp-header": "Region"]],
    ]

    /// A server whose `tools/list` handler is counted and lists `route` and
    /// the invalid `broken`, over `pages` pages.
    private func server(
        counter: CallCounter, pages: Int = 1, failing: Bool = false
    ) async -> Server {
        let server = await makeServer()
        let route = Tool(name: "route", description: nil, inputSchema: routeSchema)
        let broken = Tool(
            name: "broken", description: nil,
            inputSchema: ["type": "object", "properties": ["data": ["type": "object", "x-mcp-header": "Data"]]])
        await server.withMethodHandler(ListTools.self) { params in
            await counter.increment()
            if failing { throw MCPError.internalError("backend down") }
            let page = Int(params.cursor ?? "0") ?? 0
            let next = page + 1 < pages ? String(page + 1) : nil
            return .init(tools: page == 0 ? [route, broken] : [], nextCursor: next)
        }
        await server.withMethodHandler(CallTool.self) { params in
            .init(content: [.text(text: params.name)])
        }
        return server
    }

    private func start(_ server: Server) async throws -> StatelessHTTPServerTransport {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator(),
            ]))
        try await server.start(transport: transport)
        return transport
    }

    private func call(
        _ transport: StatelessHTTPServerTransport, tool: String, arguments: String = #"{"region":"us"}"#,
        headers: [String: String] = ["Mcp-Param-Region": "us"]
    ) async -> HTTPResponse {
        await transport.handleRequest(
            statelessRequest(
                #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":\#(statelessParams(#""name":"\#(tool)","arguments":\#(arguments)"#))}"#,
                extraHeaders: headers))
    }

    @Test("Each call reads tools/list once: the list is not kept across calls")
    func listsPerCall() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter)
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        for _ in 0..<5 {
            #expect(await call(transport, tool: "route").statusCode == 200)
        }
        #expect(await counter.count == 5)
    }

    @Test("Concurrent calls each page through tools/list")
    func pagesPerCall() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter, pages: 3)
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = await call(transport, tool: "route") }
            }
        }
        #expect(await counter.count == 30)
    }

    @Test("A call to an unlisted tool pages tools/list once")
    func unknownToolPagesOnce() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter, pages: 4)
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        for _ in 0..<3 {
            _ = await call(transport, tool: "ghost", headers: [:])
        }
        #expect(await counter.count == 12)
    }

    @Test("The schemas come from the caller's own tools/list, not an earlier caller's")
    func perCallerSchemas() async throws {
        let server = await makeServer()
        let route = Tool(name: "route", description: nil, inputSchema: routeSchema)
        // Only caller b sees `route`.
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Server.currentHandlerContext?.httpContext?.header("X-User") == "b" ? [route] : [])
        }
        await server.withMethodHandler(CallTool.self) { params in
            .init(content: [.text(text: params.name)])
        }
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        // Its arguments make a reads tools/list, where `route` is absent.
        #expect(await call(transport, tool: "route", headers: ["X-User": "a"]).statusCode == 200)
        let response = await call(transport, tool: "route", headers: ["X-User": "b", "Mcp-Param-Region": "us"])
        #expect(response.statusCode == 200)
    }

    @Test("Mcp-Param headers for an unlisted tool are refused; arguments alone pass")
    func unlistedToolWithHeaders() async throws {
        let server = await server(counter: CallCounter())
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let refused = await call(transport, tool: "ghost")
        #expect(refused.statusCode == 400)
        expectWire(try bodyJSON(refused), matches: try wireJSON(#"{"id":"c","error":{"code":-32020}}"#))
        #expect(await call(transport, tool: "ghost", headers: [:]).statusCode == 200)
    }

    @Test("A call to a tool hidden for an invalid annotation is refused")
    func invalidToolIsRefused() async throws {
        let server = await server(counter: CallCounter())
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        let response = await call(transport, tool: "broken", arguments: #"{"data":{}}"#, headers: [:])
        #expect(response.statusCode == 400)
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"c","error":{"code":-32020}}"#))
    }

    @Test("When tools/list fails, calls with Mcp-Param headers are refused; each call tries once")
    func failsClosed() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter, failing: true)
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        #expect(await call(transport, tool: "route").statusCode == 400)
        #expect(await call(transport, tool: "route", headers: [:]).statusCode == 200)
        #expect(await counter.count == 2)
    }

    @Test("A page cap that is reached refuses calls with Mcp-Param headers")
    func pageCapFailsClosed() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter, pages: 1_000)
        let transport = try await start(server)
        defer { Task { await server.stop() } }

        #expect(await call(transport, tool: "route").statusCode == 400)
        #expect(await counter.count == 100)
    }

    @Test("A refused stateless client does not reach tools/list")
    func runsAfterTheHook() async throws {
        let counter = CallCounter()
        let server = await server(counter: counter)
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator(),
            ]))
        try await server.start(
            transport: transport, initializeHook: { _, _ in },
            statelessRequestHook: { _, _ in throw MCPError.invalidRequest("not allowed") })
        defer { Task { await server.stop() } }

        let response = await call(transport, tool: "route")
        expectWire(try bodyJSON(response), matches: try wireJSON(#"{"id":"c","error":{"code":-32600}}"#))
        #expect(await counter.count == 0)
    }
}

@Suite("HTTP validation context")
struct HTTPValidationContextTests {
    @Test("By default a context serves the handshake revisions only")
    func defaultsToHandshake() throws {
        let context = HTTPValidationContext(httpMethod: "POST", sessionID: "s")
        #expect(context.supportedProtocolVersions == Set(Version.handshake))
        let request = HTTPRequest(
            method: "POST", headers: ["MCP-Protocol-Version": Version.v2026_07_28], body: Data("{}".utf8), path: "/mcp")
        let response = try #require(ProtocolVersionValidator().validate(request, context: context))
        #expect(response.statusCode == 400)
        let body = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        #expect(body.objectValue?["error"]?.objectValue?["code"] == -32022)
        #expect(
            body.objectValue?["error"]?.objectValue?["data"]?.objectValue?["supported"]?.arrayValue?
                .contains(.string(Version.v2026_07_28)) == false)
    }
}
