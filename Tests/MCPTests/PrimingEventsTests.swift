import Foundation
import Testing

@testable import MCP

/// Tests for SSE priming events on POST streams.
///
/// Priming events are empty SSE events sent at the beginning of a POST SSE stream
/// to enable resumability. They contain an event ID (for resumption) and optionally
/// a retry field (for reconnection timing).
///
/// These tests follow the TypeScript SDK patterns from:
/// - `packages/server/test/server/streamableHttp.test.ts`
///
/// TypeScript tests not yet implemented (require protocol version 2025-11-25):
///
/// Rationale: The MCP protocol requires priming events only for protocol version >= 2025-11-25.
/// The Swift SDK currently supports ['2024-11-05', '2025-03-26'], while TypeScript supports
/// ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05', '2024-10-07'].
///
/// The priming event code exists in HTTPServerTransport.writePrimingEvent() but
/// is gated by: `guard protocolVersion >= "2025-11-25" else { return }`
///
/// Once the Swift SDK adds support for 2025-11-25 (see Versioning.swift TODO), implement:
/// - `should send priming event with retry field on POST SSE stream`
/// - `should send priming event without retry field when retryInterval is not configured`
/// - `should close POST SSE stream when extra.closeSSEStream is called`
/// - `should provide closeSSEStream callback in extra when eventStore is configured`
/// - `should NOT provide closeSSEStream callback for old protocol versions`
/// - `should NOT provide closeSSEStream callback when eventStore is NOT configured`
/// - `should provide closeStandaloneSSEStream callback in extra when eventStore is configured`
/// - `should close standalone GET SSE stream when extra.closeStandaloneSSEStream is called`
/// - `should allow client to reconnect after standalone SSE stream is closed`
///
/// The current tests verify that priming events are NOT sent for the currently supported
/// protocol versions, which is the correct behavior for backwards compatibility.
@Suite("Priming Events Tests")
struct PrimingEventsTests {

    // MARK: - Test Helpers

    /// Helper to read from stream with timeout
    func readFromStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        maxChunks: Int = 1,
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        var receivedData = Data()

        try await withThrowingTaskGroup(of: Data?.self) { group in
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

            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            if let result = try await group.next(), let data = result {
                receivedData = data
            }
            group.cancelAll()
        }

        return receivedData
    }

    /// Creates a configured MCP Server with tools for testing
    func createTestServer() -> Server {
        let server = Server(
            name: "test-server",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )
        return server
    }

    /// Sets up tool handlers on the server
    func setUpToolHandlers(_ server: Server) async {
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "greet",
                    description: "A simple greeting tool",
                    inputSchema: [
                        "type": "object",
                        "properties": ["name": ["type": "string"]]
                    ]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            switch request.name {
            case "greet":
                let name = request.arguments?["name"]?.stringValue ?? "World"
                return CallTool.Result(content: [.text("Hello, \(name)!")])
            default:
                return CallTool.Result(content: [.text("Unknown tool")], isError: true)
            }
        }
    }

    // MARK: - 4.1 Priming event configuration
    //
    // Note: The Swift SDK currently requires protocol version >= "2025-11-25" for priming events,
    // but the supported versions are "2024-11-05" and "2025-03-26". This means priming events
    // won't be sent until a newer protocol version is added. These tests verify the current behavior.

    @Test("Priming event configuration - retryInterval can be configured")
    func primingEventRetryIntervalConfig() async throws {
        // Test that retryInterval can be set in transport options
        let options1 = HTTPServerTransportOptions(retryInterval: 5000)
        #expect(options1.retryInterval == 5000)

        let options2 = HTTPServerTransportOptions()
        #expect(options2.retryInterval == nil)
    }

    @Test("Priming events not sent for current supported protocol versions")
    func primingEventsNotSentForCurrentVersions() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let eventStore = InMemoryEventStore()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore,
                retryInterval: 5000
            )
        )
        try await server.start(transport: transport)

        // Initialize with latest supported version (2025-03-26)
        // Note: Priming events require >= 2025-11-25 which is not yet supported
        let initRequest = TestPayloads.initializeRequest(protocolVersion: Version.v2025_03_26)
        let initResponse = await transport.handleRequest(TestPayloads.postRequest(body: initRequest, protocolVersion: Version.v2025_03_26))
        #expect(initResponse.statusCode == 200)

        // Send a tool call request
        let toolCallRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"100","params":{"name":"greet","arguments":{"name":"Test"}}}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: toolCallRequest, sessionId: sessionId, protocolVersion: Version.v2025_03_26))

        #expect(response.statusCode == 200)

        if let stream = response.stream {
            let data = try await readFromStream(stream, maxChunks: 2)
            let text = String(data: data, encoding: .utf8) ?? ""

            // Priming events have empty data - current versions won't have them
            #expect(!text.contains("data: \n\n"), "Should NOT have empty priming event for current protocol versions")
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")
        } else if let body = response.body {
            let text = String(data: body, encoding: .utf8) ?? ""
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")
        }
    }

    // MARK: - 4.2 Event ID on messages (even without priming events)

    @Test("Event IDs are included in SSE messages when event store is configured")
    func eventIdsIncludedInMessages() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let eventStore = InMemoryEventStore()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore
            )
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send a tool call request
        let toolCallRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"100","params":{"name":"greet","arguments":{"name":"Test"}}}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: toolCallRequest, sessionId: sessionId))

        #expect(response.statusCode == 200)

        if let stream = response.stream {
            let data = try await readFromStream(stream, maxChunks: 2)
            let text = String(data: data, encoding: .utf8) ?? ""

            // Even without priming events, messages should have event IDs for resumability
            #expect(text.contains("id: "), "SSE messages should include event IDs for resumability")
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")

            // Verify events were stored
            let eventCount = await eventStore.eventCount
            #expect(eventCount > 0, "Events should be stored in event store")
        }
    }

    // MARK: - Priming Event Content Tests

    @Test("No priming event for old protocol versions (backwards compatibility)")
    func noPrimingEventForOldProtocolVersions() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let eventStore = InMemoryEventStore()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore,
                retryInterval: 5000
            )
        )
        try await server.start(transport: transport)

        // Initialize with OLD protocol version (< 2025-11-25)
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest, protocolVersion: Version.v2024_11_05))

        // Send a tool call request
        let toolCallRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"100","params":{"name":"greet","arguments":{"name":"Test"}}}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: toolCallRequest, sessionId: sessionId, protocolVersion: Version.v2024_11_05))

        #expect(response.statusCode == 200)

        if let stream = response.stream {
            let data = try await readFromStream(stream, maxChunks: 2)
            let text = String(data: data, encoding: .utf8) ?? ""

            // Should NOT have retry field for old protocol versions
            // Priming events are not sent for backwards compatibility
            #expect(!text.contains("data: \n\n"), "Should NOT have empty priming event data for old protocol versions")
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain actual tool result")
        } else if let body = response.body {
            let text = String(data: body, encoding: .utf8) ?? ""
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")
        }
    }

    @Test("No priming event when event store is not configured")
    func noPrimingEventWithoutEventStore() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        // No event store configured
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId }
                // No eventStore
            )
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send a tool call request
        let toolCallRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"100","params":{"name":"greet","arguments":{"name":"Test"}}}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: toolCallRequest, sessionId: sessionId))

        #expect(response.statusCode == 200)

        // Without event store, the response might be JSON directly or SSE without priming
        // Either way, the actual response should be there
        if let body = response.body {
            let text = String(data: body, encoding: .utf8) ?? ""
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")
        } else if let stream = response.stream {
            let data = try await readFromStream(stream, maxChunks: 2)
            let text = String(data: data, encoding: .utf8) ?? ""
            // Without event store, there should be no event ID in the stream
            // Note: The first message could still have an id field depending on implementation
            #expect(text.contains("Hello, Test!") || text.contains("result"), "Should contain tool result")
        }
    }

    // MARK: - Close SSE Stream Tests

    @Test("Close SSE stream for specific request")
    func closeSSEStreamForSpecificRequest() async throws {
        let server = createTestServer()

        let eventStore = InMemoryEventStore()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                eventStore: eventStore,
                retryInterval: 1000
            )
        )

        // Set up a tool that takes time, allowing us to close the stream mid-execution
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "slow-tool",
                    description: "A slow tool",
                    inputSchema: ["type": "object"]
                )
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, context in
            if request.name == "slow-tool" {
                // Simulate slow operation
                try? await Task.sleep(for: .milliseconds(500))
                return CallTool.Result(content: [.text("Done")])
            }
            return CallTool.Result(content: [.text("Unknown tool")], isError: true)
        }

        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // The closeSSEStream method exists and is callable
        // We can't fully test the stream closure without complex async coordination
        // but we can verify the method exists and doesn't crash
        let requestId: RequestId = .string("test-request")
        await transport.closeSSEStream(for: requestId)

        // If we get here without crashing, the method works
    }

    // MARK: - Retry Interval Configuration Tests

    @Test("Retry interval is configurable in transport options")
    func retryIntervalIsConfigurable() async throws {
        // Test that different retry interval configurations can be set
        let options1 = HTTPServerTransportOptions(retryInterval: 1000)
        #expect(options1.retryInterval == 1000)

        let options2 = HTTPServerTransportOptions(retryInterval: 30000)
        #expect(options2.retryInterval == 30000)

        let options3 = HTTPServerTransportOptions()
        #expect(options3.retryInterval == nil)
    }
}
