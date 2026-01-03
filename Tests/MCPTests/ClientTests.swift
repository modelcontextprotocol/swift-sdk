import Foundation
import Testing

@testable import MCP

@Suite("Client Tests")
struct ClientTests {
    @Test("Client connect and disconnect")
    func testClientConnectAndDisconnect() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        #expect(await transport.isConnected == false)

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        let result = try await client.connect(transport: transport)
        #expect(await transport.isConnected == true)
        #expect(result.protocolVersion == Version.latest)
        await client.disconnect()
        #expect(await transport.isConnected == false)
        initTask.cancel()
    }

    @Test(
        "Ping request",
        .timeLimit(.minutes(1))
    )
    func testClientPing() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Queue a response for the initialize request
        try await Task.sleep(for: .milliseconds(10))  // Wait for request to be sent

        if let lastMessage = await transport.sentMessages.last,
            let data = lastMessage.data(using: .utf8),
            let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
        {
            // Create a valid initialize response
            let response = Initialize.response(
                id: request.id,
                result: .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    serverInfo: .init(name: "TestServer", version: "1.0"),
                    instructions: nil
                )
            )

            try await transport.queue(response: response)

            // Now complete the connect call which will automatically initialize
            let result = try await client.connect(transport: transport)
            #expect(result.protocolVersion == Version.latest)
            #expect(result.serverInfo.name == "TestServer")
            #expect(result.serverInfo.version == "1.0")

            // Small delay to ensure message loop is started
            try await Task.sleep(for: .milliseconds(10))

            // Create a task for the ping
            let pingTask = Task {
                try await client.ping()
            }

            // Give it a moment to send the request
            try await Task.sleep(for: .milliseconds(10))

            #expect(await transport.sentMessages.count == 2)  // Initialize + Ping
            #expect(await transport.sentMessages.last?.contains(Ping.name) == true)

            // Cancel the ping task
            pingTask.cancel()
        }

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Connection failure handling")
    func testClientConnectionFailure() async {
        let transport = MockTransport()
        await transport.setFailConnect(true)
        let client = Client(name: "TestClient", version: "1.0")

        do {
            try await client.connect(transport: transport)
            #expect(Bool(false), "Expected connection to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }

    @Test("Send failure handling")
    func testClientSendFailure() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        // Connect first without failure
        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Now set the transport to fail sends
        await transport.setFailSend(true)

        do {
            try await client.ping()
            #expect(Bool(false), "Expected ping to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }

        await client.disconnect()
    }

    @Test("Strict configuration - capabilities check")
    func testStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.strict
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)

        // Create a task for listPrompts
        let promptsTask = Task<Void, Swift.Error> {
            do {
                _ = try await client.listPrompts()
                #expect(Bool(false), "Expected listPrompts to fail in strict mode")
            } catch let error as MCPError {
                if case MCPError.methodNotFound = error {
                    #expect(Bool(true))
                } else {
                    #expect(Bool(false), "Expected methodNotFound error, got \(error)")
                }
            } catch {
                #expect(Bool(false), "Expected MCP.Error")
            }
        }

        // Give it a short time to execute the task
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task if it's still running
        promptsTask.cancel()
        initTask.cancel()

        // Disconnect client
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Non-strict configuration - capabilities check")
    func testNonStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.default
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)

        // Make sure init task is complete
        initTask.cancel()

        // Wait a bit for any setup to complete
        try await Task.sleep(for: .milliseconds(10))

        // Send the listPrompts request and immediately provide an error response
        let promptsTask = Task {
            do {
                // Start the request
                try await Task.sleep(for: .seconds(1))

                // Get the last sent message and extract the request ID
                if let lastMessage = await transport.sentMessages.last,
                    let data = lastMessage.data(using: .utf8),
                    let decodedRequest = try? JSONDecoder().decode(
                        Request<ListPrompts>.self, from: data)
                {

                    // Create an error response with the same ID
                    let errorResponse = Response<ListPrompts>(
                        id: decodedRequest.id,
                        error: MCPError.methodNotFound("Test: Prompts capability not available")
                    )
                    try await transport.queue(response: errorResponse)

                    // Try the request now that we have a response queued
                    do {
                        _ = try await client.listPrompts()
                        #expect(Bool(false), "Expected listPrompts to fail in non-strict mode")
                    } catch let error as MCPError {
                        if case MCPError.methodNotFound = error {
                            #expect(Bool(true))
                        } else {
                            #expect(Bool(false), "Expected methodNotFound error, got \(error)")
                        }
                    } catch {
                        #expect(Bool(false), "Expected MCP.Error")
                    }
                }
            } catch {
                // Ignore task cancellation
                if !(error is CancellationError) {
                    throw error
                }
            }
        }

        // Wait for the task to complete or timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .milliseconds(500))
            promptsTask.cancel()
        }

        // Wait for the task to complete
        _ = await promptsTask.result

        // Cancel the timeout task
        timeoutTask.cancel()

        // Disconnect client
        await client.disconnect()
    }

    @Test("Batch request - success")
    func testBatchRequestSuccess() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))  // Allow connection tasks
        initTask.cancel()

        let request1 = Ping.request()
        let request2 = Ping.request()

        // Use an actor to safely capture the tasks from the closure
        actor TaskHolder {
            var task1: Task<Ping.Result, Swift.Error>?
            var task2: Task<Ping.Result, Swift.Error>?
            func set(task1: Task<Ping.Result, Swift.Error>, task2: Task<Ping.Result, Swift.Error>) {
                self.task1 = task1
                self.task2 = task2
            }
        }
        let holder = TaskHolder()

        try await client.withBatch { batch in
            let t1 = try await batch.addRequest(request1)
            let t2 = try await batch.addRequest(request2)
            await holder.set(task1: t1, task2: t2)
        }

        // Check if batch message was sent (after initialize and initialized notification)
        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 3)  // Initialize request + Initialized notification + Batch

        guard let batchData = sentMessages.last?.data(using: .utf8) else {
            #expect(Bool(false), "Failed to get batch data")
            return
        }

        // Verify the sent batch contains the two requests
        let decoder = JSONDecoder()
        let sentRequests = try decoder.decode([AnyRequest].self, from: batchData)
        #expect(sentRequests.count == 2)
        #expect(sentRequests.first?.id == request1.id)
        #expect(sentRequests.first?.method == Ping.name)
        #expect(sentRequests.last?.id == request2.id)
        #expect(sentRequests.last?.method == Ping.name)

        // Prepare batch response
        let response1 = Response<Ping>(id: request1.id, result: .init())
        let response2 = Response<Ping>(id: request2.id, result: .init())
        let anyResponse1 = try AnyResponse(response1)
        let anyResponse2 = try AnyResponse(response2)

        // Queue the batch response
        try await transport.queue(batch: [anyResponse1, anyResponse2])

        // Wait for results and verify
        guard let task1 = await holder.task1, let task2 = await holder.task2 else {
            #expect(Bool(false), "Result tasks not created")
            return
        }

        _ = try await task1.value  // Should succeed
        _ = try await task2.value  // Should succeed

        #expect(Bool(true))  // Reaching here means success

        await client.disconnect()
    }

    @Test("Batch request - mixed success/error")
    func testBatchRequestMixed() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        let request1 = Ping.request()  // Success
        let request2 = Ping.request()  // Error

        // Use an actor to safely capture the tasks from the closure
        actor TasksHolder {
            var tasks: [Task<Ping.Result, Swift.Error>] = []
            func append(_ task: Task<Ping.Result, Swift.Error>) {
                tasks.append(task)
            }
        }
        let holder = TasksHolder()

        try await client.withBatch { batch in
            await holder.append(try await batch.addRequest(request1))
            await holder.append(try await batch.addRequest(request2))
        }

        // Check if batch message was sent (after initialize and initialized notification)
        #expect(await transport.sentMessages.count == 3)  // Initialize request + Initialized notification + Batch

        // Prepare batch response (success for 1, error for 2)
        let response1 = Response<Ping>(id: request1.id, result: .init())
        let error = MCPError.internalError("Simulated batch error")
        let response2 = Response<Ping>(id: request2.id, error: error)
        let anyResponse1 = try AnyResponse(response1)
        let anyResponse2 = try AnyResponse(response2)

        // Queue the batch response
        try await transport.queue(batch: [anyResponse1, anyResponse2])

        // Wait for results and verify
        let resultTasks = await holder.tasks
        #expect(resultTasks.count == 2)
        guard resultTasks.count == 2 else {
            #expect(Bool(false), "Expected 2 result tasks")
            return
        }

        let task1 = resultTasks[0]
        let task2 = resultTasks[1]

        _ = try await task1.value  // Task 1 should succeed

        do {
            _ = try await task2.value  // Task 2 should fail
            #expect(Bool(false), "Task 2 should have thrown an error")
        } catch let mcpError as MCPError {
            if case .internalError(let message) = mcpError {
                #expect(message == "Simulated batch error")
            } else {
                #expect(Bool(false), "Expected internalError, got \(mcpError)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        await client.disconnect()
    }

    @Test("Batch request - empty")
    func testBatchRequestEmpty() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Call withBatch but don't add any requests
        try await client.withBatch { _ in
            // No requests added
        }

        // Check that only initialize message and initialized notification were sent
        #expect(await transport.sentMessages.count == 2)  // Initialize request + Initialized notification

        await client.disconnect()
    }

    @Test("Notify method sends notifications")
    func testClientNotify() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Create a test notification
        let notification = InitializedNotification.message()
        try await client.notify(notification)

        // Verify notification was sent (in addition to initialize and initialized notification)
        #expect(await transport.sentMessages.count == 3)  // Initialize request + Initialized notification + Custom notification

        if let sentMessage = await transport.sentMessages.last,
            let data = sentMessage.data(using: .utf8)
        {

            // Decode as Message<InitializedNotification>
            let decoder = JSONDecoder()
            do {
                let decodedNotification = try decoder.decode(
                    Message<InitializedNotification>.self, from: data)
                #expect(decodedNotification.method == InitializedNotification.name)
            } catch {
                #expect(Bool(false), "Failed to decode notification: \(error)")
            }
        } else {
            #expect(Bool(false), "No message was sent")
        }

        await client.disconnect()
    }

    @Test("Initialize sends initialized notification")
    func testClientInitializeNotification() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Create a task for initialize
        let initTask = Task {
            // Queue a response for the initialize request
            try await Task.sleep(for: .milliseconds(10))  // Wait for request to be sent

            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {

                // Create a valid initialize response
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )

                try await transport.queue(response: response)

                // Now complete the initialize call
                try await client.connect(transport: transport)
                try await Task.sleep(for: .milliseconds(10))

                // Verify that two messages were sent: initialize request and initialized notification
                #expect(await transport.sentMessages.count == 2)

                // Check that the second message is the initialized notification
                let notifications = await transport.sentMessages
                if notifications.count >= 2 {
                    let notificationJson = notifications[1]
                    if let notificationData = notificationJson.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            let decodedNotification = try decoder.decode(
                                Message<InitializedNotification>.self, from: notificationData)
                            #expect(decodedNotification.method == InitializedNotification.name)
                        } catch {
                            #expect(Bool(false), "Failed to decode notification: \(error)")
                        }
                    } else {
                        #expect(Bool(false), "Could not convert notification to data")
                    }
                } else {
                    #expect(
                        Bool(false), "Expected both initialize request and initialized notification"
                    )
                }
            }
        }

        // Wait with timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(1))
            initTask.cancel()
        }

        // Wait for the task to complete
        do {
            _ = try await initTask.value
        } catch is CancellationError {
            #expect(Bool(false), "Test timed out")
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        timeoutTask.cancel()

        await client.disconnect()
    }

    @Test("Race condition between send error and response")
    func testSendErrorResponseRace() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Set up the transport to fail sends from the start
        await transport.setFailSend(true)

        // Create a ping request to get the ID
        let request = Ping.request()

        // Create a response for the request and queue it immediately
        let response = Response<Ping>(id: request.id, result: .init())
        let anyResponse = try AnyResponse(response)
        try await transport.queue(response: anyResponse)

        // Now attempt to send the request - this should fail due to send error
        // but the response handler might also try to process the queued response
        do {
            _ = try await client.ping()
            #expect(Bool(false), "Expected send to fail")
        } catch let error as MCPError {
            if case .transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Verify no continuation misuse occurred
        // (If it did, the test would have crashed)

        await client.disconnect()
    }

    @Test("Race condition between response and send error")
    func testResponseSendErrorRace() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Create a ping request to get the ID
        let request = Ping.request()

        // Create a response for the request and queue it immediately
        let response = Response<Ping>(id: request.id, result: .init())
        let anyResponse = try AnyResponse(response)
        try await transport.queue(response: anyResponse)

        // Set up the transport to fail sends
        await transport.setFailSend(true)

        // Now attempt to send the request
        // The response might be processed before the send error occurs
        do {
            _ = try await client.ping()
            // In this case, the response handler won the race and the request succeeded
            #expect(Bool(true), "Response handler won the race - request succeeded")
        } catch let error as MCPError {
            if case .transportError = error {
                // In this case, the send error handler won the race
                #expect(Bool(true), "Send error handler won the race - request failed")
            } else {
                #expect(Bool(false), "Expected transport error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Verify no continuation misuse occurred
        // (If it did, the test would have crashed)

        await client.disconnect()
    }

    @Test(
        "Unexpected transport closure with pending requests",
        .timeLimit(.minutes(1))
    )
    func testUnexpectedTransportClosureWithPendingRequests() async throws {
        // Based on: mcp-python-sdk/tests/client/test_stdio.py::test_stdio_client_bad_path
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        initTask.cancel()

        // Start a ping request in a separate task - we intentionally don't queue
        // a response, so this request will remain pending
        let pingTask = Task<Void, Swift.Error> {
            try await client.ping()
        }

        // Give it time to send the request and register as pending
        try await Task.sleep(for: .milliseconds(20))

        // Verify the ping request was sent (Initialize + Initialized notification + Ping)
        #expect(await transport.sentMessages.count >= 3)

        // Simulate unexpected transport closure (e.g., server process exits)
        // by disconnecting the transport directly without calling client.disconnect()
        await transport.disconnect()

        // Wait for the receive loop to detect the closed transport and clean up
        try await Task.sleep(for: .milliseconds(50))

        // The pending request should receive a connectionClosed error
        do {
            _ = try await pingTask.value
            #expect(Bool(false), "Expected request to fail with connectionClosed error")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.connectionClosed, "Expected CONNECTION_CLOSED error code")
            let errorMessage = error.errorDescription ?? ""
            #expect(errorMessage.contains("Connection closed"))
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Clean up
        await client.disconnect()
    }

    @Test("Client rejects unsupported server protocol version")
    func testClientRejectsUnsupportedProtocolVersion() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Set up a task to handle the initialize response with an unsupported version
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                // Respond with an unsupported protocol version
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: "2099-01-01",  // Future unsupported version
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        defer { initTask.cancel() }

        // Connect should fail with an error about unsupported protocol version
        do {
            try await client.connect(transport: transport)
            #expect(Bool(false), "Expected connection to fail due to unsupported protocol version")
        } catch let error as MCPError {
            // Should be an invalidRequest error about unsupported version
            if case .invalidRequest(let message) = error {
                #expect(message?.contains("unsupported protocol version") == true)
                #expect(message?.contains("2099-01-01") == true)
            } else {
                #expect(Bool(false), "Expected invalidRequest error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected MCPError, got \(error)")
        }

        // Client should have disconnected
        #expect(await transport.isConnected == false)
    }

    @Test("Client accepts supported server protocol version")
    func testClientAcceptsSupportedProtocolVersion() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Test with an older but supported version
        let olderSupportedVersion = Version.v2024_11_05

        // Set up a task to handle the initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: olderSupportedVersion,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        defer { initTask.cancel() }

        // Connect should succeed
        let result = try await client.connect(transport: transport)
        #expect(result.protocolVersion == olderSupportedVersion)
        #expect(await transport.isConnected == true)

        await client.disconnect()
    }
}
