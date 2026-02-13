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

    @Test("Server capability check validates client capabilities")
    func testServerCapabilityCheckValidatesClientCapabilities() async throws {
        let server = Server(
            name: "test-server",
            version: "1.0.0",
            configuration: .strict
        )

        // Server not initialized yet, should throw
        await #expect(throws: (any Error).self) {
            try await server.listRoots()
        }
    }

    @Test("Server Capabilities struct validation")
    func testServerCapabilitiesStruct() throws {
        // Test that Server.Capabilities exists and can be used
        let capabilities = Server.Capabilities(
            prompts: .init(listChanged: true),
            resources: .init(listChanged: true),
            tools: .init(listChanged: true)
        )

        #expect(capabilities.resources?.listChanged == true)
        #expect(capabilities.tools?.listChanged == true)
        #expect(capabilities.prompts?.listChanged == true)
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
}
