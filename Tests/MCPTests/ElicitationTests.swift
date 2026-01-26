import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Elicitation Tests")
struct ElicitationTests {
    @Test("Request schema encoding and decoding")
    func testSchemaCoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let schema = Elicitation.RequestSchema(
            title: "Contact Information",
            description: "Used to follow up after onboarding",
            properties: [
                "name": [
                    "type": "string",
                    "title": "Full Name",
                    "description": "Enter your legal name",
                    "minLength": 2,
                    "maxLength": 120,
                ],
                "email": [
                    "type": "string",
                    "title": "Email Address",
                    "description": "Where we can reach you",
                    "format": "email",
                ],
                "age": [
                    "type": "integer",
                    "minimum": 18,
                    "maximum": 110,
                ],
                "marketingOptIn": [
                    "type": "boolean",
                    "title": "Marketing opt-in",
                    "default": false,
                ],
            ],
            required: ["name", "email"]
        )

        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(Elicitation.RequestSchema.self, from: data)

        #expect(decoded.title == "Contact Information")
        let emailSchema = decoded.properties["email"]?.objectValue
        #expect(emailSchema?["format"]?.stringValue == "email")

        let ageSchema = decoded.properties["age"]?.objectValue
        #expect(ageSchema?["minimum"]?.intValue == 18)

        let marketingSchema = decoded.properties["marketingOptIn"]?.objectValue
        #expect(marketingSchema?["default"]?.boolValue == false)
        #expect(decoded.required == ["name", "email"])
    }

    @Test("Enumeration support")
    func testEnumerationSupport() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let property: Value = [
            "type": "string",
            "title": "Department",
            "enum": ["engineering", "design", "product"],
            "enumNames": ["Engineering", "Design", "Product"],
        ]

        let data = try encoder.encode(property)
        let decoded = try decoder.decode(Value.self, from: data)

        let object = decoded.objectValue
        let enumeration = object?["enum"]?.arrayValue?.compactMap { $0.stringValue }
        let enumNames = object?["enumNames"]?.arrayValue?.compactMap { $0.stringValue }

        #expect(enumeration == ["engineering", "design", "product"])
        #expect(enumNames == ["Engineering", "Design", "Product"])
    }

    @Test("CreateElicitation.Parameters coding")
    func testParametersCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let schema = Elicitation.RequestSchema(
            properties: [
                "username": [
                    "type": "string",
                    "minLength": 2,
                    "maxLength": 39,
                ]
            ],
            required: ["username"]
        )

        let parameters = CreateElicitation.Parameters(
            message: "Please share your GitHub username",
            requestedSchema: schema,
            metadata: ["flow": "onboarding"]
        )

        let data = try encoder.encode(parameters)
        let decoded = try decoder.decode(CreateElicitation.Parameters.self, from: data)

        #expect(decoded.message == "Please share your GitHub username")
        #expect(decoded.requestedSchema?.properties.keys.contains("username") == true)
        #expect(decoded.metadata?["flow"]?.stringValue == "onboarding")
    }

    @Test("CreateElicitation.Result coding")
    func testResultCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let result = CreateElicitation.Result(
            action: .accept,
            content: ["username": "octocat", "age": 30]
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateElicitation.Result.self, from: data)

        #expect(decoded.action == .accept)
        #expect(decoded.content?["username"]?.stringValue == "octocat")
        #expect(decoded.content?["age"]?.intValue == 30)
    }

    @Test("Client capabilities include elicitation")
    func testClientCapabilitiesIncludeElicitation() throws {
        let capabilities = Client.Capabilities(
            elicitation: .init()
        )

        #expect(capabilities.elicitation != nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.elicitation != nil)
    }

    @Test("Client elicitation handler registration")
    func testClientElicitationHandlerRegistration() async throws {
        let client = Client(name: "TestClient", version: "1.0")

        let handlerClient = await client.withElicitationHandler { parameters in
            #expect(parameters.message == "Collect input")
            return CreateElicitation.Result(action: .decline)
        }

        #expect(handlerClient === client)
    }
}
