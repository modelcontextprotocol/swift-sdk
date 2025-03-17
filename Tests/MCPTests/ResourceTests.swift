import Foundation
import Testing

@testable import MCP

@Suite("Resource Tests")
struct ResourceTests {
    @Test("Resource initialization with valid parameters")
    func testResourceInitialization() throws {
        let resource = Resource(
            name: "test_resource",
            uri: "file://test.txt",
            description: "A test resource",
            mimeType: "text/plain",
            metadata: ["key": "value"]
        )

        #expect(resource.name == "test_resource")
        #expect(resource.uri == "file://test.txt")
        #expect(resource.description == "A test resource")
        #expect(resource.mimeType == "text/plain")
        #expect(resource.metadata?["key"] == "value")
    }

    @Test("Resource encoding and decoding")
    func testResourceEncodingDecoding() throws {
        let resource = Resource(
            name: "test_resource",
            uri: "file://test.txt",
            description: "Test resource description",
            mimeType: "text/plain",
            metadata: ["key1": "value1", "key2": "value2"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(resource)
        let decoded = try decoder.decode(Resource.self, from: data)

        #expect(decoded.name == resource.name)
        #expect(decoded.uri == resource.uri)
        #expect(decoded.description == resource.description)
        #expect(decoded.mimeType == resource.mimeType)
        #expect(decoded.metadata == resource.metadata)
    }

    @Test("Resource.Content text initialization and encoding")
    func testResourceContentTextEncoding() throws {
        let content = Resource.Content.text(
            "Hello, world!", uri: "file://test.txt", mimeType: "text/plain")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Resource.Content.self, from: data)

        #expect(decoded.uri == "file://test.txt")
        #expect(decoded.mimeType == "text/plain")
        #expect(decoded.text == "Hello, world!")
        #expect(decoded.blob == nil)
    }

    @Test("Resource.Content binary initialization and encoding")
    func testResourceContentBinaryEncoding() throws {
        let binaryData = "Test binary data".data(using: .utf8)!
        let content = Resource.Content.binary(
            binaryData, uri: "file://test.bin", mimeType: "application/octet-stream")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Resource.Content.self, from: data)

        #expect(decoded.uri == "file://test.bin")
        #expect(decoded.mimeType == "application/octet-stream")
        #expect(decoded.text == nil)
        #expect(decoded.blob == binaryData.base64EncodedString())
    }

    @Test("ListResources parameters validation")
    func testListResourcesParameters() throws {
        let params = ListResources.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListResources.Parameters()
        #expect(emptyParams.cursor == nil)
    }
    
    @Test("ListResources request decoding with omitted params")
    func testListResourcesRequestDecodingWithOmittedParams() throws {
        // Test decoding when params field is omitted
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"resources/list"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListResources>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListResources.name)
    }
    
    @Test("ListResources request decoding with null params")
    func testListResourcesRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"resources/list","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListResources>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListResources.name)
    }

    @Test("ListResources result validation")
    func testListResourcesResult() throws {
        let resources = [
            Resource(name: "resource1", uri: "file://test1.txt"),
            Resource(name: "resource2", uri: "file://test2.txt"),
        ]

        let result = ListResources.Result(resources: resources, nextCursor: "next_page")
        #expect(result.resources.count == 2)
        #expect(result.resources[0].name == "resource1")
        #expect(result.resources[1].name == "resource2")
        #expect(result.nextCursor == "next_page")
    }

    @Test("ReadResource parameters validation")
    func testReadResourceParameters() throws {
        let params = ReadResource.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
    }

    @Test("ReadResource result validation")
    func testReadResourceResult() throws {
        let contents = [
            Resource.Content.text("Content 1", uri: "file://test1.txt"),
            Resource.Content.text("Content 2", uri: "file://test2.txt"),
        ]

        let result = ReadResource.Result(contents: contents)
        #expect(result.contents.count == 2)
    }

    @Test("ResourceSubscribe parameters validation")
    func testResourceSubscribeParameters() throws {
        let params = ResourceSubscribe.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
    }

    @Test("ResourceUpdatedNotification parameters validation")
    func testResourceUpdatedNotification() throws {
        let params = ResourceUpdatedNotification.Parameters(uri: "file://test.txt")
        #expect(params.uri == "file://test.txt")
        #expect(ResourceUpdatedNotification.name == "notifications/resources/updated")
    }

    @Test("ResourceListChangedNotification name validation")
    func testResourceListChangedNotification() throws {
        #expect(ResourceListChangedNotification.name == "notifications/resources/list_changed")
    }
}
