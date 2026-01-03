import Foundation
import Testing

@testable import MCP

/// Tests for resumability support - verifying that clients can reconnect and resume
/// receiving events after disconnection using InMemoryEventStore integration with
/// HTTPServerTransport.
///
/// These tests follow the TypeScript SDK patterns from:
/// - `packages/server/test/server/streamableHttp.test.ts`
///
/// Note: These tests use protocol version 2024-11-05. The TypeScript SDK uses 2025-11-25.
/// TODO: Update tests when Swift SDK adds support for protocol version 2025-11-25.
///
/// TypeScript test not yet implemented:
///
/// `should resume long-running notifications with lastEventId` (taskResumability.test.ts:180)
///
/// Rationale: This is a full end-to-end integration test that requires:
/// 1. A Client instance connected to a Server via HTTPClientTransport
/// 2. A tool handler that sends multiple progress notifications over time
/// 3. Ability to disconnect the client mid-stream and reconnect with lastEventId
/// 4. The `onresumptiontoken` callback on the client side
///
/// The Swift SDK has all the building blocks, but testing this requires either:
/// - A real HTTP server running in tests (like TypeScript's node http.Server)
/// - Full client-server integration test infrastructure
///
/// The server-side resumability is tested here; client-side reconnection with
/// resumption token is tested in HTTPClientTransportTests and ClientReconnectionTests.
@Suite("Resumability Tests")
struct ResumabilityTests {

    // MARK: - Test Helpers

    static let initializeMessage = TestPayloads.initializeRequest(id: "init-1", clientName: "test-client")

    /// Parses SSE data to extract event ID and data content
    func parseSSEEvents(_ data: Data) -> [(id: String?, data: String)] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [(id: String?, data: String)] = []
        var currentId: String?
        var currentData: [String] = []

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("id: ") || line.hasPrefix("id:") {
                let idValue = line.hasPrefix("id: ") ? String(line.dropFirst(4)) : String(line.dropFirst(3))
                currentId = idValue.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") || line.hasPrefix("data:") {
                let dataValue = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : String(line.dropFirst(5))
                currentData.append(dataValue)
            } else if line.isEmpty && !currentData.isEmpty {
                // End of event
                events.append((id: currentId, data: currentData.joined(separator: "\n")))
                currentId = nil
                currentData = []
            }
        }

        // Handle case where last event doesn't end with empty line
        if !currentData.isEmpty {
            events.append((id: currentId, data: currentData.joined(separator: "\n")))
        }

        return events
    }

    /// Helper to read from stream with timeout
    func readFromStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        maxChunks: Int = 1,
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        var receivedData = Data()

        try await withThrowingTaskGroup(of: Data?.self) { group in
            // Task to read from stream
            group.addTask {
                var data = Data()
                var count = 0
                for try await chunk in stream {
                    data.append(chunk)
                    count += 1
                    if count >= maxChunks {
                        break
                    }
                }
                return data
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil  // Return nil on timeout
            }

            // Wait for first to complete
            if let result = try await group.next(), let data = result {
                receivedData = data
            }
            group.cancelAll()
        }

        return receivedData
    }

    // MARK: - 1.1 Store and include event IDs in server SSE messages

    @Test("Store and include event IDs in server SSE messages")
    func storeAndIncludeEventIds() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize the transport
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)
        #expect(initResponse.headers[HTTPHeader.sessionId] == sessionId)

        // Open a standalone SSE stream (GET request)
        let getRequest = TestPayloads.getRequest(sessionId: sessionId)
        let getResponse = await transport.handleRequest(getRequest)

        #expect(getResponse.statusCode == 200)
        #expect(getResponse.headers[HTTPHeader.contentType] == "text/event-stream")
        #expect(getResponse.stream != nil)

        guard let stream = getResponse.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Send a notification through the transport (in a concurrent task)
        // and read from the stream simultaneously
        let notification = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Test notification with event ID"}}
            """

        // Start reading task first
        let readTask = Task {
            try await readFromStream(stream, maxChunks: 1, timeout: .seconds(2))
        }

        // Give a small delay then send notification
        try await Task.sleep(for: .milliseconds(50))
        try await transport.send(notification.data(using: .utf8)!)

        // Wait for read to complete
        let receivedData = try await readTask.value

        // Parse the SSE events
        let events = parseSSEEvents(receivedData)

        // Verify we got at least one event with an ID
        #expect(!events.isEmpty, "Should have received at least one event")

        if let firstEvent = events.first {
            #expect(firstEvent.id != nil, "Event should have an ID")
            #expect(firstEvent.data.contains("notifications/message"), "Event should contain the notification")

            // Verify the event was stored
            let eventCount = await eventStore.eventCount
            #expect(eventCount > 0, "Event should be stored in event store")
        }
    }

    // MARK: - 1.2 Store and replay MCP server tool notifications

    @Test("Store and replay MCP server notifications")
    func storeAndReplayServerNotifications() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Open first SSE stream
        let getRequest1 = TestPayloads.getRequest(sessionId: sessionId)
        let getResponse1 = await transport.handleRequest(getRequest1)
        #expect(getResponse1.statusCode == 200)

        guard let stream1 = getResponse1.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Start reading and send first notification
        let readTask1 = Task {
            try await readFromStream(stream1, maxChunks: 1, timeout: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(50))

        let notification1 = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"First notification"}}
            """
        try await transport.send(notification1.data(using: .utf8)!)

        let receivedData1 = try await readTask1.value
        let events1 = parseSSEEvents(receivedData1)
        #expect(!events1.isEmpty, "Should have received first notification")

        guard let firstEventId = events1.first?.id else {
            Issue.record("First event should have an ID")
            return
        }

        // Close the first stream (simulating disconnect)
        await transport.closeStandaloneSSEStream()

        // Send second notification while "disconnected"
        let notification2 = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Second notification"}}
            """
        try await transport.send(notification2.data(using: .utf8)!)

        // Reconnect with Last-Event-ID to get missed messages
        let getRequest2 = TestPayloads.getRequest(sessionId: sessionId, lastEventId: firstEventId)
        let getResponse2 = await transport.handleRequest(getRequest2)

        #expect(getResponse2.statusCode == 200)

        guard let stream2 = getResponse2.stream else {
            Issue.record("Expected stream in reconnection response")
            return
        }

        // Read replayed notifications
        let receivedData2 = try await readFromStream(stream2, maxChunks: 1, timeout: .seconds(2))
        let events2 = parseSSEEvents(receivedData2)

        // Verify we received the second notification that was sent after our stored eventId
        let hasSecondNotification = events2.contains { event in
            event.data.contains("Second notification")
        }
        #expect(hasSecondNotification, "Should have received the second notification on reconnect")
    }

    // MARK: - 1.3 Store and replay multiple notifications

    @Test("Store and replay multiple notifications sent while client is disconnected")
    func storeAndReplayMultipleNotifications() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Open first SSE stream
        let getRequest1 = TestPayloads.getRequest(sessionId: sessionId)
        let getResponse1 = await transport.handleRequest(getRequest1)
        #expect(getResponse1.statusCode == 200)

        guard let stream1 = getResponse1.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Start reading and send initial notification
        let readTask1 = Task {
            try await readFromStream(stream1, maxChunks: 1, timeout: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(50))

        let initialNotification = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Initial notification"}}
            """
        try await transport.send(initialNotification.data(using: .utf8)!)

        let receivedData1 = try await readTask1.value
        let events1 = parseSSEEvents(receivedData1)

        guard let lastEventId = events1.first?.id else {
            Issue.record("Initial event should have an ID")
            return
        }

        // Close the SSE stream (simulate disconnect)
        await transport.closeStandaloneSSEStream()

        // Send MULTIPLE notifications while the client is disconnected
        for i in 1...3 {
            let notification = """
                {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Missed notification \(i)"}}
                """
            try await transport.send(notification.data(using: .utf8)!)
        }

        // Reconnect with the Last-Event-ID to get all missed messages
        let getRequest2 = TestPayloads.getRequest(sessionId: sessionId, lastEventId: lastEventId)
        let getResponse2 = await transport.handleRequest(getRequest2)

        #expect(getResponse2.statusCode == 200)

        guard let stream2 = getResponse2.stream else {
            Issue.record("Expected stream in reconnection response")
            return
        }

        // Read replayed notifications (expect 3 chunks)
        let receivedData2 = try await readFromStream(stream2, maxChunks: 3, timeout: .seconds(3))
        let allText = String(data: receivedData2, encoding: .utf8) ?? ""

        // Verify we received ALL notifications that were sent while disconnected
        #expect(allText.contains("Missed notification 1"), "Should have received missed notification 1")
        #expect(allText.contains("Missed notification 2"), "Should have received missed notification 2")
        #expect(allText.contains("Missed notification 3"), "Should have received missed notification 3")
    }

    // MARK: - Event Store Integration

    @Test("Event store receives events with correct stream ID")
    func eventStoreReceivesEventsWithCorrectStreamId() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Open SSE stream
        let getRequest = TestPayloads.getRequest(sessionId: sessionId)
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 200)

        guard let stream = getResponse.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Start reading task
        let readTask = Task {
            try await readFromStream(stream, maxChunks: 1, timeout: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(50))

        // Send a notification
        let notification = """
            {"jsonrpc":"2.0","method":"test/notification","params":{}}
            """
        try await transport.send(notification.data(using: .utf8)!)

        // Wait for read to complete
        _ = try await readTask.value

        // Verify events were stored
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1, "At least one event should be stored")
    }

    @Test("Replay returns correct stream ID")
    func replayReturnsCorrectStreamId() async throws {
        let eventStore = InMemoryEventStore()

        // Store some test events directly
        let message1 = """
            {"jsonrpc":"2.0","method":"test","params":{"msg":"first"}}
            """.data(using: .utf8)!
        let eventId1 = try await eventStore.storeEvent(streamId: "stream-A", message: message1)

        let message2 = """
            {"jsonrpc":"2.0","method":"test","params":{"msg":"second"}}
            """.data(using: .utf8)!
        _ = try await eventStore.storeEvent(streamId: "stream-A", message: message2)

        // Replay events after the first one
        actor MessageCollector {
            var messages: [String] = []
            func add(_ msg: String) { messages.append(msg) }
            func get() -> [String] { messages }
        }
        let collector = MessageCollector()

        let streamId = try await eventStore.replayEventsAfter(eventId1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.add(text)
            }
        }

        #expect(streamId == "stream-A")
        let messages = await collector.get()
        #expect(messages.count == 1)
        #expect(messages.first?.contains("second") == true)
    }

    // MARK: - Edge Cases

    @Test("Replay with unknown event ID returns error")
    func replayWithUnknownEventIdReturnsError() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Try to reconnect with an unknown event ID
        let getRequest = TestPayloads.getRequest(sessionId: sessionId, lastEventId: "unknown-event-id")
        let getResponse = await transport.handleRequest(getRequest)

        // Should return 400 Bad Request for unknown event ID
        #expect(getResponse.statusCode == 400, "Should return 400 for unknown event ID")
    }

    @Test("Transport without event store does not include event IDs")
    func transportWithoutEventStoreDoesNotIncludeEventIds() async throws {
        let sessionId = "test-session-\(UUID().uuidString)"

        // Transport without event store
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Open SSE stream
        let getRequest = TestPayloads.getRequest(sessionId: sessionId)
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 200)

        guard let stream = getResponse.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Start reading task
        let readTask = Task {
            try await readFromStream(stream, maxChunks: 1, timeout: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(50))

        // Send a notification
        let notification = """
            {"jsonrpc":"2.0","method":"test/notification","params":{}}
            """
        try await transport.send(notification.data(using: .utf8)!)

        let receivedData = try await readTask.value
        let events = parseSSEEvents(receivedData)

        // Events should NOT have IDs when there's no event store
        if let firstEvent = events.first {
            #expect(firstEvent.id == nil, "Events should not have IDs without event store")
        }
    }

    // MARK: - Priming Events After Replay

    /// Creates a GET request with protocol version >= 2025-11-25 to enable priming events

    @Test("Replay sends a new priming event after replayed events")
    func replaySendsNewPrimingEventAfterReplayedEvents() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore,
                retryInterval: 5000  // Include retry to make priming event more visible
            )
        )
        try await transport.connect()

        // Initialize with modern protocol version
        let initMessage = TestPayloads.initializeRequest(id: "init-1", protocolVersion: Version.v2025_11_25, clientName: "test-client")
        let initRequest = TestPayloads.postRequest(body: initMessage)
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Open first SSE stream with modern protocol
        let getRequest1 = TestPayloads.getRequest(sessionId: sessionId, protocolVersion: Version.v2025_11_25)
        let getResponse1 = await transport.handleRequest(getRequest1)
        #expect(getResponse1.statusCode == 200)

        guard let stream1 = getResponse1.stream else {
            Issue.record("Expected stream in response")
            return
        }

        // Read the priming event
        let readTask1 = Task {
            try await readFromStream(stream1, maxChunks: 2, timeout: .seconds(2))
        }

        try await Task.sleep(for: .milliseconds(50))

        // Send a notification
        let notification = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Test notification"}}
            """
        try await transport.send(notification.data(using: .utf8)!)

        let receivedData1 = try await readTask1.value
        let events1 = parseSSEEvents(receivedData1)

        // Should have priming event (empty data) followed by notification
        #expect(events1.count >= 2, "Should have at least priming event + notification")

        // Find the priming event (empty data) and notification event
        let primingEvent = events1.first { $0.data.isEmpty || $0.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let notificationEvent = events1.first { $0.data.contains("notifications/message") }

        guard let firstPrimingEventId = primingEvent?.id else {
            Issue.record("Priming event should have an ID")
            return
        }

        guard let notificationEventId = notificationEvent?.id else {
            Issue.record("Notification event should have an ID")
            return
        }

        // Close the stream
        await transport.closeStandaloneSSEStream()

        // Send another notification while disconnected
        let notification2 = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Second notification"}}
            """
        try await transport.send(notification2.data(using: .utf8)!)

        // Reconnect with Last-Event-ID pointing to the notification
        // This should replay the second notification AND send a new priming event
        let getRequest2 = TestPayloads.getRequest(sessionId: sessionId, protocolVersion: Version.v2025_11_25, lastEventId: notificationEventId)
        let getResponse2 = await transport.handleRequest(getRequest2)

        #expect(getResponse2.statusCode == 200)

        guard let stream2 = getResponse2.stream else {
            Issue.record("Expected stream in reconnection response")
            return
        }

        // Read replayed events + new priming event
        let receivedData2 = try await readFromStream(stream2, maxChunks: 2, timeout: .seconds(3))
        let events2 = parseSSEEvents(receivedData2)

        // Should have replayed notification AND a NEW priming event
        let hasSecondNotification = events2.contains { $0.data.contains("Second notification") }
        #expect(hasSecondNotification, "Should have replayed the second notification")

        // Find the new priming event (empty data with different ID than first)
        let newPrimingEvent = events2.first { event in
            (event.data.isEmpty || event.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && event.id != nil && event.id != firstPrimingEventId
        }
        #expect(newPrimingEvent != nil, "Should have a NEW priming event after replay for resumability")
    }

    @Test("Priming events (empty data) are skipped during replay")
    func primingEventsAreSkippedDuringReplay() async throws {
        // Per MCP spec: "replay messages that would have been sent after the last event ID"
        // Priming events have empty data and are NOT messages - they should be skipped during replay.
        // This aligns with Python SDK behavior which skips None messages during replay.

        let eventStore = InMemoryEventStore()

        // Store events directly: priming (empty), message, priming (empty), message
        // This simulates an edge case where multiple priming events might exist
        let primingEvent1 = try await eventStore.storeEvent(streamId: "stream-A", message: Data())
        let message1 = """
            {"jsonrpc":"2.0","method":"test","params":{"msg":"first"}}
            """.data(using: .utf8)!
        _ = try await eventStore.storeEvent(streamId: "stream-A", message: message1)

        // Hypothetical second priming event (shouldn't happen in practice, but test the safeguard)
        _ = try await eventStore.storeEvent(streamId: "stream-A", message: Data())

        let message2 = """
            {"jsonrpc":"2.0","method":"test","params":{"msg":"second"}}
            """.data(using: .utf8)!
        _ = try await eventStore.storeEvent(streamId: "stream-A", message: message2)

        // Replay events after the first priming event
        actor MessageCollector {
            var messages: [Data] = []
            func add(_ msg: Data) { messages.append(msg) }
            func get() -> [Data] { messages }
        }
        let collector = MessageCollector()

        let streamId = try await eventStore.replayEventsAfter(primingEvent1) { _, message in
            await collector.add(message)
        }

        #expect(streamId == "stream-A")
        let messages = await collector.get()

        // Should only get the two actual messages, not the priming events
        #expect(messages.count == 2, "Should only replay actual messages, not priming events (empty data)")

        // Verify both messages are actual JSON-RPC messages, not empty
        for message in messages {
            #expect(!message.isEmpty, "Replayed message should not be empty (priming events should be skipped)")
            let text = String(data: message, encoding: .utf8) ?? ""
            #expect(text.contains("jsonrpc"), "Replayed message should be a JSON-RPC message")
        }
    }

    @Test("GET without Last-Event-ID opens fresh stream")
    func getWithoutLastEventIdOpensFreshStream() async throws {
        let eventStore = InMemoryEventStore()
        let sessionId = "test-session-\(UUID().uuidString)"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Store some events in the event store manually
        _ = try await eventStore.storeEvent(
            streamId: "_GET_stream",
            message: """
                {"jsonrpc":"2.0","method":"old/notification","params":{}}
                """.data(using: .utf8)!
        )

        // Open SSE stream WITHOUT Last-Event-ID
        let getRequest = TestPayloads.getRequest(sessionId: sessionId)  // No lastEventId
        let getResponse = await transport.handleRequest(getRequest)

        #expect(getResponse.statusCode == 200)
        #expect(getResponse.stream != nil)
        // Should open a fresh stream, not replay old events
    }
}
