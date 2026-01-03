import Foundation
import Logging
import Testing

@testable import MCP

/// Tests for the request capture pattern that ensures responses go to the correct transport
/// even when the server's connection changes while a request is being processed.
///
/// This is critical for HTTP transports where multiple clients can connect and the server's
/// `connection` reference gets reassigned.
@Suite("Transport Switching Tests")
struct TransportSwitchingTests {

    /// Mock transport that tracks sent messages with their related request IDs
    actor TrackingMockTransport: Transport {
        var logger: Logger

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var isConnected = false

        /// Messages sent through this transport, along with their related request IDs
        struct SentMessage {
            let data: Data
            let relatedRequestId: RequestId?

            var asString: String? {
                String(data: data, encoding: .utf8)
            }
        }

        private(set) var sentMessages: [SentMessage] = []

        private var dataToReceive: [Data] = []
        private var dataStreamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?

        let name: String

        init(name: String, logger: Logger = Logger(label: "mcp.test.tracking-transport")) {
            self.name = name
            self.logger = logger
        }

        public func connect() async throws {
            isConnected = true
        }

        public func disconnect() async {
            isConnected = false
            dataStreamContinuation?.finish()
            dataStreamContinuation = nil
        }

        public func send(_ data: Data) async throws {
            sentMessages.append(SentMessage(data: data, relatedRequestId: nil))
        }

        public func send(_ data: Data, relatedRequestId: RequestId?) async throws {
            sentMessages.append(SentMessage(data: data, relatedRequestId: relatedRequestId))
        }

        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return AsyncThrowingStream<Data, Swift.Error> { continuation in
                dataStreamContinuation = continuation
                for message in dataToReceive {
                    continuation.yield(message)
                }
                dataToReceive.removeAll()
            }
        }

        func queue(data: Data) {
            if let continuation = dataStreamContinuation {
                continuation.yield(data)
            } else {
                dataToReceive.append(data)
            }
        }

        func queue<M: MCP.Method>(request: Request<M>) throws {
            queue(data: try encoder.encode(request))
        }

        func clearMessages() {
            sentMessages.removeAll()
            dataToReceive.removeAll()
        }
    }

    @Test("Response goes to correct transport when connection changes during request handling")
    func testResponseGoesToCorrectTransportWhenConnectionChanges() async throws {
        // Create two transports (simulating two clients)
        let transportA = TrackingMockTransport(name: "TransportA")
        let transportB = TrackingMockTransport(name: "TransportB")

        // Create a server with a custom handler that we can control
        let server = Server(name: "TestServer", version: "1.0")

        // Use a continuation to control when the handler completes
        actor HandlerControl {
            var handlerContinuation: CheckedContinuation<Void, Never>?
            var handlerWasCalled = false

            func waitForSignal() async {
                await withCheckedContinuation { continuation in
                    handlerContinuation = continuation
                }
            }

            func signalHandler() {
                handlerContinuation?.resume()
                handlerContinuation = nil
            }

            func markCalled() {
                handlerWasCalled = true
            }
        }

        let control = HandlerControl()

        // 1. Start server with transport A
        try await server.start(transport: transportA)

        // Register a custom ping handler that waits for our signal AFTER start
        // (start() registers default handlers, so we must override after)
        // This simulates a slow handler to create a timing window
        await server.withRequestHandler(Ping.self) { [control] _, _ in
            await control.markCalled()
            // Wait for signal before returning
            await control.waitForSignal()
            return Empty()
        }

        // Wait for server to be ready
        try await Task.sleep(for: .milliseconds(50))

        // Initialize the server first
        try await transportA.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Wait for initialization
        try await Task.sleep(for: .milliseconds(100))
        await transportA.clearMessages()

        // 2. Send a ping request from transport A (with ID 100)
        let pingJSON = """
            {"jsonrpc":"2.0","id":100,"method":"ping","params":{}}
            """
        await transportA.queue(data: pingJSON.data(using: .utf8)!)

        // Wait for the handler to be called
        try await Task.sleep(for: .milliseconds(50))

        // Verify handler was called
        let wasCalled = await control.handlerWasCalled
        #expect(wasCalled == true, "Handler should have been called")

        // 3. While A's request is processing, switch to transport B
        // This simulates another client connecting and reassigning server.connection
        try await server.start(transport: transportB)

        // Give time for connection switch
        try await Task.sleep(for: .milliseconds(50))

        // 4. Complete A's request by signaling the handler
        await control.signalHandler()

        // Wait for response to be sent
        try await Task.sleep(for: .milliseconds(100))

        // 5. Verify the response went to transport A (not transport B)
        let messagesA = await transportA.sentMessages
        let messagesB = await transportB.sentMessages

        #expect(messagesA.count >= 1, "Transport A should have received the response")

        // Find the response with ID 100
        let responseToA = messagesA.first { msg in
            if let str = msg.asString {
                return str.contains("\"id\":100") || str.contains("\"id\": 100")
            }
            return false
        }
        #expect(responseToA != nil, "Transport A should have received response for request 100")

        // Verify the related request ID was passed
        if let response = responseToA {
            #expect(response.relatedRequestId == .number(100), "Response should have relatedRequestId set to 100")
        }

        // Transport B should NOT have received the response for request 100
        let responseToB = messagesB.first { msg in
            if let str = msg.asString {
                return str.contains("\"id\":100") || str.contains("\"id\": 100")
            }
            return false
        }
        #expect(responseToB == nil, "Transport B should NOT have received response for request 100")

        // Cleanup
        await server.stop()
        await transportA.disconnect()
        await transportB.disconnect()
    }

    @Test("Simple request routes correctly with relatedRequestId")
    func testSimpleRequestRoutesCorrectly() async throws {
        let transportA = TrackingMockTransport(name: "TransportA")

        let server = Server(name: "TestServer", version: "1.0")

        // Start server with transport A
        try await server.start(transport: transportA)
        try await Task.sleep(for: .milliseconds(50))

        // Initialize
        try await transportA.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))
        try await Task.sleep(for: .milliseconds(100))
        await transportA.clearMessages()

        // Send ping request from A with a specific ID
        let pingJSON = """
            {"jsonrpc":"2.0","id":42,"method":"ping","params":{}}
            """
        await transportA.queue(data: pingJSON.data(using: .utf8)!)

        // Wait for response
        try await Task.sleep(for: .milliseconds(100))

        // Verify response went to transport A
        let messagesA = await transportA.sentMessages
        let pingResponse = messagesA.first { msg in
            if let str = msg.asString {
                return str.contains("\"id\":42") || str.contains("\"id\": 42")
            }
            return false
        }
        #expect(pingResponse != nil, "Transport A should have received ping response")

        // Verify relatedRequestId was set
        if let response = pingResponse {
            #expect(response.relatedRequestId == .number(42), "Response should have relatedRequestId set to 42")
        }

        // Cleanup
        await server.stop()
        await transportA.disconnect()
    }

    @Test("Batch response goes to correct transport")
    func testBatchResponseGoesToCorrectTransport() async throws {
        let transportA = TrackingMockTransport(name: "TransportA")

        let server = Server(name: "TestServer", version: "1.0")

        // Start server
        try await server.start(transport: transportA)
        try await Task.sleep(for: .milliseconds(50))

        // Initialize
        try await transportA.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))
        try await Task.sleep(for: .milliseconds(100))
        await transportA.clearMessages()

        // Send a batch request
        let batchJSON = """
            [
                {"jsonrpc":"2.0","id":1,"method":"ping","params":{}},
                {"jsonrpc":"2.0","id":2,"method":"ping","params":{}}
            ]
            """
        let batchData = batchJSON.data(using: .utf8)!
        await transportA.queue(data: batchData)

        // Wait for response
        try await Task.sleep(for: .milliseconds(100))

        // Verify batch response went to transport A
        let messagesA = await transportA.sentMessages
        #expect(messagesA.count >= 1, "Transport A should have received the batch response")

        let batchResponse = messagesA.first { msg in
            if let str = msg.asString {
                // Batch response should be an array containing both IDs
                return str.hasPrefix("[") && str.contains("\"id\":1") && str.contains("\"id\":2")
            }
            return false
        }
        #expect(batchResponse != nil, "Transport A should have received batch response with both request IDs")

        // Cleanup
        await server.stop()
        await transportA.disconnect()
    }

    @Test("Error response goes to correct transport with relatedRequestId")
    func testErrorResponseGoesToCorrectTransport() async throws {
        let transportA = TrackingMockTransport(name: "TransportA")

        let server = Server(name: "TestServer", version: "1.0")

        // Start server
        try await server.start(transport: transportA)
        try await Task.sleep(for: .milliseconds(50))

        // Initialize
        try await transportA.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))
        try await Task.sleep(for: .milliseconds(100))
        await transportA.clearMessages()

        // Send a request for an unknown method
        let unknownMethodJSON = """
            {"jsonrpc":"2.0","id":99,"method":"unknown/method","params":{}}
            """
        await transportA.queue(data: unknownMethodJSON.data(using: .utf8)!)

        // Wait for response
        try await Task.sleep(for: .milliseconds(100))

        // Verify error response went to transport A
        let messagesA = await transportA.sentMessages
        let errorResponse = messagesA.first { msg in
            if let str = msg.asString {
                return str.contains("\"id\":99") && str.contains("\"error\"")
            }
            return false
        }
        #expect(errorResponse != nil, "Transport A should have received error response")

        // Verify relatedRequestId was set even for error responses
        if let response = errorResponse {
            #expect(response.relatedRequestId == .number(99), "Error response should have relatedRequestId set to 99")
        }

        // Cleanup
        await server.stop()
        await transportA.disconnect()
    }

    @Test("Notifications sent via context include relatedRequestId")
    func testNotificationsSentViaContextIncludeRelatedRequestId() async throws {
        let transportA = TrackingMockTransport(name: "TransportA")

        let server = Server(name: "TestServer", version: "1.0")

        // Track when handler sends notification
        actor NotificationTracker {
            var notificationSent = false
            func markSent() { notificationSent = true }
        }
        let tracker = NotificationTracker()

        // Start server with transport A
        try await server.start(transport: transportA)

        // Register a handler that sends a notification using the context
        await server.withRequestHandler(Ping.self) { [tracker] _, context in
            // Send a notification mid-execution using the context
            // The notification should include the relatedRequestId
            try await context.sendNotification(ToolListChangedNotification())
            await tracker.markSent()
            return Empty()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Initialize
        try await transportA.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))
        try await Task.sleep(for: .milliseconds(100))
        await transportA.clearMessages()

        // Send ping with a specific ID
        let pingJSON = """
            {"jsonrpc":"2.0","id":42,"method":"ping","params":{}}
            """
        await transportA.queue(data: pingJSON.data(using: .utf8)!)

        // Wait for handler to execute
        try await Task.sleep(for: .milliseconds(200))

        // Check that notification was sent
        let wasSent = await tracker.notificationSent
        #expect(wasSent == true, "Handler should have sent a notification")

        // Verify the notification was sent with the correct relatedRequestId
        let messagesA = await transportA.sentMessages
        let notification = messagesA.first { msg in
            if let str = msg.asString {
                return str.contains("\"method\":\"notifications/tools/list_changed\"")
            }
            return false
        }
        #expect(notification != nil, "Transport A should have received the notification")

        // Verify the notification has the relatedRequestId of the original request
        if let notif = notification {
            #expect(notif.relatedRequestId == .number(42), "Notification should have relatedRequestId matching the request (42)")
        }

        // Cleanup
        await server.stop()
        await transportA.disconnect()
    }
}
