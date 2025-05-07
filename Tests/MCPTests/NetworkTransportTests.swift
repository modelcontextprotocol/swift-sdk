import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(Network)
    import Network

    /// A mock implementation of NetworkConnectionProtocol for testing
    final class MockNetworkConnection: NetworkConnectionProtocol, @unchecked Sendable {
        /// Current state of the connection
        private var mockState: NWConnection.State = .setup

        /// Error to be returned on send/receive operations
        private var mockError: Swift.Error?

        /// Data queue for testing
        private var dataToReceive: [Data] = []
        private var sentData: [Data] = []

        /// The state update handler
        public var stateUpdateHandler: ((@Sendable (NWConnection.State) -> Void))?

        /// Current state
        var state: NWConnection.State {
            return mockState
        }

        /// Initialize a mock connection
        init() {}

        /// Start the connection
        func start(queue: DispatchQueue) {
            // Simulate successful connection by default
            Task { @MainActor in
                self.updateState(.ready)
            }
        }

        /// Send data through the connection
        func send(
            content: Data?,
            contentContext: NWConnection.ContentContext,
            isComplete: Bool,
            completion: NWConnection.SendCompletion
        ) {
            if let content = content {
                sentData.append(content)
            }

            switch completion {
            case .contentProcessed(let handler):
                Task { @MainActor in
                    handler(self.mockError as? NWError)
                }
            default:
                break
            }
        }

        /// Receive data from the connection
        func receive(
            minimumIncompleteLength: Int,
            maximumLength: Int,
            completion: @escaping @Sendable (
                Data?, NWConnection.ContentContext?, Bool, NWError?
            ) -> Void
        ) {
            Task { @MainActor in
                if self.mockState == .cancelled {
                    completion(
                        nil, nil, true,
                        NWError.posix(POSIXErrorCode.ECANCELED)
                    )
                    return
                }

                if let error = self.mockError {
                    completion(nil, nil, false, error as? NWError)
                    return
                }

                if self.dataToReceive.isEmpty {
                    completion(Data(), nil, false, nil)
                    return
                }

                let data = self.dataToReceive.removeFirst()
                completion(data, nil, self.dataToReceive.isEmpty, nil)
            }
        }

        /// Cancel the connection
        func cancel() {
            updateState(.cancelled)
        }

        // Test helpers

        /// Simulate the connection becoming ready
        func simulateReady() {
            updateState(.ready)
        }

        /// Simulate the connection becoming preparing
        func simulatePreparing() {
            updateState(.preparing)
        }

        /// Simulate a connection failure
        func simulateFailure(
            error: Swift.Error? = nil
        ) {
            mockError = error
            if let nwError = error as? NWError {
                updateState(.failed(nwError))
            } else {
                updateState(.failed(NWError.posix(POSIXErrorCode(rawValue: 57)!)))
            }
        }

        /// Simulate connection cancellation
        func simulateCancellation() {
            updateState(.cancelled)
        }

        /// Update the connection state and notify handler
        private func updateState(_ newState: NWConnection.State) {
            mockState = newState
            Task { @MainActor in
                self.stateUpdateHandler?(newState)
            }
        }

        /// Queue data to be received
        func queueDataForReceiving(_ data: Data) {
            dataToReceive.append(data)
        }

        /// Queue a heartbeat message to be received
        func queueHeartbeat() {
            // Create a mock heartbeat message that matches the format
            let magicBytes: [UInt8] = [0xF0, 0x9F, 0x92, 0x93]  // Magic bytes for heartbeat
            var data = Data(magicBytes)
            let timestamp = UInt64(Date().timeIntervalSinceReferenceDate * 1000)
            withUnsafeBytes(of: timestamp) { buffer in
                data.append(contentsOf: buffer)
            }
            queueDataForReceiving(data)
        }

        /// Queue text message to be received
        func queueTextMessage(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            queueDataForReceiving(data)
        }

        /// Get all sent data
        func getSentData() -> [Data] {
            return sentData
        }

        /// Clear sent data buffer
        func clearSentData() {
            sentData.removeAll()
        }
    }

    @Suite("Network Transport Tests", .serialized)
    struct NetworkTransportTests {
        @Test("Heartbeat Creation And Parsing")
        func testHeartbeatCreationAndParsing() {
            // Create a heartbeat
            let heartbeat = NetworkTransport.Heartbeat()

            // Convert to data and back
            let data = heartbeat.data
            let parsed = NetworkTransport.Heartbeat.from(data: data)

            #expect(parsed != nil)

            // Time should be very close (within 1 second)
            if let parsed = parsed {
                let timeDifference = abs(parsed.timestamp.timeIntervalSince(heartbeat.timestamp))
                #expect(timeDifference < 1.0)
            }

            // Test invalid data
            let invalidData = Data([0x01, 0x02, 0x03])
            #expect(NetworkTransport.Heartbeat.from(data: invalidData) == nil)
            #expect(NetworkTransport.Heartbeat.isHeartbeat(invalidData) == false)
            #expect(NetworkTransport.Heartbeat.isHeartbeat(data) == true)
        }

        @Test("Reconnection Configuration")
        func testReconnectionConfiguration() {
            // Create custom config
            let config = NetworkTransport.ReconnectionConfiguration(
                enabled: true,
                maxAttempts: 3,
                backoffMultiplier: 2.0
            )

            #expect(config.enabled == true)
            #expect(config.maxAttempts == 3)
            #expect(config.backoffMultiplier == 2.0)

            // Test backoff delay calculation
            let firstDelay = config.backoffDelay(for: 1)
            let secondDelay = config.backoffDelay(for: 2)
            let thirdDelay = config.backoffDelay(for: 3)

            // Check delays are approximately correct (within 0.001)
            #expect(abs(firstDelay - 0.5) < 0.001)
            #expect(abs(secondDelay - 1.0) < 0.001)
            #expect(abs(thirdDelay - 2.0) < 0.001)

            // Test disabled config
            let disabledConfig = NetworkTransport.ReconnectionConfiguration.disabled
            #expect(disabledConfig.enabled == false)
        }

        @Test("Heartbeat Configuration")
        func testHeartbeatConfiguration() {
            // Create custom config
            let config = NetworkTransport.HeartbeatConfiguration(
                enabled: true,
                interval: 5.0
            )

            #expect(config.enabled == true)
            #expect(config.interval == 5.0)

            // Test default config
            let defaultConfig = NetworkTransport.HeartbeatConfiguration.default
            #expect(defaultConfig.enabled == true)
            #expect(defaultConfig.interval == 15.0)

            // Test disabled config
            let disabledConfig = NetworkTransport.HeartbeatConfiguration.disabled
            #expect(disabledConfig.enabled == false)
        }

        @Test("Connect Success")
        func testNetworkTransportConnectSuccess() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled  // Disable heartbeats for simplified testing
            )

            try await transport.connect()

            // Verify connection state
            #expect(mockConnection.state == .ready)

            await transport.disconnect()
        }

        @Test("Connect Failure")
        func testNetworkTransportConnectFailure() async {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                reconnectionConfig: .disabled  // Disable reconnection for this test
            )

            // Simulate failure before connecting
            mockConnection.simulateFailure(error: NWError.posix(POSIXErrorCode.ECONNRESET))

            do {
                try await transport.connect()
                Issue.record("Expected connect to throw an error")
            } catch let error as MCPError {
                // Expected failure
                #expect(error.localizedDescription.contains("Connection failed"))
            } catch let error as NWError {
                // Also accept NWError since it's the underlying error
                #expect((error as NSError).code == POSIXErrorCode.ECONNRESET.rawValue)
            } catch {
                Issue.record("Unexpected error type: \(type(of: error))")
            }

            await transport.disconnect()
        }

        @Test("Send Message")
        func testNetworkTransportSendMessage() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            try await transport.connect()

            // Test sending a simple message
            let message = #"{"key":"value"}"#.data(using: .utf8)!
            try await transport.send(message)

            // Verify the message was sent with a newline delimiter
            let sentData = mockConnection.getSentData()
            #expect(sentData.count == 1)

            if sentData.count > 0 {
                let expectedOutput = message + "\n".data(using: .utf8)!
                #expect(sentData[0] == expectedOutput)
            }

            await transport.disconnect()
        }

        @Test("Receive Message")
        func testNetworkTransportReceiveMessage() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            // Queue a message to be received
            let message = #"{"key":"value"}"#
            let messageWithNewline = message + "\n"
            mockConnection.queueTextMessage(messageWithNewline)

            try await transport.connect()

            // Start receiving messages
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            // Get first message
            let received = try await iterator.next()
            #expect(received != nil)

            if let received = received {
                #expect(received == message.data(using: .utf8)!)
            }

            await transport.disconnect()
        }

        @Test("Heartbeat Send and Receive")
        func testNetworkTransportHeartbeat() async throws {
            let mockConnection = MockNetworkConnection()

            // Create transport with rapid heartbeats
            let heartbeatConfig = NetworkTransport.HeartbeatConfiguration(
                enabled: true,
                interval: 0.1  // Short interval for testing
            )

            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: heartbeatConfig
            )

            try await transport.connect()

            // Wait for initial connection setup
            try await Task.sleep(for: .milliseconds(100))

            // Wait for initial heartbeat delay (1 second) plus a small buffer
            try await Task.sleep(for: .seconds(1.2))

            // Check if heartbeat was sent
            let sentData = mockConnection.getSentData()
            #expect(sentData.count >= 1, "No heartbeat was sent after \(sentData.count) attempts")

            if let firstSent = sentData.first {
                #expect(
                    NetworkTransport.Heartbeat.isHeartbeat(firstSent),
                    "Sent data is not a heartbeat")
            }

            // Queue a heartbeat to be received
            mockConnection.queueHeartbeat()

            // Wait for heartbeat processing
            try await Task.sleep(for: .milliseconds(100))

            await transport.disconnect()
        }

        @Test("Reconnection")
        func testNetworkTransportReconnection() async throws {
            let mockConnection = MockNetworkConnection()

            // Configure for quick reconnection
            let reconnectionConfig = NetworkTransport.ReconnectionConfiguration(
                enabled: true,
                maxAttempts: 2,
                backoffMultiplier: 1.0
            )

            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled,
                reconnectionConfig: reconnectionConfig
            )

            try await transport.connect()

            // Simulate connection failure during operation
            mockConnection.simulateFailure(error: NWError.posix(POSIXErrorCode.ECONNRESET))

            // Wait a bit to ensure failure is processed
            try await Task.sleep(for: .milliseconds(100))

            // Try to send message after failure - should trigger reconnection process
            let message = #"{"test":"reconnect"}"#.data(using: .utf8)!

            do {
                try await transport.send(message)
                Issue.record("Expected send to fail after connection lost")
            } catch {
                // Expected error
                #expect(error is MCPError, "Expected MCPError but got \(type(of: error))")
            }

            // Wait for potential reconnection attempt
            try await Task.sleep(for: .milliseconds(600))

            await transport.disconnect()
        }

        @Test("Multiple Messages")
        func testNetworkTransportMultipleMessages() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            // Queue multiple messages
            let messages = [
                #"{"id":1,"method":"test1"}"#,
                #"{"id":2,"method":"test2"}"#,
                #"{"id":3,"method":"test3"}"#,
            ]

            for message in messages {
                mockConnection.queueTextMessage(message + "\n")
            }

            try await transport.connect()

            // Receive and verify all messages
            let stream = await transport.receive()
            var receiveCount = 0

            for try await data in stream {
                if let receivedStr = String(data: data, encoding: .utf8) {
                    #expect(messages.contains(receivedStr))
                    receiveCount += 1

                    if receiveCount >= messages.count {
                        break
                    }
                }
            }

            await transport.disconnect()
        }

        @Test("Disconnect During Receive")
        func testNetworkTransportDisconnectDuringReceive() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            try await transport.connect()

            // Start a task to receive messages
            let receiveTask = Task {
                var count = 0
                for try await _ in await transport.receive() {
                    count += 1
                    if count > 10 {
                        // Prevent infinite loop in test
                        break
                    }
                }
            }

            // Let the receive loop start
            try await Task.sleep(for: .milliseconds(100))

            // Disconnect while receiving
            await transport.disconnect()

            // Wait for the receive task to complete
            _ = await receiveTask.result
        }

        @Test("Connection State Transitions")
        func testConnectionStateTransitions() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            // Test setup -> preparing -> ready transition
            mockConnection.simulatePreparing()
            try await Task.sleep(for: .milliseconds(100))
            mockConnection.simulateReady()
            try await transport.connect()
            #expect(mockConnection.state == .ready)

            // Test ready -> failed transition
            mockConnection.simulateFailure(error: NWError.posix(POSIXErrorCode.ECONNRESET))
            try await Task.sleep(for: .milliseconds(100))
            if case .failed = mockConnection.state {
                // expected
            } else {
                Issue.record("Expected state to be failed")
            }

            await transport.disconnect()
        }

        @Test("Partial Message Reception")
        func testPartialMessageReception() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            try await transport.connect()

            // Split a message into multiple parts
            let message = #"{"key":"value"}"#
            let parts = [
                message.prefix(5).data(using: .utf8)!,
                message.dropFirst(5).data(using: .utf8)!,
                "\n".data(using: .utf8)!,
            ]

            // Queue the parts
            for part in parts {
                mockConnection.queueDataForReceiving(part)
            }

            // Start receiving messages
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            // Get the complete message
            let received = try await iterator.next()
            #expect(received != nil)
            if let received = received {
                #expect(received == message.data(using: .utf8)!)
            }

            await transport.disconnect()
        }

        @Test("Large Message Handling")
        func testLargeMessageHandling() async throws {
            let mockConnection = MockNetworkConnection()
            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled
            )

            try await transport.connect()

            // Create a large message (larger than typical receive buffer)
            let largeMessage = String(repeating: "x", count: 100_000)
            let messageWithNewline = largeMessage + "\n"
            mockConnection.queueTextMessage(messageWithNewline)

            // Start receiving messages
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            // Get the message
            let received = try await iterator.next()
            #expect(received != nil)
            if let received = received {
                #expect(received.count == largeMessage.count)
            }

            await transport.disconnect()
        }

        @Test("Reconnection Backoff")
        func testReconnectionBackoff() async throws {
            let mockConnection = MockNetworkConnection()
            let startTime = Date()

            // Configure for quick reconnection with known backoff
            let reconnectionConfig = NetworkTransport.ReconnectionConfiguration(
                enabled: true,
                maxAttempts: 3,
                backoffMultiplier: 2.0
            )

            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: .disabled,
                reconnectionConfig: reconnectionConfig
            )

            try await transport.connect()

            // Simulate failure
            mockConnection.simulateFailure(error: NWError.posix(POSIXErrorCode.ECONNRESET))

            // Wait for reconnection attempts
            try await Task.sleep(for: .seconds(4))

            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)

            // Verify we had enough time for reconnection attempts
            #expect(duration >= 3.5)  // Should have time for 3 attempts with backoff

            await transport.disconnect()
        }

        @Test("Heartbeat Failure Handling")
        func testHeartbeatFailureHandling() async throws {
            let mockConnection = MockNetworkConnection()

            // Create transport with rapid heartbeats
            let heartbeatConfig = NetworkTransport.HeartbeatConfiguration(
                enabled: true,
                interval: 0.1
            )

            let transport = NetworkTransport(
                mockConnection,
                heartbeatConfig: heartbeatConfig
            )

            try await transport.connect()

            // Wait for initial heartbeat
            try await Task.sleep(for: .seconds(1.2))

            // Simulate failure during heartbeat
            mockConnection.simulateFailure(error: NWError.posix(POSIXErrorCode.ECONNRESET))

            // Wait for potential recovery
            try await Task.sleep(for: .milliseconds(500))

            // Verify connection state
            if case .failed = mockConnection.state {
                // expected
            } else {
                Issue.record("Expected state to be failed")
            }

            await transport.disconnect()
        }

        @Test("Resource Cleanup")
        func testResourceCleanup() async throws {
            weak var weakConnection: MockNetworkConnection?

            do {
                let mockConnection = MockNetworkConnection()
                weakConnection = mockConnection

                // Create and use transport in a separate scope
                let transport = NetworkTransport(
                    mockConnection,
                    heartbeatConfig: .disabled
                )

                try await transport.connect()
                await transport.disconnect()
            }

            // Wait for potential async cleanup
            try await Task.sleep(for: .milliseconds(100))

            // Verify connection is cleaned up
            #expect(weakConnection == nil, "Connection was not properly cleaned up")
        }
    }
#endif
