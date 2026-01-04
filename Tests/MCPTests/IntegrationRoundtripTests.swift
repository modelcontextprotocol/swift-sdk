import Foundation
import Testing

@testable import MCP

/// Integration roundtrip tests that verify full client-server communication flows.
///
/// These tests are based on the Python SDK's `tests/server/fastmcp/test_integration.py`
/// and TypeScript SDK's integration tests. They test complete roundtrip scenarios
/// including callbacks, notifications, and bi-directional communication.
///
/// Key test patterns covered:
/// - `test_basic_prompts` - GetPrompt with argument substitution
/// - `test_tool_progress` - Progress notifications during tool execution
/// - `test_sampling` - Server requesting LLM sampling from client
/// - `test_elicitation` - Server requesting user input from client
/// - `test_notifications` - Logging and list change notifications

@Suite("Integration Roundtrip Tests")
struct IntegrationRoundtripTests {

    // MARK: - Basic Tools Roundtrip Tests

    /// Tests basic tool functionality with list and call operations.
    ///
    /// Based on Python SDK's `test_basic_tools`:
    /// 1. Client lists tools
    /// 2. Client calls tools with arguments
    /// 3. Server executes and returns results
    @Test("Basic tools roundtrip - list and call")
    func testBasicToolsRoundtrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        // Register tools
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "sum",
                    description: "Adds two numbers",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "a": ["type": "integer", "description": "First number"],
                            "b": ["type": "integer", "description": "Second number"],
                        ],
                        "required": ["a", "b"],
                    ]
                ),
                Tool(
                    name: "get_weather",
                    description: "Gets weather for a city",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "city": ["type": "string", "description": "City name"]
                        ],
                        "required": ["city"],
                    ]
                ),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            switch request.name {
            case "sum":
                let a = request.arguments?["a"]?.intValue ?? 0
                let b = request.arguments?["b"]?.intValue ?? 0
                return CallTool.Result(content: [.text("\(a + b)")])

            case "get_weather":
                let city = request.arguments?["city"]?.stringValue ?? "Unknown"
                return CallTool.Result(content: [
                    .text("Weather in \(city): 22°C, Sunny")
                ])

            default:
                return CallTool.Result(
                    content: [.text("Unknown tool: \(request.name)")],
                    isError: true
                )
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "ToolTestClient", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        // Verify tools capability
        #expect(initResult.capabilities.tools != nil)

        // Test listing tools
        let toolsResult = try await client.listTools()
        #expect(toolsResult.tools.count == 2)

        let sumTool = toolsResult.tools.first { $0.name == "sum" }
        #expect(sumTool != nil)
        #expect(sumTool?.description == "Adds two numbers")

        let weatherTool = toolsResult.tools.first { $0.name == "get_weather" }
        #expect(weatherTool != nil)

        // Test sum tool
        let sumResult = try await client.callTool(
            name: "sum",
            arguments: ["a": 5, "b": 3]
        )
        #expect(sumResult.content.count == 1)
        if case .text(let text, _, _) = sumResult.content[0] {
            #expect(text == "8")
        } else {
            Issue.record("Expected text content")
        }

        // Test weather tool
        let weatherResult = try await client.callTool(
            name: "get_weather",
            arguments: ["city": "London"]
        )
        #expect(weatherResult.content.count == 1)
        if case .text(let text, _, _) = weatherResult.content[0] {
            #expect(text.contains("Weather in London"))
            #expect(text.contains("22°C"))
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Tests that calling an unknown tool returns an error.
    ///
    /// Based on TypeScript SDK's integration tests for error handling.
    @Test("Unknown tool returns error")
    func testUnknownToolReturnsError() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "known_tool", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "known_tool" {
                return CallTool.Result(content: [.text("OK")])
            }
            return CallTool.Result(
                content: [.text("Unknown tool: \(request.name)")],
                isError: true
            )
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "ToolTestClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        // Call unknown tool
        let result = try await client.callTool(
            name: "nonexistent_tool",
            arguments: [:]
        )

        #expect(result.isError == true)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Unknown tool"))
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Basic Resources Roundtrip Tests

    /// Tests basic resource functionality with list and read operations.
    ///
    /// Based on Python SDK's `test_basic_resources`:
    /// 1. Client lists resources
    /// 2. Client reads resources
    /// 3. Server returns resource contents
    @Test("Basic resources roundtrip - list and read")
    func testBasicResourcesRoundtrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ResourceServer",
            version: "1.0.0",
            capabilities: .init(resources: .init())
        )

        // Register resources
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(
                    name: "readme",
                    uri: "file://documents/readme",
                    description: "Project readme file",
                    mimeType: "text/plain"
                ),
                Resource(
                    name: "settings",
                    uri: "config://settings",
                    description: "Application settings",
                    mimeType: "application/json"
                ),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            switch request.uri {
            case "file://documents/readme":
                return ReadResource.Result(contents: [
                    .text("# Project Readme\n\nContent of readme file.", uri: request.uri)
                ])

            case "config://settings":
                let settingsJSON = """
                    {"theme": "dark", "language": "en", "notifications": true}
                    """
                return ReadResource.Result(contents: [
                    .text(settingsJSON, uri: request.uri, mimeType: "application/json")
                ])

            default:
                throw MCPError.resourceNotFound(uri: request.uri)
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "ResourceTestClient", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        // Verify resources capability
        #expect(initResult.capabilities.resources != nil)

        // Test listing resources
        let resourcesResult = try await client.listResources()
        #expect(resourcesResult.resources.count == 2)

        let readme = resourcesResult.resources.first { $0.name == "readme" }
        #expect(readme != nil)
        #expect(readme?.uri == "file://documents/readme")
        #expect(readme?.mimeType == "text/plain")

        let settings = resourcesResult.resources.first { $0.name == "settings" }
        #expect(settings != nil)
        #expect(settings?.uri == "config://settings")

        // Test reading readme resource
        let readmeResult = try await client.readResource(uri: "file://documents/readme")
        #expect(readmeResult.contents.count == 1)
        let readmeContent = readmeResult.contents[0]
        #expect(readmeContent.text?.contains("Project Readme") == true)
        #expect(readmeContent.text?.contains("Content of readme") == true)
        #expect(readmeContent.uri == "file://documents/readme")

        // Test reading settings resource
        let settingsResult = try await client.readResource(uri: "config://settings")
        #expect(settingsResult.contents.count == 1)
        let settingsContent = settingsResult.contents[0]
        #expect(settingsContent.text?.contains("\"theme\": \"dark\"") == true)
        #expect(settingsContent.text?.contains("\"language\": \"en\"") == true)
        #expect(settingsContent.mimeType == "application/json")

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Prompts Roundtrip Tests

    /// Tests full getPrompt roundtrip with argument substitution.
    ///
    /// Based on Python SDK's `test_basic_prompts`:
    /// 1. Client lists prompts
    /// 2. Client gets a prompt with arguments
    /// 3. Server substitutes arguments into prompt messages
    /// 4. Client receives the formatted prompt
    @Test("GetPrompt roundtrip with argument substitution")
    func testGetPromptRoundtrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "PromptServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init())
        )

        // Register prompts
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [
                Prompt(
                    name: "review_code",
                    description: "Reviews code and provides feedback",
                    arguments: [
                        Prompt.Argument(name: "code", description: "The code to review", required: true)
                    ]
                ),
                Prompt(
                    name: "debug_error",
                    description: "Helps debug an error",
                    arguments: [
                        Prompt.Argument(name: "error", description: "The error message", required: true)
                    ]
                ),
            ])
        }

        // Handle getPrompt with argument substitution
        await server.withRequestHandler(GetPrompt.self) { request, _ in
            switch request.name {
            case "review_code":
                let code = request.arguments?["code"] ?? ""
                return GetPrompt.Result(
                    description: "Code review prompt",
                    messages: [
                        .user("Please review this code:\n\n\(code)")
                    ]
                )

            case "debug_error":
                let error = request.arguments?["error"] ?? ""
                return GetPrompt.Result(
                    description: "Debug error prompt",
                    messages: [
                        .user("I'm seeing this error:"),
                        .user(.text(error)),
                        .assistant("I'll help debug that error. Let me analyze it."),
                    ]
                )

            default:
                throw MCPError.invalidParams("Unknown prompt: \(request.name)")
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "PromptTestClient", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        // Verify prompts capability
        #expect(initResult.capabilities.prompts != nil)

        // Test listing prompts
        let promptsList = try await client.listPrompts()
        #expect(promptsList.prompts.count == 2)
        let reviewPrompt = promptsList.prompts.first { $0.name == "review_code" }
        #expect(reviewPrompt != nil)
        #expect(reviewPrompt?.arguments?.first?.name == "code")

        // Test review_code prompt with argument substitution
        let codeToReview = "def hello():\n    print('Hello')"
        let reviewResult = try await client.getPrompt(
            name: "review_code",
            arguments: ["code": codeToReview]
        )
        #expect(reviewResult.messages.count == 1)
        if case .text(let text, _, _) = reviewResult.messages[0].content {
            #expect(text.contains("Please review this code:"))
            #expect(text.contains("def hello():"))
        } else {
            Issue.record("Expected text content")
        }

        // Test debug_error prompt with multi-message response
        let errorMessage = "TypeError: 'NoneType' object is not subscriptable"
        let debugResult = try await client.getPrompt(
            name: "debug_error",
            arguments: ["error": errorMessage]
        )
        #expect(debugResult.messages.count == 3)
        #expect(debugResult.messages[0].role == .user)
        #expect(debugResult.messages[1].role == .user)
        #expect(debugResult.messages[2].role == .assistant)

        if case .text(let text, _, _) = debugResult.messages[0].content {
            #expect(text.contains("I'm seeing this error:"))
        } else {
            Issue.record("Expected text content for first message")
        }

        if case .text(let text, _, _) = debugResult.messages[1].content {
            #expect(text.contains("TypeError"))
        } else {
            Issue.record("Expected text content for second message")
        }

        if case .text(let text, _, _) = debugResult.messages[2].content {
            #expect(text.contains("I'll help debug"))
        } else {
            Issue.record("Expected text content for third message")
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Progress Notifications Roundtrip Tests

    /// Tests progress notifications during tool execution.
    ///
    /// Based on Python SDK's `test_tool_progress`:
    /// 1. Client calls a long-running tool with a progress token
    /// 2. Server sends progress notifications during execution
    /// 3. Client receives and tracks progress updates
    @Test("Progress notifications during tool execution")
    func testProgressNotificationsDuringToolExecution() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ProgressServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "long_running_task",
                    description: "A task that reports progress",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "task_name": ["type": "string"],
                            "steps": ["type": "integer"],
                        ],
                    ]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, context in
            let taskName = request.arguments?["task_name"]?.stringValue ?? "Task"
            let steps = request.arguments?["steps"]?.intValue ?? 3

            // Send progress notifications for each step
            for step in 1...steps {
                let progress = Double(step) / Double(steps)
                let message = "Step \(step)/\(steps): Processing..."

                // Send progress notification using sendMessage
                try await context.sendMessage(ProgressNotification.message(.init(
                    progressToken: .string("progress-token"),
                    progress: progress,
                    total: 1.0,
                    message: message
                )))

                // Simulate work
                try? await Task.sleep(for: .milliseconds(10))
            }

            return CallTool.Result(content: [
                .text("Task '\(taskName)' completed after \(steps) steps")
            ])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "ProgressTestClient", version: "1.0.0")

        // Track progress updates received by the client
        let clientProgressUpdates = ClientProgressUpdates()

        await client.onNotification(ProgressNotification.self) { [clientProgressUpdates] message in
            await clientProgressUpdates.append(
                progress: message.params.progress,
                total: message.params.total,
                message: message.params.message
            )
        }

        _ = try await client.connect(transport: clientTransport)

        // Call tool
        let result = try await client.callTool(
            name: "long_running_task",
            arguments: ["task_name": "Test Task", "steps": 3]
        )

        // Give notifications time to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify tool completed successfully
        #expect(result.content.count == 1)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Test Task"))
            #expect(text.contains("completed"))
        } else {
            Issue.record("Expected text content")
        }

        // Verify progress updates were received
        let updates = await clientProgressUpdates.updates
        #expect(updates.count == 3)

        // Verify progress values
        for (index, update) in updates.enumerated() {
            let expectedProgress = Double(index + 1) / 3.0
            #expect(abs(update.progress - expectedProgress) < 0.01)
            #expect(update.total == 1.0)
            #expect(update.message?.contains("Step \(index + 1)/3") == true)
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Sampling Roundtrip Tests

    /// Tests server requesting LLM sampling from client during tool execution.
    ///
    /// Based on Python SDK's `test_sampling`:
    /// 1. Client calls a tool that needs LLM assistance
    /// 2. Server sends CreateSamplingMessage request to client
    /// 3. Client's sampling callback processes the request
    /// 4. Server receives the LLM response and completes the tool
    @Test("Sampling roundtrip - server requests LLM from client")
    func testSamplingRoundtrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "SamplingServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "generate_poem",
                    description: "Generates a poem using LLM",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "topic": ["type": "string"]
                        ],
                    ]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] request, _ in
            let topic = request.arguments?["topic"]?.stringValue ?? "nature"

            // Server requests LLM sampling from client
            let samplingResult = try await server.createMessage(
                CreateSamplingMessage.Parameters(
                    messages: [.user("Write a short poem about \(topic)")],
                    systemPrompt: "You are a creative poet.",
                    maxTokens: 100
                )
            )

            // Return the LLM response
            if case .text(let text, _, _) = samplingResult.content {
                return CallTool.Result(content: [.text("Generated poem:\n\(text)")])
            } else {
                return CallTool.Result(content: [.text("Failed to generate poem")])
            }
        }

        try await server.start(transport: serverTransport)

        // Create client with sampling capability
        let samplingCallbackInvoked = SamplingCallbackTracker()

        let client = Client(name: "SamplingTestClient", version: "1.0.0")

        // Set client capabilities
        await client.setCapabilities(Client.Capabilities(
            sampling: Client.Capabilities.Sampling()
        ))

        // Set up sampling callback that simulates LLM response
        await client.withRequestHandler(CreateSamplingMessage.self) { [samplingCallbackInvoked] params, _ in
            await samplingCallbackInvoked.record(params: params)

            // Return simulated LLM response
            return CreateSamplingMessage.Result(
                model: "test-model",
                stopReason: .endTurn,
                role: .assistant,
                content: .text("This is a simulated LLM response for testing")
            )
        }

        _ = try await client.connect(transport: clientTransport)

        // Call the tool that triggers sampling
        let result = try await client.callTool(
            name: "generate_poem",
            arguments: ["topic": "nature"]
        )

        // Verify sampling callback was invoked
        let invocations = await samplingCallbackInvoked.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].messages.count == 1)
        if case .text(let text, _, _) = invocations[0].messages[0].content.first {
            #expect(text.contains("poem"))
            #expect(text.contains("nature"))
        }
        #expect(invocations[0].systemPrompt == "You are a creative poet.")

        // Verify tool returned the LLM response
        #expect(result.content.count == 1)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("simulated LLM response"))
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Elicitation Roundtrip Tests

    /// Tests server requesting user input from client during tool execution.
    ///
    /// Based on Python SDK's `test_elicitation`:
    /// 1. Client calls a tool that needs user input
    /// 2. Server sends elicitation request to client
    /// 3. Client's elicitation callback processes the request
    /// 4. Server receives the user response and completes the tool
    @Test("Elicitation roundtrip - server requests user input from client")
    func testElicitationRoundtrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ElicitationServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "book_table",
                    description: "Books a restaurant table",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "date": ["type": "string"],
                            "time": ["type": "string"],
                            "party_size": ["type": "integer"],
                        ],
                    ]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] request, _ in
            let date = request.arguments?["date"]?.stringValue ?? ""
            let time = request.arguments?["time"]?.stringValue ?? ""
            let partySize = request.arguments?["party_size"]?.intValue ?? 2

            // Simulate date unavailable - request alternative from user
            if date == "2024-12-25" {
                let elicitResult = try await server.elicit(ElicitRequestParams.form(ElicitRequestFormParams(
                    message: "No tables available for \(date). Would you like to try an alternative date?",
                    requestedSchema: ElicitationSchema(
                        properties: [
                            "checkAlternative": .boolean(BooleanSchema(
                                title: "Try Alternative",
                                description: "Would you like to try an alternative date?"
                            )),
                            "alternativeDate": .string(StringSchema(
                                title: "Alternative Date",
                                description: "Enter an alternative date"
                            )),
                        ],
                        required: ["checkAlternative"]
                    )
                )))

                if elicitResult.action == .accept,
                    let checkAlt = elicitResult.content?["checkAlternative"]?.boolValue,
                    checkAlt,
                    let altDate = elicitResult.content?["alternativeDate"]?.stringValue
                {
                    return CallTool.Result(content: [
                        .text("[SUCCESS] Booked for \(altDate) at \(time) for \(partySize) guests")
                    ])
                } else {
                    return CallTool.Result(content: [
                        .text("[CANCELLED] Booking cancelled by user")
                    ])
                }
            }

            // Date is available
            return CallTool.Result(content: [
                .text("[SUCCESS] Booked for \(date) at \(time) for \(partySize) guests")
            ])
        }

        try await server.start(transport: serverTransport)

        // Create client with elicitation capability
        let elicitationCallbackInvoked = ElicitationCallbackTracker()

        let client = Client(name: "ElicitationTestClient", version: "1.0.0")

        // Set client capabilities
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        // Set up elicitation callback
        await client.withElicitationHandler { [elicitationCallbackInvoked] params, _ in
            await elicitationCallbackInvoked.record(params: params)

            // Simulate user accepting and providing alternative date
            if case .form(let formParams) = params {
                if formParams.message.contains("No tables available") {
                    return ElicitResult(
                        action: .accept,
                        content: [
                            "checkAlternative": .bool(true),
                            "alternativeDate": .string("2024-12-26"),
                        ]
                    )
                }
            }

            return ElicitResult(action: .decline)
        }

        _ = try await client.connect(transport: clientTransport)

        // Test booking with unavailable date (triggers elicitation)
        let result1 = try await client.callTool(
            name: "book_table",
            arguments: [
                "date": "2024-12-25",
                "time": "19:00",
                "party_size": 4,
            ]
        )

        // Verify elicitation was invoked
        let invocations = await elicitationCallbackInvoked.invocations
        #expect(invocations.count == 1)

        // Verify booking succeeded with alternative date
        #expect(result1.content.count == 1)
        if case .text(let text, _, _) = result1.content[0] {
            #expect(text.contains("[SUCCESS]"))
            #expect(text.contains("2024-12-26"))
        } else {
            Issue.record("Expected text content")
        }

        // Test booking with available date (no elicitation)
        let result2 = try await client.callTool(
            name: "book_table",
            arguments: [
                "date": "2024-12-20",
                "time": "20:00",
                "party_size": 2,
            ]
        )

        // Verify no additional elicitation was triggered
        let invocationsAfter = await elicitationCallbackInvoked.invocations
        #expect(invocationsAfter.count == 1)  // Still just 1

        // Verify booking succeeded directly
        if case .text(let text, _, _) = result2.content[0] {
            #expect(text.contains("[SUCCESS]"))
            #expect(text.contains("2024-12-20"))
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Logging Notifications Roundtrip Tests

    /// Tests logging notifications at different levels during tool execution.
    ///
    /// Based on Python SDK's `test_notifications`:
    /// 1. Client calls a tool that generates log messages
    /// 2. Server sends log notifications at various levels
    /// 3. Client receives and collects the log messages
    @Test("Logging notifications during tool execution")
    func testLoggingNotificationsDuringToolExecution() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "LoggingServer",
            version: "1.0.0",
            capabilities: .init(logging: .init(), tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "process_data",
                    description: "Processes data and logs progress",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "data": ["type": "string"]
                        ],
                    ]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, context in
            let data = request.arguments?["data"]?.stringValue ?? ""

            // Send log messages at different levels using sendMessage
            try await context.sendMessage(LogMessageNotification.message(.init(
                level: .debug,
                logger: "process",
                data: .string("Starting to process data")
            )))
            try await context.sendMessage(LogMessageNotification.message(.init(
                level: .info,
                logger: "process",
                data: .string("Processing: \(data)")
            )))
            try await context.sendMessage(LogMessageNotification.message(.init(
                level: .warning,
                logger: "process",
                data: .string("Data contains special characters")
            )))
            try await context.sendMessage(LogMessageNotification.message(.init(
                level: .error,
                logger: "process",
                data: .string("Simulated error for testing")
            )))

            return CallTool.Result(content: [.text("Processed: \(data)")])
        }

        try await server.start(transport: serverTransport)

        // Create client and track notifications
        let logCollector = LogCollector()

        let client = Client(name: "LoggingTestClient", version: "1.0.0")

        // Set up notification handler
        await client.onNotification(LogMessageNotification.self) { [logCollector] message in
            await logCollector.append(message.params)
        }

        _ = try await client.connect(transport: clientTransport)

        // Call tool that generates log messages
        let result = try await client.callTool(
            name: "process_data",
            arguments: ["data": "test_data"]
        )

        // Verify tool completed
        #expect(result.content.count == 1)
        if case .text(let text, _, _) = result.content[0] {
            #expect(text.contains("Processed: test_data"))
        }

        // Give notifications time to arrive
        try await Task.sleep(for: .milliseconds(100))

        // Verify log messages at different levels
        let logs = await logCollector.logs
        #expect(logs.count >= 4)

        let levels = Set(logs.map { $0.level })
        #expect(levels.contains(.debug))
        #expect(levels.contains(.info))
        #expect(levels.contains(.warning))
        #expect(levels.contains(.error))

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Resource List Changed Notification Test

    /// Tests resource list changed notifications.
    ///
    /// Based on Python SDK's `test_notifications` (resource notifications part).
    @Test("Resource list changed notification during tool execution")
    func testResourceListChangedNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "ResourceNotificationServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(listChanged: true), tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "create_resource",
                    description: "Creates a new resource",
                    inputSchema: ["type": "object"]
                )
            ])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "Initial Resource", uri: "test://initial")
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Notify that resource list has changed
            try await context.sendNotification(ResourceListChangedNotification())

            return CallTool.Result(content: [.text("Resource created")])
        }

        try await server.start(transport: serverTransport)

        // Track resource list changed notifications
        let notificationReceived = NotificationTracker()

        let client = Client(name: "ResourceNotificationClient", version: "1.0.0")

        await client.onNotification(ResourceListChangedNotification.self) { [notificationReceived] _ in
            await notificationReceived.recordNotification()
        }

        _ = try await client.connect(transport: clientTransport)

        // Call tool that triggers notification
        _ = try await client.callTool(name: "create_resource", arguments: nil)

        // Give notification time to arrive
        try await Task.sleep(for: .milliseconds(100))

        // Verify notification was received
        let received = await notificationReceived.wasNotified
        #expect(received)

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Tool List Changed With Refresh Tests

    /// Tests that client receives tool list changed notification and can refresh the list.
    ///
    /// Based on TypeScript SDK's `should handle tool list changed notification with auto refresh`:
    /// 1. Client connects and lists tools
    /// 2. Server sends tool list changed notification (triggered via a tool call)
    /// 3. Client receives notification and re-fetches tools
    /// 4. Client sees updated tool list
    @Test("Tool list changed notification with refresh")
    func testToolListChangedNotificationWithRefresh() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track available tools (mutable)
        let toolRegistry = ToolRegistry()

        let server = Server(
            name: "DynamicToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: true))
        )

        // Dynamic tool list handler
        await server.withRequestHandler(ListTools.self) { [toolRegistry] _, _ in
            let tools = await toolRegistry.getTools()
            return ListTools.Result(tools: tools)
        }

        await server.withRequestHandler(CallTool.self) { [toolRegistry] request, context in
            switch request.name {
            case "add_tool":
                // Add the new tool and send notification
                let toolName = request.arguments?["name"]?.stringValue ?? "unnamed"
                await toolRegistry.addTool(Tool(
                    name: toolName,
                    description: "Dynamically added",
                    inputSchema: ["type": "object"]
                ))
                try await context.sendToolListChanged()
                return CallTool.Result(content: [.text("Added tool: \(toolName)")])
            default:
                return CallTool.Result(content: [.text("Called: \(request.name)")])
            }
        }

        try await server.start(transport: serverTransport)

        // Add initial tools
        await toolRegistry.addTool(Tool(
            name: "initial_tool",
            description: "Initial tool",
            inputSchema: ["type": "object"]
        ))
        await toolRegistry.addTool(Tool(
            name: "add_tool",
            description: "Tool that adds a new tool",
            inputSchema: ["type": "object", "properties": ["name": ["type": "string"]]]
        ))

        let client = Client(name: "DynamicToolClient", version: "1.0.0")

        // Track notifications
        let notificationReceived = ToolListChangedTracker()

        await client.onNotification(ToolListChangedNotification.self) { [notificationReceived] _ in
            await notificationReceived.recordNotification()
        }

        _ = try await client.connect(transport: clientTransport)

        // Initial list should have 2 tools
        let initialToolsResult = try await client.listTools()
        #expect(initialToolsResult.tools.count == 2)
        #expect(initialToolsResult.tools.contains { $0.name == "initial_tool" })
        #expect(initialToolsResult.tools.contains { $0.name == "add_tool" })

        // Call the add_tool which adds a new tool and sends notification
        _ = try await client.callTool(name: "add_tool", arguments: ["name": "new_tool"])

        // Wait for notification to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify notification was received
        let received = await notificationReceived.wasNotified
        #expect(received)

        // Client refreshes tool list after notification
        let refreshedToolsResult = try await client.listTools()
        #expect(refreshedToolsResult.tools.count == 3)
        #expect(refreshedToolsResult.tools.contains { $0.name == "initial_tool" })
        #expect(refreshedToolsResult.tools.contains { $0.name == "add_tool" })
        #expect(refreshedToolsResult.tools.contains { $0.name == "new_tool" })

        await client.disconnect()
        await server.stop()
    }

    /// Tests that client receives prompt list changed notification and can refresh the list.
    ///
    /// Based on TypeScript SDK's `should handle prompt list changed notification with auto refresh`.
    @Test("Prompt list changed notification with refresh")
    func testPromptListChangedNotificationWithRefresh() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track available prompts (mutable)
        let promptRegistry = PromptRegistry()

        let server = Server(
            name: "DynamicPromptServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init(listChanged: true), tools: .init())
        )

        // Dynamic prompt list handler
        await server.withRequestHandler(ListPrompts.self) { [promptRegistry] _, _ in
            let prompts = await promptRegistry.getPrompts()
            return ListPrompts.Result(prompts: prompts)
        }

        await server.withRequestHandler(GetPrompt.self) { request, _ in
            GetPrompt.Result(description: nil, messages: [.user("Prompt: \(request.name)")])
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "add_prompt", inputSchema: ["type": "object", "properties": ["name": ["type": "string"]]])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [promptRegistry] request, context in
            guard request.name == "add_prompt" else {
                return CallTool.Result(content: [.text("Unknown tool")], isError: true)
            }
            // Add the new prompt and send notification
            let promptName = request.arguments?["name"]?.stringValue ?? "unnamed"
            await promptRegistry.addPrompt(Prompt(
                name: promptName,
                description: "Dynamically added"
            ))
            try await context.sendPromptListChanged()
            return CallTool.Result(content: [.text("Added prompt: \(promptName)")])
        }

        try await server.start(transport: serverTransport)

        // Add initial prompt
        await promptRegistry.addPrompt(Prompt(
            name: "initial_prompt",
            description: "Initial prompt"
        ))

        let client = Client(name: "DynamicPromptClient", version: "1.0.0")

        // Track notifications
        let notificationReceived = PromptListChangedTracker()

        await client.onNotification(PromptListChangedNotification.self) { [notificationReceived] _ in
            await notificationReceived.recordNotification()
        }

        _ = try await client.connect(transport: clientTransport)

        // Initial list should have 1 prompt
        let initialPrompts = try await client.listPrompts()
        #expect(initialPrompts.prompts.count == 1)
        #expect(initialPrompts.prompts[0].name == "initial_prompt")

        // Call tool that adds a new prompt and sends notification
        _ = try await client.callTool(name: "add_prompt", arguments: ["name": "new_prompt"])

        // Wait for notification to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify notification was received
        let received = await notificationReceived.wasNotified
        #expect(received)

        // Client refreshes prompt list after notification
        let refreshedPrompts = try await client.listPrompts()
        #expect(refreshedPrompts.prompts.count == 2)
        #expect(refreshedPrompts.prompts.contains { $0.name == "initial_prompt" })
        #expect(refreshedPrompts.prompts.contains { $0.name == "new_prompt" })

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - Test Helpers

/// Tracks progress updates received by the client.
private actor ClientProgressUpdates {
    struct Update {
        let progress: Double
        let total: Double?
        let message: String?
    }

    var updates: [Update] = []

    func append(progress: Double, total: Double?, message: String?) {
        updates.append(Update(progress: progress, total: total, message: message))
    }
}

/// Tracks sampling callback invocations.
private actor SamplingCallbackTracker {
    var invocations: [CreateSamplingMessage.Parameters] = []

    func record(params: CreateSamplingMessage.Parameters) {
        invocations.append(params)
    }
}

/// Tracks elicitation callback invocations.
private actor ElicitationCallbackTracker {
    var invocations: [ElicitRequestParams] = []

    func record(params: ElicitRequestParams) {
        invocations.append(params)
    }
}

/// Collects log notifications.
private actor LogCollector {
    var logs: [LogMessageNotification.Parameters] = []

    func append(_ notification: LogMessageNotification.Parameters) {
        logs.append(notification)
    }
}

/// Tracks whether a notification was received.
private actor NotificationTracker {
    var wasNotified = false

    func recordNotification() {
        wasNotified = true
    }
}

/// Registry for dynamically adding tools in tests.
private actor ToolRegistry {
    var tools: [Tool] = []

    func addTool(_ tool: Tool) {
        tools.append(tool)
    }

    func getTools() -> [Tool] {
        tools
    }
}

/// Registry for dynamically adding prompts in tests.
private actor PromptRegistry {
    var prompts: [Prompt] = []

    func addPrompt(_ prompt: Prompt) {
        prompts.append(prompt)
    }

    func getPrompts() -> [Prompt] {
        prompts
    }
}

/// Tracks whether a tool list changed notification was received.
private actor ToolListChangedTracker {
    var wasNotified = false

    func recordNotification() {
        wasNotified = true
    }
}

/// Tracks whether a prompt list changed notification was received.
private actor PromptListChangedTracker {
    var wasNotified = false

    func recordNotification() {
        wasNotified = true
    }
}
