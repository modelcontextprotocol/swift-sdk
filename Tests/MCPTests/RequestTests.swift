import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Request Tests")
struct RequestTests {
    struct TestMethod: Method {
        struct Parameters: Codable, Hashable, Sendable {
            let value: String
        }
        struct Result: Codable, Hashable, Sendable {
            let success: Bool
        }
        static let name = "test.method"
    }

    struct EmptyMethod: Method {
        static let name = "empty.method"
    }

    @Test("Request initialization with parameters")
    func testRequestInitialization() throws {
        let id: ID = "test-id"
        let params = TestMethod.Parameters(value: "test")
        let request = Request<TestMethod>(id: id, method: TestMethod.name, params: params)

        #expect(request.id == id)
        #expect(request.method == TestMethod.name)
        #expect(request.params.value == "test")
    }

    @Test("Request encoding and decoding")
    func testRequestEncodingDecoding() throws {
        let request = TestMethod.request(id: "test-id", TestMethod.Parameters(value: "test"))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(Request<TestMethod>.self, from: data)

        #expect(decoded.id == request.id)
        #expect(decoded.method == request.method)
        #expect(decoded.params.value == request.params.value)
    }

    @Test("Empty parameters request encoding")
    func testEmptyParametersRequestEncoding() throws {
        let request = EmptyMethod.request(id: "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)

        // Verify we can decode it back
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.method == request.method)
    }

    @Test("Empty parameters request decoding")
    func testEmptyParametersRequestDecoding() throws {
        // Create a minimal JSON string
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"empty.method"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test("NotRequired parameters request decoding - with params")
    func testNotRequiredParametersRequestDecodingWithParams() throws {
        // Test decoding when params field is present
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"ping","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == Ping.name)
    }

    @Test("NotRequired parameters request decoding - without params")
    func testNotRequiredParametersRequestDecodingWithoutParams() throws {
        // Test decoding when params field is missing
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"ping"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == Ping.name)
    }

    @Test("NotRequired parameters request decoding - with null params")
    func testNotRequiredParametersRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"ping","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == Ping.name)
    }
}
