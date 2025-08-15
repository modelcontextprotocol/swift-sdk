import Testing
import Foundation
@testable import MCP

@Suite("Elicitation Tests")
struct ElicitationTests {
    
    @Test("CreateElicitation method name")
    func testCreateElicitationMethodName() {
        #expect(CreateElicitation.name == "elicitation/create")
    }
    
    @Test("CreateElicitation Parameters encoding and decoding")
    func testCreateElicitationParametersEncoding() throws {
        let schema = Value.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")])
            ])
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: "Please provide your name",
            schema: schema,
            metadata: ["context": .string("user_registration")]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(parameters)
        let decoded = try decoder.decode(CreateElicitation.Parameters.self, from: data)
        
        #expect(decoded.message == "Please provide your name")
        #expect(decoded.schema == schema)
        #expect(decoded.metadata?["context"]?.stringValue == "user_registration")
    }
    
    @Test("CreateElicitation Result encoding and decoding")
    func testCreateElicitationResultEncoding() throws {
        let responseData = Value.object([
            "name": .string("John Doe")
        ])
        
        let result = CreateElicitation.Result(
            action: .accept,
            data: responseData
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateElicitation.Result.self, from: data)
        
        #expect(decoded.action == .accept)
        #expect(decoded.data == responseData)
    }
    
    @Test("CreateElicitation Result actions")
    func testCreateElicitationResultActions() throws {
        let acceptResult = CreateElicitation.Result(action: .accept, data: .string("test"))
        let declineResult = CreateElicitation.Result(action: .decline)
        let cancelResult = CreateElicitation.Result(action: .cancel)
        
        #expect(acceptResult.action == .accept)
        #expect(acceptResult.data?.stringValue == "test")
        
        #expect(declineResult.action == .decline)
        #expect(declineResult.data == nil)
        
        #expect(cancelResult.action == .cancel)
        #expect(cancelResult.data == nil)
    }
    
    @Test("ElicitationResult type-safe wrapper")
    func testElicitationResultWrapper() throws {
        struct UserInfo: Codable, Hashable, Sendable {
            let name: String
            let age: Int
        }
        
        let userData = UserInfo(name: "Alice", age: 30)
        let encoder = JSONEncoder()
        let userDataValue = try JSONDecoder().decode(Value.self, from: try encoder.encode(userData))
        
        let rawResult = CreateElicitation.Result(action: .accept, data: userDataValue)
        let typedResult = try ElicitationResult<UserInfo>(from: rawResult)
        
        #expect(typedResult.action == .accept)
        #expect(typedResult.data?.name == "Alice")
        #expect(typedResult.data?.age == 30)
    }
    
    @Test("ElicitationResult decline handling")
    func testElicitationResultDecline() throws {
        struct UserInfo: Codable, Hashable, Sendable {
            let name: String
        }
        
        let rawResult = CreateElicitation.Result(action: .decline)
        let typedResult = try ElicitationResult<UserInfo>(from: rawResult)
        
        #expect(typedResult.action == .decline)
        #expect(typedResult.data == nil)
    }
    
    @Test("Server elicitation capability")
    func testServerElicitationCapability() {
        let capabilities = Server.Capabilities(
            elicitation: .init()
        )
        
        #expect(capabilities.elicitation != nil)
    }
    
    @Test("Client elicitation capability")
    func testClientElicitationCapability() {
        let capabilities = Client.Capabilities(
            elicitation: .init()
        )
        
        #expect(capabilities.elicitation != nil)
    }
}
