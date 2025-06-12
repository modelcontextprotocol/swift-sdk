import Foundation
import Logging
import Testing

@testable import MCP

@Suite("InMemory Transport Tests")
struct InMemoryTransportTests {

    @Test("Create connected pair")
    func testCreateConnectedPair() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Verify both transports can be connected
        try await clientTransport.connect()
        try await serverTransport.connect()

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Connect without pairing throws error")
    func testConnectWithoutPairing() async throws {
        let transport = InMemoryTransport()

        // Attempt to connect without pairing should throw
        do {
            try await transport.connect()
            #expect(Bool(false), "Expected connect to throw an error")
        } catch let error as MCPError {
            if case .internalError(let message) = error {
                #expect(
                    message
                        == "Transport not paired. Use createConnectedPair() to create paired transports."
                )
            } else {
                #expect(Bool(false), "Expected MCPError.internalError")
            }
        }
    }

    @Test("Multiple connect calls are idempotent")
    func testMultipleConnectCalls() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Connect multiple times should not throw
        try await clientTransport.connect()
        try await clientTransport.connect()  // Should be safe
        try await clientTransport.connect()  // Should be safe

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Send and receive messages")
    func testSendAndReceiveMessages() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Start receiving on server
        let serverReceiveTask = Task {
            var messages: [Data] = []
            for try await message in await serverTransport.receive() {
                messages.append(message)
                if messages.count >= 3 {
                    break
                }
            }
            return messages
        }

        // Send messages from client
        let message1 = "Hello".data(using: .utf8)!
        let message2 = "World".data(using: .utf8)!
        let message3 = "!".data(using: .utf8)!

        try await clientTransport.send(message1)
        try await clientTransport.send(message2)
        try await clientTransport.send(message3)

        // Wait for messages to be received
        let receivedMessages = try await serverReceiveTask.value

        #expect(receivedMessages.count == 3)
        #expect(receivedMessages[0] == message1)
        #expect(receivedMessages[1] == message2)
        #expect(receivedMessages[2] == message3)

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Bidirectional communication")
    func testBidirectionalCommunication() async throws {
        let (transport1, transport2) = await InMemoryTransport.createConnectedPair()

        try await transport1.connect()
        try await transport2.connect()

        // Set up receivers
        let receive1Task = Task {
            var messages: [String] = []
            for try await data in await transport1.receive() {
                if let message = String(data: data, encoding: .utf8) {
                    messages.append(message)
                    if messages.count >= 2 {
                        break
                    }
                }
            }
            return messages
        }

        let receive2Task = Task {
            var messages: [String] = []
            for try await data in await transport2.receive() {
                if let message = String(data: data, encoding: .utf8) {
                    messages.append(message)
                    if messages.count >= 2 {
                        break
                    }
                }
            }
            return messages
        }

        // Send messages in both directions
        try await transport1.send("From transport 1 - message 1".data(using: .utf8)!)
        try await transport2.send("From transport 2 - message 1".data(using: .utf8)!)
        try await transport1.send("From transport 1 - message 2".data(using: .utf8)!)
        try await transport2.send("From transport 2 - message 2".data(using: .utf8)!)

        // Verify both sides received messages
        let messages1 = try await receive1Task.value
        let messages2 = try await receive2Task.value

        #expect(messages1.count == 2)
        #expect(messages1[0] == "From transport 2 - message 1")
        #expect(messages1[1] == "From transport 2 - message 2")

        #expect(messages2.count == 2)
        #expect(messages2[0] == "From transport 1 - message 1")
        #expect(messages2[1] == "From transport 1 - message 2")

        // Clean up
        await transport1.disconnect()
        await transport2.disconnect()
    }

    @Test("Send without connection throws error")
    func testSendWithoutConnection() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Try to send without connecting
        do {
            try await clientTransport.send("test".data(using: .utf8)!)
            #expect(Bool(false), "Expected send to throw an error")
        } catch let error as MCPError {
            if case .internalError(let message) = error {
                #expect(message == "Transport not connected")
            } else {
                #expect(Bool(false), "Expected MCPError.internalError")
            }
        }

        // Clean up (connect server to avoid dangling connections)
        try await serverTransport.connect()
        await serverTransport.disconnect()
    }

    @Test("Disconnect stops message stream")
    func testDisconnectStopsMessageStream() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Start receiving
        let receiveTask = Task {
            var messageCount = 0
            do {
                for try await _ in await serverTransport.receive() {
                    messageCount += 1
                }
            } catch {
                // Expected when disconnected
            }
            return messageCount
        }

        // Send a message
        try await clientTransport.send("message".data(using: .utf8)!)

        // Give some time for message to be received
        try await Task.sleep(for: .milliseconds(100))

        // Disconnect
        await serverTransport.disconnect()

        // The receive stream should complete
        let messageCount = await receiveTask.value
        #expect(messageCount >= 1)
    }

    @Test("Peer disconnection handling")
    func testPeerDisconnectionHandling() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Start receiving on server
        let receiveTask = Task { () -> Swift.Error? in
            do {
                for try await _ in await serverTransport.receive() {
                    // Keep receiving
                }
                return nil
            } catch {
                return error
            }
        }

        // Give a moment for the receive stream to be set up
        try await Task.sleep(for: .milliseconds(10))

        // Disconnect client (peer)
        await clientTransport.disconnect()
        
        receiveTask.cancel()
    }

    @Test("Multiple disconnects are safe")
    func testMultipleDisconnects() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Multiple disconnects should be safe
        await clientTransport.disconnect()
        await clientTransport.disconnect()
        await clientTransport.disconnect()

        // Clean up server
        await serverTransport.disconnect()
    }

    @Test("Message queueing before stream creation")
    func testMessageQueueingBeforeStreamCreation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Send messages before receive stream is created
        try await clientTransport.send("message1".data(using: .utf8)!)
        try await clientTransport.send("message2".data(using: .utf8)!)
        try await clientTransport.send("message3".data(using: .utf8)!)

        // Now create receive stream
        let messages = await serverTransport.receive()
        var receivedMessages: [String] = []

        for try await data in messages {
            if let message = String(data: data, encoding: .utf8) {
                receivedMessages.append(message)
                if receivedMessages.count >= 3 {
                    break
                }
            }
        }

        #expect(receivedMessages.count == 3)
        #expect(receivedMessages[0] == "message1")
        #expect(receivedMessages[1] == "message2")
        #expect(receivedMessages[2] == "message3")

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Receive after disconnect returns completed stream")
    func testReceiveAfterDisconnect() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Disconnect before receiving
        await serverTransport.disconnect()

        // Create receive stream after disconnect
        let messages = await serverTransport.receive()
        var messageCount = 0

        for try await _ in messages {
            messageCount += 1
        }

        // Stream should complete immediately
        #expect(messageCount == 0)

        // Clean up
        await clientTransport.disconnect()
    }

    @Test("Large message handling")
    func testLargeMessageHandling() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Create a large message (1MB)
        let largeData = Data(repeating: 0xFF, count: 1024 * 1024)

        // Start receiving
        let receiveTask = Task {
            for try await data in await serverTransport.receive() {
                return data
            }
            return Data()
        }

        // Send large message
        try await clientTransport.send(largeData)

        // Verify it was received correctly
        let receivedData = try await receiveTask.value
        #expect(receivedData == largeData)

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Concurrent send operations")
    func testConcurrentSendOperations() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await clientTransport.connect()
        try await serverTransport.connect()

        // Start receiving
        let receiveTask = Task {
            var messages: [String] = []
            for try await data in await serverTransport.receive() {
                if let message = String(data: data, encoding: .utf8) {
                    messages.append(message)
                    if messages.count >= 10 {
                        break
                    }
                }
            }
            return messages
        }

        // Send messages concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try? await clientTransport.send("Message \(i)".data(using: .utf8)!)
                }
            }
        }

        // Verify all messages were received
        let receivedMessages = try await receiveTask.value
        #expect(receivedMessages.count == 10)

        // Check that all messages are present (order may vary due to concurrency)
        let expectedMessages = Set((0..<10).map { "Message \($0)" })
        let actualMessages = Set(receivedMessages)
        #expect(actualMessages == expectedMessages)

        // Clean up
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Custom logger usage")
    func testCustomLoggerUsage() async throws {
        // Create a custom logger (in real tests, you might use a test logger that captures output)
        let logger = Logger(label: "test.in-memory.transport")

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair(
            logger: logger)

        // Verify loggers are set correctly - when a custom logger is provided, it's used for both
        #expect(clientTransport.logger.label == "test.in-memory.transport")
        #expect(serverTransport.logger.label == "test.in-memory.transport")

        // Test basic operations with custom logger
        try await clientTransport.connect()
        try await serverTransport.connect()

        try await clientTransport.send("test".data(using: .utf8)!)

        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }
}
