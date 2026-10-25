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
}

private actor MetaRecorder {
    var meta: Metadata?
    func record(_ meta: Metadata?) { self.meta = meta }
}
