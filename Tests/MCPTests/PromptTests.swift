import Foundation
import Testing

@testable import MCP

@Suite("Prompt Tests")
struct PromptTests {
    @Test("Prompt initialization with valid parameters")
    func testPromptInitialization() throws {
        let argument = Prompt.Argument(
            name: "test_arg",
            title: "Test Argument Title",
            description: "A test argument",
            required: true
        )

        let prompt = Prompt(
            name: "test_prompt",
            title: "Test Prompt Title",
            description: "A test prompt",
            arguments: [argument]
        )

        #expect(prompt.name == "test_prompt")
        #expect(prompt.title == "Test Prompt Title")
        #expect(prompt.description == "A test prompt")
        #expect(prompt.arguments?.count == 1)
        #expect(prompt.arguments?[0].name == "test_arg")
        #expect(prompt.arguments?[0].title == "Test Argument Title")
        #expect(prompt.arguments?[0].description == "A test argument")
        #expect(prompt.arguments?[0].required == true)
    }

    @Test("Prompt Message encoding and decoding")
    func testPromptMessageEncodingDecoding() throws {
        let textMessage: Prompt.Message = .user("Hello, world!")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(textMessage)
        let decoded = try decoder.decode(Prompt.Message.self, from: data)

        #expect(decoded.role == .user)
        if case .text(let text) = decoded.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Prompt Message Content types encoding and decoding")
    func testPromptMessageContentTypes() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text content
        let textContent = Prompt.Message.Content.text(text: "Test text")
        let textData = try encoder.encode(textContent)
        let decodedText = try decoder.decode(Prompt.Message.Content.self, from: textData)
        if case .text(let text) = decodedText {
            #expect(text == "Test text")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test audio content
        let audioContent = Prompt.Message.Content.audio(
            data: "base64audiodata", mimeType: "audio/wav")
        let audioData = try encoder.encode(audioContent)
        let decodedAudio = try decoder.decode(Prompt.Message.Content.self, from: audioData)
        if case .audio(let data, let mimeType) = decodedAudio {
            #expect(data == "base64audiodata")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }

        // Test image content
        let imageContent = Prompt.Message.Content.image(data: "base64data", mimeType: "image/png")
        let imageData = try encoder.encode(imageContent)
        let decodedImage = try decoder.decode(Prompt.Message.Content.self, from: imageData)
        if case .image(let data, let mimeType) = decodedImage {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }

        // Test resource content
        let textResourceContent = Resource.Content.text(
            "Sample text",
            uri: "file://test.txt",
            mimeType: "text/plain"
        )
        let resourceContent = Prompt.Message.Content.resource(resource: textResourceContent, annotations: nil, _meta: nil)
        let resourceData = try encoder.encode(resourceContent)
        let decodedResource = try decoder.decode(Prompt.Message.Content.self, from: resourceData)
        if case .resource(let resourceData, let annotations, let _meta) = decodedResource {
            #expect(resourceData.uri == "file://test.txt")
            #expect(resourceData.mimeType == "text/plain")
            #expect(resourceData.text == "Sample text")
            #expect(annotations == nil)
            #expect(_meta == nil)
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test("Prompt Reference validation")
    func testPromptReference() throws {
        let reference = Prompt.Reference(name: "test_prompt", title: "Test Prompt Title")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(Prompt.Reference.self, from: data)

        #expect(decoded == reference)
    }

    @Test("GetPrompt parameters validation")
    func testGetPromptParameters() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let arguments: [String: String] = [
            "param1": "value1",
            "param2": "42",
        ]

        let params = GetPrompt.Parameters(name: "test_prompt", arguments: arguments)
        let data = try encoder.encode(params)
        let decoded = try decoder.decode(GetPrompt.Parameters.self, from: data)

        #expect(decoded == params)
    }

    @Test("GetPrompt result validation")
    func testGetPromptResult() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let messages: [Prompt.Message] = [
            .user("User message"),
            .assistant("Assistant response"),
        ]

        let result = GetPrompt.Result(description: "Test description", messages: messages)
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(GetPrompt.Result.self, from: data)

        #expect(decoded == result)
    }

    @Test("ListPrompts parameters validation")
    func testListPromptsParameters() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let params = ListPrompts.Parameters(cursor: "next_page")
        let data = try encoder.encode(params)
        let decoded = try decoder.decode(ListPrompts.Parameters.self, from: data)

        #expect(decoded == params)

        let emptyParams = ListPrompts.Parameters()
        let emptyData = try encoder.encode(emptyParams)
        let decodedEmpty = try decoder.decode(ListPrompts.Parameters.self, from: emptyData)

        #expect(decodedEmpty == emptyParams)
    }

    @Test("ListPrompts request decoding with omitted params")
    func testListPromptsRequestDecodingWithOmittedParams() throws {
        // Test decoding when params field is omitted
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"prompts/list"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListPrompts>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListPrompts.name)
    }

    @Test("ListPrompts request decoding with null params")
    func testListPromptsRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"prompts/list","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListPrompts>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListPrompts.name)
    }

    @Test("ListPrompts result validation")
    func testListPromptsResult() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let prompts = [
            Prompt(name: "prompt1", description: "First prompt"),
            Prompt(name: "prompt2", description: "Second prompt"),
        ]

        let result = ListPrompts.Result(prompts: prompts, nextCursor: "next_page")
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListPrompts.Result.self, from: data)

        #expect(decoded == result)
    }

    @Test("PromptListChanged notification name validation")
    func testPromptListChangedNotification() throws {
        #expect(PromptListChangedNotification.name == "notifications/prompts/list_changed")
    }

    @Test("Prompt Message factory methods")
    func testPromptMessageFactoryMethods() throws {
        // Test user message factory method
        let userMessage: Prompt.Message = .user("Hello, world!")
        #expect(userMessage.role == .user)
        if case .text(let text) = userMessage.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message factory method
        let assistantMessage: Prompt.Message = .assistant("Hi there!")
        #expect(assistantMessage.role == .assistant)
        if case .text(let text) = assistantMessage.content {
            #expect(text == "Hi there!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test with image content
        let imageMessage: Prompt.Message = .user(.image(data: "base64data", mimeType: "image/png"))
        #expect(imageMessage.role == .user)
        if case .image(let data, let mimeType) = imageMessage.content {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }

        // Test with audio content
        let audioMessage: Prompt.Message = .assistant(
            .audio(data: "base64audio", mimeType: "audio/wav"))
        #expect(audioMessage.role == .assistant)
        if case .audio(let data, let mimeType) = audioMessage.content {
            #expect(data == "base64audio")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }

        // Test with resource content
        let resourceContent = Resource.Content.text(
            "Sample text",
            uri: "file://test.txt",
            mimeType: "text/plain"
        )
        let resourceMessage: Prompt.Message = .user(.resource(resource: resourceContent, annotations: nil, _meta: nil))
        #expect(resourceMessage.role == .user)
        if case .resource(let resource, let annotations, let _meta) = resourceMessage.content {
            #expect(resource.uri == "file://test.txt")
            #expect(resource.mimeType == "text/plain")
            #expect(resource.text == "Sample text")
            #expect(annotations == nil)
            #expect(_meta == nil)
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test("Prompt Content ExpressibleByStringLiteral")
    func testPromptContentExpressibleByStringLiteral() throws {
        // Test string literal assignment
        let content: Prompt.Message.Content = "Hello from string literal"

        if case .text(let text) = content {
            #expect(text == "Hello from string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation
        let message: Prompt.Message = .user("Direct string literal")
        if case .text(let text) = message.content {
            #expect(text == "Direct string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in array context
        let messages: [Prompt.Message] = [
            .user("First message"),
            .assistant("Second message"),
            .user("Third message"),
        ]

        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)
    }

    @Test("Prompt Content ExpressibleByStringInterpolation")
    func testPromptContentExpressibleByStringInterpolation() throws {
        let userName = "Alice"
        let position = "Software Engineer"
        let company = "TechCorp"

        // Test string interpolation
        let content: Prompt.Message.Content =
            "Hello \(userName), welcome to your \(position) interview at \(company)"

        if case .text(let text) = content {
            #expect(text == "Hello Alice, welcome to your Software Engineer interview at TechCorp")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation with interpolation
        let message: Prompt.Message = .user(
            "Hi \(userName), I'm excited about the \(position) role at \(company)")
        if case .text(let text) = message.content {
            #expect(text == "Hi Alice, I'm excited about the Software Engineer role at TechCorp")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test complex interpolation
        let skills = ["Swift", "Python", "JavaScript"]
        let experience = 5
        let interviewMessage: Prompt.Message = .assistant(
            "I see you have \(experience) years of experience with \(skills.joined(separator: ", ")). That's impressive!"
        )

        if case .text(let text) = interviewMessage.content {
            #expect(
                text
                    == "I see you have 5 years of experience with Swift, Python, JavaScript. That's impressive!"
            )
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Prompt Message factory methods with string interpolation")
    func testPromptMessageFactoryMethodsWithStringInterpolation() throws {
        let candidateName = "Bob"
        let position = "Data Scientist"
        let company = "DataCorp"
        let experience = 3

        // Test user message with interpolation
        let userMessage: Prompt.Message = .user(
            "Hello, I'm \(candidateName) and I'm interviewing for the \(position) position")
        #expect(userMessage.role == .user)
        if case .text(let text) = userMessage.content {
            #expect(text == "Hello, I'm Bob and I'm interviewing for the Data Scientist position")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message with interpolation
        let assistantMessage: Prompt.Message = .assistant(
            "Welcome \(candidateName)! Tell me about your \(experience) years of experience in data science"
        )
        #expect(assistantMessage.role == .assistant)
        if case .text(let text) = assistantMessage.content {
            #expect(text == "Welcome Bob! Tell me about your 3 years of experience in data science")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in conversation array
        let conversation: [Prompt.Message] = [
            .user("Hi, I'm \(candidateName) applying for \(position) at \(company)"),
            .assistant("Welcome \(candidateName)! How many years of experience do you have?"),
            .user("I have \(experience) years of experience in the field"),
            .assistant(
                "Great! \(experience) years is solid experience for a \(position) role at \(company)"
            ),
        ]

        #expect(conversation.count == 4)

        // Verify interpolated content
        if case .text(let text) = conversation[2].content {
            #expect(text == "I have 3 years of experience in the field")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Prompt ergonomic API usage patterns")
    func testPromptErgonomicAPIUsagePatterns() throws {
        // Test various ergonomic usage patterns enabled by the new API

        // Pattern 1: Simple interview conversation
        let interviewConversation: [Prompt.Message] = [
            .user("Tell me about yourself"),
            .assistant("I'm a software engineer with 5 years of experience"),
            .user("What's your biggest strength?"),
            .assistant("I'm great at problem-solving and team collaboration"),
        ]
        #expect(interviewConversation.count == 4)

        // Pattern 2: Dynamic content with interpolation
        let candidateName = "Sarah"
        let role = "Product Manager"
        let yearsExp = 7

        let dynamicConversation: [Prompt.Message] = [
            .user("Welcome \(candidateName) to the \(role) interview"),
            .assistant("Thank you! I'm excited about this \(role) opportunity"),
            .user("I see you have \(yearsExp) years of experience. Tell me about your background"),
            .assistant(
                "In my \(yearsExp) years as a \(role), I've led multiple successful product launches"
            ),
        ]
        #expect(dynamicConversation.count == 4)

        // Pattern 3: Mixed content types
        let mixedContent: [Prompt.Message] = [
            .user("Please review this design mockup"),
            .assistant(.image(data: "design_mockup_data", mimeType: "image/png")),
            .user("What do you think of the user flow?"),
            .assistant(
                "The design looks clean and intuitive. I particularly like the navigation structure."
            ),
        ]
        #expect(mixedContent.count == 4)

        // Verify content types
        if case .text = mixedContent[0].content,
            case .image = mixedContent[1].content,
            case .text = mixedContent[2].content,
            case .text = mixedContent[3].content
        {
            // All content types are correct
        } else {
            #expect(Bool(false), "Content types don't match expected pattern")
        }

        // Pattern 4: Encoding/decoding still works
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(interviewConversation)
        let decoded = try decoder.decode([Prompt.Message].self, from: data)

        #expect(decoded.count == 4)
        #expect(decoded[0].role == .user)
        #expect(decoded[1].role == .assistant)
        #expect(decoded[2].role == .user)
        #expect(decoded[3].role == .assistant)
    }
}

@Suite("Prompt Integration Tests")
struct PromptIntegrationTests {

    @Test("List prompts with empty results")
    func testListPromptsEmpty() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        // Register list prompts handler
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: [])
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let (prompts, nextCursor) = try await client.listPrompts()

        #expect(prompts.isEmpty)
        #expect(nextCursor == nil)

        await server.stop()
        await client.disconnect()
    }

    @Test("List prompts with multiple results")
    func testListPromptsWithResults() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        let expectedPrompts = [
            Prompt(
                name: "greeting",
                title: "Greeting Prompt",
                description: "A friendly greeting prompt"
            ),
            Prompt(
                name: "interview",
                title: "Interview Prompt",
                description: "An interview preparation prompt",
                arguments: [
                    Prompt.Argument(
                        name: "position",
                        title: "Job Position",
                        description: "The job position to interview for",
                        required: true
                    )
                ]
            ),
        ]

        // Register list prompts handler
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: expectedPrompts, nextCursor: "page2")
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let (prompts, nextCursor) = try await client.listPrompts()

        #expect(prompts == expectedPrompts)
        #expect(nextCursor == "page2")

        await server.stop()
        await client.disconnect()
    }

    @Test("Get prompt with messages")
    func testGetPrompt() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        let expectedMessages: [Prompt.Message] = [
            .user("Hello, I'd like to schedule an interview for the Software Engineer position"),
            .assistant("I'd be happy to help you prepare for the Software Engineer interview. Let's discuss your background."),
        ]

        // Register get prompt handler
        await server.withMethodHandler(GetPrompt.self) { params in
            #expect(params.name == "interview")
            #expect(params.arguments?["position"] == "Software Engineer")

            return GetPrompt.Result(
                description: "Interview preparation prompt",
                messages: expectedMessages
            )
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let (description, messages) = try await client.getPrompt(
            name: "interview",
            arguments: ["position": "Software Engineer"]
        )

        #expect(description == "Interview preparation prompt")
        #expect(messages == expectedMessages)

        await server.stop()
        await client.disconnect()
    }

    @Test("Get prompt with mixed content types")
    func testGetPromptMixedContent() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        let expectedMessages: [Prompt.Message] = [
            .user("Please review this design mockup:"),
            .user(.image(data: "base64_image_data", mimeType: "image/png")),
            .assistant("I'll analyze the design mockup for you."),
            .assistant(.audio(data: "base64_audio_data", mimeType: "audio/mp3")),
        ]

        // Register get prompt handler
        await server.withMethodHandler(GetPrompt.self) { params in
            #expect(params.name == "design_review")

            return GetPrompt.Result(
                description: "Design review prompt with multimedia",
                messages: expectedMessages
            )
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let (description, messages) = try await client.getPrompt(name: "design_review")

        #expect(description == "Design review prompt with multimedia")
        #expect(messages == expectedMessages)

        await server.stop()
        await client.disconnect()
    }

    @Test("Prompt with resource content")
    func testPromptWithResourceContent() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        let resourceContent = Resource.Content.text(
            "Code review content",
            uri: "file://code.swift",
            mimeType: "text/plain"
        )

        let expectedMessages: [Prompt.Message] = [
            .user("Review this code:"),
            .user(.resource(resource: resourceContent, annotations: nil, _meta: nil)),
            .assistant("I'll review the code for you."),
        ]

        // Register get prompt handler
        await server.withMethodHandler(GetPrompt.self) { _ in
            GetPrompt.Result(
                description: "Code review prompt",
                messages: expectedMessages
            )
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let (description, messages) = try await client.getPrompt(name: "code_review")

        #expect(description == "Code review prompt")
        #expect(messages == expectedMessages)

        await server.stop()
        await client.disconnect()
    }

    @Test("List prompts with pagination")
    func testListPromptsWithPagination() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
        )

        // Register list prompts handler with pagination
        await server.withMethodHandler(ListPrompts.self) { params in
            if let cursor = params.cursor {
                #expect(cursor == "page2")
                return ListPrompts.Result(
                    prompts: [
                        Prompt(name: "prompt3", description: "Third prompt"),
                        Prompt(name: "prompt4", description: "Fourth prompt"),
                    ],
                    nextCursor: nil
                )
            } else {
                return ListPrompts.Result(
                    prompts: [
                        Prompt(name: "prompt1", description: "First prompt"),
                        Prompt(name: "prompt2", description: "Second prompt"),
                    ],
                    nextCursor: "page2"
                )
            }
        }

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // First page
        let (page1Prompts, page1Cursor) = try await client.listPrompts()
        #expect(page1Prompts.count == 2)
        #expect(page1Prompts[0].name == "prompt1")
        #expect(page1Prompts[1].name == "prompt2")
        #expect(page1Cursor == "page2")

        // Second page
        let (page2Prompts, page2Cursor) = try await client.listPrompts(cursor: "page2")
        #expect(page2Prompts.count == 2)
        #expect(page2Prompts[0].name == "prompt3")
        #expect(page2Prompts[1].name == "prompt4")
        #expect(page2Cursor == nil)

        await server.stop()
        await client.disconnect()
    }

    @Test("Prompt without capability fails")
    func testPromptWithoutCapabilityFails() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT prompts capability
        let server = Server(
            name: "PromptTestServer",
            version: "1.0"
        )

        let client = Client(
            name: "PromptTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should throw an error because server doesn't have prompts capability
        await #expect(throws: MCPError.self) {
            _ = try await client.listPrompts()
        }

        await server.stop()
        await client.disconnect()
    }

    @Test("Strict mode succeeds when server declares prompts capability")
    func testPromptStrictCapabilitiesSuccess() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "StrictPromptTestServer",
            version: "1.0",
            capabilities: .init(prompts: .init()),
            configuration: .strict
        )

        // Register list prompts handler
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(
                prompts: [
                    Prompt(name: "test", description: "Test prompt")
                ]
            )
        }

        let client = Client(
            name: "StrictPromptTestClient",
            version: "1.0",
            configuration: .strict
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should succeed because server declares prompts capability
        let (prompts, _) = try await client.listPrompts()

        #expect(prompts.count == 1)
        #expect(prompts[0].name == "test")

        await server.stop()
        await client.disconnect()
    }

    @Test("Strict mode fails when server doesn't declare prompts capability")
    func testPromptStrictCapabilitiesError() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT prompts capability in strict mode
        let server = Server(
            name: "StrictPromptTestServer",
            version: "1.0",
            capabilities: .init(),
            configuration: .strict
        )

        let client = Client(
            name: "StrictPromptTestClient",
            version: "1.0",
            configuration: .strict
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should fail because server doesn't declare prompts capability in strict mode
        await #expect(throws: MCPError.self) {
            _ = try await client.listPrompts()
        }

        await server.stop()
        await client.disconnect()
    }

    @Test("Non-strict mode succeeds even without server capability declaration")
    func testPromptNonStrictCapabilities() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT prompts capability in non-strict mode
        let server = Server(
            name: "NonStrictPromptTestServer",
            version: "1.0",
            capabilities: .init(),
            configuration: .default
        )

        // Register list prompts handler anyway
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(
                prompts: [
                    Prompt(name: "non_strict_test", description: "Non-strict test prompt")
                ]
            )
        }

        let client = Client(
            name: "NonStrictPromptTestClient",
            version: "1.0",
            configuration: .default
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Should succeed because client is in non-strict mode
        let (prompts, _) = try await client.listPrompts()

        #expect(prompts.count == 1)
        #expect(prompts[0].name == "non_strict_test")

        await server.stop()
        await client.disconnect()
    }
}
