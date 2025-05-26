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
        if case .text(let text) = decodedTextMessage.content {
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
        if case .image(let data, let mimeType) = decodedImageMessage.content {
            #expect(data == "base64imagedata")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
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

        let reasons: [Sampling.StopReason] = [.endTurn, .stopSequence, .maxTokens]

        for reason in reasons {
            let data = try encoder.encode(reason)
            let decoded = try decoder.decode(Sampling.StopReason.self, from: data)
            #expect(decoded == reason)
        }
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

    @Test("CreateMessage result")
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

        if case .text(let text) = decoded.content {
            #expect(text == "The weather is sunny and 75°F.")
        } else {
            #expect(Bool(false), "Expected text content")
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

    @Test("Server capabilities include sampling")
    func testServerCapabilitiesIncludeSampling() throws {
        let capabilities = Server.Capabilities(
            sampling: .init()
        )

        #expect(capabilities.sampling != nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)

        #expect(decoded.sampling != nil)
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

    @Test("Client sampling handler registration")
    func testClientSamplingHandlerRegistration() async throws {
        let client = Client(name: "TestClient", version: "1.0")

        // Test that sampling handler can be registered
        let handlerClient = await client.withSamplingHandler { parameters in
            // Mock handler that returns a simple response
            return CreateSamplingMessage.Result(
                model: "test-model",
                stopReason: .endTurn,
                role: .assistant,
                content: .text("Test response")
            )
        }

        // Should return self for method chaining
        #expect(handlerClient === client)
    }

    @Test("Server sampling request method")
    func testServerSamplingRequestMethod() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(sampling: .init())
        )

        try await server.start(transport: transport)

        // Test that server can attempt to request sampling
        let messages: [Sampling.Message] = [
            .user("Test message")
        ]

        do {
            _ = try await server.requestSampling(
                messages: messages,
                maxTokens: 100
            )
            #expect(
                Bool(false),
                "Should have thrown an error for unimplemented bidirectional communication")
        } catch let error as MCPError {
            if case .internalError(let message) = error {
                #expect(
                    message?.contains("Bidirectional sampling requests not yet implemented") == true
                )
            } else {
                #expect(Bool(false), "Expected internalError, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        await server.stop()
    }

    @Test("Sampling message content JSON format")
    func testSamplingMessageContentJSONFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // Test text content JSON format
        let textContent: Sampling.Message.Content = .text("Hello")
        let textData = try encoder.encode(textContent)
        let textJSON = String(data: textData, encoding: .utf8)!

        #expect(textJSON.contains("\"type\":\"text\""))
        #expect(textJSON.contains("\"text\":\"Hello\""))

        // Test image content JSON format
        let imageContent: Sampling.Message.Content = .image(
            data: "base64data", mimeType: "image/png")
        let imageData = try encoder.encode(imageContent)
        let imageJSON = String(data: imageData, encoding: .utf8)!

        #expect(imageJSON.contains("\"type\":\"image\""))
        #expect(imageJSON.contains("\"data\":\"base64data\""))
        #expect(imageJSON.contains("\"mimeType\":\"image\\/png\""))
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
        if case .text(let text) = userMessage.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message factory method
        let assistantMessage: Sampling.Message = .assistant("Hi there!")
        #expect(assistantMessage.role == .assistant)
        if case .text(let text) = assistantMessage.content {
            #expect(text == "Hi there!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test with image content
        let imageMessage: Sampling.Message = .user(
            .image(data: "base64data", mimeType: "image/png"))
        #expect(imageMessage.role == .user)
        if case .image(let data, let mimeType) = imageMessage.content {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }
    }

    @Test("Content ExpressibleByStringLiteral")
    func testContentExpressibleByStringLiteral() throws {
        // Test string literal assignment
        let content: Sampling.Message.Content = "Hello from string literal"

        if case .text(let text) = content {
            #expect(text == "Hello from string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation
        let message: Sampling.Message = .user("Direct string literal")
        if case .text(let text) = message.content {
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
        let content: Sampling.Message.Content =
            "Hello \(userName), the temperature in \(location) is \(temperature)°F"

        if case .text(let text) = content {
            #expect(text == "Hello Alice, the temperature in San Francisco is 72°F")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation with interpolation
        let message = Sampling.Message.user(
            "Welcome \(userName)! Today's weather in \(location) is \(temperature)°F")
        if case .text(let text) = message.content {
            #expect(text == "Welcome Alice! Today's weather in San Francisco is 72°F")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test complex interpolation
        let items = ["apples", "bananas", "oranges"]
        let count = items.count
        let listMessage: Sampling.Message = .assistant(
            "You have \(count) items: \(items.joined(separator: ", "))")

        if case .text(let text) = listMessage.content {
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
        if case .text(let text) = userMessage.content {
            #expect(text == "Hi, I'm Bob and I have an issue with order ORD-12345")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message with interpolation
        let assistantMessage: Sampling.Message = .assistant(
            "Hello \(customerName), I can help you with your \(issueType) issue for order \(orderNumber)"
        )
        #expect(assistantMessage.role == .assistant)
        if case .text(let text) = assistantMessage.content {
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
        if case .text(let text) = conversation[2].content {
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

        let data = try encoder.encode(simpleConversation)
        let decoded = try decoder.decode([Sampling.Message].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].role == .user)
        #expect(decoded[1].role == .assistant)
        #expect(decoded[2].role == .user)
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

        // Server with sampling capability
        let server = Server(
            name: "SamplingTestServer",
            version: "1.0.0",
            capabilities: .init(
                sampling: .init(),  // Enable sampling
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

        // Test initialization and capability negotiation
        let initTask = Task {
            let result = try await client.initialize()

            #expect(result.serverInfo.name == "SamplingTestServer")
            #expect(result.serverInfo.version == "1.0.0")
            #expect(
                result.capabilities.sampling != nil, "Server should advertise sampling capability")
            #expect(result.protocolVersion == Version.latest)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                initTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await initTask.value
            }
            try await group.next()
            group.cancelAll()
        }

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
    func testSamplingHandlerRegistration() async throws {
        let client = Client(
            name: "SamplingHandlerTestClient",
            version: "1.0"
        )

        // Register sampling handler
        let handlerClient = await client.withSamplingHandler { parameters in
            // Mock LLM response
            return CreateSamplingMessage.Result(
                model: "test-model-v1",
                stopReason: .endTurn,
                role: .assistant,
                content: .text("This is a test completion from the mock LLM.")
            )
        }

        // Verify method chaining works
        #expect(
            handlerClient === client, "withSamplingHandler should return self for method chaining")

        // Note: We can't test the actual handler invocation without bidirectional transport,
        // but we can verify the handler registration doesn't crash and returns correctly
    }

    @Test(
        .timeLimit(.minutes(1))
    )
    func testServerSamplingRequestAPI() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "SamplingRequestTestServer",
            version: "1.0",
            capabilities: .init(sampling: .init())
        )

        try await server.start(transport: transport)

        // Test sampling request with comprehensive parameters
        let messages: [Sampling.Message] = [
            .user("Analyze the following data and provide insights:"),
            .user("Sales data: Q1: $100k, Q2: $150k, Q3: $200k, Q4: $180k"),
            .user("Marketing data: Q1: $50k, Q2: $75k, Q3: $100k, Q4: $90k"),
        ]

        let modelPreferences = Sampling.ModelPreferences(
            hints: [
                Sampling.ModelPreferences.Hint(name: "claude-4-sonnet"),
                Sampling.ModelPreferences.Hint(name: "gpt-4.1"),
            ],
            costPriority: 0.3,
            speedPriority: 0.7,
            intelligencePriority: 0.9
        )

        // Test that the API accepts all parameters correctly
        do {
            _ = try await server.requestSampling(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: "You are a business analyst expert.",
                includeContext: .thisServer,
                temperature: 0.7,
                maxTokens: 500,
                stopSequences: ["END_ANALYSIS", "\n\n---"],
                metadata: [
                    "requestId": "test-123",
                    "priority": "high",
                    "department": "analytics",
                ]
            )
            #expect(Bool(false), "Should throw error for unimplemented bidirectional communication")
        } catch let error as MCPError {
            if case .internalError(let message) = error {
                #expect(
                    message?.contains("Bidirectional sampling requests not yet implemented")
                        == true,
                    "Should indicate bidirectional communication not implemented"
                )
            } else {
                #expect(Bool(false), "Expected internalError, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        await server.stop()
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
        if case .text(let text) = decodedTextMessage.content {
            #expect(text == "What do you see in this data?")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test image message
        let imageData = try encoder.encode(imageMessage)
        let decodedImageMessage = try decoder.decode(Sampling.Message.self, from: imageData)
        #expect(decodedImageMessage.role == .user)
        if case .image(let data, let mimeType) = decodedImageMessage.content {
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
    func testSamplingErrorHandling() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "ErrorTestServer",
            version: "1.0",
            capabilities: .init()  // No sampling capability
        )

        try await server.start(transport: transport)

        // Test sampling request on server without sampling capability
        let messages: [Sampling.Message] = [
            .user("Test message")
        ]

        do {
            _ = try await server.requestSampling(
                messages: messages,
                maxTokens: 100
            )
            #expect(Bool(false), "Should throw error for missing connection")
        } catch let error as MCPError {
            if case .internalError(let message) = error {
                #expect(
                    message?.contains("Server connection not initialized") == true
                        || message?.contains("Bidirectional sampling requests not yet implemented")
                            == true,
                    "Should indicate connection or implementation issue"
                )
            } else {
                #expect(Bool(false), "Expected internalError, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        await server.stop()
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
