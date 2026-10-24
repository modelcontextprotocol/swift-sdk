import Foundation
import Testing

@testable import MCP

@Suite("Roots Tests")
struct RootsTests {
    @Test("Root initialization with file:// URI")
    func testRootInitialization() throws {
        let root = Root(uri: "file:///workspace", name: "Workspace")

        #expect(root.uri == "file:///workspace")
        #expect(root.name == "Workspace")
    }

    @Test("Root initialization without name")
    func testRootInitializationWithoutName() throws {
        let root = Root(uri: "file:///home/user/docs")

        #expect(root.uri == "file:///home/user/docs")
        #expect(root.name == nil)
    }

    @Test("Root encoding and decoding")
    func testRootEncodingDecoding() throws {
        let root = Root(uri: "file:///workspace", name: "Workspace")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(root)
        let decoded = try decoder.decode(Root.self, from: data)

        #expect(decoded.uri == root.uri)
        #expect(decoded.name == root.name)
    }

    @Test("Root encoding and decoding without name")
    func testRootEncodingDecodingWithoutName() throws {
        let root = Root(uri: "file:///home/user/docs")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(root)
        let decoded = try decoder.decode(Root.self, from: data)

        #expect(decoded.uri == root.uri)
        #expect(decoded.name == nil)
    }

    @Test("Root JSON encoding format")
    func testRootJSONFormat() throws {
        let root = Root(uri: "file:///workspace", name: "Workspace")

        let encoder = JSONEncoder()
        let data = try encoder.encode(root)
        let jsonString = String(data: data, encoding: .utf8)

        #expect(jsonString?.contains("\"uri\"") == true)
        #expect(jsonString?.contains("\"name\"") == true)
        // The URI might be escaped differently, so just check it's present
        #expect(jsonString?.contains("workspace") == true)
        #expect(jsonString?.contains("Workspace") == true)
    }

    @Test("ListRoots method name")
    func testListRootsMethodName() throws {
        #expect(ListRoots.name == "roots/list")
    }

    @Test("ListRoots request creation")
    func testListRootsRequestCreation() throws {
        let request = ListRoots.request()

        #expect(request.method == "roots/list")
        #expect(request.params == Empty())
    }

    @Test("ListRoots request decoding with omitted params")
    func testListRootsRequestDecodingWithOmittedParams() throws {
        // Test decoding when params field is omitted
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"roots/list"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListRoots>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListRoots.name)
    }

    @Test("ListRoots request decoding with null params")
    func testListRootsRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"roots/list","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListRoots>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListRoots.name)
    }

    @Test("ListRoots result validation")
    func testListRootsResult() throws {
        let roots = [
            Root(uri: "file:///workspace", name: "Workspace"),
            Root(uri: "file:///home/user/docs", name: "Documents"),
        ]

        let result = ListRoots.Result(roots: roots)
        #expect(result.roots.count == 2)
        #expect(result.roots[0].uri == "file:///workspace")
        #expect(result.roots[0].name == "Workspace")
        #expect(result.roots[1].uri == "file:///home/user/docs")
        #expect(result.roots[1].name == "Documents")
    }

    @Test("ListRoots result encoding and decoding")
    func testListRootsResultEncodingDecoding() throws {
        let roots = [
            Root(uri: "file:///workspace", name: "Workspace"),
            Root(uri: "file:///home/user/docs"),
        ]
        let result = ListRoots.Result(roots: roots)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListRoots.Result.self, from: data)

        #expect(decoded.roots.count == result.roots.count)
        #expect(decoded.roots[0].uri == result.roots[0].uri)
        #expect(decoded.roots[0].name == result.roots[0].name)
        #expect(decoded.roots[1].uri == result.roots[1].uri)
        #expect(decoded.roots[1].name == result.roots[1].name)
    }

    @Test("ListRoots response format")
    func testListRootsResponseFormat() throws {
        let response = ListRoots.response(
            id: "test-id",
            result: ListRoots.Result(
                roots: [
                    Root(uri: "file:///workspace", name: "Workspace")
                ]
            )
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        let jsonString = String(data: data, encoding: .utf8)

        #expect(jsonString?.contains("\"jsonrpc\"") == true)
        #expect(jsonString?.contains("\"2.0\"") == true)
        #expect(jsonString?.contains("\"id\"") == true)
        #expect(jsonString?.contains("\"result\"") == true)
        #expect(jsonString?.contains("\"roots\"") == true)
    }

    @Test("RootsListChangedNotification name")
    func testRootsListChangedNotificationName() throws {
        #expect(RootsListChangedNotification.name == "notifications/roots/list_changed")
    }

    @Test("RootsListChangedNotification message creation")
    func testRootsListChangedNotificationMessage() throws {
        let notification = RootsListChangedNotification.message()

        #expect(notification.method == "notifications/roots/list_changed")
        #expect(notification.params == Empty())
    }

    @Test("RootsListChangedNotification encoding")
    func testRootsListChangedNotificationEncoding() throws {
        let notification = RootsListChangedNotification.message()

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)
        let jsonString = String(data: data, encoding: .utf8)

        #expect(jsonString?.contains("\"jsonrpc\"") == true)
        #expect(jsonString?.contains("\"2.0\"") == true)
        #expect(jsonString?.contains("\"method\"") == true)
        // The method name might be escaped differently, so check key parts
        #expect(jsonString?.contains("roots") == true)
        #expect(jsonString?.contains("list_changed") == true)
    }

    @Test("Client.Capabilities.Roots initialization")
    func testClientCapabilitiesRoots() throws {
        let roots = Client.Capabilities.Roots(listChanged: true)

        #expect(roots.listChanged == true)
    }

    @Test("Client.Capabilities.Roots optional listChanged")
    func testClientCapabilitiesRootsOptional() throws {
        let roots = Client.Capabilities.Roots()

        #expect(roots.listChanged == nil)
    }

    @Test("Client.Capabilities with roots")
    func testClientCapabilitiesWithRoots() throws {
        let capabilities = Client.Capabilities(
            roots: Client.Capabilities.Roots(listChanged: true)
        )

        #expect(capabilities.roots?.listChanged == true)
    }

    @Test("Root hashable conformance")
    func testRootHashable() throws {
        let root1 = Root(uri: "file:///workspace", name: "Workspace")
        let root2 = Root(uri: "file:///workspace", name: "Workspace")
        let root3 = Root(uri: "file:///other", name: "Other")

        #expect(root1 == root2)
        #expect(root1 != root3)

        // Test in a Set
        let set: Set<Root> = [root1, root2, root3]
        #expect(set.count == 2)  // root1 and root2 should be the same
    }

    @Test("Client Capabilities struct with roots encoding")
    func testClientCapabilitiesWithRootsEncoding() throws {
        let capabilities = Client.Capabilities(
            roots: Client.Capabilities.Roots(listChanged: true)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.roots?.listChanged == true)
    }

    // MARK: - Integration Tests

    @Test("Server listRoots with client that has roots capability")
    func testServerListRootsWithCapableClient() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            configuration: .strict
        )

        let testRoots = [
            Root(uri: "file:///workspace", name: "Workspace"),
            Root(uri: "file:///home/user/docs", name: "Documents"),
        ]

        let client = Client(
            name: "test-client",
            version: "1.0.0",
            capabilities: Client.Capabilities(
                roots: Client.Capabilities.Roots(listChanged: true)
            )
        )

        await client.withRootsHandler {
            return testRoots
        }

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Wait for initialization to complete
        try await Task.sleep(for: .milliseconds(100))

        // Server requests roots from client - should succeed
        let roots = try await server.listRoots()

        #expect(roots == testRoots)

        // Cleanup
        await server.stop()
        await client.disconnect()
    }

    @Test("Server listRoots fails when client lacks roots capability (strict mode)")
    func testServerListRootsFailsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            configuration: .strict
        )

        // Client has NO roots capability (default empty capabilities)
        let client = Client(
            name: "test-client",
            version: "1.0.0"
        )

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Wait for initialization to complete
        try await Task.sleep(for: .milliseconds(100))

        // Server tries to request roots - should fail
        await #expect(throws: MCPError.self) {
            try await server.listRoots()
        }

        // Cleanup
        await server.stop()
        await client.disconnect()
    }

    @Test("Server listRoots succeeds when client lacks capability (non-strict mode)")
    func testServerListRootsNonStrictMode() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            configuration: .default  // Non-strict mode
        )

        let testRoots = [Root(uri: "file:///workspace")]

        // Client has NO roots capability but registers handler anyway
        let client = Client(
            name: "test-client",
            version: "1.0.0"
        )

        await client.withRootsHandler {
            return testRoots
        }

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Wait for initialization to complete
        try await Task.sleep(for: .milliseconds(100))

        // Server requests roots - should succeed in non-strict mode
        let roots = try await server.listRoots()
        #expect(roots == testRoots)

        // Cleanup
        await server.stop()
        await client.disconnect()
    }

    @Test("Client sends roots list changed notification")
    func testClientSendsRootsListChangedNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0"
        )

        let client = Client(
            name: "test-client",
            version: "1.0.0",
            capabilities: Client.Capabilities(
                roots: Client.Capabilities.Roots(listChanged: true)
            )
        )

        // Register notification handler on server
        nonisolated(unsafe) var didReceive = false
        await server.onNotification(RootsListChangedNotification.self) { _ in
            didReceive = true
        }

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Wait for initialization
        try await Task.sleep(for: .milliseconds(100))

        // Client sends notification
        try await client.notifyRootsChanged()

        // Wait for notification to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify notification was received
        #expect(didReceive)

        // Cleanup
        await server.stop()
        await client.disconnect()
    }

    @Test("Server listRoots fails when client has no handler registered")
    func testServerListRootsFailsWithoutHandler() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0",
            configuration: .default
        )

        let client = Client(
            name: "test-client",
            version: "1.0.0",
            capabilities: Client.Capabilities(
                roots: Client.Capabilities.Roots(listChanged: true)
            )
        )

        // NO handler registered on client

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Wait for initialization
        try await Task.sleep(for: .milliseconds(100))

        // Server requests roots - should fail with method not found
        await #expect(throws: MCPError.self) {
            try await server.listRoots()
        }

        // Cleanup
        await server.stop()
        await client.disconnect()
    }

    @Test("Multiple roots requests work correctly")
    func testMultipleRootsRequests() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0.0"
        )

        nonisolated(unsafe) var count = 0

        let client = Client(
            name: "test-client",
            version: "1.0.0",
            capabilities: Client.Capabilities(
                roots: Client.Capabilities.Roots(listChanged: true)
            )
        )

        await client.withRootsHandler {
            count += 1
            return [Root(uri: "file:///workspace\(count)")]
        }

        // Start server and client
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        try await Task.sleep(for: .milliseconds(100))

        // Make multiple requests
        let roots1 = try await server.listRoots()
        #expect(roots1.count == 1)
        #expect(roots1[0].uri == "file:///workspace1")

        let roots2 = try await server.listRoots()
        #expect(roots2.count == 1)
        #expect(roots2[0].uri == "file:///workspace2")

        let roots3 = try await server.listRoots()
        #expect(roots3.count == 1)
        #expect(roots3[0].uri == "file:///workspace3")

        // Cleanup
        await server.stop()
        await client.disconnect()
    }
}
