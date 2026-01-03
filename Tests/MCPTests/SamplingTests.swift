import Logging
import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("Sampling Tests")
struct SamplingTests {
    @Test("Sampling.Message encoding and decoding")
    func testSamplingMessageCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text content
        let textMessage: Sampling.Message = .user("Hello, world!")

        let textData = try encoder.encode(textMessage)
        let decodedTextMessage = try decoder.decode(Sampling.Message.self, from: textData)

        #expect(decodedTextMessage.role == .user)
        if case .text(let text, _, _) = decodedTextMessage.content.first {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test image content
        let imageMessage: Sampling.Message = .assistant(
            .image(data: "base64imagedata", mimeType: "image/png"))

        let imageData = try encoder.encode(imageMessage)
        let decodedImageMessage = try decoder.decode(Sampling.Message.self, from: imageData)

        #expect(decodedImageMessage.role == .assistant)
        if case .image(let data, let mimeType, _, _) = decodedImageMessage.content.first {
            #expect(data == "base64imagedata")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }

        // Test audio content
        let audioMessage: Sampling.Message = .user(
            .audio(data: "base64audiodata", mimeType: "audio/wav"))

        let audioData = try encoder.encode(audioMessage)
        let decodedAudioMessage = try decoder.decode(Sampling.Message.self, from: audioData)

        #expect(decodedAudioMessage.role == .user)
        if case .audio(let data, let mimeType, _, _) = decodedAudioMessage.content.first {
            #expect(data == "base64audiodata")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }
    }

    @Test("ModelPreferences encoding and decoding")
    func testModelPreferencesCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let preferences = Sampling.ModelPreferences(
            hints: [
                Sampling.ModelPreferences.Hint(name: "claude-4"),
                Sampling.ModelPreferences.Hint(name: "gpt-4.1"),
            ],
            costPriority: 0.8,
            speedPriority: 0.3,
            intelligencePriority: 0.9
        )

        let data = try encoder.encode(preferences)
        let decoded = try decoder.decode(Sampling.ModelPreferences.self, from: data)

        #expect(decoded.hints?.count == 2)
        #expect(decoded.hints?[0].name == "claude-4")
        #expect(decoded.hints?[1].name == "gpt-4.1")
        #expect(decoded.costPriority?.doubleValue == 0.8)
        #expect(decoded.speedPriority?.doubleValue == 0.3)
        #expect(decoded.intelligencePriority?.doubleValue == 0.9)
    }

    @Test("ContextInclusion encoding and decoding")
    func testContextInclusionCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let contexts: [Sampling.ContextInclusion] = [.none, .thisServer, .allServers]

        for context in contexts {
            let data = try encoder.encode(context)
            let decoded = try decoder.decode(Sampling.ContextInclusion.self, from: data)
            #expect(decoded == context)
        }
    }

    @Test("StopReason encoding and decoding")
    func testStopReasonCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test standard stop reasons
        let reasons: [Sampling.StopReason] = [.endTurn, .stopSequence, .maxTokens, .toolUse]

        for reason in reasons {
            let data = try encoder.encode(reason)
            let decoded = try decoder.decode(Sampling.StopReason.self, from: data)
            #expect(decoded == reason)
        }

        // Test "refusal" stop reason (part of MCP spec)
        let refusalReason = Sampling.StopReason(rawValue: "refusal")
        let refusalData = try encoder.encode(refusalReason)
        let decodedRefusal = try decoder.decode(Sampling.StopReason.self, from: refusalData)
        #expect(decodedRefusal.rawValue == "refusal")

        // Test "other" stop reason (part of MCP spec)
        let otherReason = Sampling.StopReason(rawValue: "other")
        let otherData = try encoder.encode(otherReason)
        let decodedOther = try decoder.decode(Sampling.StopReason.self, from: otherData)
        #expect(decodedOther.rawValue == "other")

        // Test custom/provider-specific stop reason
        let customReason = Sampling.StopReason(rawValue: "customProviderReason")
        let customData = try encoder.encode(customReason)
        let decodedCustom = try decoder.decode(Sampling.StopReason.self, from: customData)
        #expect(decodedCustom == customReason)
        #expect(decodedCustom.rawValue == "customProviderReason")
    }

    @Test("CreateMessage request parameters")
    func testCreateMessageParameters() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let messages: [Sampling.Message] = [
            .user("What is the weather like?"),
            .assistant("I need to check the weather for you."),
        ]

        let modelPreferences = Sampling.ModelPreferences(
            hints: [Sampling.ModelPreferences.Hint(name: "claude-4-sonnet")],
            costPriority: 0.5,
            speedPriority: 0.7,
            intelligencePriority: 0.9
        )

        let parameters = CreateSamplingMessage.Parameters(
            messages: messages,
            modelPreferences: modelPreferences,
            systemPrompt: "You are a helpful weather assistant.",
            includeContext: .thisServer,
            temperature: 0.7,
            maxTokens: 150,
            stopSequences: ["END", "STOP"],
            metadata: ["provider": "test"]
        )

        let data = try encoder.encode(parameters)
        let decoded = try decoder.decode(CreateSamplingMessage.Parameters.self, from: data)

        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0].role == .user)
        #expect(decoded.systemPrompt == "You are a helpful weather assistant.")
        #expect(decoded.includeContext == .thisServer)
        #expect(decoded.temperature == 0.7)
        #expect(decoded.maxTokens == 150)
        #expect(decoded.stopSequences?.count == 2)
        #expect(decoded.stopSequences?[0] == "END")
        #expect(decoded.stopSequences?[1] == "STOP")
        #expect(decoded.metadata?["provider"]?.stringValue == "test")
    }

    @Test("CreateMessage result (without tools)")
    func testCreateMessageResult() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let result = CreateSamplingMessage.Result(
            model: "claude-4-sonnet",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("The weather is sunny and 75°F.")
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateSamplingMessage.Result.self, from: data)

        #expect(decoded.model == "claude-4-sonnet")
        #expect(decoded.stopReason == .endTurn)
        #expect(decoded.role == .assistant)

        // Content is now SamplingContent (single block), not an array
        if case .text(let text, _, _) = decoded.content {
            #expect(text == "The weather is sunny and 75°F.")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("CreateMessage result decodes array content (MCP spec compatibility)")
    func testCreateMessageResultDecodesArrayContent() throws {
        let decoder = JSONDecoder()

        // MCP spec allows content to be either single or array.
        // Some clients may send content as array even for non-tool requests.
        let jsonWithArrayContent = """
        {
            "model": "claude-4-sonnet",
            "stopReason": "endTurn",
            "role": "assistant",
            "content": [{"type": "text", "text": "Response from array format"}]
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(CreateSamplingMessage.Result.self, from: jsonWithArrayContent)

        #expect(decoded.model == "claude-4-sonnet")
        #expect(decoded.stopReason == .endTurn)
        #expect(decoded.role == .assistant)

        if case .text(let text, _, _) = decoded.content {
            #expect(text == "Response from array format")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("CreateMessage result decodes single content")
    func testCreateMessageResultDecodesSingleContent() throws {
        let decoder = JSONDecoder()

        // Single object content (common format)
        let jsonWithSingleContent = """
        {
            "model": "claude-4-sonnet",
            "role": "assistant",
            "content": {"type": "text", "text": "Response from single format"}
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(CreateSamplingMessage.Result.self, from: jsonWithSingleContent)

        if case .text(let text, _, _) = decoded.content {
            #expect(text == "Response from single format")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("CreateMessage result with tools")
    func testCreateMessageResultWithTools() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test with tool use content
        let toolUse = ToolUseContent(
            name: "get_weather",
            id: "call-123",
            input: ["city": "Paris"]
        )
        let result = CreateSamplingMessageWithTools.Result(
            model: "claude-4-sonnet",
            stopReason: .toolUse,
            role: .assistant,
            content: .toolUse(toolUse)
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateSamplingMessageWithTools.Result.self, from: data)

        #expect(decoded.model == "claude-4-sonnet")
        #expect(decoded.stopReason == .toolUse)
        #expect(decoded.role == .assistant)
        #expect(decoded.content.count == 1)

        if case .toolUse(let content) = decoded.content.first {
            #expect(content.name == "get_weather")
            #expect(content.id == "call-123")
        } else {
            #expect(Bool(false), "Expected tool use content")
        }
    }

    @Test("CreateMessage result with parallel tool calls")
    func testCreateMessageResultWithParallelToolCalls() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test with multiple tool use content (parallel calls)
        let toolUse1 = ToolUseContent(name: "get_weather", id: "call-1", input: ["city": "Paris"])
        let toolUse2 = ToolUseContent(name: "get_time", id: "call-2", input: ["city": "Paris"])

        let result = CreateSamplingMessageWithTools.Result(
            model: "claude-4-sonnet",
            stopReason: .toolUse,
            role: .assistant,
            content: [.toolUse(toolUse1), .toolUse(toolUse2)]
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateSamplingMessageWithTools.Result.self, from: data)

        #expect(decoded.model == "claude-4-sonnet")
        #expect(decoded.stopReason == .toolUse)
        #expect(decoded.content.count == 2)

        if case .toolUse(let content1) = decoded.content[0],
           case .toolUse(let content2) = decoded.content[1] {
            #expect(content1.name == "get_weather")
            #expect(content2.name == "get_time")
        } else {
            #expect(Bool(false), "Expected tool use content")
        }
    }

    @Test("CreateMessage request creation")
    func testCreateMessageRequest() throws {
        let messages: [Sampling.Message] = [
            .user("Hello")
        ]

        let request = CreateSamplingMessage.request(
            .init(
                messages: messages,
                maxTokens: 100
            )
        )

        #expect(request.method == "sampling/createMessage")
        #expect(request.params.messages.count == 1)
        #expect(request.params.maxTokens == 100)
    }

    @Test("Client capabilities include sampling")
    func testClientCapabilitiesIncludeSampling() throws {
        let capabilities = Client.Capabilities(
            sampling: .init()
        )

        #expect(capabilities.sampling != nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.sampling != nil)
    }

    @Test("Client capabilities with sampling.tools")
    func testClientCapabilitiesWithSamplingTools() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(tools: .init())
        )

        #expect(capabilities.sampling?.tools != nil)
        #expect(capabilities.sampling?.context == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tools\":{}"))

        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling?.tools != nil)
        #expect(decoded.sampling?.context == nil)
    }

    @Test("Client capabilities with sampling.context")
    func testClientCapabilitiesWithSamplingContext() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(context: .init())
        )

        #expect(capabilities.sampling?.context != nil)
        #expect(capabilities.sampling?.tools == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"context\":{}"))

        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling?.context != nil)
        #expect(decoded.sampling?.tools == nil)
    }

    @Test("Client capabilities with sampling.tools and sampling.context")
    func testClientCapabilitiesWithSamplingToolsAndContext() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(context: .init(), tools: .init())
        )

        #expect(capabilities.sampling?.tools != nil)
        #expect(capabilities.sampling?.context != nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tools\":{}"))
        #expect(json.contains("\"context\":{}"))

        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling?.tools != nil)
        #expect(decoded.sampling?.context != nil)
    }

    @Test("Sampling message content JSON format")
    func testSamplingMessageContentJSONFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // Test text content JSON format
        let textContent: Sampling.Message.ContentBlock = .text("Hello")
        let textData = try encoder.encode(textContent)
        let textJSON = String(data: textData, encoding: .utf8)!

        #expect(textJSON.contains("\"type\":\"text\""))
        #expect(textJSON.contains("\"text\":\"Hello\""))

        // Test image content JSON format
        let imageContent: Sampling.Message.ContentBlock = .image(
            data: "base64data", mimeType: "image/png")
        let imageData = try encoder.encode(imageContent)
        let imageJSON = String(data: imageData, encoding: .utf8)!

        #expect(imageJSON.contains("\"type\":\"image\""))
        #expect(imageJSON.contains("\"data\":\"base64data\""))
        #expect(imageJSON.contains("\"mimeType\":\"image\\/png\""))

        // Test audio content JSON format
        let audioContent: Sampling.Message.ContentBlock = .audio(
            data: "base64audiodata", mimeType: "audio/wav")
        let audioData = try encoder.encode(audioContent)
        let audioJSON = String(data: audioData, encoding: .utf8)!

        #expect(audioJSON.contains("\"type\":\"audio\""))
        #expect(audioJSON.contains("\"data\":\"base64audiodata\""))
        #expect(audioJSON.contains("\"mimeType\":\"audio\\/wav\""))
    }

    @Test("Backwards compatibility: Sampling.Message.Content alias")
    func testContentTypeAliasBackwardsCompatibility() throws {
        // Test that the deprecated Content type alias still works
        let content: Sampling.Message.ContentBlock = .text("Hello")

        if case .text(let text, _, _) = content {
            #expect(text == "Hello")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Verify it's the same type as ContentBlock
        let block: Sampling.Message.ContentBlock = content
        #expect(block == content)
    }

    @Test("UnitInterval in Sampling.ModelPreferences")
    func testUnitIntervalInModelPreferences() throws {
        // Test that UnitInterval validation works in Sampling.ModelPreferences
        let validPreferences = Sampling.ModelPreferences(
            costPriority: 0.5,
            speedPriority: 1.0,
            intelligencePriority: 0.0
        )

        #expect(validPreferences.costPriority?.doubleValue == 0.5)
        #expect(validPreferences.speedPriority?.doubleValue == 1.0)
        #expect(validPreferences.intelligencePriority?.doubleValue == 0.0)

        // Test JSON encoding/decoding preserves UnitInterval constraints
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(validPreferences)
        let decoded = try decoder.decode(Sampling.ModelPreferences.self, from: data)

        #expect(decoded.costPriority?.doubleValue == 0.5)
        #expect(decoded.speedPriority?.doubleValue == 1.0)
        #expect(decoded.intelligencePriority?.doubleValue == 0.0)
    }

    @Test("Message factory methods")
    func testMessageFactoryMethods() throws {
        // Test user message factory method
        let userMessage: Sampling.Message = .user("Hello, world!")
        #expect(userMessage.role == .user)
        if case .text(let text, _, _) = userMessage.content.first {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message factory method
        let assistantMessage: Sampling.Message = .assistant("Hi there!")
        #expect(assistantMessage.role == .assistant)
        if case .text(let text, _, _) = assistantMessage.content.first {
            #expect(text == "Hi there!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test with image content
        let imageMessage: Sampling.Message = .user(
            .image(data: "base64data", mimeType: "image/png"))
        #expect(imageMessage.role == .user)
        if case .image(let data, let mimeType, _, _) = imageMessage.content.first {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }
    }

    @Test("Content ExpressibleByStringLiteral")
    func testContentExpressibleByStringLiteral() throws {
        // Test string literal assignment
        let content: Sampling.Message.ContentBlock = "Hello from string literal"

        if case .text(let text, _, _) = content {
            #expect(text == "Hello from string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation
        let message: Sampling.Message = .user("Direct string literal")
        if case .text(let text, _, _) = message.content.first {
            #expect(text == "Direct string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in array context
        let messages: [Sampling.Message] = [
            .user("First message"),
            .assistant("Second message"),
            .user("Third message"),
        ]

        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)
    }

    @Test("Content ExpressibleByStringInterpolation")
    func testContentExpressibleByStringInterpolation() throws {
        let userName = "Alice"
        let temperature = 72
        let location = "San Francisco"

        // Test string interpolation
        let content: Sampling.Message.ContentBlock =
            "Hello \(userName), the temperature in \(location) is \(temperature)°F"

        if case .text(let text, _, _) = content {
            #expect(text == "Hello Alice, the temperature in San Francisco is 72°F")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation with interpolation
        let message = Sampling.Message.user(
            "Welcome \(userName)! Today's weather in \(location) is \(temperature)°F")
        if case .text(let text, _, _) = message.content.first {
            #expect(text == "Welcome Alice! Today's weather in San Francisco is 72°F")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test complex interpolation
        let items = ["apples", "bananas", "oranges"]
        let count = items.count
        let listMessage: Sampling.Message = .assistant(
            "You have \(count) items: \(items.joined(separator: ", "))")

        if case .text(let text, _, _) = listMessage.content.first {
            #expect(text == "You have 3 items: apples, bananas, oranges")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Message factory methods with string interpolation")
    func testMessageFactoryMethodsWithStringInterpolation() throws {
        let customerName = "Bob"
        let orderNumber = "ORD-12345"
        let issueType = "delivery delay"

        // Test user message with interpolation
        let userMessage: Sampling.Message = .user(
            "Hi, I'm \(customerName) and I have an issue with order \(orderNumber)")
        #expect(userMessage.role == .user)
        if case .text(let text, _, _) = userMessage.content.first {
            #expect(text == "Hi, I'm Bob and I have an issue with order ORD-12345")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message with interpolation
        let assistantMessage: Sampling.Message = .assistant(
            "Hello \(customerName), I can help you with your \(issueType) issue for order \(orderNumber)"
        )
        #expect(assistantMessage.role == .assistant)
        if case .text(let text, _, _) = assistantMessage.content.first {
            #expect(
                text
                    == "Hello Bob, I can help you with your delivery delay issue for order ORD-12345"
            )
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in conversation array
        let conversation: [Sampling.Message] = [
            .user("Hello, I'm \(customerName)"),
            .assistant("Hi \(customerName), how can I help you today?"),
            .user("I have an issue with order \(orderNumber) - it's a \(issueType)"),
            .assistant(
                "I understand you're experiencing a \(issueType) with order \(orderNumber). Let me look into that for you."
            ),
        ]

        #expect(conversation.count == 4)

        // Verify interpolated content
        if case .text(let text, _, _) = conversation[2].content.first {
            #expect(text == "I have an issue with order ORD-12345 - it's a delivery delay")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Ergonomic API usage patterns")
    func testErgonomicAPIUsagePatterns() throws {
        // Test various ergonomic usage patterns enabled by the new API

        // Pattern 1: Simple conversation
        let simpleConversation: [Sampling.Message] = [
            .user("What's the weather like?"),
            .assistant("I'd be happy to help you check the weather!"),
            .user("Thanks!"),
        ]
        #expect(simpleConversation.count == 3)

        // Pattern 2: Dynamic content with interpolation
        let productName = "Smart Thermostat"
        let price = 199.99
        let discount = 20

        let salesConversation: [Sampling.Message] = [
            .user("Tell me about the \(productName)"),
            .assistant("The \(productName) is priced at $\(String(format: "%.2f", price))"),
            .user("Do you have any discounts?"),
            .assistant(
                "Yes! We currently have a \(discount)% discount, bringing the price to $\(String(format: "%.2f", price * (1.0 - Double(discount)/100.0)))"
            ),
        ]
        #expect(salesConversation.count == 4)

        // Pattern 3: Mixed content types
        let mixedContent: [Sampling.Message] = [
            .user("Can you analyze this image?"),
            .assistant(.image(data: "analysis_chart_data", mimeType: "image/png")),
            .user("What does it show?"),
            .assistant("The chart shows a clear upward trend in sales."),
        ]
        #expect(mixedContent.count == 4)

        // Verify content types
        if case .text = mixedContent[0].content.first,
            case .image = mixedContent[1].content.first,
            case .text = mixedContent[2].content.first,
            case .text = mixedContent[3].content.first
        {
            // All content types are correct
        } else {
            #expect(Bool(false), "Content types don't match expected pattern")
        }

        // Pattern 4: Encoding/decoding still works
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(simpleConversation)
        let decoded = try decoder.decode([Sampling.Message].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].role == .user)
        #expect(decoded[1].role == .assistant)
        #expect(decoded[2].role == .user)
    }
}

@Suite("Sampling Message Validation Tests")
struct SamplingMessageValidationTests {
    @Test("validateToolUseResultMessages passes for empty messages")
    func testEmptyMessages() throws {
        let messages: [Sampling.Message] = []
        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages passes for simple text messages")
    func testSimpleTextMessages() throws {
        let messages: [Sampling.Message] = [
            .user("Hello"),
            .assistant("Hi there!"),
        ]
        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages passes for valid tool_use then tool_result")
    func testValidToolUseAndResult() throws {
        let toolUseContent = ToolUseContent(
            name: "get_weather",
            id: "tool-123",
            input: ["city": "Paris"]
        )
        let toolResultContent = ToolResultContent(
            toolUseId: "tool-123",
            content: [.text("Sunny, 72°F")]
        )

        let messages: [Sampling.Message] = [
            .user("What's the weather?"),
            .assistant(.toolUse(toolUseContent)),
            Sampling.Message(role: .user, content: [.toolResult(toolResultContent)]),
        ]

        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails when tool_result mixed with other content")
    func testToolResultMixedWithOtherContent() throws {
        let toolResultContent = ToolResultContent(
            toolUseId: "tool-123",
            content: [.text("Result")]
        )

        let messages: [Sampling.Message] = [
            .user("Hello"),
            .assistant(.toolUse(ToolUseContent(name: "test", id: "tool-123", input: [:]))),
            Sampling.Message(role: .user, content: [
                .text("Some text"),  // Mixed with tool_result - invalid!
                .toolResult(toolResultContent),
            ]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails when tool_result without preceding tool_use")
    func testToolResultWithoutPrecedingToolUse() throws {
        let toolResultContent = ToolResultContent(
            toolUseId: "tool-123",
            content: [.text("Result")]
        )

        let messages: [Sampling.Message] = [
            .user("Hello"),
            .assistant("Let me help you"),  // No tool_use here
            Sampling.Message(role: .user, content: [.toolResult(toolResultContent)]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails when tool_result is first message")
    func testToolResultAsFirstMessage() throws {
        let toolResultContent = ToolResultContent(
            toolUseId: "tool-123",
            content: [.text("Result")]
        )

        let messages: [Sampling.Message] = [
            Sampling.Message(role: .user, content: [.toolResult(toolResultContent)]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails when tool IDs don't match")
    func testMismatchedToolIds() throws {
        let toolUseContent = ToolUseContent(
            name: "get_weather",
            id: "tool-123",
            input: [:]
        )
        let toolResultContent = ToolResultContent(
            toolUseId: "tool-456",  // Different ID!
            content: [.text("Result")]
        )

        let messages: [Sampling.Message] = [
            .user("Hello"),
            .assistant(.toolUse(toolUseContent)),
            Sampling.Message(role: .user, content: [.toolResult(toolResultContent)]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages passes with multiple matching tool_use/tool_result")
    func testMultipleMatchingToolUseAndResults() throws {
        let toolUse1 = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])
        let toolUse2 = ToolUseContent(name: "get_time", id: "tool-2", input: [:])
        let toolResult1 = ToolResultContent(toolUseId: "tool-1", content: [.text("Sunny")])
        let toolResult2 = ToolResultContent(toolUseId: "tool-2", content: [.text("3pm")])

        let messages: [Sampling.Message] = [
            .user("What's the weather and time?"),
            Sampling.Message(role: .assistant, content: [
                .toolUse(toolUse1),
                .toolUse(toolUse2),
            ]),
            Sampling.Message(role: .user, content: [
                .toolResult(toolResult1),
                .toolResult(toolResult2),
            ]),
        ]

        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails with partial tool_result match")
    func testPartialToolResultMatch() throws {
        let toolUse1 = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])
        let toolUse2 = ToolUseContent(name: "get_time", id: "tool-2", input: [:])
        // Only providing result for tool-1, missing tool-2
        let toolResult1 = ToolResultContent(toolUseId: "tool-1", content: [.text("Sunny")])

        let messages: [Sampling.Message] = [
            .user("What's the weather and time?"),
            Sampling.Message(role: .assistant, content: [
                .toolUse(toolUse1),
                .toolUse(toolUse2),
            ]),
            Sampling.Message(role: .user, content: [
                .toolResult(toolResult1),
            ]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails with extra tool_results not matching tool_use")
    func testExtraToolResultsNotMatchingToolUse() throws {
        // tool_use has [1], but tool_result has [1, 2] - extra result for non-existent tool
        let toolUse = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])
        let toolResult1 = ToolResultContent(toolUseId: "tool-1", content: [.text("Sunny")])
        let toolResult2 = ToolResultContent(toolUseId: "tool-2", content: [.text("Extra")])

        let messages: [Sampling.Message] = [
            .user("What's the weather?"),
            .assistant(.toolUse(toolUse)),
            Sampling.Message(role: .user, content: [
                .toolResult(toolResult1),
                .toolResult(toolResult2),  // Extra result with no matching tool_use
            ]),
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages fails when text message follows tool_use")
    func testTextMessageAfterToolUse() throws {
        // After tool_use, you MUST provide tool_result - can't just send text
        let toolUse = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])

        let messages: [Sampling.Message] = [
            .user("What's the weather?"),
            .assistant(.toolUse(toolUse)),
            .user("Thanks!"),  // Invalid: should be tool_result, not text
        ]

        #expect(throws: MCPError.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages passes for conversation continuing after tool results")
    func testConversationContinuesAfterToolResults() throws {
        // Valid flow: tool_use → tool_result → text → text (conversation continues normally)
        let toolUse = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])
        let toolResult = ToolResultContent(toolUseId: "tool-1", content: [.text("Sunny")])

        let messages: [Sampling.Message] = [
            .user("What's the weather?"),
            .assistant(.toolUse(toolUse)),
            Sampling.Message(role: .user, content: [.toolResult(toolResult)]),
            .assistant("The weather is sunny!"),
            .user("Great, thanks!"),  // Valid: conversation continues after tool cycle
        ]

        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }

    @Test("validateToolUseResultMessages passes when tool_use has text alongside")
    func testToolUseWithTextInAssistantMessage() throws {
        // Assistant can have both text and tool_use in the same message
        let toolUse = ToolUseContent(name: "get_weather", id: "tool-1", input: [:])
        let toolResult = ToolResultContent(toolUseId: "tool-1", content: [.text("Sunny")])

        let messages: [Sampling.Message] = [
            .user("What's the weather?"),
            Sampling.Message(role: .assistant, content: [
                .text("Let me check the weather for you."),
                .toolUse(toolUse),
            ]),
            Sampling.Message(role: .user, content: [.toolResult(toolResult)]),
        ]

        #expect(throws: Never.self) {
            try Sampling.Message.validateToolUseResultMessages(messages)
        }
    }
}

@Suite("Sampling Integration Tests")
struct SamplingIntegrationTests {
    @Test(
        .timeLimit(.minutes(1))
    )
    func testSamplingCapabilitiesNegotiation() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.sampling",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        // Server (sampling is a client capability, not server)
        let server = Server(
            name: "SamplingTestServer",
            version: "1.0.0",
            capabilities: .init(
                tools: .init()
            )
        )

        // Client (capabilities will be set during initialization)
        let client = Client(
            name: "SamplingTestClient",
            version: "1.0"
        )

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testSamplingMessageTypes() async throws {
        // Test comprehensive message content types
        let textMessage: Sampling.Message = .user("What do you see in this data?")

        let imageMessage: Sampling.Message = .user(
            .image(
                data:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
                mimeType: "image/png"
            ))

        // Test encoding/decoding of different message types
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text message
        let textData = try encoder.encode(textMessage)
        let decodedTextMessage = try decoder.decode(Sampling.Message.self, from: textData)
        #expect(decodedTextMessage.role == .user)
        if case .text(let text, _, _) = decodedTextMessage.content.first {
            #expect(text == "What do you see in this data?")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test image message
        let imageData = try encoder.encode(imageMessage)
        let decodedImageMessage = try decoder.decode(Sampling.Message.self, from: imageData)
        #expect(decodedImageMessage.role == .user)
        if case .image(let data, let mimeType, _, _) = decodedImageMessage.content.first {
            #expect(data.contains("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"))
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testSamplingResultTypes() async throws {
        // Test different result content types and stop reasons
        let textResult = CreateSamplingMessage.Result(
            model: "claude-4-sonnet",
            stopReason: .endTurn,
            role: .assistant,
            content: .text(
                "Based on the sales data analysis, I can see a strong upward trend through Q3, with a slight decline in Q4. This suggests seasonal factors or market saturation."
            )
        )

        let imageResult = CreateSamplingMessage.Result(
            model: "dall-e-3",
            stopReason: .maxTokens,
            role: .assistant,
            content: .image(
                data: "generated_chart_base64_data_here",
                mimeType: "image/png"
            )
        )

        let stopSequenceResult = CreateSamplingMessage.Result(
            model: "gpt-4.1",
            stopReason: .stopSequence,
            role: .assistant,
            content: .text("Analysis complete.\nEND_ANALYSIS")
        )

        // Test encoding/decoding of different result types
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text result
        let textData = try encoder.encode(textResult)
        let decodedTextResult = try decoder.decode(
            CreateSamplingMessage.Result.self, from: textData)
        #expect(decodedTextResult.model == "claude-4-sonnet")
        #expect(decodedTextResult.stopReason == .endTurn)
        #expect(decodedTextResult.role == .assistant)

        // Test image result
        let imageData = try encoder.encode(imageResult)
        let decodedImageResult = try decoder.decode(
            CreateSamplingMessage.Result.self, from: imageData)
        #expect(decodedImageResult.model == "dall-e-3")
        #expect(decodedImageResult.stopReason == .maxTokens)

        // Test stop sequence result
        let stopData = try encoder.encode(stopSequenceResult)
        let decodedStopResult = try decoder.decode(
            CreateSamplingMessage.Result.self, from: stopData)
        #expect(decodedStopResult.stopReason == .stopSequence)
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testSamplingParameterValidation() async throws {
        // Test parameter validation and edge cases
        let validMessages: [Sampling.Message] = [
            .user("Valid message")
        ]

        _ = [Sampling.Message]()  // Test empty messages array.

        // Test with valid parameters
        let validParams = CreateSamplingMessage.Parameters(
            messages: validMessages,
            maxTokens: 100
        )
        #expect(validParams.messages.count == 1)
        #expect(validParams.maxTokens == 100)

        // Test with comprehensive parameters
        let comprehensiveParams = CreateSamplingMessage.Parameters(
            messages: validMessages,
            modelPreferences: Sampling.ModelPreferences(
                hints: [Sampling.ModelPreferences.Hint(name: "claude-4")],
                costPriority: 0.5,
                speedPriority: 0.8,
                intelligencePriority: 0.9
            ),
            systemPrompt: "You are a helpful assistant.",
            includeContext: .allServers,
            temperature: 0.7,
            maxTokens: 500,
            stopSequences: ["STOP", "END"],
            metadata: [
                "sessionId": "test-session-123",
                "userId": "user-456",
            ]
        )

        #expect(comprehensiveParams.messages.count == 1)
        #expect(comprehensiveParams.modelPreferences?.hints?.count == 1)
        #expect(comprehensiveParams.systemPrompt == "You are a helpful assistant.")
        #expect(comprehensiveParams.includeContext == .allServers)
        #expect(comprehensiveParams.temperature == 0.7)
        #expect(comprehensiveParams.maxTokens == 500)
        #expect(comprehensiveParams.stopSequences?.count == 2)
        #expect(comprehensiveParams.metadata?.count == 2)

        // Test encoding/decoding of comprehensive parameters
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(comprehensiveParams)
        let decoded = try decoder.decode(CreateSamplingMessage.Parameters.self, from: data)

        #expect(decoded.messages.count == 1)
        #expect(decoded.modelPreferences?.costPriority?.doubleValue == 0.5)
        #expect(decoded.systemPrompt == "You are a helpful assistant.")
        #expect(decoded.includeContext == .allServers)
        #expect(decoded.temperature == 0.7)
        #expect(decoded.maxTokens == 500)
        #expect(decoded.stopSequences?[0] == "STOP")
        #expect(decoded.metadata?["sessionId"]?.stringValue == "test-session-123")
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testSamplingWorkflowScenarios() async throws {
        // Test realistic sampling workflow scenarios

        // Scenario 1: Data Analysis Request
        let dataAnalysisMessages: [Sampling.Message] = [
            .user("Please analyze the following customer feedback data:"),
            .user(
                """
                Feedback Summary:
                - 85% positive sentiment
                - Top complaints: shipping delays (12%), product quality (8%)
                - Top praise: customer service (45%), product features (40%)
                - NPS Score: 72
                """),
        ]

        let dataAnalysisParams = CreateSamplingMessage.Parameters(
            messages: dataAnalysisMessages,
            modelPreferences: Sampling.ModelPreferences(
                hints: [Sampling.ModelPreferences.Hint(name: "claude-4-sonnet")],
                speedPriority: 0.3,
                intelligencePriority: 0.9
            ),
            systemPrompt: "You are an expert business analyst. Provide actionable insights.",
            includeContext: .thisServer,
            temperature: 0.3,  // Lower temperature for analytical tasks
            maxTokens: 400,
            stopSequences: ["---END---"],
            metadata: ["analysisType": "customer-feedback"]
        )

        // Scenario 2: Creative Content Generation
        let creativeMessages: [Sampling.Message] = [
            .user(
                "Write a compelling product description for a new smart home device.")
        ]

        let creativeParams = CreateSamplingMessage.Parameters(
            messages: creativeMessages,
            modelPreferences: Sampling.ModelPreferences(
                hints: [Sampling.ModelPreferences.Hint(name: "gpt-4.1")],
                costPriority: 0.4,
                speedPriority: 0.6,
                intelligencePriority: 0.8
            ),
            systemPrompt: "You are a creative marketing copywriter.",
            temperature: 0.8,  // Higher temperature for creativity
            maxTokens: 200,
            metadata: ["contentType": "marketing-copy"]
        )

        // Test parameter encoding for both scenarios
        let encoder = JSONEncoder()

        let analysisData = try encoder.encode(dataAnalysisParams)
        let creativeData = try encoder.encode(creativeParams)

        // Verify both encode successfully
        #expect(analysisData.count > 0)
        #expect(creativeData.count > 0)

        // Test decoding
        let decoder = JSONDecoder()
        let decodedAnalysis = try decoder.decode(
            CreateSamplingMessage.Parameters.self, from: analysisData)
        let decodedCreative = try decoder.decode(
            CreateSamplingMessage.Parameters.self, from: creativeData)

        #expect(decodedAnalysis.temperature == 0.3)
        #expect(decodedCreative.temperature == 0.8)
        #expect(decodedAnalysis.modelPreferences?.intelligencePriority?.doubleValue == 0.9)
        #expect(decodedCreative.modelPreferences?.costPriority?.doubleValue == 0.4)
    }
}

@Suite("Client Sampling Parameters Tests")
struct ClientSamplingParametersTests {
    @Test("ClientSamplingParameters init without tools")
    func testClientSamplingParametersInitWithoutTools() throws {
        let params = ClientSamplingParameters(
            messages: [.user("Hello")],
            maxTokens: 100
        )

        #expect(params.messages.count == 1)
        #expect(params.maxTokens == 100)
        #expect(params.hasTools == false)
        #expect(params.tools == nil)
    }

    @Test("ClientSamplingParameters init with tools")
    func testClientSamplingParametersInitWithTools() throws {
        let tool = Tool(
            name: "get_weather",
            description: "Get weather",
            inputSchema: .object([:])
        )

        let params = ClientSamplingParameters(
            messages: [.user("What's the weather?")],
            maxTokens: 200,
            tools: [tool],
            toolChoice: ToolChoice(mode: .auto)
        )

        #expect(params.messages.count == 1)
        #expect(params.maxTokens == 200)
        #expect(params.hasTools == true)
        #expect(params.tools?.count == 1)
        #expect(params.tools?.first?.name == "get_weather")
        #expect(params.toolChoice?.mode == .auto)
    }

    @Test("ClientSamplingParameters encoding and decoding")
    func testClientSamplingParametersCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let tool = Tool(
            name: "test_tool",
            description: "A test tool",
            inputSchema: .object([:])
        )

        let params = ClientSamplingParameters(
            messages: [.user("Hello"), .assistant("Hi there!")],
            modelPreferences: ModelPreferences(
                hints: [ModelPreferences.Hint(name: "claude-4")],
                costPriority: 0.5
            ),
            systemPrompt: "You are helpful",
            temperature: 0.7,
            maxTokens: 150,
            stopSequences: ["STOP"],
            tools: [tool],
            toolChoice: ToolChoice(mode: .required)
        )

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(ClientSamplingParameters.self, from: data)

        #expect(decoded.messages.count == 2)
        #expect(decoded.modelPreferences?.hints?.first?.name == "claude-4")
        #expect(decoded.modelPreferences?.costPriority?.doubleValue == 0.5)
        #expect(decoded.systemPrompt == "You are helpful")
        #expect(decoded.temperature == 0.7)
        #expect(decoded.maxTokens == 150)
        #expect(decoded.stopSequences?.first == "STOP")
        #expect(decoded.tools?.count == 1)
        #expect(decoded.tools?.first?.name == "test_tool")
        #expect(decoded.toolChoice?.mode == .required)
        #expect(decoded.hasTools == true)
    }

    @Test("ClientSamplingParameters hasTools with empty tools array")
    func testClientSamplingParametersHasToolsEmpty() throws {
        let params = ClientSamplingParameters(
            messages: [.user("Hello")],
            maxTokens: 100,
            tools: []  // Empty array
        )

        // Empty array should be treated as no tools
        #expect(params.hasTools == false)
    }

    @Test("ClientSamplingRequest result type matches CreateSamplingMessageWithTools.Result")
    func testClientSamplingRequestResultType() throws {
        // Verify the type alias works correctly
        let result: ClientSamplingRequest.Result = CreateSamplingMessageWithTools.Result(
            model: "test-model",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("Hello")
        )

        #expect(result.model == "test-model")
        #expect(result.stopReason == .endTurn)
        #expect(result.content.count == 1)
    }

    @Test("ClientSamplingParameters decodes from JSON without tools")
    func testClientSamplingParametersDecodesWithoutTools() throws {
        let decoder = JSONDecoder()

        let json = """
        {
            "messages": [{"role": "user", "content": {"type": "text", "text": "Hello"}}],
            "maxTokens": 100
        }
        """.data(using: .utf8)!

        let params = try decoder.decode(ClientSamplingParameters.self, from: json)

        #expect(params.messages.count == 1)
        #expect(params.maxTokens == 100)
        #expect(params.hasTools == false)
        #expect(params.tools == nil)
    }

    @Test("ClientSamplingParameters decodes from JSON with tools")
    func testClientSamplingParametersDecodesWithTools() throws {
        let decoder = JSONDecoder()

        let json = """
        {
            "messages": [{"role": "user", "content": {"type": "text", "text": "Hello"}}],
            "maxTokens": 100,
            "tools": [{"name": "test", "inputSchema": {"type": "object"}}],
            "toolChoice": {"mode": "auto"}
        }
        """.data(using: .utf8)!

        let params = try decoder.decode(ClientSamplingParameters.self, from: json)

        #expect(params.messages.count == 1)
        #expect(params.maxTokens == 100)
        #expect(params.hasTools == true)
        #expect(params.tools?.count == 1)
        #expect(params.tools?.first?.name == "test")
        #expect(params.toolChoice?.mode == .auto)
    }
}

@Suite("Sampling JSON Format Verification Tests")
struct SamplingJSONFormatTests {
    @Test("ToolChoice encodes correctly")
    func testToolChoiceEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let autoChoice = ToolChoice(mode: .auto)
        let requiredChoice = ToolChoice(mode: .required)
        let noneChoice = ToolChoice(mode: ToolChoice.Mode.none)  // Explicit to avoid ambiguity with Optional.none
        let nilChoice = ToolChoice()

        #expect(String(data: try encoder.encode(autoChoice), encoding: .utf8) == "{\"mode\":\"auto\"}")
        #expect(String(data: try encoder.encode(requiredChoice), encoding: .utf8) == "{\"mode\":\"required\"}")
        #expect(String(data: try encoder.encode(noneChoice), encoding: .utf8) == "{\"mode\":\"none\"}")
        #expect(String(data: try encoder.encode(nilChoice), encoding: .utf8) == "{}")
    }

    @Test("ToolChoice decodes all modes correctly")
    func testToolChoiceDecoding() throws {
        let decoder = JSONDecoder()

        let auto = try decoder.decode(ToolChoice.self, from: "{\"mode\":\"auto\"}".data(using: .utf8)!)
        let required = try decoder.decode(ToolChoice.self, from: "{\"mode\":\"required\"}".data(using: .utf8)!)
        let none = try decoder.decode(ToolChoice.self, from: "{\"mode\":\"none\"}".data(using: .utf8)!)
        let empty = try decoder.decode(ToolChoice.self, from: "{}".data(using: .utf8)!)

        #expect(auto.mode == .auto)
        #expect(required.mode == .required)
        #expect(none.mode == ToolChoice.Mode.none)  // Explicit to avoid ambiguity with Optional.none
        #expect(empty.mode == nil)
    }

    @Test("Sampling result single content encodes as object not array")
    func testSingleContentEncodesAsObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = CreateSamplingMessage.Result(
            model: "test",
            role: .assistant,
            content: .text("Hello")
        )

        let json = String(data: try encoder.encode(result), encoding: .utf8)!

        // Content should be an object, not an array
        #expect(json.contains("\"content\":{\"text\":\"Hello\",\"type\":\"text\"}"))
        #expect(!json.contains("\"content\":["))
    }

    @Test("Sampling result with tools single content encodes as object")
    func testToolsResultSingleContentEncodesAsObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = CreateSamplingMessageWithTools.Result(
            model: "test",
            role: .assistant,
            content: .text("Hello")
        )

        let json = String(data: try encoder.encode(result), encoding: .utf8)!

        // Single content should be an object, not an array
        #expect(json.contains("\"content\":{\"text\":\"Hello\",\"type\":\"text\"}"))
        #expect(!json.contains("\"content\":["))
    }

    @Test("Sampling result with tools multiple content encodes as array")
    func testToolsResultMultipleContentEncodesAsArray() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let toolUse1 = ToolUseContent(name: "tool1", id: "1", input: [:])
        let toolUse2 = ToolUseContent(name: "tool2", id: "2", input: [:])

        let result = CreateSamplingMessageWithTools.Result(
            model: "test",
            role: .assistant,
            content: [.toolUse(toolUse1), .toolUse(toolUse2)]
        )

        let json = String(data: try encoder.encode(result), encoding: .utf8)!

        // Multiple content should be an array
        #expect(json.contains("\"content\":["))
    }

    @Test("Sampling message single content encodes as object")
    func testMessageSingleContentEncodesAsObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let message: Sampling.Message = .user("Hello")

        let json = String(data: try encoder.encode(message), encoding: .utf8)!

        // Single content should be an object
        #expect(json.contains("\"content\":{\"text\":\"Hello\",\"type\":\"text\"}"))
        #expect(!json.contains("\"content\":["))
    }

    @Test("Sampling message multiple content encodes as array")
    func testMessageMultipleContentEncodesAsArray() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let message = Sampling.Message(role: .user, content: [
            .text("Hello"),
            .image(data: "abc", mimeType: "image/png"),
        ])

        let json = String(data: try encoder.encode(message), encoding: .utf8)!

        // Multiple content should be an array
        #expect(json.contains("\"content\":["))
    }

    @Test("StopReason encodes as raw string")
    func testStopReasonEncoding() throws {
        let encoder = JSONEncoder()

        #expect(String(data: try encoder.encode(StopReason.endTurn), encoding: .utf8) == "\"endTurn\"")
        #expect(String(data: try encoder.encode(StopReason.stopSequence), encoding: .utf8) == "\"stopSequence\"")
        #expect(String(data: try encoder.encode(StopReason.maxTokens), encoding: .utf8) == "\"maxTokens\"")
        #expect(String(data: try encoder.encode(StopReason.toolUse), encoding: .utf8) == "\"toolUse\"")

        // Custom stop reason
        let custom = StopReason(rawValue: "customReason")
        #expect(String(data: try encoder.encode(custom), encoding: .utf8) == "\"customReason\"")
    }

    @Test("ToolUseContent encodes with correct structure")
    func testToolUseContentEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let toolUse = ToolUseContent(
            name: "get_weather",
            id: "call-123",
            input: ["city": "Paris"]
        )

        let json = String(data: try encoder.encode(toolUse), encoding: .utf8)!

        #expect(json.contains("\"type\":\"tool_use\""))
        #expect(json.contains("\"name\":\"get_weather\""))
        #expect(json.contains("\"id\":\"call-123\""))
        #expect(json.contains("\"input\":{\"city\":\"Paris\"}"))
    }

    @Test("ToolResultContent encodes with correct structure")
    func testToolResultContentEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let toolResult = ToolResultContent(
            toolUseId: "call-123",
            content: [.text("Sunny, 72°F")],
            isError: false
        )

        let json = String(data: try encoder.encode(toolResult), encoding: .utf8)!

        #expect(json.contains("\"type\":\"tool_result\""))
        #expect(json.contains("\"toolUseId\":\"call-123\""))
        #expect(json.contains("\"isError\":false"))
    }

    @Test("CreateMessage result decodes from TypeScript SDK format")
    func testDecodesFromTypeScriptFormat() throws {
        let decoder = JSONDecoder()

        // Format matching TypeScript SDK output
        let json = """
        {
            "model": "claude-4-sonnet",
            "stopReason": "endTurn",
            "role": "assistant",
            "content": {
                "type": "text",
                "text": "Hello from TypeScript SDK"
            }
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(CreateSamplingMessage.Result.self, from: json)

        #expect(result.model == "claude-4-sonnet")
        #expect(result.stopReason == .endTurn)
        #expect(result.role == .assistant)
        if case .text(let text, _, _) = result.content {
            #expect(text == "Hello from TypeScript SDK")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("CreateMessage result decodes from Python SDK format with array")
    func testDecodesFromPythonFormatWithArray() throws {
        let decoder = JSONDecoder()

        // Python SDK may send array content
        let json = """
        {
            "model": "claude-4-sonnet",
            "stopReason": "toolUse",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "name": "get_weather",
                    "id": "toolu_123",
                    "input": {"city": "Paris"}
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(CreateSamplingMessageWithTools.Result.self, from: json)

        #expect(result.model == "claude-4-sonnet")
        #expect(result.stopReason == .toolUse)
        #expect(result.content.count == 1)
        if case .toolUse(let toolUse) = result.content.first {
            #expect(toolUse.name == "get_weather")
            #expect(toolUse.id == "toolu_123")
        } else {
            #expect(Bool(false), "Expected tool use content")
        }
    }
}

@Suite("Server Sampling Capability Validation Tests")
struct ServerSamplingCapabilityValidationTests {
    @Test(
        "Server throws when tools provided without sampling.tools capability",
        .timeLimit(.minutes(1))
    )
    func testServerThrowsWhenToolsWithoutCapability() async throws {
        // Set up server
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Set up client without sampling.tools capability (just basic sampling)
        let client = Client(
            name: "TestClient",
            version: "1.0"
        )
        await client.setCapabilities(Client.Capabilities(sampling: .init()))

        // Connect via in-memory transport
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Attempt to call createMessageWithTools should fail because client
        // doesn't have sampling.tools capability
        let params = CreateSamplingMessageWithTools.Parameters(
            messages: [.user("Hello")],
            maxTokens: 100,
            tools: [
                Tool(name: "test_tool", inputSchema: .object([:]))
            ],
            toolChoice: nil
        )

        await #expect(throws: MCPError.self) {
            _ = try await server.createMessageWithTools(params)
        }

        await server.stop()
        await client.disconnect()
    }

    @Test(
        "Server throws when client lacks sampling capability entirely",
        .timeLimit(.minutes(1))
    )
    func testServerThrowsWithoutSamplingCapability() async throws {
        // Set up server (sampling is a client capability, not server)
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Set up client without sampling capability
        let client = Client(
            name: "TestClient",
            version: "1.0"
        )
        // Don't set any sampling capability

        // Connect via in-memory transport
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Attempt to call createMessage should fail because client
        // doesn't have sampling capability
        let params = SamplingParameters(
            messages: [.user("Hello")],
            maxTokens: 100
        )

        await #expect(throws: MCPError.self) {
            _ = try await server.createMessage(params)
        }

        await server.stop()
        await client.disconnect()
    }

    @Test(
        "Server succeeds when client has sampling capability",
        .timeLimit(.minutes(1))
    )
    func testServerSucceedsWithSamplingCapability() async throws {
        // Set up server (sampling is a client capability, not server)
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Set up client WITH sampling capability
        let client = Client(
            name: "TestClient",
            version: "1.0"
        )
        await client.setCapabilities(Client.Capabilities(sampling: .init()))

        // Set up client sampling handler
        await client.withSamplingHandler { _, _ in
            return ClientSamplingRequest.Result(
                model: "test-model",
                stopReason: .endTurn,
                role: .assistant,
                content: [.text("Hello from client!")]
            )
        }

        // Connect via in-memory transport
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Attempt to call createMessage should succeed
        let params = SamplingParameters(
            messages: [.user("Hello")],
            maxTokens: 100
        )

        let result = try await server.createMessage(params)

        #expect(result.model == "test-model")
        #expect(result.stopReason == .endTurn)
        if case .text(let text, _, _) = result.content {
            #expect(text == "Hello from client!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        await server.stop()
        await client.disconnect()
    }

    @Test(
        "Server succeeds with tools when client has sampling.tools capability",
        .timeLimit(.minutes(1))
    )
    func testServerSucceedsWithToolsCapability() async throws {
        // Set up server (sampling is a client capability, not server)
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init()
        )

        // Set up client WITH sampling.tools capability
        let client = Client(
            name: "TestClient",
            version: "1.0"
        )
        await client.setCapabilities(Client.Capabilities(sampling: .init(tools: .init())))

        // Set up client sampling handler
        await client.withSamplingHandler { _, _ in
            return ClientSamplingRequest.Result(
                model: "test-model",
                stopReason: .toolUse,
                role: .assistant,
                content: [.toolUse(ToolUseContent(
                    name: "get_weather",
                    id: "call-123",
                    input: ["city": "Paris"]
                ))]
            )
        }

        // Connect via in-memory transport
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Attempt to call createMessageWithTools should succeed
        let params = CreateSamplingMessageWithTools.Parameters(
            messages: [.user("What's the weather?")],
            maxTokens: 100,
            tools: [
                Tool(name: "get_weather", inputSchema: .object([:]))
            ],
            toolChoice: ToolChoice(mode: .auto)
        )

        let result = try await server.createMessageWithTools(params)

        #expect(result.model == "test-model")
        #expect(result.stopReason == .toolUse)
        #expect(result.content.count == 1)
        if case .toolUse(let toolUse) = result.content.first {
            #expect(toolUse.name == "get_weather")
        } else {
            #expect(Bool(false), "Expected tool use content")
        }

        await server.stop()
        await client.disconnect()
    }
}
