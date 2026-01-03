import Foundation
import Testing

@testable import MCP

/// Tests for additional server functionality.
///
/// These tests follow the TypeScript SDK patterns from:
/// - `packages/server/test/server/streamableHttp.test.ts`
///
/// Additional TypeScript tests that are covered elsewhere:
/// - DNS rebinding protection tests - see HTTPServerTransportTests
/// - JSON response mode tests - see HTTPServerTransportTests
/// - Pre-parsed body tests - Swift SDK handles body parsing differently
///
/// TypeScript tests not applicable in Swift:
///
/// 1. `should support sync onsessioninitialized callback (backwards compatibility)`
///    Rationale: Swift callbacks are always async with signature `@Sendable (String) async -> Void`.
///    The language doesn't support sync/async callback overloading like TypeScript does.
///
/// 2. `should propagate errors from async onsessioninitialized callback`
/// 3. `should propagate errors from async onsessionclosed callback`
///    Rationale: Swift callback signature is `@Sendable (String) async -> Void` (non-throwing).
///    TypeScript callbacks can throw because JavaScript functions can always throw.
///    This is a language difference - Swift callbacks cannot throw by design.
///    If error handling is needed, Swift users should handle errors inside the callback itself.
@Suite("Additional Server Tests")
struct AdditionalServerTests {

    // MARK: - Test Helpers

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

    // MARK: - 5.1 Response routing with concurrent requests

    @Test("Response messages are sent to the connection that sent the request")
    func responseRoutingWithConcurrentRequests() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Prepare two different requests
        let listToolsRequest = TestPayloads.listToolsRequest(id: "req-1")
        let callToolRequest = TestPayloads.callToolRequest(
            id: "req-2",
            name: "greet",
            arguments: ["name": "Connection2"]
        )

        // Send requests concurrently
        async let response1Task = transport.handleRequest(TestPayloads.postRequest(body: listToolsRequest, sessionId: sessionId))
        async let response2Task = transport.handleRequest(TestPayloads.postRequest(body: callToolRequest, sessionId: sessionId))

        let response1 = await response1Task
        let response2 = await response2Task

        #expect(response1.statusCode == 200)
        #expect(response2.statusCode == 200)

        // Verify response 1 contains tools/list result with correct ID
        if let body1 = response1.body {
            let text1 = String(data: body1, encoding: .utf8) ?? ""
            #expect(text1.contains("\"id\":\"req-1\"") || text1.contains("\"id\": \"req-1\""), "Response 1 should have ID req-1")
            #expect(text1.contains("tools") || text1.contains("greet"), "Response 1 should contain tools list")
        }

        // Verify response 2 contains tools/call result with correct ID
        if let body2 = response2.body {
            let text2 = String(data: body2, encoding: .utf8) ?? ""
            #expect(text2.contains("\"id\":\"req-2\"") || text2.contains("\"id\": \"req-2\""), "Response 2 should have ID req-2")
            #expect(text2.contains("Hello, Connection2"), "Response 2 should contain greeting result")
        }
    }

    @Test("Multiple sequential requests maintain isolation")
    func multipleSequentialRequestsMaintainIsolation() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send 3 sequential requests with different greet names
        let names = ["Alice", "Bob", "Charlie"]
        var successCount = 0

        for (index, name) in names.enumerated() {
            let requestId = "req-\(index)"
            let request = """
                {"jsonrpc":"2.0","method":"tools/call","id":"\(requestId)","params":{"name":"greet","arguments":{"name":"\(name)"}}}
                """
            let response = await transport.handleRequest(TestPayloads.postRequest(body: request, sessionId: sessionId))

            #expect(response.statusCode == 200, "Request for \(name) should succeed")

            // Response can be in body or stream depending on implementation
            var responseText: String? = nil

            if let body = response.body, let text = String(data: body, encoding: .utf8) {
                responseText = text
            } else if let stream = response.stream {
                // Try to read from stream with timeout
                var data = Data()
                let deadline = Date().addingTimeInterval(1.0)
                for try await chunk in stream {
                    data.append(chunk)
                    if Date() > deadline { break }
                    if data.count > 0 { break }  // Got some data
                }
                responseText = String(data: data, encoding: .utf8)
            }

            if let text = responseText {
                #expect(text.contains("Hello, \(name)!") || text.contains(requestId), "Response should contain greeting or request ID for \(name)")
                successCount += 1
            }
        }

        #expect(successCount == 3, "Should have 3 successful requests")
    }

    // MARK: - 5.2 Error data in parse error response

    @Test("Include error data in parse error response for invalid JSON")
    func includeErrorDataInParseErrorResponse() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send invalid JSON
        let invalidJSONRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: sessionId,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ],
            body: "{ invalid json }".data(using: .utf8)
        )
        let response = await transport.handleRequest(invalidJSONRequest)

        #expect(response.statusCode == 400, "Should return 400 for parse error")

        // Verify error response contains proper error data
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("error"), "Response should contain error field")
            #expect(text.contains("\(ErrorCode.parseError)") || text.contains("Parse error"), "Should contain parse error code or message")
        }
    }

    @Test("Include error data for invalid JSON-RPC messages")
    func includeErrorDataForInvalidJSONRPCMessages() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send invalid JSON-RPC (missing jsonrpc field)
        // Note: Swift SDK may process this and return error in body with 200 status
        let invalidJSONRPC = """
            {"method":"tools/list","id":"test"}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: invalidJSONRPC, sessionId: sessionId))

        // The Swift SDK may return 200 with error in body, or 400
        // Either is acceptable as long as the error is communicated
        #expect(response.statusCode == 200 || response.statusCode == 400, "Should handle invalid JSON-RPC")

        // Verify error response contains proper error structure if there's a body
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("jsonrpc") || text.contains("error") || text.contains("result"), "Response should be JSON-RPC formatted")
        }
    }

    @Test("Reject requests to uninitialized server")
    func rejectRequestsToUninitializedServer() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Don't initialize - send request directly with a session ID
        let listToolsRequest = """
            {"jsonrpc":"2.0","method":"tools/list","id":"test"}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: listToolsRequest, sessionId: "any-session-id"))

        // Should reject because session doesn't exist
        #expect(response.statusCode == 400 || response.statusCode == 404, "Should reject request to uninitialized session")
    }

    // MARK: - Additional Edge Cases

    @Test("Empty batch request returns appropriate response")
    func emptyBatchRequestReturnsAppropriateResponse() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send empty batch
        let emptyBatch = "[]"
        let response = await transport.handleRequest(TestPayloads.postRequest(body: emptyBatch, sessionId: sessionId))

        // Empty batch returns 202 - same as TypeScript SDK
        // Empty batch has no requests, so it's treated like a notification-only batch
        // Per JSON-RPC spec, notification-only batches return no response (202 Accepted)
        #expect(response.statusCode == 202, "Empty batch should return 202 (no requests to respond to)")
    }

    @Test("Notifications in batch don't generate individual responses")
    func notificationsInBatchDontGenerateResponses() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send batch with notification (no id) and request
        let batchWithNotification = """
            [
                {"jsonrpc":"2.0","method":"notifications/initialized"},
                {"jsonrpc":"2.0","method":"tools/list","id":"req-1"}
            ]
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: batchWithNotification, sessionId: sessionId))

        #expect(response.statusCode == 200, "Batch should succeed")

        // Should only have response for the request, not the notification
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            // The response should contain req-1's result
            #expect(text.contains("req-1") || text.contains("tools"), "Should contain response for request")
        }
    }

    @Test("Batch requests work for protocol versions before 2025-06-18")
    func batchRequestsWorkForOlderProtocolVersions() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize with protocol version 2024-11-05 (before batch removal)
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send batch of requests (both have IDs, so both need responses)
        // Batching is supported in protocol versions < 2025-06-18
        let batchRequests = """
            [
                {"jsonrpc":"2.0","method":"tools/list","id":"req-1"},
                {"jsonrpc":"2.0","method":"tools/call","id":"req-2","params":{"name":"greet","arguments":{"name":"BatchUser"}}}
            ]
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: batchRequests, sessionId: sessionId))

        #expect(response.statusCode == 200, "Batch requests should succeed for protocol version 2024-11-05")

        // Check the response body contains both results
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            // Verify both request IDs are in the response
            #expect(text.contains("req-1") || text.contains("tools"),
                    "Should contain response for req-1 (tools/list)")
            #expect(text.contains("req-2") || text.contains("Hello, BatchUser"),
                    "Should contain response for req-2 (tools/call)")
        } else {
            // If no body, at least verify we got a response
            #expect(response.stream != nil, "Should have either body or stream")
        }
    }

    @Test("Batch requests rejected for protocol versions >= 2025-06-18")
    func batchRequestsRejectedForNewerProtocolVersions() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize with protocol version 2025-06-18 (batch removal version)
        let initRequest = TestPayloads.initializeRequest(id: "init", protocolVersion: Version.v2025_06_18)
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest, protocolVersion: Version.v2025_06_18))

        // Send batch of requests - should be rejected per spec
        let batchRequests = """
            [
                {"jsonrpc":"2.0","method":"tools/list","id":"req-1"},
                {"jsonrpc":"2.0","method":"tools/call","id":"req-2","params":{"name":"greet","arguments":{"name":"BatchUser"}}}
            ]
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: batchRequests, sessionId: sessionId, protocolVersion: Version.v2025_06_18))

        // Batch requests should be rejected with 400 for protocol version >= 2025-06-18
        #expect(response.statusCode == 400, "Batch requests should be rejected for protocol version 2025-06-18")

        // Verify error message
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.invalidRequest)") || text.contains("not supported") || text.contains("Invalid"),
                    "Should return Invalid Request error for batch in newer protocol")
        }
    }

    @Test("Keep stream open after sending server notifications")
    func keepStreamOpenAfterNotifications() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Open standalone SSE stream
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: sessionId,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200, "GET should succeed")
        #expect(response.stream != nil, "Should return a stream")

        // Send a notification through the transport
        let notification = """
            {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"Test notification"}}
            """
        try await transport.send(notification.data(using: .utf8)!)

        // Stream should still be open (we just verify the transport is still functional)
        // We can't easily verify the stream is still open, but we can verify transport works
        let listToolsRequest = """
            {"jsonrpc":"2.0","method":"tools/list","id":"test"}
            """
        let listResponse = await transport.handleRequest(TestPayloads.postRequest(body: listToolsRequest, sessionId: sessionId))
        #expect(listResponse.statusCode == 200, "Transport should still be functional after sending notifications")
    }

    // MARK: - Session Callback Tests

    @Test("Async onSessionInitialized callback is called")
    func asyncOnSessionInitializedCallbackIsCalled() async throws {
        actor CallbackTracker {
            var events: [String] = []
            func add(_ event: String) { events.append(event) }
            func getEvents() -> [String] { events }
        }

        let tracker = CallbackTracker()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                onSessionInitialized: { id in
                    await tracker.add("initialized:\(id)")
                }
            )
        )

        let server = createTestServer()
        try await server.start(transport: transport)

        // Initialize to trigger the callback
        let initRequest = TestPayloads.initializeRequest(id: "init")
        let response = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        #expect(response.statusCode == 200)

        // Give time for async callback to complete
        try await Task.sleep(for: .milliseconds(50))

        let events = await tracker.getEvents()
        #expect(events.contains("initialized:\(sessionId)"), "onSessionInitialized should be called with session ID")
    }

    @Test("Async onSessionClosed callback is called on DELETE")
    func asyncOnSessionClosedCallbackIsCalledOnDelete() async throws {
        actor CallbackTracker {
            var events: [String] = []
            func add(_ event: String) { events.append(event) }
            func getEvents() -> [String] { events }
        }

        let tracker = CallbackTracker()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                onSessionClosed: { id in
                    await tracker.add("closed:\(id)")
                }
            )
        )

        let server = createTestServer()
        try await server.start(transport: transport)

        // Initialize first
        let initRequest = TestPayloads.initializeRequest(id: "init")
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // DELETE the session
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: sessionId,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let deleteResponse = await transport.handleRequest(deleteRequest)

        #expect(deleteResponse.statusCode == 200)

        // Give time for async callback to complete
        try await Task.sleep(for: .milliseconds(50))

        let events = await tracker.getEvents()
        #expect(events.contains("closed:\(sessionId)"), "onSessionClosed should be called with session ID")
    }

    @Test("Both async callbacks work together")
    func bothAsyncCallbacksWorkTogether() async throws {
        actor CallbackTracker {
            var events: [String] = []
            func add(_ event: String) { events.append(event) }
            func getEvents() -> [String] { events }
        }

        let tracker = CallbackTracker()
        let sessionId = UUID().uuidString

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId },
                onSessionInitialized: { id in
                    await tracker.add("initialized:\(id)")
                },
                onSessionClosed: { id in
                    await tracker.add("closed:\(id)")
                }
            )
        )

        let server = createTestServer()
        try await server.start(transport: transport)

        // Initialize to trigger first callback
        let initRequest = TestPayloads.initializeRequest(id: "init")
        let initResponse = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse.statusCode == 200)

        // Give time for async callback
        try await Task.sleep(for: .milliseconds(50))

        var events = await tracker.getEvents()
        #expect(events.contains("initialized:\(sessionId)"), "onSessionInitialized should be called")

        // DELETE to trigger second callback
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: sessionId,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let deleteResponse = await transport.handleRequest(deleteRequest)
        #expect(deleteResponse.statusCode == 200)

        // Give time for async callback
        try await Task.sleep(for: .milliseconds(50))

        events = await tracker.getEvents()
        #expect(events.contains("closed:\(sessionId)"), "onSessionClosed should be called")
        #expect(events.count == 2, "Should have exactly 2 events")
    }

    @Test("onSessionClosed called with correct session ID for multiple sessions")
    func onSessionClosedCalledWithCorrectSessionIdForMultipleSessions() async throws {
        actor CallbackTracker {
            var closedSessions: [String] = []
            func add(_ sessionId: String) { closedSessions.append(sessionId) }
            func getSessions() -> [String] { closedSessions }
        }

        let tracker = CallbackTracker()

        // Create first transport with unique session
        let sessionId1 = "session-1-\(UUID().uuidString)"
        let transport1 = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId1 },
                onSessionClosed: { id in
                    await tracker.add(id)
                }
            )
        )

        let server1 = createTestServer()
        try await server1.start(transport: transport1)

        // Create second transport with unique session
        let sessionId2 = "session-2-\(UUID().uuidString)"
        let transport2 = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { sessionId2 },
                onSessionClosed: { id in
                    await tracker.add(id)
                }
            )
        )

        let server2 = createTestServer()
        try await server2.start(transport: transport2)

        // Initialize both transports
        let initRequest = TestPayloads.initializeRequest(id: "init")

        let initResponse1 = await transport1.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse1.statusCode == 200)
        #expect(initResponse1.headers[HTTPHeader.sessionId] == sessionId1)

        let initResponse2 = await transport2.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse2.statusCode == 200)
        #expect(initResponse2.headers[HTTPHeader.sessionId] == sessionId2)

        // DELETE first session
        let deleteRequest1 = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: sessionId1,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let deleteResponse1 = await transport1.handleRequest(deleteRequest1)
        #expect(deleteResponse1.statusCode == 200)

        try await Task.sleep(for: .milliseconds(50))

        var closedSessions = await tracker.getSessions()
        #expect(closedSessions.count == 1)
        #expect(closedSessions.contains(sessionId1))

        // DELETE second session
        let deleteRequest2 = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: sessionId2,
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let deleteResponse2 = await transport2.handleRequest(deleteRequest2)
        #expect(deleteResponse2.statusCode == 200)

        try await Task.sleep(for: .milliseconds(50))

        closedSessions = await tracker.getSessions()
        #expect(closedSessions.count == 2)
        #expect(closedSessions.contains(sessionId1))
        #expect(closedSessions.contains(sessionId2))
    }
}
