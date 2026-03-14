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

        #expect(decoded == schema)
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

        let parameters = CreateElicitation.Parameters.form(
            .init(
                message: "Please share your GitHub username",
                requestedSchema: schema,
                _meta: Metadata(additionalFields: ["flow": "onboarding"])
            )
        )

        let data = try encoder.encode(parameters)
        let decoded = try decoder.decode(CreateElicitation.Parameters.self, from: data)

        #expect(decoded == parameters)
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

        #expect(decoded == result)
    }

    @Test("Client capabilities include elicitation")
    func testClientCapabilitiesIncludeElicitation() throws {
        let capabilities = Client.Capabilities(
            elicitation: .init()
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded == capabilities)
    }

    @Test("Client elicitation handler registration")
    func testClientElicitationHandlerRegistration() async throws {
        let client = Client(name: "TestClient", version: "1.0")

        let handlerClient = await client.withElicitationHandler { parameters in
            if case .form(let formParams) = parameters {
                #expect(formParams.message == "Collect input")
            }
            return CreateElicitation.Result(action: .decline)
        }

        #expect(handlerClient === client)
    }
}

@Suite("Elicitation 2025-11-25 Spec Tests")
struct Elicitation2025_11_25Tests {
    @Test("URL mode parameters encoding and decoding")
    func testURLModeParameters() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let params = CreateElicitation.Parameters.url(
            .init(
                message: "Please authenticate",
                url: "https://example.com/auth",
                elicitationId: "elicit-123"
            )
        )

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(CreateElicitation.Parameters.self, from: data)

        #expect(decoded == params)
    }

    @Test("Form mode backward compatibility")
    func testFormModeBackwardCompatibility() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let params = CreateElicitation.Parameters.form(
            .init(message: "Enter your name", requestedSchema: .init())
        )

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(CreateElicitation.Parameters.self, from: data)

        #expect(decoded == params)
    }

    @Test("ElicitationCompleteNotification")
    func testElicitationCompleteNotification() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let notification = ElicitationCompleteNotification.Parameters(
            elicitationId: "elicit-456"
        )

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(
            ElicitationCompleteNotification.Parameters.self, from: data
        )

        #expect(decoded == notification)
    }

    @Test("Client elicitation capabilities with sub-capabilities")
    func testElicitationSubCapabilities() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let capabilities = Client.Capabilities(
            elicitation: .init(form: .init(), url: .init())
        )

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded == capabilities)
    }

    @Test("URLElicitationRequiredError encoding and decoding")
    func testURLElicitationRequiredError() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let elicitationInfo = URLElicitationInfo(
            elicitationId: "elicit-789",
            url: "https://example.com/verify",
            message: "Please verify your identity"
        )

        let error = MCPError.urlElicitationRequired(
            message: "Authentication required",
            elicitations: [elicitationInfo]
        )

        let data = try encoder.encode(error)
        let decoded = try decoder.decode(MCPError.self, from: data)

        #expect(decoded == error)
    }
}

@Suite("Elicitation Integration Tests")
struct ElicitationIntegrationTests {

    @Test("Form-based elicitation flow")
    func testFormElicitationFlow() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "FormTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "FormTestClient",
            version: "1.0",
            capabilities: .init(elicitation: .init())
        )

        // Register handler on client that validates parameters
        await client.withElicitationHandler { parameters in
            if case .form(let formParams) = parameters {
                #expect(formParams.message == "Please enter your details")
                #expect(formParams.requestedSchema.properties["email"] != nil)
                #expect(formParams._meta?["flow"]?.stringValue == "onboarding")

                // Return accepted response
                return CreateElicitation.Result(
                    action: .accept,
                    content: [
                        "email": "user@example.com",
                        "name": "Test User"
                    ]
                )
            } else {
                Issue.record("Expected form parameters")
                return CreateElicitation.Result(action: .decline)
            }
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Server requests elicitation with form parameters
        let schema = Elicitation.RequestSchema(
            title: "User Details",
            properties: [
                "email": ["type": "string", "format": "email"],
                "name": ["type": "string", "minLength": 2]
            ],
            required: ["email"]
        )

        let result = try await server.requestElicitation(
            message: "Please enter your details",
            requestedSchema: schema,
            _meta: Metadata(additionalFields: ["flow": "onboarding"])
        )

        // Verify the response
        #expect(result.action == .accept)
        #expect(result.content?["email"]?.stringValue == "user@example.com")
        #expect(result.content?["name"]?.stringValue == "Test User")

        await server.stop()
        await client.disconnect()
    }

    @Test("URL-based elicitation flow")
    func testURLElicitationFlow() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "URLTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "URLTestClient",
            version: "1.0",
            capabilities: .init(elicitation: .init(url: .init()))
        )

        // Register handler on client that validates URL parameters
        await client.withElicitationHandler { parameters in
            if case .url(let urlParams) = parameters {
                #expect(urlParams.message == "Please authenticate")
                #expect(urlParams.url == "https://example.com/auth")
                #expect(urlParams.elicitationId.isEmpty == false)
                #expect(urlParams._meta?["provider"]?.stringValue == "oauth")

                // Return accepted response
                return CreateElicitation.Result(
                    action: .accept,
                    content: ["token": "auth-token-123"]
                )
            } else {
                Issue.record("Expected URL parameters")
                return CreateElicitation.Result(action: .decline)
            }
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Server requests elicitation with URL parameters
        let result = try await server.requestElicitation(
            message: "Please authenticate",
            url: "https://example.com/auth",
            elicitationId: "elicit-test-123",
            _meta: Metadata(additionalFields: ["provider": "oauth"])
        )

        // Verify the response
        #expect(result.action == .accept)
        #expect(result.content?["token"]?.stringValue == "auth-token-123")

        await server.stop()
        await client.disconnect()
    }

    @Test("Declined elicitation")
    func testDeclinedElicitation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "DeclineTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "DeclineTestClient",
            version: "1.0",
            capabilities: .init(elicitation: .init())
        )

        // Register handler that declines
        await client.withElicitationHandler { _ in
            CreateElicitation.Result(action: .decline)
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let result = try await server.requestElicitation(
            message: "Optional question",
            requestedSchema: .init()
        )

        #expect(result.action == .decline)
        #expect(result.content == nil)

        await server.stop()
        await client.disconnect()
    }

    @Test("Elicitation without handler fails")
    func testElicitationWithoutHandlerFails() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ErrorTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "ErrorTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should throw an error because client doesn't have elicitation capability
        await #expect(throws: MCPError.self) {
            _ = try await server.requestElicitation(
                message: "Test message",
                requestedSchema: .init()
            )
        }

        await server.stop()
        await client.disconnect()
    }

    @Test("Strict mode succeeds when client declares elicitation capability")
    func testElicitationStrictCapabilitiesSuccess() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "StrictTestServer",
            version: "1.0",
            configuration: .strict
        )

        let client = Client(
            name: "StrictTestClient",
            version: "1.0",
            capabilities: .init(elicitation: .init()),
            configuration: .strict
        )

        // Register elicitation handler
        await client.withElicitationHandler { _ in
            CreateElicitation.Result(
                action: .accept,
                content: ["response": "strict mode success"]
            )
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should succeed because client declares elicitation capability
        let result = try await server.requestElicitation(
            message: "Test message",
            requestedSchema: .init()
        )

        #expect(result.action == .accept)
        #expect(result.content?["response"]?.stringValue == "strict mode success")

        await server.stop()
        await client.disconnect()
    }

    @Test("Strict mode fails when client doesn't declare elicitation capability")
    func testElicitationStrictCapabilitiesError() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "StrictTestServer",
            version: "1.0",
            configuration: .strict
        )

        // Client WITHOUT elicitation capability in strict mode
        let client = Client(
            name: "StrictTestClient",
            version: "1.0",
            capabilities: .init(),
            configuration: .strict
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should fail because client doesn't declare elicitation capability in strict mode
        await #expect(throws: MCPError.self) {
            _ = try await server.requestElicitation(
                message: "Test message",
                requestedSchema: .init()
            )
        }

        await server.stop()
        await client.disconnect()
    }

    @Test("Non-strict mode succeeds even without client capability declaration")
    func testElicitationNonStrictCapabilities() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "NonStrictTestServer",
            version: "1.0",
            configuration: .default  // Non-strict mode
        )

        // Client WITHOUT elicitation capability in non-strict mode
        let client = Client(
            name: "NonStrictTestClient",
            version: "1.0",
            capabilities: .init(),
            configuration: .default
        )

        // Register elicitation handler anyway
        await client.withElicitationHandler { _ in
            CreateElicitation.Result(
                action: .accept,
                content: ["response": "non-strict mode success"]
            )
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should succeed because server is in non-strict mode
        let result = try await server.requestElicitation(
            message: "Test message",
            requestedSchema: .init()
        )

        #expect(result.action == .accept)
        #expect(result.content?["response"]?.stringValue == "non-strict mode success")

        await server.stop()
        await client.disconnect()
    }

    @Test("Complex schema validation")
    func testComplexSchemaValidation() async throws {
        let schema = Elicitation.RequestSchema(
            title: "User Profile",
            description: "Complete user profile information",
            properties: [
                "username": [
                    "type": "string",
                    "minLength": 3,
                    "maxLength": 20,
                    "pattern": "^[a-zA-Z0-9_]+$"
                ],
                "email": [
                    "type": "string",
                    "format": "email"
                ],
                "age": [
                    "type": "integer",
                    "minimum": 18,
                    "maximum": 120
                ],
                "preferences": [
                    "type": "object",
                    "properties": [
                        "theme": ["type": "string", "enum": ["light", "dark"]],
                        "notifications": ["type": "boolean"]
                    ]
                ]
            ],
            required: ["username", "email"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let decoder = JSONDecoder()

        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(Elicitation.RequestSchema.self, from: data)

        #expect(decoded == schema)
    }

    @Test("Multiple elicitation requests in sequence")
    func testSequentialElicitations() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "SequentialTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "SequentialTestClient",
            version: "1.0",
            capabilities: .init(elicitation: .init())
        )

        // Register handler that echoes the message
        await client.withElicitationHandler { parameters in
            if case .form(let formParams) = parameters {
                return CreateElicitation.Result(
                    action: .accept,
                    content: ["echo": Value(stringLiteral: formParams.message)]
                )
            } else {
                return CreateElicitation.Result(action: .decline)
            }
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Make multiple sequential requests
        let result1 = try await server.requestElicitation(message: "First question", requestedSchema: .init())
        #expect(result1.action == .accept)
        #expect(result1.content?["echo"]?.stringValue == "First question")

        let result2 = try await server.requestElicitation(message: "Second question", requestedSchema: .init())
        #expect(result2.action == .accept)
        #expect(result2.content?["echo"]?.stringValue == "Second question")

        let result3 = try await server.requestElicitation(message: "Third question", requestedSchema: .init())
        #expect(result3.action == .accept)
        #expect(result3.content?["echo"]?.stringValue == "Third question")

        await server.stop()
        await client.disconnect()
    }
}
