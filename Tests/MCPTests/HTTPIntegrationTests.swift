import Foundation
import Testing

@testable import MCP

/// Integration tests for HTTP transport following TypeScript SDK patterns.
///
/// These tests verify:
/// - Multi-client scenarios (10+ concurrent clients)
/// - Session lifecycle (create, use, delete)
/// - Stateful vs stateless mode
/// - Response routing
@Suite("HTTP Integration Tests")
struct HTTPIntegrationTests {

    // MARK: - Test Message Templates (matching TypeScript SDK)

    static let initializeMessage = TestPayloads.initializeRequest(id: "init-1", clientName: "test-client")

    static let toolsListMessage = TestPayloads.listToolsRequest(id: "tools-1")

    // MARK: - Helper Functions

    // MARK: - Initialization Tests (matching TypeScript SDK)

    @Test("Initialize server and generate session ID")
    func initializeServerAndGenerateSessionId() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        let request = TestPayloads.postRequest(body: Self.initializeMessage)
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "text/event-stream")
        #expect(response.headers[HTTPHeader.sessionId] != nil)
    }

    @Test("Reject second initialization request")
    func rejectSecondInitializationRequest() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        // First initialize
        let request1 = TestPayloads.postRequest(body: Self.initializeMessage)
        let response1 = await transport.handleRequest(request1)
        #expect(response1.statusCode == 200)

        let sessionId = response1.headers[HTTPHeader.sessionId]!

        // Second initialize - should fail
        let secondInitMessage = TestPayloads.initializeRequest(id: "init-2", clientName: "test-client")
        let request2 = TestPayloads.postRequest(body: secondInitMessage, sessionId: sessionId)
        let response2 = await transport.handleRequest(request2)

        #expect(response2.statusCode == 400)
    }

    @Test("Reject batch initialize request")
    func rejectBatchInitializeRequest() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        let batchInitMessages = TestPayloads.batchRequest([
            TestPayloads.initializeRequest(id: "init-1", clientName: "test-client-1"),
            TestPayloads.initializeRequest(id: "init-2", clientName: "test-client-2"),
        ])
        let request = TestPayloads.postRequest(body: batchInitMessages)
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 400)
    }

    // MARK: - Session Validation Tests (matching TypeScript SDK)

    @Test("Reject requests without valid session ID")
    func rejectRequestsWithoutValidSessionId() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        // Initialize first
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Try without session ID
        let request = TestPayloads.postRequest(body: Self.toolsListMessage)
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 400)
    }

    @Test("Reject invalid session ID")
    func rejectInvalidSessionId() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        // Initialize first
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Try with invalid session ID
        let request = TestPayloads.postRequest(body: Self.toolsListMessage, sessionId: "invalid-session-id")
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 404)
    }

    // MARK: - SSE Stream Tests (matching TypeScript SDK)

    @Test("Reject second SSE stream for same session")
    func rejectSecondSSEStreamForSameSession() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // First GET - should succeed
        let getRequest1 = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response1 = await transport.handleRequest(getRequest1)
        #expect(response1.statusCode == 200)

        // Second GET - should fail (only one stream allowed)
        let getRequest2 = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response2 = await transport.handleRequest(getRequest2)
        #expect(response2.statusCode == 409)
    }

    @Test("Reject GET requests without Accept header")
    func rejectGETRequestsWithoutAcceptHeader() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // GET without proper Accept header
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "application/json",  // Wrong Accept header
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response = await transport.handleRequest(getRequest)
        #expect(response.statusCode == 406)
    }

    // MARK: - Content Type Validation (matching TypeScript SDK)

    @Test("Reject POST requests without proper Accept header")
    func rejectPOSTRequestsWithoutProperAcceptHeader() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // POST without text/event-stream in Accept
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json",  // Missing text/event-stream
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ],
            body: Self.toolsListMessage.data(using: .utf8)
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
    }

    @Test("Reject unsupported Content-Type")
    func rejectUnsupportedContentType() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // POST with wrong Content-Type
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "text/plain",  // Wrong Content-Type
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ],
            body: "This is plain text".data(using: .utf8)
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 415)
    }

    // MARK: - Notification Handling (matching TypeScript SDK)

    @Test("Handle JSON-RPC batch notification messages with 202 response")
    func handleJSONRPCBatchNotificationMessagesWith202Response() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Send batch of notifications (no IDs)
        let batchNotifications = """
            [{"jsonrpc":"2.0","method":"someNotification1","params":{}},{"jsonrpc":"2.0","method":"someNotification2","params":{}}]
            """
        let request = TestPayloads.postRequest(body: batchNotifications, sessionId: "test-session")
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 202)
    }

    // MARK: - JSON Parsing (matching TypeScript SDK)

    @Test("Handle invalid JSON data properly")
    func handleInvalidJSONDataProperly() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Send invalid JSON
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ],
            body: "This is not valid JSON".data(using: .utf8)
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
    }

    // MARK: - DELETE Tests (matching TypeScript SDK)

    @Test("Handle DELETE requests and close session properly")
    func handleDELETERequestsAndCloseSession() async throws {
        actor ClosedState {
            var closed = false
            func markClosed() { closed = true }
            func isClosed() -> Bool { closed }
        }
        let state = ClosedState()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                onSessionClosed: { _ in await state.markClosed() }
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // DELETE
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 200)
        let closed = await state.isClosed()
        #expect(closed == true)
    }

    @Test("Reject DELETE requests with invalid session ID")
    func rejectDELETERequestsWithInvalidSessionId() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "valid-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // DELETE with invalid session ID
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: "invalid-session-id",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 404)
    }

    // MARK: - Protocol Version Tests (matching TypeScript SDK)

    @Test("Accept requests with matching protocol version")
    func acceptRequestsWithMatchingProtocolVersion() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Request with valid protocol version
        let request = TestPayloads.postRequest(body: Self.toolsListMessage, sessionId: "test-session")
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 200)
    }

    @Test("Reject unsupported protocol version")
    func rejectUnsupportedProtocolVersion() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Request with unsupported protocol version
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: "1999-01-01",  // Unsupported version
            ],
            body: Self.toolsListMessage.data(using: .utf8)
        )
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 400)
    }

    // MARK: - Stateless Mode Tests (matching TypeScript SDK)

    @Test("Stateless mode - no session ID validation")
    func statelessModeNoSessionIdValidation() async throws {
        // Stateless mode - no session ID generator
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        let initResponse = await transport.handleRequest(initRequest)

        #expect(initResponse.statusCode == 200)
        // Should NOT have session ID header in stateless mode
        #expect(initResponse.headers[HTTPHeader.sessionId] == nil)

        // Request without session ID should work in stateless mode
        let toolsRequest = TestPayloads.postRequest(body: Self.toolsListMessage)
        let toolsResponse = await transport.handleRequest(toolsRequest)

        #expect(toolsResponse.statusCode == 200)
    }

    @Test("Stateless mode accepts requests with various session IDs")
    func statelessModeAcceptsRequestsWithVariousSessionIds() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // Try with random session ID - should be accepted in stateless mode
        let request1 = TestPayloads.postRequest(body: Self.toolsListMessage, sessionId: "random-id-1")
        let response1 = await transport.handleRequest(request1)
        #expect(response1.statusCode == 200)

        // Try with another random session ID - should also be accepted
        let request2 = TestPayloads.postRequest(body: Self.toolsListMessage, sessionId: "different-id-2")
        let response2 = await transport.handleRequest(request2)
        #expect(response2.statusCode == 200)
    }

    @Test("Stateless mode rejects second SSE stream")
    func statelessModeRejectsSecondSSEStream() async throws {
        // Despite no session ID requirement, only one SSE stream allowed
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize
        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        // First GET
        let getRequest1 = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"]
        )
        let response1 = await transport.handleRequest(getRequest1)
        #expect(response1.statusCode == 200)

        // Second GET - should be rejected
        let getRequest2 = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"]
        )
        let response2 = await transport.handleRequest(getRequest2)
        #expect(response2.statusCode == 409)
    }

    // MARK: - Multi-Client Tests

    @Test("Ten concurrent clients")
    func tenConcurrentClients() async throws {
        // Simulate 10 clients connecting concurrently
        // Each client gets its own transport
        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let successCounter = Counter()

        await withTaskGroup(of: Int.self) { group in
            for clientId in 0..<10 {
                group.addTask {
                    let transport = HTTPServerTransport(
                        options: .init(sessionIdGenerator: { "session-\(clientId)" })
                    )
                    try? await transport.connect()

                    let initMessage = TestPayloads.initializeRequest(
                        id: "\(clientId)",
                        clientName: "client-\(clientId)"
                    )
                    let request = TestPayloads.postRequest(body: initMessage)

                    let response = await transport.handleRequest(request)
                    return response.statusCode
                }
            }

            // Verify all clients connected successfully
            for await statusCode in group {
                if statusCode == 200 {
                    await successCounter.increment()
                }
            }
        }

        let count = await successCounter.value()
        #expect(count == 10)
    }

    // MARK: - Session Callbacks

    @Test("Session initialized callback fires")
    func sessionInitializedCallbackFires() async throws {
        actor CallbackTracker {
            var sessionId: String?
            func set(_ id: String) { sessionId = id }
            func get() -> String? { sessionId }
        }
        let tracker = CallbackTracker()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "callback-test-session" },
                onSessionInitialized: { sessionId in
                    await tracker.set(sessionId)
                }
            )
        )
        try await transport.connect()

        let initRequest = TestPayloads.postRequest(body: Self.initializeMessage)
        _ = await transport.handleRequest(initRequest)

        let trackedSessionId = await tracker.get()
        #expect(trackedSessionId == "callback-test-session")
    }
}
