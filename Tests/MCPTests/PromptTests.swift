import Foundation
import Testing

@testable import MCP

@Suite("Prompt Tests")
struct PromptTests {
    @Test("Prompt initialization with valid parameters")
    func testPromptInitialization() throws {
        let argument = Prompt.Argument(
            name: "test_arg",
            description: "A test argument",
            required: true
        )

        let prompt = Prompt(
            name: "test_prompt",
            description: "A test prompt",
            arguments: [argument]
        )

        #expect(prompt.name == "test_prompt")
        #expect(prompt.description == "A test prompt")
        #expect(prompt.arguments?.count == 1)
        #expect(prompt.arguments?[0].name == "test_arg")
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
        let resourceContent = Prompt.Message.Content.resource(
            uri: "file://test.txt",
            mimeType: "text/plain",
            text: "Sample text",
            blob: "blob_data"
        )
        let resourceData = try encoder.encode(resourceContent)
        let decodedResource = try decoder.decode(Prompt.Message.Content.self, from: resourceData)
        if case .resource(let uri, let mimeType, let text, let blob) = decodedResource {
            #expect(uri == "file://test.txt")
            #expect(mimeType == "text/plain")
            #expect(text == "Sample text")
            #expect(blob == "blob_data")
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test("Prompt Reference validation")
    func testPromptReference() throws {
        let reference = Prompt.Reference(name: "test_prompt")
        #expect(reference.name == "test_prompt")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(Prompt.Reference.self, from: data)

        #expect(decoded.name == "test_prompt")
    }

    @Test("GetPrompt parameters validation")
    func testGetPromptParameters() throws {
        let arguments: [String: Value] = [
            "param1": .string("value1"),
            "param2": .int(42),
        ]

        let params = GetPrompt.Parameters(name: "test_prompt", arguments: arguments)
        #expect(params.name == "test_prompt")
        #expect(params.arguments?["param1"] == .string("value1"))
        #expect(params.arguments?["param2"] == .int(42))
    }

    @Test("GetPrompt result validation")
    func testGetPromptResult() throws {
        let messages: [Prompt.Message] = [
            .user("User message"),
            .assistant("Assistant response"),
        ]

        let result = GetPrompt.Result(description: "Test description", messages: messages)
        #expect(result.description == "Test description")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[1].role == .assistant)
    }

    @Test("ListPrompts parameters validation")
    func testListPromptsParameters() throws {
        let params = ListPrompts.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListPrompts.Parameters()
        #expect(emptyParams.cursor == nil)
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
        let prompts = [
            Prompt(name: "prompt1", description: "First prompt"),
            Prompt(name: "prompt2", description: "Second prompt"),
        ]

        let result = ListPrompts.Result(prompts: prompts, nextCursor: "next_page")
        #expect(result.prompts.count == 2)
        #expect(result.prompts[0].name == "prompt1")
        #expect(result.prompts[1].name == "prompt2")
        #expect(result.nextCursor == "next_page")
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
        let resourceMessage: Prompt.Message = .user(
            .resource(
                uri: "file://test.txt", mimeType: "text/plain", text: "Sample text", blob: nil))
        #expect(resourceMessage.role == .user)
        if case .resource(let uri, let mimeType, let text, let blob) = resourceMessage.content {
            #expect(uri == "file://test.txt")
            #expect(mimeType == "text/plain")
            #expect(text == "Sample text")
            #expect(blob == nil)
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
