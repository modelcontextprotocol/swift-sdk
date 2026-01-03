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
        let id: RequestId = 1
        let params = CallTool.Parameters(name: "test-tool")
        let request = Request<CallTool>(id: id, method: CallTool.name, params: params)

        #expect(request.id == id)
        #expect(request.method == CallTool.name)
        #expect(request.params.name == "test-tool")
    }

    @Test("Request encoding and decoding")
    func testRequestEncodingDecoding() throws {
        let request = CallTool.request(id: 1, CallTool.Parameters(name: "test-tool"))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(Request<CallTool>.self, from: data)

        #expect(decoded.id == request.id)
        #expect(decoded.method == request.method)
        #expect(decoded.params.name == request.params.name)
    }

    @Test("Empty parameters request encoding")
    func testEmptyParametersRequestEncoding() throws {
        let request = EmptyMethod.request(id: 1)

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
            {"jsonrpc":"2.0","id":1,"method":"empty.method"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test("NotRequired parameters request decoding - with params")
    func testNotRequiredParametersRequestDecodingWithParams() throws {
        // Test decoding when params field is present
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test("NotRequired parameters request decoding - without params")
    func testNotRequiredParametersRequestDecodingWithoutParams() throws {
        // Test decoding when params field is missing
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test("NotRequired parameters request decoding - with null params")
    func testNotRequiredParametersRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test("Required parameters request decoding - missing params")
    func testRequiredParametersRequestDecodingMissingParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test("Required parameters request decoding - null params")
    func testRequiredParametersRequestDecodingNullParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test("Empty parameters request decoding - with null params")
    func testEmptyParametersRequestDecodingNullParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"empty.method","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test("Empty parameters request decoding - with empty object params")
    func testEmptyParametersRequestDecodingEmptyParams() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"empty.method","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test("Initialize request decoding - requires params")
    func testInitializeRequestDecodingRequiresParams() throws {
        // Test missing params field
        let missingParams = """
            {"jsonrpc":"2.0","id":"test-id","method":"initialize"}
            """
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                Request<Initialize>.self, from: missingParams.data(using: .utf8)!)
        }

        // Test null params
        let nullParams = """
            {"jsonrpc":"2.0","id":"test-id","method":"initialize","params":null}
            """
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<Initialize>.self, from: nullParams.data(using: .utf8)!)
        }

        // Verify that empty object params works (since fields have defaults)
        let emptyParams = """
            {"jsonrpc":"2.0","id":"test-id","method":"initialize","params":{}}
            """
        let decoded = try decoder.decode(
            Request<Initialize>.self, from: emptyParams.data(using: .utf8)!)
        #expect(decoded.params.protocolVersion == Version.latest)
        #expect(decoded.params.clientInfo.name == "unknown")
    }

    @Test("Invalid parameters request decoding")
    func testInvalidParametersRequestDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"invalid":"value"}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test("NotRequired parameters request decoding")
    func testNotRequiredParametersRequestDecoding() throws {
        // Test with missing params
        let missingParams = """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        let decoder = JSONDecoder()
        let decodedMissing = try decoder.decode(
            Request<ListTools>.self,
            from: missingParams.data(using: .utf8)!)
        #expect(decodedMissing.id == 1)
        #expect(decodedMissing.method == ListTools.name)
        #expect(decodedMissing.params.cursor == nil)

        // Test with null params
        let nullParams = """
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}
            """
        let decodedNull = try decoder.decode(
            Request<ListTools>.self,
            from: nullParams.data(using: .utf8)!)
        #expect(decodedNull.params.cursor == nil)

        // Test with empty object params
        let emptyParams = """
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
            """
        let decodedEmpty = try decoder.decode(
            Request<ListTools>.self,
            from: emptyParams.data(using: .utf8)!)
        #expect(decodedEmpty.params.cursor == nil)

        // Test with provided cursor
        let withCursor = """
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"next-page"}}
            """
        let decodedWithCursor = try decoder.decode(
            Request<ListTools>.self,
            from: withCursor.data(using: .utf8)!)
        #expect(decodedWithCursor.params.cursor == "next-page")
    }

    @Test("AnyRequest parameters request decoding - without params")
    func testAnyRequestParametersRequestDecodingWithoutParams() throws {
        // Test decoding when params field is missing
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyRequest.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test("AnyRequest parameters request decoding - with null params")
    func testAnyRequestParametersRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }
    
    @Test("AnyRequest parameters request decoding - with empty params")
    func testAnyRequestParametersRequestDecodingWithEmptyParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }
}
