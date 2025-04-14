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
        let textMessage = Prompt.Message(
            role: .user,
            content: .text(text: "Hello, world!")
        )

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
        let messages = [
            Prompt.Message(role: .user, content: .text(text: "User message")),
            Prompt.Message(role: .assistant, content: .text(text: "Assistant response")),
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
}
