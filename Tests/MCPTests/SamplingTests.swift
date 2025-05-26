import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Sampling Tests")
struct SamplingTests {

    @Test("Sampling.Message encoding and decoding")
    func testSamplingMessageCoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text content
        let textMessage = Sampling.Message(
            role: .user,
            content: .text("Hello, world!")
        )

        let textData = try encoder.encode(textMessage)
        let decodedTextMessage = try decoder.decode(Sampling.Message.self, from: textData)

        #expect(decodedTextMessage.role == .user)
        if case .text(let text) = decodedTextMessage.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test image content
        let imageMessage = Sampling.Message(
            role: .assistant,
            content: .image(data: "base64imagedata", mimeType: "image/png")
        )

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
                Sampling.ModelPreferences.Hint(name: "claude-3"),
                Sampling.ModelPreferences.Hint(name: "gpt-4"),
            ],
            costPriority: 0.8,
            speedPriority: 0.3,
            intelligencePriority: 0.9
        )

        let data = try encoder.encode(preferences)
        let decoded = try decoder.decode(Sampling.ModelPreferences.self, from: data)

        #expect(decoded.hints?.count == 2)
        #expect(decoded.hints?[0].name == "claude-3")
        #expect(decoded.hints?[1].name == "gpt-4")
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

        let messages = [
            Sampling.Message(role: .user, content: .text("What is the weather like?")),
            Sampling.Message(
                role: .assistant, content: .text("I need to check the weather for you.")),
        ]

        let modelPreferences = Sampling.ModelPreferences(
            hints: [Sampling.ModelPreferences.Hint(name: "claude-3-sonnet")],
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
            model: "claude-3-sonnet-20240229",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("The weather is sunny and 75°F.")
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CreateSamplingMessage.Result.self, from: data)

        #expect(decoded.model == "claude-3-sonnet-20240229")
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
        let messages = [
            Sampling.Message(role: .user, content: .text("Hello"))
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
        let messages = [
            Sampling.Message(role: .user, content: .text("Test message"))
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
        let textContent = Sampling.Message.Content.text("Hello")
        let textData = try encoder.encode(textContent)
        let textJSON = String(data: textData, encoding: .utf8)!

        #expect(textJSON.contains("\"type\":\"text\""))
        #expect(textJSON.contains("\"text\":\"Hello\""))

        // Test image content JSON format
        let imageContent = Sampling.Message.Content.image(data: "base64data", mimeType: "image/png")
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
}
