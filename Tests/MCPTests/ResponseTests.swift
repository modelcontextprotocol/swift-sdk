import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Response Tests")
struct ResponseTests {
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

    @Test("Success response initialization and encoding")
    func testSuccessResponse() throws {
        let id: RequestId = "test-id"
        let result = TestMethod.Result(success: true)
        let response = Response<TestMethod>(id: id, result: result)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case .success(let decodedResult) = decoded.result {
            #expect(decodedResult.success == true)
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }

    @Test("Error response initialization and encoding")
    func testErrorResponse() throws {
        let id: RequestId = "test-id"
        let error = MCPError.parseError(nil)
        let response = Response<TestMethod>(id: id, error: error)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case .failure(let decodedError) = decoded.result {
            #expect(decodedError.code == ErrorCode.parseError)
            // Roundtrip preserves the error: parseError(nil) encodes as "Invalid JSON",
            // which decodes back to parseError(nil) since it matches the default message
            #expect(decodedError.localizedDescription == "Parse error: Invalid JSON")
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }

    @Test("Error response with detail")
    func testErrorResponseWithDetail() throws {
        let id: RequestId = "test-id"
        let error = MCPError.parseError("Invalid syntax")
        let response = Response<TestMethod>(id: id, error: error)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case .failure(let decodedError) = decoded.result {
            #expect(decodedError.code == ErrorCode.parseError)
            #expect(
                decodedError.localizedDescription
                    == "Parse error: Invalid JSON: Invalid syntax")
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }

    @Test("Empty result response encoding")
    func testEmptyResultResponseEncoding() throws {
        let response = EmptyMethod.response(id: "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)

        // Verify we can decode it back
        let decoded = try decoder.decode(Response<EmptyMethod>.self, from: data)
        #expect(decoded.id == response.id)
    }

    @Test("Empty result response decoding")
    func testEmptyResultResponseDecoding() throws {
        // Create a minimal JSON string
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","result":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Response<EmptyMethod>.self, from: data)

        #expect(decoded.id == "test-id")
        if case .success = decoded.result {
            // Success
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }
}
