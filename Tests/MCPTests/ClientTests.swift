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
        try await client.connect(transport: transport)
        #expect(await transport.isConnected == true)
        await client.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test(
        "Initialize request",
        .timeLimit(.minutes(1))
    )
    func testClientInitialize() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(for: .milliseconds(10))

        // Create a task for initialize that we'll cancel
        let initTask = Task {
            try await client.initialize()
        }

        // Give it a moment to send the request
        try await Task.sleep(for: .milliseconds(10))

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages.first?.contains(Initialize.name) == true)
        #expect(await transport.sentMessages.first?.contains(client.name) == true)
        #expect(await transport.sentMessages.first?.contains(client.version) == true)

        // Cancel the initialize task
        initTask.cancel()

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test(
        "Ping request",
        .timeLimit(.minutes(1))
    )
    func testClientPing() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(for: .milliseconds(10))

        // Create a task for the ping that we'll cancel
        let pingTask = Task {
            try await client.ping()
        }

        // Give it a moment to send the request
        try await Task.sleep(for: .milliseconds(10))

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages.first?.contains(Ping.name) == true)

        // Cancel the ping task
        pingTask.cancel()

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
        await transport.setFailSend(true)
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)

        do {
            try await client.ping()
            #expect(Bool(false), "Expected ping to fail")
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

    @Test("Strict configuration - capabilities check")
    func testStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.strict
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

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

        // Disconnect client
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Non-strict configuration - capabilities check")
    func testNonStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.default
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        try await client.connect(transport: transport)

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

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))  // Allow connection tasks

        let request1 = Ping.request()
        let request2 = Ping.request()
        var resultTask1: Task<Ping.Result, Swift.Error>?
        var resultTask2: Task<Ping.Result, Swift.Error>?

        try await client.withBatch { batch in
            resultTask1 = try await batch.addRequest(request1)
            resultTask2 = try await batch.addRequest(request2)
        }

        // Check if one batch message was sent
        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 1)

        guard let batchData = sentMessages.first?.data(using: .utf8) else {
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
        guard let task1 = resultTask1, let task2 = resultTask2 else {
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

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))

        let request1 = Ping.request()  // Success
        let request2 = Ping.request()  // Error

        var resultTasks: [Task<Ping.Result, Swift.Error>] = []

        try await client.withBatch { batch in
            resultTasks.append(try await batch.addRequest(request1))
            resultTasks.append(try await batch.addRequest(request2))
        }

        // Check if one batch message was sent
        #expect(await transport.sentMessages.count == 1)

        // Prepare batch response (success for 1, error for 2)
        let response1 = Response<Ping>(id: request1.id, result: .init())
        let error = MCPError.internalError("Simulated batch error")
        let response2 = Response<Ping>(id: request2.id, error: error)
        let anyResponse1 = try AnyResponse(response1)
        let anyResponse2 = try AnyResponse(response2)

        // Queue the batch response
        try await transport.queue(batch: [anyResponse1, anyResponse2])

        // Wait for results and verify
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

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))

        // Call withBatch but don't add any requests
        try await client.withBatch { _ in
            // No requests added
        }

        // Check that no messages were sent
        #expect(await transport.sentMessages.isEmpty)

        await client.disconnect()
    }

    @Test("Notify method sends notifications")
    func testClientNotify() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))

        // Create a test notification
        let notification = InitializedNotification.message()
        try await client.notify(notification)

        // Verify notification was sent
        #expect(await transport.sentMessages.count == 1)

        if let sentMessage = await transport.sentMessages.first,
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

        try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(10))

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
                _ = try await client.initialize()

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
}
