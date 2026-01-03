import Logging
import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("Roots Tests")
struct RootsTests {
    @Test("Root encoding and decoding")
    func testRootCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let root = Root(
            uri: "file:///home/user/projects/myproject",
            name: "My Project"
        )

        let data = try encoder.encode(root)
        let decoded = try decoder.decode(Root.self, from: data)

        #expect(decoded.uri == "file:///home/user/projects/myproject")
        #expect(decoded.name == "My Project")
    }

    @Test("Root with metadata encoding and decoding")
    func testRootWithMetadataCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let root = Root(
            uri: "file:///workspace/repo",
            name: "Repository",
            _meta: ["version": "1.0", "type": "git"]
        )

        let data = try encoder.encode(root)
        let decoded = try decoder.decode(Root.self, from: data)

        #expect(decoded.uri == "file:///workspace/repo")
        #expect(decoded.name == "Repository")
        #expect(decoded._meta?["version"]?.stringValue == "1.0")
        #expect(decoded._meta?["type"]?.stringValue == "git")
    }

    @Test("Root without optional fields")
    func testRootWithoutOptionalFields() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let root = Root(uri: "file:///path/to/root")

        let data = try encoder.encode(root)
        let decoded = try decoder.decode(Root.self, from: data)

        #expect(decoded.uri == "file:///path/to/root")
        #expect(decoded.name == nil)
        #expect(decoded._meta == nil)
    }

    @Test("Root URI must start with file://")
    func testRootURIPrecondition() {
        // Valid URIs should work
        _ = Root(uri: "file:///valid/path")
        _ = Root(uri: "file:///")
        _ = Root(uri: "file:///C:/Users/test")

        // Note: Invalid URIs will cause a precondition failure,
        // which cannot be tested directly in Swift Testing.
        // The precondition is enforced at runtime.
    }

    @Test("Root decoding fails for invalid URI")
    func testRootDecodingFailsForInvalidURI() throws {
        let decoder = JSONDecoder()

        // http:// URI should fail
        let httpJSON = """
        {"uri": "http://example.com/path", "name": "Invalid"}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Root.self, from: httpJSON)
        }

        // https:// URI should fail
        let httpsJSON = """
        {"uri": "https://example.com/path", "name": "Invalid"}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Root.self, from: httpsJSON)
        }

        // No protocol should fail
        let noProtocolJSON = """
        {"uri": "/path/to/file", "name": "Invalid"}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Root.self, from: noProtocolJSON)
        }
    }

    @Test("Root Hashable conformance")
    func testRootHashable() {
        let root1 = Root(uri: "file:///path/a", name: "A")
        let root2 = Root(uri: "file:///path/a", name: "A")
        let root3 = Root(uri: "file:///path/b", name: "B")

        #expect(root1 == root2)
        #expect(root1 != root3)

        var set = Set<Root>()
        set.insert(root1)
        set.insert(root2)
        #expect(set.count == 1)
    }

    @Test("ListRoots request encoding")
    func testListRootsRequestEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let request = ListRoots.request(id: .number(1))

        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"method\":\"roots/list\""))
        #expect(json.contains("\"id\":1"))
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
    }

    @Test("ListRoots result encoding and decoding")
    func testListRootsResultCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let roots = [
            Root(uri: "file:///home/user/project1", name: "Project 1"),
            Root(uri: "file:///home/user/project2", name: "Project 2"),
        ]

        let result = ListRoots.Result(roots: roots)

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListRoots.Result.self, from: data)

        #expect(decoded.roots.count == 2)
        #expect(decoded.roots[0].uri == "file:///home/user/project1")
        #expect(decoded.roots[0].name == "Project 1")
        #expect(decoded.roots[1].uri == "file:///home/user/project2")
        #expect(decoded.roots[1].name == "Project 2")
    }

    @Test("ListRoots result with metadata")
    func testListRootsResultWithMetadata() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let result = ListRoots.Result(
            roots: [Root(uri: "file:///path")],
            _meta: ["cursor": "next-page-token"]
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListRoots.Result.self, from: data)

        #expect(decoded.roots.count == 1)
        #expect(decoded._meta?["cursor"]?.stringValue == "next-page-token")
    }

    @Test("ListRoots result empty roots")
    func testListRootsResultEmptyRoots() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let result = ListRoots.Result(roots: [])

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListRoots.Result.self, from: data)

        #expect(decoded.roots.isEmpty)
    }

    @Test("RootsListChangedNotification name")
    func testRootsListChangedNotificationName() {
        #expect(RootsListChangedNotification.name == "notifications/roots/list_changed")
    }

    @Test("RootsListChangedNotification encoding")
    func testRootsListChangedNotificationEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notification = RootsListChangedNotification.message(.init())

        let data = try encoder.encode(notification)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"method\":\"notifications/roots/list_changed\""))
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
    }

    @Test("Client capabilities include roots")
    func testClientCapabilitiesIncludeRoots() throws {
        let capabilities = Client.Capabilities(
            roots: .init(listChanged: true)
        )

        #expect(capabilities.roots != nil)
        #expect(capabilities.roots?.listChanged == true)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.roots != nil)
        #expect(decoded.roots?.listChanged == true)
    }

    @Test("Client capabilities roots without listChanged")
    func testClientCapabilitiesRootsWithoutListChanged() throws {
        let capabilities = Client.Capabilities(
            roots: .init()
        )

        #expect(capabilities.roots != nil)
        #expect(capabilities.roots?.listChanged == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.roots != nil)
        #expect(decoded.roots?.listChanged == nil)
    }

    @Test("Root requiredURIPrefix constant")
    func testRootRequiredURIPrefix() {
        #expect(Root.requiredURIPrefix == "file://")
    }

    @Test("Root JSON format matches MCP spec")
    func testRootJSONFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let root = Root(
            uri: "file:///home/user/projects/myproject",
            name: "My Project"
        )

        let data = try encoder.encode(root)
        let json = String(data: data, encoding: .utf8)!

        // Verify JSON structure matches MCP spec
        #expect(json.contains("\"uri\":\"file:///home/user/projects/myproject\""))
        #expect(json.contains("\"name\":\"My Project\""))
    }

    @Test("ListRoots result decodes from TypeScript SDK format")
    func testDecodesFromTypeScriptFormat() throws {
        let decoder = JSONDecoder()

        let json = """
        {
            "roots": [
                {
                    "uri": "file:///home/user/project",
                    "name": "My Project"
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(ListRoots.Result.self, from: json)

        #expect(result.roots.count == 1)
        #expect(result.roots[0].uri == "file:///home/user/project")
        #expect(result.roots[0].name == "My Project")
    }

    @Test("ListRoots result decodes from Python SDK format")
    func testDecodesFromPythonFormat() throws {
        let decoder = JSONDecoder()

        // Python SDK may include _meta
        let json = """
        {
            "roots": [
                {
                    "uri": "file:///users/fake/test",
                    "name": "Test Root 1"
                },
                {
                    "uri": "file:///users/fake/test/2",
                    "name": "Test Root 2"
                }
            ],
            "_meta": {}
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(ListRoots.Result.self, from: json)

        #expect(result.roots.count == 2)
        #expect(result.roots[0].uri == "file:///users/fake/test")
        #expect(result.roots[0].name == "Test Root 1")
        #expect(result.roots[1].uri == "file:///users/fake/test/2")
        #expect(result.roots[1].name == "Test Root 2")
    }
}

@Suite("Roots Integration Tests")
struct RootsIntegrationTests {
    @Test(
        .timeLimit(.minutes(1))
    )
    func testRootsCapabilitiesNegotiation() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.roots",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "RootsTestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Client with roots capability
        let client = Client(
            name: "RootsTestClient",
            version: "1.0"
        )
        await client.setCapabilities(.init(roots: .init(listChanged: true)))

        // Register roots handler (required since we declared the capability)
        await client.withRootsHandler {
            [Root(uri: "file:///test/path")]
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Verify roots capability is working by attempting to list roots
        // (if server couldn't see the capability, listRoots would throw)
        let roots = try await server.listRoots()
        #expect(roots.count == 1)
        #expect(roots[0].uri == "file:///test/path")

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testServerListRootsFromClient() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.roots.list",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "RootsTestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Client with roots capability and handler
        let expectedRoots = [
            Root(uri: "file:///home/user/project1", name: "Project 1"),
            Root(uri: "file:///home/user/project2", name: "Project 2"),
        ]

        let client = Client(
            name: "RootsTestClient",
            version: "1.0"
        )
        await client.setCapabilities(.init(roots: .init(listChanged: true)))
        await client.withRootsHandler {
            expectedRoots
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Server requests roots from client
        let roots = try await server.listRoots()

        #expect(roots.count == 2)
        #expect(roots[0].uri == "file:///home/user/project1")
        #expect(roots[0].name == "Project 1")
        #expect(roots[1].uri == "file:///home/user/project2")
        #expect(roots[1].name == "Project 2")

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testServerListRootsFailsWithoutCapability() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.roots.nocap",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "RootsTestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Client WITHOUT roots capability
        let client = Client(
            name: "RootsTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Server should fail to request roots since client doesn't have capability
        await #expect(throws: MCPError.self) {
            _ = try await server.listRoots()
        }

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testClientSendRootsChanged() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.roots.changed",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        // Use a continuation to wait for notification
        let notificationExpectation = AsyncStream.makeStream(of: Void.self)

        let server = Server(
            name: "RootsTestServer",
            version: "1.0.0",
            capabilities: .init()
        )
        await server.onNotification(RootsListChangedNotification.self) { _ in
            notificationExpectation.continuation.yield()
            notificationExpectation.continuation.finish()
        }

        // Client with roots.listChanged capability
        let client = Client(
            name: "RootsTestClient",
            version: "1.0"
        )
        await client.setCapabilities(.init(roots: .init(listChanged: true)))
        await client.withRootsHandler {
            [Root(uri: "file:///path")]
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Client sends roots changed notification
        try await client.sendRootsChanged()

        // Wait for notification to be processed (with timeout via test time limit)
        var notificationReceived = false
        for await _ in notificationExpectation.stream {
            notificationReceived = true
        }

        #expect(notificationReceived == true)

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testClientSendRootsChangedFailsWithoutCapability() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.roots.changed.nocap",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "RootsTestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Client WITH roots capability but WITHOUT listChanged
        let client = Client(
            name: "RootsTestClient",
            version: "1.0"
        )
        await client.setCapabilities(.init(roots: .init()))  // No listChanged

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Client should fail to send roots changed notification
        await #expect(throws: MCPError.self) {
            try await client.sendRootsChanged()
        }

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }
}
