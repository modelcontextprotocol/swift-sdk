import Foundation
import Testing

@testable import MCP

@Suite("Wire Golden Tests")
struct WireGoldenTests {
    private func makeServer() async -> Server {
        let server = Server(
            name: "golden", version: "1.0.0",
            capabilities: .init(resources: .init(), tools: .init()))
        await server.withMethodHandler(ReadResource.self) { params in
            throw MCPError.resourceNotFound(uri: params.uri)
        }
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "t", description: nil, inputSchema: ["type": "object"])])
        }
        return server
    }

    @Test("Legacy initialize negotiates and omits 2026 members")
    func testLegacyInitialize() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        )
        expectWire(
            reply[0],
            matches: try wireJSON(
                #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"golden","version":"1.0.0"},"capabilities":{"tools":{}}}}"#
            ))
        expectWireLacks(try #require(reply[0].objectValue?["result"]), "resultType", "ttlMs", "cacheScope")
    }

    @Test("Resource not found is -32602 with data.uri")
    func testResourceNotFound() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(
            #"{"jsonrpc":"2.0","id":"r","method":"resources/read","params":{"uri":"test://missing"}}"#)
        expectWire(
            reply[0],
            matches: try wireJSON(
                #"{"jsonrpc":"2.0","id":"r","error":{"code":-32602,"message":"<any>","data":{"uri":"test://missing"}}}"#
            ))
    }

    @Test("Unknown method is -32601")
    func testUnknownMethod() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        let reply = try await wire.send(#"{"jsonrpc":"2.0","id":2,"method":"nope/nope","params":{}}"#)
        expectWire(reply[0], matches: try wireJSON(#"{"id":2,"error":{"code":-32601}}"#))
    }

    @Test("Request _meta reaches typed parameters unchanged")
    func testMetaPassthrough() async throws {
        let server = await makeServer()
        let seen = MetaRecorder()
        await server.withMethodHandler(CallTool.self) { params in
            await seen.record(params._meta)
            return .init(content: [])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        try await wire.send(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"t","_meta":{"io.modelcontextprotocol/logLevel":"debug","progressToken":9}}}"#
        )
        let meta = try #require(await seen.meta)
        #expect(meta.logLevel == .debug)
        #expect(meta.progressToken == .integer(9))
    }

    @Test("A reply that never comes throws instead of returning fewer messages")
    func testSendTimeoutThrows() async throws {
        let wire = WireExchange(server: await makeServer())
        try await wire.start()
        defer { Task { await wire.stop() } }

        // A notification gets no reply.
        let error = await #expect(throws: WireExchange.Timeout.self) {
            try await wire.send(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                timeout: .milliseconds(100))
        }
        #expect(error?.expected == 1)
        #expect(error?.received == 0)
    }
}

@Suite("Data URL String Tests")
struct DataURLStringTests {
    /// The last message the server sent, parsed without turning `data:` URLs into data.
    private func lastSent(_ wire: WireExchange) async throws -> Any {
        let data = try #require(await wire.transport.sentData.last)
        return try JSONSerialization.jsonObject(with: data)
    }

    @Test("A typed string that is a data: URL reaches the handler and the peer as written")
    func testServerKeepsDataURLStrings() async throws {
        let server = Server(
            name: "s", version: "1", capabilities: .init(resources: .init(), tools: .init()))
        let seen = StringRecorder()
        await server.withMethodHandler(ReadResource.self) { params in
            await seen.record(params.uri)
            return .init(contents: [.text("x", uri: params.uri)])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.text(text: "data:,hello")])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        try await wire.send(
            #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"data:,abc"}}"#)
        #expect(await seen.values == ["data:,abc"])

        try await wire.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"t"}}"#)
        let reply = try #require(try await lastSent(wire) as? [String: Any])
        let content = (reply["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "data:,hello")

        try await wire.send(
            #"[{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"data:,batch"}}]"#)
        #expect(await seen.values == ["data:,abc", "data:,batch"])
    }

    @Test("Value parameters still decode data: URLs as data for the handler")
    func testHandlerValueSemantics() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let seen = ValueRecorder()
        await server.withMethodHandler(CallTool.self) { params in
            await seen.record(params.arguments?["blob"])
            return .init(content: [])
        }
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }

        try await wire.send(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"t","arguments":{"blob":"data:,x"}}}"#
        )
        #expect(await seen.value == .data(mimeType: "text/plain", Data("x".utf8)))
    }

    @Test("The client reads a data: URL text block as sent")
    func testClientKeepsDataURLStrings() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [.text(text: "data:,hello")], structuredContent: .string("data:,hi"))
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1")
        defer { Task { await client.disconnect(); await server.stop() } }
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.send(CallTool.request(.init(name: "t"))).value
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("Expected a text block, got \(result.content)")
            return
        }
        #expect(text == "data:,hello")
        #expect(result.structuredContent == .data(mimeType: "text/plain", Data("hi".utf8)))
    }
}

private actor StringRecorder {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor ValueRecorder {
    var value: Value?
    func record(_ value: Value?) { self.value = value }
}

private actor MetaRecorder {
    var meta: Metadata?
    func record(_ meta: Metadata?) { self.meta = meta }
}
