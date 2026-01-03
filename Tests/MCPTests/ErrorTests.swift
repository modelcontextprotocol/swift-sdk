import Foundation
import Testing

@testable import MCP

@Suite("MCPError Roundtrip Tests")
struct MCPErrorRoundtripTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // MARK: - Standard JSON-RPC Errors

    @Test("parseError roundtrip with nil detail")
    func testParseErrorNilRoundtrip() throws {
        let original = MCPError.parseError(nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.parseError)
        #expect(decoded.message == "Invalid JSON")
    }

    @Test("parseError roundtrip with custom detail")
    func testParseErrorDetailRoundtrip() throws {
        let original = MCPError.parseError("Unexpected token at position 5")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "Unexpected token at position 5")
    }

    @Test("invalidRequest roundtrip with nil detail")
    func testInvalidRequestNilRoundtrip() throws {
        let original = MCPError.invalidRequest(nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.invalidRequest)
    }

    @Test("invalidRequest roundtrip with custom detail")
    func testInvalidRequestDetailRoundtrip() throws {
        let original = MCPError.invalidRequest("Missing id field")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "Missing id field")
    }

    @Test("methodNotFound roundtrip with nil detail")
    func testMethodNotFoundNilRoundtrip() throws {
        let original = MCPError.methodNotFound(nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.methodNotFound)
    }

    @Test("methodNotFound roundtrip with custom detail")
    func testMethodNotFoundDetailRoundtrip() throws {
        let original = MCPError.methodNotFound("tools/call")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "tools/call")
    }

    @Test("invalidParams roundtrip with nil detail")
    func testInvalidParamsNilRoundtrip() throws {
        let original = MCPError.invalidParams(nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.invalidParams)
    }

    @Test("invalidParams roundtrip with custom detail")
    func testInvalidParamsDetailRoundtrip() throws {
        let original = MCPError.invalidParams("name is required")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "name is required")
    }

    @Test("internalError roundtrip with nil detail")
    func testInternalErrorNilRoundtrip() throws {
        let original = MCPError.internalError(nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.internalError)
    }

    @Test("internalError roundtrip with custom detail")
    func testInternalErrorDetailRoundtrip() throws {
        let original = MCPError.internalError("Database connection failed")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "Database connection failed")
    }

    // MARK: - MCP-Specific Errors

    @Test("resourceNotFound roundtrip with nil URI")
    func testResourceNotFoundNilRoundtrip() throws {
        let original = MCPError.resourceNotFound(uri: nil)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.resourceNotFound)
        #expect(decoded.data == nil)
    }

    @Test("resourceNotFound roundtrip with URI")
    func testResourceNotFoundUriRoundtrip() throws {
        let original = MCPError.resourceNotFound(uri: "file:///path/to/file.txt")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.message == "Resource not found: file:///path/to/file.txt")
        #expect(decoded.data == .object(["uri": .string("file:///path/to/file.txt")]))
    }

    @Test("urlElicitationRequired roundtrip")
    func testUrlElicitationRequiredRoundtrip() throws {
        let elicitations = [
            ElicitRequestURLParams(
                message: "Please authorize",
                elicitationId: "auth-123",
                url: "https://example.com/oauth"
            )
        ]
        let original = MCPError.urlElicitationRequired(
            message: "Authorization required",
            elicitations: elicitations
        )
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.urlElicitationRequired)
        #expect(decoded.elicitations?.count == 1)
        #expect(decoded.elicitations?[0].elicitationId == "auth-123")
    }

    // MARK: - Server Errors

    @Test("serverError roundtrip")
    func testServerErrorRoundtrip() throws {
        let original = MCPError.serverError(code: -32050, message: "Custom server error")
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == -32050)
        #expect(decoded.message == "Custom server error")
    }

    @Test("serverErrorWithData roundtrip")
    func testServerErrorWithDataRoundtrip() throws {
        let data: Value = .object(["detail": .string("Extra info"), "count": .int(42)])
        let original = MCPError.serverErrorWithData(code: -32051, message: "Error with data", data: data)
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == -32051)
        #expect(decoded.data == data)
    }

    // MARK: - SDK-Specific Errors

    @Test("connectionClosed roundtrip")
    func testConnectionClosedRoundtrip() throws {
        let original = MCPError.connectionClosed
        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.code == ErrorCode.connectionClosed)
    }

    @Test("requestTimeout roundtrip")
    func testRequestTimeoutRoundtrip() throws {
        let original = MCPError.requestTimeout(timeout: .seconds(30), message: nil)
        let decoded = try roundtrip(original)
        #expect(decoded.code == ErrorCode.requestTimeout)
        // Note: Duration precision may not be exact due to ms conversion
    }

    @Test("requestTimeout roundtrip with message")
    func testRequestTimeoutMessageRoundtrip() throws {
        let original = MCPError.requestTimeout(timeout: .seconds(60), message: "Server unresponsive")
        let decoded = try roundtrip(original)
        #expect(decoded.code == ErrorCode.requestTimeout)
        #expect(decoded.message == "Server unresponsive")
    }

    @Test("requestCancelled roundtrip")
    func testRequestCancelledRoundtrip() throws {
        let original = MCPError.requestCancelled(reason: nil)
        let decoded = try roundtrip(original)
        #expect(decoded.code == ErrorCode.requestCancelled)
        #expect(decoded.message == "Request cancelled")
    }

    @Test("requestCancelled roundtrip with reason")
    func testRequestCancelledWithReasonRoundtrip() throws {
        let original = MCPError.requestCancelled(reason: "User cancelled the operation")
        let decoded = try roundtrip(original)
        #expect(decoded.code == ErrorCode.requestCancelled)
        #expect(decoded.message == "User cancelled the operation")
        if case .requestCancelled(let reason) = decoded {
            #expect(reason == "User cancelled the operation")
        } else {
            Issue.record("Expected requestCancelled")
        }
    }

    // MARK: - Helpers

    private func roundtrip(_ error: MCPError) throws -> MCPError {
        let data = try encoder.encode(error)
        return try decoder.decode(MCPError.self, from: data)
    }
}

@Suite("MCPError Message and Data Properties Tests")
struct MCPErrorPropertyTests {
    @Test("message property returns raw message for wire format")
    func testMessageProperty() {
        #expect(MCPError.parseError(nil).message == "Invalid JSON")
        #expect(MCPError.parseError("custom").message == "custom")
        #expect(MCPError.invalidRequest(nil).message == "Invalid Request")
        #expect(MCPError.methodNotFound(nil).message == "Method not found")
        #expect(MCPError.invalidParams(nil).message == "Invalid params")
        #expect(MCPError.internalError(nil).message == "Internal error")
        #expect(MCPError.resourceNotFound(uri: nil).message == "Resource not found")
        #expect(MCPError.resourceNotFound(uri: "test://uri").message == "Resource not found: test://uri")
        #expect(MCPError.connectionClosed.message == "Connection closed")
        #expect(MCPError.serverError(code: -32050, message: "Custom").message == "Custom")
    }

    @Test("data property returns correct payload for wire format")
    func testDataProperty() {
        // Standard errors have no data
        #expect(MCPError.parseError(nil).data == nil)
        #expect(MCPError.invalidRequest("detail").data == nil)

        // Resource not found with URI includes URI in data
        #expect(MCPError.resourceNotFound(uri: nil).data == nil)
        let resourceData = MCPError.resourceNotFound(uri: "test://uri").data
        #expect(resourceData == .object(["uri": .string("test://uri")]))

        // Server error with data includes the data
        let customData: Value = .object(["key": .string("value")])
        #expect(MCPError.serverErrorWithData(code: -32050, message: "msg", data: customData).data == customData)
        #expect(MCPError.serverError(code: -32050, message: "msg").data == nil)
    }

    @Test("code property returns correct error codes")
    func testCodeProperty() {
        #expect(MCPError.parseError(nil).code == ErrorCode.parseError)
        #expect(MCPError.invalidRequest(nil).code == ErrorCode.invalidRequest)
        #expect(MCPError.methodNotFound(nil).code == ErrorCode.methodNotFound)
        #expect(MCPError.invalidParams(nil).code == ErrorCode.invalidParams)
        #expect(MCPError.internalError(nil).code == ErrorCode.internalError)
        #expect(MCPError.resourceNotFound(uri: nil).code == ErrorCode.resourceNotFound)
        #expect(MCPError.urlElicitationRequired(message: "", elicitations: []).code == ErrorCode.urlElicitationRequired)
        #expect(MCPError.connectionClosed.code == ErrorCode.connectionClosed)
        #expect(MCPError.requestTimeout(timeout: .seconds(1), message: nil).code == ErrorCode.requestTimeout)
        #expect(MCPError.transportError(NSError(domain: "", code: 0)).code == ErrorCode.transportError)
        #expect(MCPError.requestCancelled(reason: nil).code == ErrorCode.requestCancelled)
        // Custom server error codes (no constants defined - these are arbitrary test values)
        #expect(MCPError.serverError(code: -32050, message: "").code == -32050)
        #expect(MCPError.serverErrorWithData(code: -32051, message: "", data: .null).code == -32051)
    }
}

@Suite("MCPError fromError Factory Tests")
struct MCPErrorFromErrorTests {
    @Test("fromError reconstructs standard errors")
    func testFromErrorStandardErrors() {
        let parseError = MCPError.fromError(code: ErrorCode.parseError, message: "Invalid JSON")
        #expect(parseError == .parseError(nil))

        let parseErrorCustom = MCPError.fromError(code: ErrorCode.parseError, message: "Custom parse error")
        #expect(parseErrorCustom == .parseError("Custom parse error"))

        let invalidRequest = MCPError.fromError(code: ErrorCode.invalidRequest, message: "Invalid Request")
        #expect(invalidRequest == .invalidRequest(nil))

        let methodNotFound = MCPError.fromError(code: ErrorCode.methodNotFound, message: "Method not found")
        #expect(methodNotFound == .methodNotFound(nil))
    }

    @Test("fromError reconstructs resourceNotFound with URI from data")
    func testFromErrorResourceNotFound() {
        let withoutData = MCPError.fromError(code: ErrorCode.resourceNotFound, message: "Resource not found")
        if case .resourceNotFound(let uri) = withoutData {
            #expect(uri == nil)
        } else {
            Issue.record("Expected resourceNotFound")
        }

        let data: Value = .object(["uri": .string("file:///test.txt")])
        let withData = MCPError.fromError(code: ErrorCode.resourceNotFound, message: "Resource not found", data: data)
        if case .resourceNotFound(let uri) = withData {
            #expect(uri == "file:///test.txt")
        } else {
            Issue.record("Expected resourceNotFound with uri")
        }
    }

    @Test("fromError reconstructs urlElicitationRequired from data")
    func testFromErrorUrlElicitation() {
        let data: Value = .object([
            "elicitations": .array([
                .object([
                    "mode": .string("url"),
                    "elicitationId": .string("test-123"),
                    "url": .string("https://example.com"),
                    "message": .string("Authorize")
                ])
            ])
        ])
        let error = MCPError.fromError(code: ErrorCode.urlElicitationRequired, message: "Elicitation required", data: data)
        #expect(error.code == ErrorCode.urlElicitationRequired)
        #expect(error.elicitations?.count == 1)
        #expect(error.elicitations?[0].elicitationId == "test-123")
    }

    @Test("fromError falls back to serverError for unknown codes")
    func testFromErrorUnknownCode() {
        let error = MCPError.fromError(code: -32099, message: "Unknown error")
        if case .serverError(let code, let message) = error {
            #expect(code == -32099)
            #expect(message == "Unknown error")
        } else {
            Issue.record("Expected serverError")
        }
    }

    @Test("fromError preserves data for unknown codes")
    func testFromErrorUnknownCodeWithData() {
        let data: Value = .object(["extra": .string("info")])
        let error = MCPError.fromError(code: -32099, message: "Error with data", data: data)
        if case .serverErrorWithData(let code, let message, let errorData) = error {
            #expect(code == -32099)
            #expect(message == "Error with data")
            #expect(errorData == data)
        } else {
            Issue.record("Expected serverErrorWithData")
        }
    }

    @Test("fromError reconstructs requestCancelled")
    func testFromErrorRequestCancelled() {
        // Without reason
        let withoutReason = MCPError.fromError(code: ErrorCode.requestCancelled, message: "Request cancelled")
        if case .requestCancelled(let reason) = withoutReason {
            #expect(reason == nil)
        } else {
            Issue.record("Expected requestCancelled")
        }

        // With reason in message
        let withMessage = MCPError.fromError(code: ErrorCode.requestCancelled, message: "User cancelled")
        if case .requestCancelled(let reason) = withMessage {
            #expect(reason == "User cancelled")
        } else {
            Issue.record("Expected requestCancelled")
        }

        // With reason in data
        let data: Value = .object(["reason": .string("Operation aborted by user")])
        let withData = MCPError.fromError(code: ErrorCode.requestCancelled, message: "Request cancelled", data: data)
        if case .requestCancelled(let reason) = withData {
            #expect(reason == "Operation aborted by user")
        } else {
            Issue.record("Expected requestCancelled")
        }
    }
}

@Suite("MCPError Wire Format Tests")
struct MCPErrorWireFormatTests {
    let encoder = JSONEncoder()

    @Test("Standard errors encode without data field")
    func testStandardErrorsNoData() throws {
        let error = MCPError.parseError(nil)
        let data = try encoder.encode(error)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["code"] as? Int == ErrorCode.parseError)
        #expect(json["message"] as? String == "Invalid JSON")
        #expect(json["data"] == nil)
    }

    @Test("resourceNotFound encodes URI in data field")
    func testResourceNotFoundWireFormat() throws {
        let error = MCPError.resourceNotFound(uri: "file:///test.txt")
        let data = try encoder.encode(error)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["code"] as? Int == ErrorCode.resourceNotFound)
        #expect(json["message"] as? String == "Resource not found: file:///test.txt")
        let dataField = json["data"] as? [String: Any]
        #expect(dataField?["uri"] as? String == "file:///test.txt")
    }

    @Test("urlElicitationRequired encodes elicitations in data field")
    func testUrlElicitationWireFormat() throws {
        let error = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Auth",
                    elicitationId: "e1",
                    url: "https://auth.example.com"
                )
            ],
            message: "Authorization needed"
        )
        let data = try encoder.encode(error)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["code"] as? Int == ErrorCode.urlElicitationRequired)
        #expect(json["message"] as? String == "Authorization needed")
        let dataField = json["data"] as? [String: Any]
        let elicitations = dataField?["elicitations"] as? [[String: Any]]
        #expect(elicitations?.count == 1)
        #expect(elicitations?[0]["elicitationId"] as? String == "e1")
    }
}
