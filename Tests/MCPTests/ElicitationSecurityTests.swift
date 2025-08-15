import Testing
import Foundation
@testable import MCP

@Suite("Elicitation Security Tests")
struct ElicitationSecurityTests {
    
    @Test("Elicitation should not request sensitive information - password example")
    func testSensitiveInformationPrevention() throws {
        let sensitiveSchema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "password": .object(["type": .string("string")]),
                "ssn": .object(["type": .string("string")]),
                "creditCard": .object(["type": .string("string")])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please provide your password and SSN",
            schema: sensitiveSchema
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.count > 0)
        #expect(warnings.contains { $0.contains("password") })
        #expect(warnings.contains { $0.contains("ssn") })
    }
    
    @Test("Elicitation should provide clear decline option")
    func testDeclineOptionAvailable() throws {
        let result = CreateElicitation.Result(action: .decline)
        #expect(result.action == .decline)
        #expect(result.data == nil)
    }
    
    @Test("Elicitation should provide clear cancel option")
    func testCancelOptionAvailable() throws {
        let result = CreateElicitation.Result(action: .cancel)
        #expect(result.action == .cancel)
        #expect(result.data == nil)
    }
    
    @Test("Elicitation should handle user privacy - no data on decline")
    func testPrivacyOnDecline() throws {
        struct UserData: Codable, Hashable, Sendable {
            let name: String
            let email: String
        }
        
        let declineResult = CreateElicitation.Result(action: .decline)
        let typedResult = try ElicitationResult<UserData>(from: declineResult)
        
        #expect(typedResult.action == .decline)
        #expect(typedResult.data == nil)
        #expect(typedResult.isRejected == true)
        #expect(typedResult.isAccepted == false)
    }
    
    @Test("Elicitation should handle user privacy - no data on cancel")
    func testPrivacyOnCancel() throws {
        struct UserData: Codable, Hashable, Sendable {
            let name: String
            let email: String
        }
        
        let cancelResult = CreateElicitation.Result(action: .cancel)
        let typedResult = try ElicitationResult<UserData>(from: cancelResult)
        
        #expect(typedResult.action == .cancel)
        #expect(typedResult.data == nil)
        #expect(typedResult.isRejected == true)
        #expect(typedResult.isAccepted == false)
    }
    
    @Test("Elicitation metadata should identify requesting server")
    func testServerIdentificationInMetadata() throws {
        let parameters = CreateElicitation.Parameters(
            message: "Please provide your preferences",
            schema: Value.object(["type": .string("object")]),
            metadata: [
                "server_id": .string("booking-server"),
                "server_name": .string("Restaurant Booking Service"),
                "request_context": .string("table_reservation")
            ]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(!warnings.contains { $0.contains("Missing server identification") })
        #expect(parameters.metadata?["server_id"]?.stringValue == "booking-server")
        #expect(parameters.metadata?["server_name"]?.stringValue == "Restaurant Booking Service")
    }
    
    @Test("Elicitation should validate schema structure")
    func testSchemaValidation() throws {
        let validSchema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "preference": .object([
                    "type": .string("string"),
                    "description": .string("User preference")
                ])
            ]),
            "required": .array([.string("preference")])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please select your preference",
            schema: validSchema,
            metadata: ["server_name": .string("Test Server")]
        )
        
        #expect(parameters.schema.objectValue?["type"]?.stringValue == "object")
        #expect(parameters.schema.objectValue?["properties"] != nil)
    }
    
    @Test("Elicitation should handle malformed responses gracefully")
    func testMalformedResponseHandling() throws {
        struct ValidData: Codable, Hashable, Sendable {
            let name: String
        }
        
        let malformedData = Value.object([
            "invalid_field": .string("test")
        ])
        
        let result = CreateElicitation.Result(action: .accept, data: malformedData)
        
        #expect(throws: (any Error).self) {
            try ElicitationResult<ValidData>(from: result)
        }
    }
    
    @Test("Default elicitation handler should decline by default")
    func testDefaultHandlerSecurity() async throws {
        let parameters = CreateElicitation.Parameters(
            message: "Test request",
            schema: Value.object(["type": .string("object")]),
            metadata: ["server_name": .string("Test Server")]
        )
        
        let result = try await Client.defaultElicitationHandler(parameters)
        #expect(result.action == .decline)
        #expect(result.data == nil)
    }
    
    @Test("Security validation detects missing server identification")
    func testMissingServerIdentification() throws {
        let parameters = CreateElicitation.Parameters(
            message: "Please provide information",
            schema: Value.object(["type": .string("object")])
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.contains { $0.contains("Missing server identification") })
    }
    
    @Test("Security validation detects multiple sensitive terms")
    func testMultipleSensitiveTermsDetection() throws {
        let parameters = CreateElicitation.Parameters(
            message: "Please provide your password, SSN, and credit card number for verification",
            schema: Value.object(["type": .string("object")]),
            metadata: ["server_name": .string("Test Server")]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.count >= 3)
        #expect(warnings.contains { $0.contains("password") })
        #expect(warnings.contains { $0.contains("ssn") })
        #expect(warnings.contains { $0.contains("credit card") })
    }
}
