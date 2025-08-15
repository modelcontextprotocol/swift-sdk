import Testing
import Foundation
@testable import MCP

@Suite("Elicitation Use Case Tests")
struct ElicitationUseCaseTests {
    
    @Test("Safe use case - Restaurant booking preferences")
    func testRestaurantBookingUseCase() throws {
        struct BookingPreferences: Codable, Hashable, Sendable {
            let checkAlternative: Bool
            let alternativeDate: String
            let partySize: Int?
        }
        
        let schema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "checkAlternative": .object([
                    "type": .string("boolean"),
                    "description": .string("Would you like to check another date?")
                ]),
                "alternativeDate": .object([
                    "type": .string("string"),
                    "description": .string("Alternative date (YYYY-MM-DD)")
                ]),
                "partySize": .object([
                    "type": .string("integer"),
                    "description": .string("Number of people")
                ])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "No tables available for December 25th. Would you like to try another date?",
            schema: schema,
            metadata: [
                "server_name": .string("Restaurant Booking"),
                "context": .string("availability_check"),
                "safe_request": .bool(true)
            ]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.isEmpty)
        #expect(parameters.message.contains("Would you like"))
        #expect(!parameters.message.contains("password"))
        #expect(!parameters.message.contains("credit card"))
        #expect(parameters.metadata?["safe_request"]?.boolValue == true)
    }
    
    @Test("Safe use case - Travel preferences")
    func testTravelPreferencesUseCase() throws {
        struct TravelPreferences: Codable, Hashable, Sendable {
            let destination: String
            let travelDates: [String]
            let budget: String
        }
        
        let schema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "destination": .object([
                    "type": .string("string"),
                    "description": .string("Preferred destination")
                ]),
                "travelDates": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "budget": .object([
                    "type": .string("string"),
                    "enum": .array([.string("low"), .string("medium"), .string("high")])
                ])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please specify your travel preferences to find the best options",
            schema: schema,
            metadata: [
                "server_name": .string("Travel Assistant"),
                "purpose": .string("preference_collection")
            ]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.isEmpty)
        #expect(parameters.message.contains("preferences"))
        #expect(parameters.schema.objectValue?["properties"] != nil)
    }
    
    @Test("Unsafe use case detection - Personal information")
    func testUnsafePersonalInformationDetection() throws {
        let unsafeSchema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "ssn": .object(["type": .string("string")]),
                "password": .object(["type": .string("string")]),
                "creditCardNumber": .object(["type": .string("string")])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please provide your SSN and password for verification",
            schema: unsafeSchema,
            metadata: ["server_name": .string("Verification Service")]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.count >= 2)
        
        let schemaProps = parameters.schema.objectValue?["properties"]?.objectValue
        #expect(schemaProps?["ssn"] != nil)
        #expect(schemaProps?["password"] != nil)
        #expect(schemaProps?["creditCardNumber"] != nil)
    }
    
    @Test("User review workflow simulation")
    func testUserReviewWorkflow() throws {
        struct FormData: Codable, Hashable, Sendable {
            let name: String
            let email: String
        }
        
        let userData = FormData(name: "John Doe", email: "john@example.com")
        let encoder = JSONEncoder()
        let userDataValue = try JSONDecoder().decode(Value.self, from: try encoder.encode(userData))
        
        let acceptResult = CreateElicitation.Result(action: .accept, data: userDataValue)
        let typedResult = try ElicitationResult<FormData>(from: acceptResult)
        
        #expect(typedResult.action == .accept)
        #expect(typedResult.data?.name == "John Doe")
        #expect(typedResult.data?.email == "john@example.com")
        #expect(typedResult.isAccepted == true)
        #expect(typedResult.isRejected == false)
    }
    
    @Test("Clear server identification in UI context")
    func testServerIdentificationForUI() throws {
        let parameters = CreateElicitation.Parameters(
            message: "The Restaurant Booking Service is requesting your dining preferences",
            schema: Value.object(["type": .string("object")]),
            metadata: [
                "server_display_name": .string("Restaurant Booking Service"),
                "server_icon": .string("🍽️"),
                "trust_level": .string("verified"),
                "ui_context": .object([
                    "show_server_badge": .bool(true),
                    "highlight_privacy_options": .bool(true)
                ])
            ]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.isEmpty)
        #expect(parameters.message.contains("Restaurant Booking Service"))
        #expect(parameters.metadata?["server_display_name"]?.stringValue == "Restaurant Booking Service")
        #expect(parameters.metadata?["trust_level"]?.stringValue == "verified")
        #expect(parameters.metadata?["ui_context"]?.objectValue?["show_server_badge"]?.boolValue == true)
    }
    
    @Test("Privacy-respecting decline handling")
    func testPrivacyRespectingDecline() throws {
        struct SensitiveData: Codable, Hashable, Sendable {
            let personalInfo: String
        }
        
        let declineResult = CreateElicitation.Result(action: .decline)
        let typedResult = try ElicitationResult<SensitiveData>(from: declineResult)
        
        #expect(typedResult.action == .decline)
        #expect(typedResult.data == nil)
        #expect(typedResult.isRejected == true)
    }
    
    @Test("Multiple choice safe options")
    func testMultipleChoiceSafeOptions() throws {
        let safeChoiceSchema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "preference": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("option_a"),
                        .string("option_b"), 
                        .string("option_c"),
                        .string("decline")
                    ])
                ])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please select your preference (you can always decline)",
            schema: safeChoiceSchema,
            metadata: ["server_name": .string("Preference Service")]
        )
        
        let warnings = parameters.validateSecurity()
        #expect(warnings.isEmpty)
        
        let enumOptions = parameters.schema.objectValue?["properties"]?.objectValue?["preference"]?.objectValue?["enum"]?.arrayValue
        #expect(enumOptions?.contains(.string("decline")) == true)
    }
    
    @Test("Timeout and cancellation handling")
    func testTimeoutHandling() throws {
        let cancelResult = CreateElicitation.Result(action: .cancel)
        let typedResult = try ElicitationResult<String>(from: cancelResult)
        
        #expect(cancelResult.action == .cancel)
        #expect(cancelResult.data == nil)
        #expect(typedResult.isRejected == true)
    }
}
