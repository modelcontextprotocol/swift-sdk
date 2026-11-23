@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private func makeStatelessServer(
    versions: [String] = Version.stateless + Version.handshake
) async -> Server {
    let server = Server(
        name: "discoverable", version: "3.1.4", instructions: "Hello",
        capabilities: .init(logging: .init(), tools: .init()),
        configuration: .init(protocolVersions: versions))
    await server.withMethodHandler(ListTools.self) { _ in
        let context = Server.currentHandlerContext
        let summary =
            "\(context?.isStateless ?? false)|\(context?.clientInfo?.name ?? "-")|\(context?.logLevel?.rawValue ?? "-")"
        return .init(tools: [Tool(name: summary, description: nil, inputSchema: ["type": "object"])])
    }
    return server
}

private func connectClient(
    _ server: Server, mode: Client.ProtocolMode, logLevel: LogLevel? = nil
) async throws -> (Client, Initialize.Result) {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(
        name: "probe", version: "1.0",
        configuration: .init(protocolMode: mode, logLevel: logLevel))
    let result = try await client.connect(transport: clientTransport)
    return (client, result)
}

@Suite("Client Stateless Connection Tests")
struct ClientStatelessTests {
    @Test("Automatic mode discovers a stateless server")
    func testAutomaticDiscovers() async throws {
        let server = await makeStatelessServer()
        let (client, result) = try await connectClient(server, mode: .automatic, logLevel: .warning)
        defer { Task { await client.disconnect(); await server.stop() } }

        #expect(result.protocolVersion == Version.v2026_07_28)
        #expect(result.serverInfo.name == "discoverable")
        #expect(result.instructions == "Hello")
        #expect(await client.isStateless)
        #expect(await client.negotiatedProtocolVersion == Version.v2026_07_28)
        #expect(await client.serverInfo?.version == "3.1.4")
        #expect(await client.serverCapabilities?.tools != nil)

        // Every request carries the _meta envelope.
        let (tools, _) = try await client.listTools()
        #expect(tools.first?.name == "true|probe|warning")
    }

    @Test("Automatic mode falls back to initialize on a handshake-only server")
    func testAutomaticFallsBack() async throws {
        let server = await makeStatelessServer(versions: Version.handshake)
        let (client, result) = try await connectClient(server, mode: .automatic)
        defer { Task { await client.disconnect(); await server.stop() } }

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(await !client.isStateless)
        let (tools, _) = try await client.listTools()
        #expect(tools.first?.name == "false|probe|-")
    }

    @Test("Reconnecting after a stateless connection negotiates afresh")
    func testReconnectAfterStateless() async throws {
        let stateless = await makeStatelessServer()
        let (client, first) = try await connectClient(stateless, mode: .automatic)
        #expect(first.protocolVersion == Version.v2026_07_28)
        await client.disconnect()
        await stateless.stop()

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let handshake = await makeStatelessServer(versions: Version.handshake)
        try await handshake.start(transport: serverTransport)
        defer { Task { await client.disconnect(); await handshake.stop() } }
        let result = try await client.connect(transport: clientTransport)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(await !client.isStateless)
        // Requests no longer carry the stateless _meta envelope.
        let (tools, _) = try await client.listTools()
        #expect(tools.first?.name == "false|probe|-")
    }

    @Test("Handshake mode never sends server/discover")
    func testHandshakeMode() async throws {
        let server = await makeStatelessServer()
        let (client, result) = try await connectClient(server, mode: .handshake)
        defer { Task { await client.disconnect(); await server.stop() } }

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(await !client.isStateless)
    }

    @Test("Pinned stateless mode fails when the server does not serve it")
    func testPinnedStatelessFails() async throws {
        let server = await makeStatelessServer(versions: Version.handshake)
        await #expect(throws: MCPError.self) {
            _ = try await connectClient(server, mode: .stateless(Version.v2026_07_28))
        }
        await server.stop()
    }

    @Test("Ping on a stateless connection sends server/discover")
    func testStatelessPing() async throws {
        let server = await makeStatelessServer()
        let (client, _) = try await connectClient(server, mode: .automatic)
        defer { Task { await client.disconnect(); await server.stop() } }
        try await client.ping()
    }

    @Test("setLoggingLevel on a stateless connection stamps the level")
    func testStatelessLogLevel() async throws {
        let server = await makeStatelessServer()
        let (client, _) = try await connectClient(server, mode: .automatic)
        defer { Task { await client.disconnect(); await server.stop() } }

        try await client.setLoggingLevel(.error)
        let (tools, _) = try await client.listTools()
        #expect(tools.first?.name == "true|probe|error")
    }
}

/// Lists different tools on each call: `a` first, then `b`.
private actor ToolListing {
    private var calls = 0
    func next() -> String {
        calls += 1
        return calls == 1 ? "a" : "b"
    }
}

@Suite("Client tool header cache")
struct ClientToolHeaderCacheTests {
    private func server(_ listing: ToolListing) async -> Server {
        let server = Server(
            name: "headers", version: "1", capabilities: .init(tools: .init()),
            configuration: .init(protocolVersions: Version.stateless + Version.handshake))
        await server.withMethodHandler(ListTools.self) { _ in
            let name = await listing.next()
            return .init(tools: [
                Tool(
                    name: name, description: nil,
                    inputSchema: ["type": "object", "properties": ["r": ["type": "string", "x-mcp-header": "R"]]])
            ])
        }
        return server
    }

    @Test("A first page replaces earlier tools, and disconnect clears them")
    func replacesAndClears() async throws {
        let server = await server(ToolListing())
        let (client, _) = try await connectClient(server, mode: .automatic)
        _ = try await client.listTools()
        #expect(await client.toolHeaderParameters.keys.sorted() == ["a"])
        _ = try await client.listTools()
        #expect(await client.toolHeaderParameters.keys.sorted() == ["b"])
        await client.disconnect()
        #expect(await client.toolHeaderParameters.isEmpty)
        await server.stop()
    }
}

/// A transport that wraps another one and records the headers the client
/// passes to `send(_:additionalHeaders:)`, by method.
private actor HeaderForwardingTransport: Transport {
    nonisolated let logger = Logger(label: "test.header-forwarding")
    private let base: any Transport
    private(set) var headers: [String: [String: String]] = [:]

    init(_ base: any Transport) {
        self.base = base
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func send(_ data: Data, additionalHeaders: [String: String]) async throws {
        let method = try JSONDecoder().decode(Value.self, from: data).objectValue?["method"]?.stringValue
        headers[method ?? ""] = additionalHeaders
        try await base.send(data, additionalHeaders: additionalHeaders)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() { continuation.yield(data) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Client request headers on custom transports")
struct ClientCustomTransportHeaderTests {
    @Test("A wrapping transport receives the Mcp-Param headers of a stateless tools/call")
    func wrapperReceivesParameterHeaders() async throws {
        let server = Server(
            name: "headers", version: "1", capabilities: .init(tools: .init()),
            configuration: .init(protocolVersions: Version.stateless + Version.handshake))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "route", description: nil,
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "region": ["type": "string", "x-mcp-header": "Region"],
                            "count": ["type": "integer", "x-mcp-header": "Count"],
                            "note": ["type": "string"],
                        ],
                    ])
            ])
        }
        await server.withMethodHandler(CallTool.self) { _ in .init(content: []) }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let transport = HeaderForwardingTransport(clientTransport)
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        try await client.connect(transport: transport)
        #expect(await client.isStateless)

        _ = try await client.listTools()
        _ = try await client.callTool(name: "route", arguments: ["region": "Zürich", "count": 3, "note": "n"])
        await client.disconnect()
        await server.stop()

        let call = try #require(await transport.headers["tools/call"])
        #expect(call == ["Mcp-Param-Region": "=?base64?WsO8cmljaA==?=", "Mcp-Param-Count": "3"])
        #expect(await transport.headers["tools/list"] == nil)
    }
}

@Suite("Client Discovery Negotiation Tests")
struct ClientDiscoveryNegotiationTests {
    /// Waits until the client has sent `count` messages and returns the last one.
    private func sent(_ transport: MockTransport, count: Int) async throws -> [String: Value] {
        for _ in 0..<200 where await transport.sentData.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        let data = try #require(await transport.sentData.dropFirst(count - 1).first)
        return try #require(try JSONDecoder().decode(Value.self, from: data).objectValue)
    }

    private func reply(_ transport: MockTransport, to message: [String: Value], _ body: String) async throws {
        let id = try #require(message["id"])
        let idJSON = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        await transport.queue(data: Data(#"{"jsonrpc":"2.0","id":\#(idJSON),\#(body)}"#.utf8))
    }

    private let discoverResult =
        #""result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mock","version":"1"}}}"#

    @Test("-32022 is retried once with a listed stateless version")
    func testRetryOnUnsupportedVersion() async throws {
        let transport = MockTransport()
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        let connecting = Task { try await client.connect(transport: transport) }

        let first = try await sent(transport, count: 1)
        #expect(first["method"] == "server/discover")
        try await reply(
            transport, to: first,
            #""error":{"code":-32022,"message":"Unsupported","data":{"supported":["2026-07-28"],"requested":"2026-07-28"}}"#)

        let second = try await sent(transport, count: 2)
        #expect(second["method"] == "server/discover")
        #expect(second["id"] != first["id"])
        #expect(
            second["params"]?.objectValue?["_meta"]?.objectValue?[MetaKey.protocolVersion] == "2026-07-28")
        try await reply(transport, to: second, discoverResult)

        let result = try await connecting.value
        #expect(result.serverInfo.name == "mock")
        #expect(await client.isStateless)
        await client.disconnect()
    }

    @Test("Method not found on server/discover falls back to initialize")
    func testFallbackOnMethodNotFound() async throws {
        let transport = MockTransport()
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        let connecting = Task { try await client.connect(transport: transport) }

        let first = try await sent(transport, count: 1)
        try await reply(transport, to: first, #""error":{"code":-32601,"message":"Method not found"}"#)

        let initialize = try await sent(transport, count: 2)
        #expect(initialize["method"] == "initialize")
        try await reply(
            transport, to: initialize,
            #""result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"old","version":"0"}}"#)

        let result = try await connecting.value
        #expect(result.serverInfo.name == "old")
        #expect(await !client.isStateless)
        await client.disconnect()
    }

    @Test("-32022 listing only handshake versions falls back to initialize")
    func testFallbackOnHandshakeOnly() async throws {
        let transport = MockTransport()
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        let connecting = Task { try await client.connect(transport: transport) }

        let first = try await sent(transport, count: 1)
        try await reply(
            transport, to: first,
            #""error":{"code":-32022,"message":"Unsupported","data":{"supported":["2025-11-25"]}}"#)
        let initialize = try await sent(transport, count: 2)
        #expect(initialize["method"] == "initialize")
        try await reply(
            transport, to: initialize,
            #""result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"old","version":"0"}}"#)
        _ = try await connecting.value
        await client.disconnect()
    }
}

#if swift(>=6.1)
    // Shares MockURLProtocol's global handler, so it runs inside the
    // serialized HTTP client suite.
    extension HTTPClientTransportTests {
        var endpoint: URL { testEndpoint }

        @Test("Header follows the request _meta version; 4xx JSON-RPC errors are delivered", .httpClientTransportSetup)
        func testHeaderAndErrorBody() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false)
            try await transport.connect()

            let errorBody = Data(
                #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported","data":{"supported":["2026-07-28"]}}}"#.utf8)
            await MockURLProtocol.requestHandlerStorage.setHandler { [endpoint] request in
                #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2099-01-01")
                let response = HTTPURLResponse(
                    url: endpoint, statusCode: 400, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, errorBody)
            }

            try await transport.send(
                Data(
                    #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#.utf8))
            var iterator = await transport.receive().makeAsyncIterator()
            #expect(try await iterator.next() == errorBody)
            await transport.disconnect()
        }

        @Test("Stateless mode sends no session ID", .httpClientTransportSetup)
        func testNoSessionID() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false)
            try await transport.connect()
            await transport.useStatelessProtocol("2026-07-28")

            await MockURLProtocol.requestHandlerStorage.setHandler { [endpoint] request in
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
                #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
                let response = HTTPURLResponse(
                    url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }
            try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8))
            #expect(await transport.protocolVersion == "2026-07-28")
            await transport.disconnect()
        }

        @Test("Stateless requests carry Mcp-Method, Mcp-Name and Mcp-Param headers", .httpClientTransportSetup)
        func testRequestHeaders() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false)
            let recorder = HeaderRecorder()

            await MockURLProtocol.requestHandlerStorage.setHandler { [endpoint] request in
                let message = try JSONDecoder().decode(Value.self, from: bodyData(of: request)).objectValue ?? [:]
                let method = message["method"]?.stringValue ?? ""
                await recorder.record(method, headers: request.allHTTPHeaderFields ?? [:])
                let result: Value
                switch method {
                case "server/discover":
                    result = [
                        "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "mock", "version": "1"],
                    ]
                case "tools/list":
                    result = [
                        "tools": [
                            [
                                "name": "route", "inputSchema": [
                                    "type": "object",
                                    "properties": [
                                        "region": ["type": "string", "x-mcp-header": "Region"],
                                        "count": ["type": "integer", "x-mcp-header": "Count"],
                                        "note": ["type": "string"],
                                    ],
                                ],
                            ],
                            [
                                "name": "broken", "inputSchema": [
                                    "type": "object",
                                    "properties": ["data": ["type": "object", "x-mcp-header": "Data"]],
                                ],
                            ],
                        ]
                    ]
                default:
                    result = ["content": []]
                }
                let body: Value = ["jsonrpc": "2.0", "id": message["id"] ?? .null, "result": result]
                let response = HTTPURLResponse(
                    url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, try JSONEncoder().encode(body))
            }

            let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
            try await client.connect(transport: transport)
            #expect(try await client.listTools().tools.map(\.name) == ["route"])
            _ = try await client.callTool(name: "route", arguments: ["region": "Zürich", "count": 3, "note": "n"])
            await client.disconnect()

            let discover = try #require(await recorder.headers["server/discover"])
            #expect(discover["Mcp-Method"] == "server/discover")
            let list = try #require(await recorder.headers["tools/list"])
            #expect(list["Mcp-Method"] == "tools/list")
            #expect(list["Mcp-Name"] == nil)
            let call = try #require(await recorder.headers["tools/call"])
            #expect(call["Mcp-Method"] == "tools/call")
            #expect(call["Mcp-Name"] == "route")
            #expect(call["Mcp-Param-Region"] == "=?base64?WsO8cmljaA==?=")
            #expect(call["Mcp-Param-Count"] == "3")
            #expect(call.keys.filter { $0.hasPrefix("Mcp-Param-") }.count == 2)
        }

        @Test("Handshake requests carry no SEP-2243 headers", .httpClientTransportSetup)
        func testNoHeadersOnHandshake() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let transport = HTTPClientTransport(
                endpoint: endpoint, configuration: configuration, streaming: false)
            try await transport.connect()
            await MockURLProtocol.requestHandlerStorage.setHandler { [endpoint] request in
                #expect(request.value(forHTTPHeaderField: "Mcp-Method") == nil)
                #expect(request.value(forHTTPHeaderField: "Mcp-Name") == nil)
                let response = HTTPURLResponse(
                    url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }
            try await transport.send(
                Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8))
            await transport.disconnect()
        }
    }

    private actor HeaderRecorder {
        var headers: [String: [String: String]] = [:]
        func record(_ method: String, headers: [String: String]) {
            self.headers[method] = headers
        }
    }

    private func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
#endif
