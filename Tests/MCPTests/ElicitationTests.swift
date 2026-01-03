import Foundation
import Testing

@testable import MCP

// MARK: - Test Helpers

/// Extension to provide convenient value accessors for testing
extension ElicitValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringsValue: [String]? {
        if case .strings(let value) = self { return value }
        return nil
    }
}

// MARK: - Schema Encoding/Decoding Tests

@Suite("Schema Encoding/Decoding Tests")
struct SchemaEncodingTests {

    @Test("StringSchema encodes and decodes correctly")
    func testStringSchemaRoundtrip() throws {
        let schema = StringSchema(
            title: "Name",
            description: "The user's name",
            minLength: 1,
            maxLength: 100,
            format: .email,
            defaultValue: "user@example.com"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(StringSchema.self, from: data)

        #expect(decoded.title == "Name")
        #expect(decoded.description == "The user's name")
        #expect(decoded.minLength == 1)
        #expect(decoded.maxLength == 100)
        #expect(decoded.format == .email)
        #expect(decoded.defaultValue == "user@example.com")
    }

    @Test("StringSchema with format encodes correctly")
    func testStringSchemaFormats() throws {
        let formats: [StringSchemaFormat] = [.email, .uri, .date, .dateTime]

        for format in formats {
            let schema = StringSchema(format: format)
            let data = try JSONEncoder().encode(schema)
            let decoded = try JSONDecoder().decode(StringSchema.self, from: data)
            #expect(decoded.format == format)
        }
    }

    @Test("StringSchema with pattern encodes correctly")
    func testStringSchemaPattern() throws {
        let schema = StringSchema(
            title: "ZIP Code",
            pattern: "^[0-9]{5}$"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(schema)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"pattern\":\"^[0-9]{5}$\""))

        let decoded = try JSONDecoder().decode(StringSchema.self, from: data)
        #expect(decoded.pattern == "^[0-9]{5}$")
        #expect(decoded.title == "ZIP Code")
    }

    @Test("NumberSchema encodes and decodes correctly")
    func testNumberSchemaRoundtrip() throws {
        let schema = NumberSchema(
            isInteger: true,
            title: "Age",
            description: "User age",
            minimum: 0,
            maximum: 150,
            defaultValue: 25
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(NumberSchema.self, from: data)

        #expect(decoded.type == "integer")  // isInteger is encoded as type
        #expect(decoded.title == "Age")
        #expect(decoded.minimum == 0)
        #expect(decoded.maximum == 150)
        #expect(decoded.defaultValue == 25)
    }

    @Test("BooleanSchema encodes and decodes correctly")
    func testBooleanSchemaRoundtrip() throws {
        let schema = BooleanSchema(
            title: "Subscribe",
            description: "Subscribe to newsletter",
            defaultValue: true
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(BooleanSchema.self, from: data)

        #expect(decoded.title == "Subscribe")
        #expect(decoded.defaultValue == true)
    }

    @Test("TitledEnumSchema encodes and decodes correctly")
    func testTitledEnumSchemaRoundtrip() throws {
        let schema = TitledEnumSchema(
            title: "Color",
            description: "Pick a color",
            oneOf: [
                TitledEnumOption(const: "red", title: "Red"),
                TitledEnumOption(const: "green", title: "Green"),
                TitledEnumOption(const: "blue", title: "Blue"),
            ],
            defaultValue: "red"
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(TitledEnumSchema.self, from: data)

        #expect(decoded.title == "Color")
        #expect(decoded.oneOf.count == 3)
        #expect(decoded.oneOf[0].const == "red")
        #expect(decoded.oneOf[0].title == "Red")
        #expect(decoded.defaultValue == "red")
    }

    @Test("UntitledEnumSchema encodes and decodes correctly")
    func testUntitledEnumSchemaRoundtrip() throws {
        let schema = UntitledEnumSchema(
            title: "Size",
            enumValues: ["small", "medium", "large"],
            defaultValue: "medium"
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(UntitledEnumSchema.self, from: data)

        #expect(decoded.title == "Size")
        #expect(decoded.enumValues == ["small", "medium", "large"])
        #expect(decoded.defaultValue == "medium")
    }

    @Test("TitledMultiSelectEnumSchema encodes and decodes correctly")
    func testTitledMultiSelectEnumSchemaRoundtrip() throws {
        let schema = TitledMultiSelectEnumSchema(
            title: "Interests",
            description: "Select your interests",
            options: [
                TitledEnumOption(const: "tech", title: "Technology"),
                TitledEnumOption(const: "sports", title: "Sports"),
                TitledEnumOption(const: "music", title: "Music"),
            ],
            defaultValue: ["tech"]
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(TitledMultiSelectEnumSchema.self, from: data)

        #expect(decoded.title == "Interests")
        #expect(decoded.items.anyOf.count == 3)  // options are in items.anyOf
        #expect(decoded.defaultValue == ["tech"])
    }

    @Test("UntitledMultiSelectEnumSchema encodes and decodes correctly")
    func testUntitledMultiSelectEnumSchemaRoundtrip() throws {
        let schema = UntitledMultiSelectEnumSchema(
            title: "Tags",
            enumValues: ["tag1", "tag2", "tag3"],
            defaultValue: ["tag1", "tag2"]
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(UntitledMultiSelectEnumSchema.self, from: data)

        #expect(decoded.title == "Tags")
        #expect(decoded.items.enumValues == ["tag1", "tag2", "tag3"])  // enumValues are in items
        #expect(decoded.defaultValue == ["tag1", "tag2"])
    }

    @Test("ElicitationSchema with mixed property types encodes correctly")
    func testElicitationSchemaWithMixedTypes() throws {
        let schema = ElicitationSchema(
            properties: [
                "name": .string(StringSchema(title: "Name")),
                "age": .number(NumberSchema(isInteger: true, title: "Age")),
                "subscribe": .boolean(BooleanSchema(title: "Subscribe")),
                "color": .titledEnum(TitledEnumSchema(
                    title: "Color",
                    oneOf: [TitledEnumOption(const: "red", title: "Red")]
                )),
            ],
            required: ["name", "age"]
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(ElicitationSchema.self, from: data)

        #expect(decoded.properties.count == 4)
        #expect(decoded.required == ["name", "age"])
    }
}

// MARK: - ElicitRequestParams Tests

@Suite("ElicitRequestParams Tests")
struct ElicitRequestParamsTests {

    @Test("Form mode params encode and decode correctly")
    func testFormModeParams() throws {
        let params = ElicitRequestParams.form(ElicitRequestFormParams(
            message: "Please fill out this form",
            requestedSchema: ElicitationSchema(
                properties: [
                    "name": .string(StringSchema(title: "Name")),
                ],
                required: ["name"]
            )
        ))

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ElicitRequestParams.self, from: data)

        if case .form(let formParams) = decoded {
            #expect(formParams.message == "Please fill out this form")
            #expect(formParams.requestedSchema.properties.count == 1)
        } else {
            Issue.record("Expected form params")
        }
    }

    @Test("URL mode params encode and decode correctly")
    func testURLModeParams() throws {
        let params = ElicitRequestParams.url(ElicitRequestURLParams(
            message: "Please authorize access",
            elicitationId: "auth-123",
            url: "https://example.com/oauth/authorize"
        ))

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ElicitRequestParams.self, from: data)

        if case .url(let urlParams) = decoded {
            #expect(urlParams.message == "Please authorize access")
            #expect(urlParams.elicitationId == "auth-123")
            #expect(urlParams.url == "https://example.com/oauth/authorize")
        } else {
            Issue.record("Expected URL params")
        }
    }
}

// MARK: - ElicitResult Tests

@Suite("ElicitResult Tests")
struct ElicitResultTests {

    @Test("ElicitResult with accept action encodes correctly")
    func testElicitResultAccept() throws {
        let result = ElicitResult(
            action: .accept,
            content: [
                "name": .string("Alice"),
                "age": .int(30),
            ]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ElicitResult.self, from: data)

        #expect(decoded.action == .accept)
        #expect(decoded.content?["name"]?.stringValue == "Alice")
        #expect(decoded.content?["age"]?.intValue == 30)
    }

    @Test("ElicitResult with decline action encodes correctly")
    func testElicitResultDecline() throws {
        let result = ElicitResult(action: .decline)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ElicitResult.self, from: data)

        #expect(decoded.action == .decline)
        #expect(decoded.content == nil)
    }

    @Test("ElicitResult with cancel action encodes correctly")
    func testElicitResultCancel() throws {
        let result = ElicitResult(action: .cancel)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ElicitResult.self, from: data)

        #expect(decoded.action == .cancel)
    }
}

// MARK: - ElicitValue Tests

@Suite("ElicitValue Tests")
struct ElicitValueTests {

    @Test("String value encodes and decodes correctly")
    func testStringValue() throws {
        let value = ElicitValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ElicitValue.self, from: data)
        #expect(decoded.stringValue == "hello")
    }

    @Test("Int value encodes and decodes correctly")
    func testIntValue() throws {
        let value = ElicitValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ElicitValue.self, from: data)
        #expect(decoded.intValue == 42)
    }

    @Test("Double value encodes and decodes correctly")
    func testDoubleValue() throws {
        let value = ElicitValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ElicitValue.self, from: data)
        #expect(decoded.doubleValue == 3.14)
    }

    @Test("Bool value encodes and decodes correctly")
    func testBoolValue() throws {
        let value = ElicitValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ElicitValue.self, from: data)
        #expect(decoded.boolValue == true)
    }

    @Test("Strings array value encodes and decodes correctly")
    func testStringsValue() throws {
        let value = ElicitValue.strings(["a", "b", "c"])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ElicitValue.self, from: data)
        #expect(decoded.stringsValue == ["a", "b", "c"])
    }
}

// MARK: - ElicitAction Tests

@Suite("ElicitAction Tests")
struct ElicitActionTests {

    @Test("All action types encode and decode correctly")
    func testActionTypes() throws {
        let actions: [ElicitAction] = [.accept, .decline, .cancel]

        for action in actions {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(ElicitAction.self, from: data)
            #expect(decoded == action)
        }
    }
}

// MARK: - Capability Tests

@Suite("Elicitation Capability Tests")
struct ElicitationCapabilityTests {

    @Test("Form capability encodes correctly")
    func testFormCapability() throws {
        let capability = Client.Capabilities.Elicitation(
            form: Client.Capabilities.Elicitation.Form(applyDefaults: true)
        )

        let data = try JSONEncoder().encode(capability)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Elicitation.self, from: data)

        #expect(decoded.form?.applyDefaults == true)
    }

    @Test("URL capability encodes correctly")
    func testURLCapability() throws {
        let capability = Client.Capabilities.Elicitation(
            url: Client.Capabilities.Elicitation.URL()
        )

        let data = try JSONEncoder().encode(capability)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Elicitation.self, from: data)

        #expect(decoded.url != nil)
    }

    @Test("Combined form and URL capability encodes correctly")
    func testCombinedCapability() throws {
        let capability = Client.Capabilities.Elicitation(
            form: Client.Capabilities.Elicitation.Form(),
            url: Client.Capabilities.Elicitation.URL()
        )

        let data = try JSONEncoder().encode(capability)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Elicitation.self, from: data)

        #expect(decoded.form != nil)
        #expect(decoded.url != nil)
    }
}

// MARK: - ElicitationRequiredErrorData Tests

@Suite("ElicitationRequiredErrorData Tests")
struct ElicitationRequiredErrorDataTests {

    @Test("Error data encodes correctly")
    func testErrorDataEncoding() throws {
        let errorData = ElicitationRequiredErrorData(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Authorize",
                    elicitationId: "auth-1",
                    url: "https://example.com/auth"
                )
            ]
        )

        let data = try JSONEncoder().encode(errorData)
        let decoded = try JSONDecoder().decode(ElicitationRequiredErrorData.self, from: data)

        #expect(decoded.elicitations.count == 1)
        #expect(decoded.elicitations[0].elicitationId == "auth-1")
        #expect(decoded.elicitations[0].url == "https://example.com/auth")
    }
}

// MARK: - Server-Client Integration Tests

@Suite("Elicitation Integration Tests")
struct ElicitationIntegrationTests {

    // MARK: - Form Mode Flow Tests

    @Test("Server can elicit form input from client - accept with content")
    func testFormElicitationAccept() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "askName", description: "Ask for name", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Please enter your name",
                requestedSchema: ElicitationSchema(
                    properties: ["name": .string(StringSchema(title: "Name"))],
                    required: ["name"]
                )
            )))

            if result.action == .accept, let name = result.content?["name"]?.stringValue {
                return CallTool.Result(content: [.text("Hello, \(name)!")])
            } else {
                return CallTool.Result(content: [.text("No name provided")], isError: true)
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }
            #expect(formParams.message == "Please enter your name")
            return ElicitResult(action: .accept, content: ["name": .string("Alice")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "askName", arguments: [:])

        #expect(result.isError == nil)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Hello, Alice!")
        }

        await client.disconnect()
    }

    @Test("Server can elicit form input from client - user declines")
    func testFormElicitationDecline() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "confirm", description: "Confirm action", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Confirm action?",
                requestedSchema: ElicitationSchema(
                    properties: ["confirm": .boolean(BooleanSchema(title: "Confirm"))]
                )
            )))

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Confirmed")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "confirm", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Declined")
        }

        await client.disconnect()
    }

    @Test("Server can elicit form input from client - user cancels")
    func testFormElicitationCancel() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "getData", description: "Get data", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Enter data",
                requestedSchema: ElicitationSchema(
                    properties: ["data": .string(StringSchema())]
                )
            )))

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Got data")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .cancel)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "getData", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Cancelled")
        }

        await client.disconnect()
    }

    @Test("Form elicitation with multiple field types")
    func testFormElicitationMultipleFieldTypes() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "survey", description: "Survey", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Complete the survey",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "name": .string(StringSchema(title: "Name")),
                        "age": .number(NumberSchema(isInteger: true, title: "Age")),
                        "score": .number(NumberSchema(isInteger: false, title: "Score")),
                        "subscribe": .boolean(BooleanSchema(title: "Subscribe")),
                    ],
                    required: ["name"]
                )
            )))

            guard result.action == .accept, let content = result.content else {
                return CallTool.Result(content: [.text("No response")])
            }

            let name = content["name"]?.stringValue ?? "unknown"
            let age = content["age"]?.intValue ?? 0
            let score = content["score"]?.doubleValue ?? 0.0
            let subscribe = content["subscribe"]?.boolValue ?? false

            return CallTool.Result(content: [.text(
                "Name: \(name), Age: \(age), Score: \(score), Subscribe: \(subscribe)"
            )])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(
                action: .accept,
                content: [
                    "name": .string("Bob"),
                    "age": .int(30),
                    "score": .double(95.5),
                    "subscribe": .bool(true),
                ]
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "survey", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Name: Bob"))
            #expect(text.contains("Age: 30"))
            #expect(text.contains("Score: 95.5"))
            #expect(text.contains("Subscribe: true"))
        }

        await client.disconnect()
    }

    // MARK: - URL Mode Flow Tests

    @Test("Server can elicit URL authorization from client - accept")
    func testURLElicitationAccept() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                message: "Please authorize access",
                elicitationId: "auth-123",
                url: "https://example.com/oauth"
            )))

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Authorized")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url(let urlParams) = params else {
                return ElicitResult(action: .decline)
            }
            #expect(urlParams.message == "Please authorize access")
            #expect(urlParams.elicitationId == "auth-123")
            #expect(urlParams.url == "https://example.com/oauth")
            return ElicitResult(action: .accept)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Authorized")
        }

        await client.disconnect()
    }

    // MARK: - Capability Checking Tests

    @Test("Server rejects form elicitation when client only supports URL mode")
    func testFormElicitationRejectedWhenClientOnlySupportsURL() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "formTool", description: "Tool requiring form", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            do {
                _ = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                    message: "This should fail",
                    requestedSchema: ElicitationSchema(properties: [:])
                )))
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch let error as MCPError {
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        // Client only supports URL mode, not form
        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { _, _ in
            Issue.record("Handler should not be called")
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "formTool", arguments: [:])

        #expect(result.isError == true)

        await client.disconnect()
    }

    @Test("Server rejects URL elicitation when client only supports form mode")
    func testURLElicitationRejectedWhenClientOnlySupportsForm() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "urlTool", description: "Tool requiring URL", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            do {
                _ = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                    message: "This should fail",
                    elicitationId: "test",
                    url: "https://example.com/auth"
                )))
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch let error as MCPError {
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        // Client only supports form mode, not URL
        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            Issue.record("Handler should not be called")
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "urlTool", arguments: [:])

        #expect(result.isError == true)

        await client.disconnect()
    }

    @Test("Server rejects elicitation when client has no elicitation capability")
    func testElicitationRejectedWhenNoCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "elicitTool", description: "Tool that elicits", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            do {
                _ = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                    message: "This should fail",
                    requestedSchema: ElicitationSchema(properties: [:])
                )))
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch let error as MCPError {
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        // Client has no elicitation capability
        let client = Client(name: "ElicitTestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "elicitTool", arguments: [:])

        #expect(result.isError == true)

        await client.disconnect()
    }

    // MARK: - Multiple Elicitations Tests

    @Test("Server can perform multiple sequential elicitations")
    func testMultipleSequentialElicitations() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "wizard", description: "Multi-step wizard", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            // Step 1: Get name
            let step1 = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Step 1: Enter name",
                requestedSchema: ElicitationSchema(
                    properties: ["name": .string(StringSchema())],
                    required: ["name"]
                )
            )))

            guard step1.action == .accept, let name = step1.content?["name"]?.stringValue else {
                return CallTool.Result(content: [.text("Cancelled at step 1")])
            }

            // Step 2: Get age
            let step2 = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Step 2: Enter age",
                requestedSchema: ElicitationSchema(
                    properties: ["age": .number(NumberSchema(isInteger: true))],
                    required: ["age"]
                )
            )))

            guard step2.action == .accept, let age = step2.content?["age"]?.intValue else {
                return CallTool.Result(content: [.text("Cancelled at step 2")])
            }

            return CallTool.Result(content: [.text("Completed: \(name), \(age)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func getCount() -> Int { count }
        }
        let counter = Counter()

        await client.withElicitationHandler { params, _ in
            await counter.increment()
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }

            if formParams.message.contains("Step 1") {
                return ElicitResult(action: .accept, content: ["name": .string("Charlie")])
            } else if formParams.message.contains("Step 2") {
                return ElicitResult(action: .accept, content: ["age": .int(25)])
            }

            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "wizard", arguments: [:])

        #expect(await counter.getCount() == 2)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Completed: Charlie, 25")
        }

        await client.disconnect()
    }

    // MARK: - Enum Schema Tests

    @Test("Form elicitation with titled enum")
    func testFormElicitationWithTitledEnum() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "pickColor", description: "Pick a color", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Choose your color",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "color": .titledEnum(TitledEnumSchema(
                            title: "Color",
                            oneOf: [
                                TitledEnumOption(const: "#FF0000", title: "Red"),
                                TitledEnumOption(const: "#00FF00", title: "Green"),
                                TitledEnumOption(const: "#0000FF", title: "Blue"),
                            ]
                        ))
                    ],
                    required: ["color"]
                )
            )))

            guard result.action == .accept, let color = result.content?["color"]?.stringValue else {
                return CallTool.Result(content: [.text("No color")])
            }

            return CallTool.Result(content: [.text("Color: \(color)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }

            // Verify enum options are present
            if case .titledEnum(let enumSchema) = formParams.requestedSchema.properties["color"] {
                #expect(enumSchema.oneOf.count == 3)
                #expect(enumSchema.oneOf[0].title == "Red")
            }

            return ElicitResult(action: .accept, content: ["color": .string("#00FF00")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "pickColor", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Color: #00FF00")
        }

        await client.disconnect()
    }

    @Test("Form elicitation with multi-select enum")
    func testFormElicitationWithMultiSelect() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "selectTags", description: "Select tags", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Select your interests",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "interests": .titledMultiSelect(TitledMultiSelectEnumSchema(
                            title: "Interests",
                            options: [
                                TitledEnumOption(const: "tech", title: "Technology"),
                                TitledEnumOption(const: "sports", title: "Sports"),
                                TitledEnumOption(const: "music", title: "Music"),
                            ]
                        ))
                    ]
                )
            )))

            guard result.action == .accept,
                  let interests = result.content?["interests"]?.stringsValue else {
                return CallTool.Result(content: [.text("No interests")])
            }

            return CallTool.Result(content: [.text("Interests: \(interests.joined(separator: ", "))")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .accept, content: ["interests": .strings(["tech", "music"])])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "selectTags", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Interests: tech, music")
        }

        await client.disconnect()
    }

    // MARK: - URL Mode Decline/Cancel Tests

    @Test("Server can elicit URL authorization from client - decline")
    func testURLElicitationDecline() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                message: "Please authorize access",
                elicitationId: "auth-decline-123",
                url: "https://example.com/oauth"
            )))

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Authorized")])
            case .decline: CallTool.Result(content: [.text("User declined authorization")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url(let urlParams) = params else {
                return ElicitResult(action: .cancel)
            }
            #expect(urlParams.elicitationId == "auth-decline-123")
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "User declined authorization")
        }

        await client.disconnect()
    }

    @Test("Server can elicit URL authorization from client - cancel")
    func testURLElicitationCancel() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                message: "Please authorize access",
                elicitationId: "auth-cancel-456",
                url: "https://example.com/oauth"
            )))

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Authorized")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("User cancelled authorization")])
            }
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url = params else {
                return ElicitResult(action: .decline)
            }
            return ElicitResult(action: .cancel)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "User cancelled authorization")
        }

        await client.disconnect()
    }

    @Test("URL mode elicitation response should not include content")
    func testURLElicitationNoContent() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "checkContent", description: "Check content", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                message: "Complete authorization",
                elicitationId: "content-check-789",
                url: "https://example.com/auth"
            )))

            // URL mode responses should not have content
            let hasContent = result.content != nil
            return CallTool.Result(content: [.text("Action: \(result.action.rawValue), HasContent: \(hasContent)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url = params else {
                return ElicitResult(action: .decline)
            }
            // URL mode should return accept without content
            return ElicitResult(action: .accept)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "checkContent", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Action: accept, HasContent: false")
        }

        await client.disconnect()
    }

    // MARK: - Legacy Enum Format Tests

    @Test("Form elicitation with legacy enumNames format")
    func testFormElicitationWithLegacyEnumNames() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "pickColor", description: "Pick a color", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Choose your color",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "color": .legacyTitledEnum(LegacyTitledEnumSchema(
                            title: "Color",
                            description: "Choose your favorite color",
                            enumValues: ["#FF0000", "#00FF00", "#0000FF"],
                            enumNames: ["Red", "Green", "Blue"],
                            defaultValue: "#00FF00"
                        ))
                    ],
                    required: ["color"]
                )
            )))

            guard result.action == .accept, let color = result.content?["color"]?.stringValue else {
                return CallTool.Result(content: [.text("No color selected")])
            }

            return CallTool.Result(content: [.text("Selected color: \(color)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }

            // Verify legacy enum schema is decoded correctly
            if case .legacyTitledEnum(let enumSchema) = formParams.requestedSchema.properties["color"] {
                #expect(enumSchema.enumValues == ["#FF0000", "#00FF00", "#0000FF"])
                #expect(enumSchema.enumNames == ["Red", "Green", "Blue"])
                #expect(enumSchema.defaultValue == "#00FF00")
            }

            // Return the const value, not the display name
            return ElicitResult(action: .accept, content: ["color": .string("#FF0000")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "pickColor", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Selected color: #FF0000")
        }

        await client.disconnect()
    }

    // MARK: - Optional Fields Tests

    @Test("Form elicitation with optional fields - all provided")
    func testFormElicitationOptionalFieldsAllProvided() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "userInfo", description: "Get user info", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Please provide your information",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "name": .string(StringSchema(title: "Name", description: "Your name (required)")),
                        "nickname": .string(StringSchema(title: "Nickname", description: "Optional nickname")),
                        "age": .number(NumberSchema(isInteger: true, title: "Age", description: "Optional age")),
                        "subscribe": .boolean(BooleanSchema(title: "Subscribe", description: "Optional subscription")),
                    ],
                    required: ["name"]  // Only name is required
                )
            )))

            guard result.action == .accept, let content = result.content else {
                return CallTool.Result(content: [.text("No response")])
            }

            var parts: [String] = []
            if let name = content["name"]?.stringValue {
                parts.append("Name: \(name)")
            }
            if let nickname = content["nickname"]?.stringValue {
                parts.append("Nickname: \(nickname)")
            }
            if let age = content["age"]?.intValue {
                parts.append("Age: \(age)")
            }
            if let subscribe = content["subscribe"]?.boolValue {
                parts.append("Subscribe: \(subscribe)")
            }

            return CallTool.Result(content: [.text(parts.joined(separator: ", "))])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(
                action: .accept,
                content: [
                    "name": .string("John Doe"),
                    "nickname": .string("Johnny"),
                    "age": .int(30),
                    "subscribe": .bool(true),
                ]
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "userInfo", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Name: John Doe"))
            #expect(text.contains("Nickname: Johnny"))
            #expect(text.contains("Age: 30"))
            #expect(text.contains("Subscribe: true"))
        }

        await client.disconnect()
    }

    @Test("Form elicitation with optional fields - only required provided")
    func testFormElicitationOptionalFieldsOnlyRequired() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "userInfo", description: "Get user info", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Please provide your information",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "name": .string(StringSchema(title: "Name")),
                        "nickname": .string(StringSchema(title: "Nickname")),
                        "email": .string(StringSchema(title: "Email", format: .email)),
                    ],
                    required: ["name"]
                )
            )))

            guard result.action == .accept, let content = result.content else {
                return CallTool.Result(content: [.text("No response")])
            }

            let name = content["name"]?.stringValue ?? "unknown"
            let hasNickname = content["nickname"] != nil
            let hasEmail = content["email"] != nil

            return CallTool.Result(content: [.text("Name: \(name), HasNickname: \(hasNickname), HasEmail: \(hasEmail)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            // Only provide the required field
            return ElicitResult(action: .accept, content: ["name": .string("Jane Smith")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "userInfo", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Name: Jane Smith, HasNickname: false, HasEmail: false")
        }

        await client.disconnect()
    }

    // MARK: - Default Values Tests

    @Test("Schema default values are included in encoded JSON")
    func testSchemaDefaultValuesEncoding() throws {
        let schema = ElicitationSchema(
            properties: [
                "name": .string(StringSchema(title: "Name", defaultValue: "Guest")),
                "age": .number(NumberSchema(isInteger: true, title: "Age", defaultValue: 18)),
                "subscribe": .boolean(BooleanSchema(title: "Subscribe", defaultValue: true)),
                "color": .untitledEnum(UntitledEnumSchema(
                    title: "Color",
                    enumValues: ["red", "green", "blue"],
                    defaultValue: "green"
                )),
                "interests": .untitledMultiSelect(UntitledMultiSelectEnumSchema(
                    title: "Interests",
                    enumValues: ["tech", "sports", "music"],
                    defaultValue: ["tech", "music"]
                )),
            ],
            required: ["name"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let json = String(data: data, encoding: .utf8)!

        // Verify defaults are present in the encoded JSON
        #expect(json.contains("\"default\":\"Guest\""))
        #expect(json.contains("\"default\":18"))
        #expect(json.contains("\"default\":true"))
        #expect(json.contains("\"default\":\"green\""))
        #expect(json.contains("\"default\":[\"tech\",\"music\"]"))
    }

    @Test("Form elicitation with default values in schema")
    func testFormElicitationWithDefaultValues() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "preferences", description: "Get preferences", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Set your preferences",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "email": .string(StringSchema(title: "Email", format: .email)),
                        "nickname": .string(StringSchema(title: "Nickname", defaultValue: "Guest")),
                        "volume": .number(NumberSchema(isInteger: true, title: "Volume", minimum: 0, maximum: 100, defaultValue: 50)),
                        "darkMode": .boolean(BooleanSchema(title: "Dark Mode", defaultValue: false)),
                    ],
                    required: ["email"]
                )
            )))

            guard result.action == .accept, let content = result.content else {
                return CallTool.Result(content: [.text("No response")])
            }

            let email = content["email"]?.stringValue ?? "none"
            let nickname = content["nickname"]?.stringValue ?? "Guest"  // Use default if not provided
            let volume = content["volume"]?.intValue ?? 50  // Use default if not provided
            let darkMode = content["darkMode"]?.boolValue ?? false  // Use default if not provided

            return CallTool.Result(content: [.text("Email: \(email), Nickname: \(nickname), Volume: \(volume), DarkMode: \(darkMode)")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { params, _ in
            // Verify the schema contains default values
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }

            if case .string(let nicknameSchema) = formParams.requestedSchema.properties["nickname"] {
                #expect(nicknameSchema.defaultValue == "Guest")
            }
            if case .number(let volumeSchema) = formParams.requestedSchema.properties["volume"] {
                #expect(volumeSchema.defaultValue == 50)
            }
            if case .boolean(let darkModeSchema) = formParams.requestedSchema.properties["darkMode"] {
                #expect(darkModeSchema.defaultValue == false)
            }

            // Client provides only email, using defaults for others
            return ElicitResult(action: .accept, content: ["email": .string("test@example.com")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "preferences", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Email: test@example.com, Nickname: Guest, Volume: 50, DarkMode: false")
        }

        await client.disconnect()
    }

    // MARK: - Complex Schema Tests (matching TypeScript SDK)

    @Test("Form elicitation with complex object - multiple fields like TypeScript SDK")
    func testFormElicitationComplexObject() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "userProfile", description: "Get user profile", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                message: "Please provide your information",
                requestedSchema: ElicitationSchema(
                    properties: [
                        "name": .string(StringSchema(title: "Name", minLength: 1)),
                        "email": .string(StringSchema(title: "Email", format: .email)),
                        "age": .number(NumberSchema(isInteger: true, title: "Age", minimum: 0, maximum: 150)),
                        "street": .string(StringSchema(title: "Street")),
                        "city": .string(StringSchema(title: "City")),
                        "zipCode": .string(StringSchema(title: "Zip Code")),
                        "newsletter": .boolean(BooleanSchema(title: "Newsletter")),
                        "notifications": .boolean(BooleanSchema(title: "Notifications")),
                    ],
                    required: ["name", "email", "age", "street", "city", "zipCode"]
                )
            )))

            guard result.action == .accept, let content = result.content else {
                return CallTool.Result(content: [.text("No response")])
            }

            let name = content["name"]?.stringValue ?? ""
            let email = content["email"]?.stringValue ?? ""
            let age = content["age"]?.intValue ?? 0
            let city = content["city"]?.stringValue ?? ""
            let zipCode = content["zipCode"]?.stringValue ?? ""
            let newsletter = content["newsletter"]?.boolValue ?? false

            return CallTool.Result(content: [.text(
                "\(name), \(email), \(age), \(city), \(zipCode), newsletter=\(newsletter)"
            )])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(
                action: .accept,
                content: [
                    "name": .string("Jane Smith"),
                    "email": .string("jane@example.com"),
                    "age": .int(28),
                    "street": .string("123 Main St"),
                    "city": .string("San Francisco"),
                    "zipCode": .string("94105"),
                    "newsletter": .bool(true),
                    "notifications": .bool(false),
                ]
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "userProfile", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Jane Smith, jane@example.com, 28, San Francisco, 94105, newsletter=true")
        }

        await client.disconnect()
    }
}

// MARK: - Additional Schema Encoding Tests

@Suite("LegacyTitledEnumSchema Tests")
struct LegacyTitledEnumSchemaTests {

    @Test("LegacyTitledEnumSchema encodes and decodes correctly")
    func testLegacyTitledEnumSchemaRoundtrip() throws {
        let schema = LegacyTitledEnumSchema(
            title: "Priority",
            description: "Select priority level",
            enumValues: ["low", "medium", "high"],
            enumNames: ["Low Priority", "Medium Priority", "High Priority"],
            defaultValue: "medium"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(LegacyTitledEnumSchema.self, from: data)

        #expect(decoded.title == "Priority")
        #expect(decoded.description == "Select priority level")
        #expect(decoded.enumValues == ["low", "medium", "high"])
        #expect(decoded.enumNames == ["Low Priority", "Medium Priority", "High Priority"])
        #expect(decoded.defaultValue == "medium")
    }

    @Test("LegacyTitledEnumSchema decodes via PrimitiveSchemaDefinition")
    func testLegacyTitledEnumSchemaDecodingViaPrimitive() throws {
        let json = """
        {
            "type": "string",
            "title": "Status",
            "enum": ["active", "inactive", "pending"],
            "enumNames": ["Active", "Inactive", "Pending"],
            "default": "pending"
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrimitiveSchemaDefinition.self, from: data)

        guard case .legacyTitledEnum(let schema) = decoded else {
            Issue.record("Expected legacyTitledEnum")
            return
        }

        #expect(schema.title == "Status")
        #expect(schema.enumValues == ["active", "inactive", "pending"])
        #expect(schema.enumNames == ["Active", "Inactive", "Pending"])
        #expect(schema.defaultValue == "pending")
    }
}

// MARK: - ElicitationCompleteNotification Tests

@Suite("ElicitationCompleteNotification Tests")
struct ElicitationCompleteNotificationTests {

    @Test("ElicitationCompleteNotification name is correct")
    func testNotificationName() {
        #expect(ElicitationCompleteNotification.name == "notifications/elicitation/complete")
    }

    @Test("ElicitationCompleteNotification parameters encode correctly")
    func testNotificationParametersEncoding() throws {
        let params = ElicitationCompleteNotification.Parameters(
            elicitationId: "test-elicitation-123"
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ElicitationCompleteNotification.Parameters.self, from: data)

        #expect(decoded.elicitationId == "test-elicitation-123")
    }

    @Test("ElicitationCompleteNotification message encoding")
    func testNotificationMessageEncoding() throws {
        let notification = ElicitationCompleteNotification.message(
            ElicitationCompleteNotification.Parameters(elicitationId: "complete-456")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(notification)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"method\":\"notifications/elicitation/complete\""))
        #expect(json.contains("\"elicitationId\":\"complete-456\""))
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
    }
}

// MARK: - Untitled Enum Schema Tests

@Suite("UntitledEnumSchema Tests")
struct UntitledEnumSchemaTests {

    @Test("UntitledEnumSchema with minItems/maxItems constraints")
    func testUntitledMultiSelectWithConstraints() throws {
        let schema = UntitledMultiSelectEnumSchema(
            title: "Tags",
            description: "Select 1-3 tags",
            minItems: 1,
            maxItems: 3,
            enumValues: ["tag1", "tag2", "tag3", "tag4", "tag5"],
            defaultValue: ["tag1"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(UntitledMultiSelectEnumSchema.self, from: data)

        #expect(decoded.title == "Tags")
        #expect(decoded.minItems == 1)
        #expect(decoded.maxItems == 3)
        #expect(decoded.items.enumValues == ["tag1", "tag2", "tag3", "tag4", "tag5"])
        #expect(decoded.defaultValue == ["tag1"])
    }
}

// MARK: - Additional Capability Tests

@Suite("Elicitation Capability applyDefaults Tests")
struct ElicitationCapabilityApplyDefaultsTests {

    @Test("Form capability with applyDefaults encodes correctly")
    func testFormCapabilityWithApplyDefaults() throws {
        let capability = Client.Capabilities.Elicitation(
            form: Client.Capabilities.Elicitation.Form(applyDefaults: true)
        )

        let data = try JSONEncoder().encode(capability)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("applyDefaults"))
        #expect(json.contains("true"))

        let decoded = try JSONDecoder().decode(Client.Capabilities.Elicitation.self, from: data)
        #expect(decoded.form?.applyDefaults == true)
    }

    @Test("Form capability with applyDefaults false encodes correctly")
    func testFormCapabilityWithApplyDefaultsFalse() throws {
        let capability = Client.Capabilities.Elicitation(
            form: Client.Capabilities.Elicitation.Form(applyDefaults: false)
        )

        let data = try JSONEncoder().encode(capability)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Elicitation.self, from: data)

        #expect(decoded.form?.applyDefaults == false)
    }
}

// MARK: - URLElicitationRequiredError Tests

@Suite("URLElicitationRequiredError Tests")
struct URLElicitationRequiredErrorTests {

    @Test("MCPError.urlElicitationRequired creates error with correct code")
    func testErrorCode() {
        let error = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Please authorize",
                    elicitationId: "auth-123",
                    url: "https://example.com/oauth"
                )
            ]
        )

        #expect(error.code == ErrorCode.urlElicitationRequired)
    }

    @Test("MCPError.urlElicitationRequired default message")
    func testDefaultMessage() {
        let singleError = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Authorize",
                    elicitationId: "auth-1",
                    url: "https://example.com/auth"
                )
            ]
        )

        #expect(singleError.errorDescription == "URL elicitation required")

        let multipleError = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(message: "Auth 1", elicitationId: "a1", url: "https://example.com/1"),
                ElicitRequestURLParams(message: "Auth 2", elicitationId: "a2", url: "https://example.com/2"),
            ]
        )

        #expect(multipleError.errorDescription == "URL elicitations required")
    }

    @Test("MCPError.urlElicitationRequired custom message")
    func testCustomMessage() {
        let error = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Authorize",
                    elicitationId: "auth-1",
                    url: "https://example.com/auth"
                )
            ],
            message: "Custom authorization required"
        )

        #expect(error.errorDescription == "Custom authorization required")
    }

    @Test("MCPError.urlElicitationRequired elicitations accessor")
    func testElicitationsAccessor() {
        let elicitations = [
            ElicitRequestURLParams(message: "Auth 1", elicitationId: "a1", url: "https://example.com/1"),
            ElicitRequestURLParams(message: "Auth 2", elicitationId: "a2", url: "https://example.com/2"),
        ]

        let error = MCPError.urlElicitationRequired(elicitations: elicitations)

        #expect(error.elicitations?.count == 2)
        #expect(error.elicitations?[0].elicitationId == "a1")
        #expect(error.elicitations?[1].elicitationId == "a2")
    }

    @Test("MCPError.urlElicitationRequired encodes correctly to JSON")
    func testEncoding() throws {
        let error = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Please authorize",
                    elicitationId: "auth-123",
                    url: "https://example.com/oauth"
                )
            ],
            message: "Authorization required"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(error)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"code\":-32042"))
        #expect(json.contains("\"message\":\"Authorization required\""))
        #expect(json.contains("\"elicitations\""))
        #expect(json.contains("\"elicitationId\":\"auth-123\""))
        #expect(json.contains("\"url\":\"https://example.com/oauth\""))
    }

    @Test("MCPError.urlElicitationRequired decodes correctly from JSON")
    func testDecoding() throws {
        let json = """
        {
            "code": -32042,
            "message": "Authorization required",
            "data": {
                "elicitations": [
                    {
                        "mode": "url",
                        "message": "Please authorize",
                        "elicitationId": "auth-456",
                        "url": "https://example.com/authorize"
                    }
                ]
            }
        }
        """

        let data = json.data(using: .utf8)!
        let error = try JSONDecoder().decode(MCPError.self, from: data)

        #expect(error.code == ErrorCode.urlElicitationRequired)
        #expect(error.elicitations?.count == 1)
        #expect(error.elicitations?[0].elicitationId == "auth-456")
        #expect(error.elicitations?[0].url == "https://example.com/authorize")
    }

    @Test("MCPError.urlElicitationRequired roundtrip encoding")
    func testRoundtrip() throws {
        let original = MCPError.urlElicitationRequired(
            elicitations: [
                ElicitRequestURLParams(
                    message: "Authorize OAuth",
                    elicitationId: "oauth-789",
                    url: "https://provider.com/oauth/authorize"
                )
            ],
            message: "OAuth authorization needed"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)

        #expect(decoded.code == original.code)
        #expect(decoded.errorDescription == original.errorDescription)
        #expect(decoded.elicitations?.count == original.elicitations?.count)
        #expect(decoded.elicitations?[0].elicitationId == original.elicitations?[0].elicitationId)
    }

    @Test("MCPError.fromError reconstructs urlElicitationRequired")
    func testFromError() {
        let data: Value = .object([
            "elicitations": .array([
                .object([
                    "mode": .string("url"),
                    "message": .string("Authorize access"),
                    "elicitationId": .string("from-error-123"),
                    "url": .string("https://example.com/auth"),
                ])
            ])
        ])

        let error = MCPError.fromError(
            code: ErrorCode.urlElicitationRequired,
            message: "Elicitation required",
            data: data
        )

        #expect(error.code == ErrorCode.urlElicitationRequired)
        #expect(error.elicitations?.count == 1)
        #expect(error.elicitations?[0].elicitationId == "from-error-123")
    }

    @Test("MCPError.fromError falls back to serverError for invalid data")
    func testFromErrorFallback() {
        let error = MCPError.fromError(
            code: ErrorCode.urlElicitationRequired,
            message: "Elicitation required",
            data: nil
        )

        // Should fall back to serverError when data is missing
        if case .serverError(let code, let message) = error {
            #expect(code == ErrorCode.urlElicitationRequired)
            #expect(message == "Elicitation required")
        } else {
            Issue.record("Expected serverError fallback")
        }
    }

    @Test("Tool handler can throw URLElicitationRequiredError")
    func testThrowFromToolHandler() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "requiresAuth", description: "Requires auth", inputSchema: [:])
            ])
        }

        // Tool handler throws URLElicitationRequiredError
        await server.withRequestHandler(CallTool.self) { _, _ in
            throw MCPError.urlElicitationRequired(
                elicitations: [
                    ElicitRequestURLParams(
                        message: "Please authorize access to your files",
                        elicitationId: "file-access-auth",
                        url: "https://files.example.com/oauth"
                    )
                ],
                message: "Authorization required to access files"
            )
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        do {
            _ = try await client.callTool(name: "requiresAuth", arguments: [:])
            Issue.record("Expected error to be thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.urlElicitationRequired)
            #expect(error.elicitations?.count == 1)
            #expect(error.elicitations?[0].elicitationId == "file-access-auth")
            #expect(error.elicitations?[0].url == "https://files.example.com/oauth")
        }

        await client.disconnect()
    }

    @Test("Client receives URLElicitationRequiredError with multiple elicitations")
    func testMultipleElicitations() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "multiAuth", description: "Multiple auth", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            throw MCPError.urlElicitationRequired(
                elicitations: [
                    ElicitRequestURLParams(
                        message: "Authorize Google Drive",
                        elicitationId: "google-drive",
                        url: "https://accounts.google.com/oauth"
                    ),
                    ElicitRequestURLParams(
                        message: "Authorize Dropbox",
                        elicitationId: "dropbox",
                        url: "https://www.dropbox.com/oauth"
                    ),
                    ElicitRequestURLParams(
                        message: "Authorize OneDrive",
                        elicitationId: "onedrive",
                        url: "https://login.microsoftonline.com/oauth"
                    ),
                ],
                message: "Multiple cloud storage authorizations required"
            )
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        do {
            _ = try await client.callTool(name: "multiAuth", arguments: [:])
            Issue.record("Expected error to be thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.urlElicitationRequired)
            #expect(error.elicitations?.count == 3)
            #expect(error.elicitations?[0].elicitationId == "google-drive")
            #expect(error.elicitations?[1].elicitationId == "dropbox")
            #expect(error.elicitations?[2].elicitationId == "onedrive")
        }

        await client.disconnect()
    }
}

// MARK: - ElicitationComplete Notification Integration Tests

/// Actor to track notification receipt in tests
private actor NotificationState {
    var received = false
    var elicitationId: String?
    var count = 0

    func markReceived(elicitationId: String? = nil) {
        received = true
        self.elicitationId = elicitationId
        count += 1
    }
}

@Suite("ElicitationComplete Notification Integration Tests")
struct ElicitationCompleteNotificationIntegrationTests {

    @Test("Server can send elicitation complete notification")
    func testServerSendsElicitationCompleteNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        let notificationState = NotificationState()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "completeAuth", description: "Complete auth", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Simulate async operation completion (e.g., user finished OAuth in browser)
            let elicitationId = "complete-test-123"

            // Send the completion notification
            try await context.sendMessage(ElicitationCompleteNotification.message(.init(
                elicitationId: elicitationId
            )))

            return CallTool.Result(content: [.text("Elicitation completed")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        // Set up notification handler
        await client.onNotification(ElicitationCompleteNotification.self) { [notificationState] message in
            await notificationState.markReceived(elicitationId: message.params.elicitationId)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "completeAuth", arguments: [:])

        // Verify tool result
        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Elicitation completed")
        }

        // Give time for notification to be processed
        try await Task.sleep(for: .milliseconds(50))

        // Verify notification was received
        let received = await notificationState.received
        let receivedId = await notificationState.elicitationId
        #expect(received == true)
        #expect(receivedId == "complete-test-123")

        await client.disconnect()
    }

    @Test("Server sends elicitation complete after URL mode elicitation")
    func testElicitationCompleteAfterURLElicitation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        let notificationState = NotificationState()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, context in
            // First, send a URL elicitation
            let elicitationId = "oauth-flow-456"
            let result = try await server.elicit(ElicitRequestParams.url(ElicitRequestURLParams(
                message: "Complete OAuth",
                elicitationId: elicitationId,
                url: "https://example.com/oauth"
            )))

            // After client responds, send completion notification
            if result.action == .accept {
                try await context.sendMessage(ElicitationCompleteNotification.message(.init(
                    elicitationId: elicitationId
                )))
            }

            return CallTool.Result(content: [.text("Authorization complete")])
        }

        let client = Client(name: "ElicitTestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url(let urlParams) = params else {
                return ElicitResult(action: .decline)
            }
            #expect(urlParams.elicitationId == "oauth-flow-456")
            return ElicitResult(action: .accept)
        }

        await client.onNotification(ElicitationCompleteNotification.self) { [notificationState] _ in
            await notificationState.markReceived()
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        if case .text(let text, _, _) = result.content[0] {
            #expect(text == "Authorization complete")
        }

        // Give time for notification to be processed
        try await Task.sleep(for: .milliseconds(50))

        let count = await notificationState.count
        #expect(count == 1)

        await client.disconnect()
    }
}

// MARK: - Task-Augmented Elicitation Tests

/// Actor to track task-augmented elicitation state
private actor TaskAugmentedState {
    var received = false
    var taskId: String?

    func markReceived(taskId: String) {
        received = true
        self.taskId = taskId
    }
}

@Suite("Task-Augmented Elicitation Tests")
struct TaskAugmentedElicitationTests {

    /// Helper to create a simple MCPTask for testing
    private static func makeTask(taskId: String, status: TaskStatus) -> MCPTask {
        let now = ISO8601DateFormatter().string(from: Date())
        return MCPTask(
            taskId: taskId,
            status: status,
            createdAt: now,
            lastUpdatedAt: now
        )
    }

    @Test("Client can register task-augmented elicitation handler")
    func testTaskAugmentedElicitationHandler() async throws {
        let elicitationState = TaskAugmentedState()

        let client = Client(name: "ElicitTestClient", version: "1.0.0")

        // Set up task-augmented elicitation handler
        var taskHandlers = ExperimentalClientTaskHandlers()
        taskHandlers.taskAugmentedElicitation = { [elicitationState] _, _ in
            let taskId = UUID().uuidString
            await elicitationState.markReceived(taskId: taskId)

            // Create a task to handle the elicitation
            return CreateTaskResult(task: Self.makeTask(taskId: taskId, status: .completed))
        }

        await client.enableTaskHandlers(ClientTaskSupport.inMemory(handlers: taskHandlers))

        // Verify the capability was built correctly
        let caps = await client.capabilities
        #expect(caps.tasks?.requests?.elicitation?.create != nil)
    }

    @Test("TaskAugmentedElicitationHandler type alias exists")
    func testTaskAugmentedElicitationHandlerType() {
        // Verify the type alias compiles correctly
        let handler: ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler = { _, _ in
            let taskId = UUID().uuidString
            return CreateTaskResult(task: Self.makeTask(taskId: taskId, status: .working))
        }

        // Just verify it compiles - the type system enforces correctness
        _ = handler
    }

    @Test("ExperimentalClientTaskHandlers builds correct capability for elicitation")
    func testBuildCapabilityWithElicitation() {
        var handlers = ExperimentalClientTaskHandlers()

        // With elicitation handler, capability should include requests.elicitation
        handlers.taskAugmentedElicitation = { _, _ in
            CreateTaskResult(task: Self.makeTask(taskId: UUID().uuidString, status: .completed))
        }

        let capability = handlers.buildCapability()
        #expect(capability != nil)
        #expect(capability?.requests?.elicitation?.create != nil)
    }

    @Test("ExperimentalClientTaskHandlers builds capability with both sampling and elicitation")
    func testBuildCapabilityWithBoth() {
        var handlers = ExperimentalClientTaskHandlers()

        handlers.taskAugmentedSampling = { _, _ in
            CreateTaskResult(task: Self.makeTask(taskId: UUID().uuidString, status: .completed))
        }

        handlers.taskAugmentedElicitation = { _, _ in
            CreateTaskResult(task: Self.makeTask(taskId: UUID().uuidString, status: .completed))
        }

        let capability = handlers.buildCapability()
        #expect(capability != nil)
        #expect(capability?.requests?.sampling?.createMessage != nil)
        #expect(capability?.requests?.elicitation?.create != nil)
    }

    @Test("hasTaskAugmentedElicitation returns correct value")
    func testHasTaskAugmentedElicitation() {
        // Without capability
        #expect(hasTaskAugmentedElicitation(nil) == false)

        // With empty capabilities
        let emptyCaps = Client.Capabilities()
        #expect(hasTaskAugmentedElicitation(emptyCaps) == false)

        // With tasks but no requests
        let withTasks = Client.Capabilities(tasks: .init())
        #expect(hasTaskAugmentedElicitation(withTasks) == false)

        // With requests but no elicitation
        let withRequests = Client.Capabilities(tasks: .init(requests: .init()))
        #expect(hasTaskAugmentedElicitation(withRequests) == false)

        // With elicitation.create
        let withElicitation = Client.Capabilities(
            tasks: .init(requests: .init(elicitation: .init(create: .init())))
        )
        #expect(hasTaskAugmentedElicitation(withElicitation) == true)
    }

    @Test("requireTaskAugmentedElicitation throws when not supported")
    func testRequireTaskAugmentedElicitation() {
        // Should throw when capability is nil
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedElicitation(nil)
        }

        // Should throw when tasks.requests.elicitation is nil
        let withoutElicitation = Client.Capabilities(tasks: .init())
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedElicitation(withoutElicitation)
        }

        // Should not throw when supported
        let withElicitation = Client.Capabilities(
            tasks: .init(requests: .init(elicitation: .init(create: .init())))
        )
        #expect(throws: Never.self) {
            try requireTaskAugmentedElicitation(withElicitation)
        }
    }
}
