import Foundation
import Testing

@testable import MCP

@Suite("Streamable HTTP Server Transport Tests")
struct HTTPServerTransportTests {

    // MARK: - Basic Initialization

    @Test("Stateless mode initialization")
    func statelessModeInitialization() async throws {
        let transport = HTTPServerTransport()

        // Should not have a session ID in stateless mode
        let sessionId = await transport.sessionId
        #expect(sessionId == nil)
    }

    @Test("Stateful mode initialization")
    func statefulModeInitialization() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )

        // Session ID not generated until initialize request
        let sessionId = await transport.sessionId
        #expect(sessionId == nil)
    }

    // MARK: - POST Request Handling

    @Test("POST requires correct Accept header")
    func postRequiresCorrectAcceptHeader() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Missing text/event-stream in Accept header
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"initialize","id":"1"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
    }

    @Test("POST requires Content-Type")
    func postRequiresContentType() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream"
            ],
            body: #"{"jsonrpc":"2.0","method":"initialize","id":"1"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 415)
    }

    @Test("POST with valid initialize request")
    func postWithValidInitializeRequest() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        let initializeRequest =
            TestPayloads.initializeRequest()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: initializeRequest.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
        #expect(response.headers[HTTPHeader.contentType] == "text/event-stream")
    }

    @Test("POST with notification only returns 202")
    func postWithNotificationOnlyReturns202() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Then send a notification (no id field)
        let notificationRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(notificationRequest)
        #expect(response.statusCode == 202)
    }

    @Test("POST with batch notifications returns 202")
    func postWithBatchNotificationsReturns202() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send batch of notifications (no id fields) - should return 202
        let batchNotificationsRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                #"[{"jsonrpc":"2.0","method":"notifications/someNotification1","params":{}},{"jsonrpc":"2.0","method":"notifications/someNotification2","params":{}}]"#
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(batchNotificationsRequest)
        #expect(response.statusCode == 202)
    }

    @Test("POST with invalid JSON returns parse error")
    func postWithInvalidJsonReturnsParseError() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send invalid JSON
        let invalidJsonRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: "This is not valid JSON".data(using: .utf8)
        )

        let response = await transport.handleRequest(invalidJsonRequest)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC parse error
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)") || text.lowercased().contains("parse"))
        }
    }

    @Test("POST with invalid JSON-RPC format returns error")
    func postWithInvalidJsonRpcFormatReturnsError() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send message missing jsonrpc version (invalid JSON-RPC format)
        let invalidFormatRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(invalidFormatRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - Session Management

    @Test("Stateful mode generates session ID")
    func statefulModeGeneratesSessionId() async throws {
        actor SessionStore {
            var sessionId: String?
            func set(_ id: String) { sessionId = id }
            func get() -> String? { sessionId }
        }
        let store = SessionStore()
        let expectedSessionId = "test-session-123"

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { expectedSessionId },
                onSessionInitialized: { sessionId in
                    await store.set(sessionId)
                }
            )
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.sessionId] == expectedSessionId)

        let generatedSessionId = await store.get()
        #expect(generatedSessionId == expectedSessionId)

        let actualSessionId = await transport.sessionId
        #expect(actualSessionId == expectedSessionId)
    }

    @Test("Stateful mode rejects invalid session ID")
    func statefulModeRejectsInvalidSessionId() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "valid-session" })
        )
        try await transport.connect()

        // First initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Then try with wrong session ID
        let badRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "wrong-session",
            ],
            body:
                #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(badRequest)
        #expect(response.statusCode == 404)
    }

    @Test("Stateful mode requires session ID after init")
    func statefulModeRequiresSessionIdAfterInit() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Try without session ID
        let noSessionRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(noSessionRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - GET Request Handling

    @Test("GET requires Accept header")
    func getRequiresAcceptHeader() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        let request = HTTPRequest(method: "GET", headers: [:])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 406)
    }

    @Test("GET returns SSE stream")
    func getReturnsSSEStream() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first (stateless mode - no session required)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        let request = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "text/event-stream")
        #expect(response.stream != nil)
    }

    @Test("GET rejects multiple SSE streams")
    func getRejectsMultipleSSEStreams() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // First GET
        let request1 = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response1 = await transport.handleRequest(request1)
        #expect(response1.statusCode == 200)

        // Second GET - should fail
        let request2 = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response2 = await transport.handleRequest(request2)
        #expect(response2.statusCode == 409)
    }

    // MARK: - DELETE Request Handling

    @Test("DELETE closes session")
    func deleteClosesSession() async throws {
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
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"]
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 200)
        let sessionClosed = await state.isClosed()
        #expect(sessionClosed == true)
    }

    @Test("DELETE in stateless mode returns 405")
    func deleteInStatelessModeReturns405() async throws {
        // Stateless mode (no session ID generator)
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE should return 405 in stateless mode (no session to terminate)
        let deleteRequest = HTTPRequest(method: "DELETE", headers: [:])
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeader.allow] == "GET, POST")

        // Verify it's a proper JSON-RPC error
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Session management is not enabled") || text.contains("Method Not Allowed"))
        }
    }

    @Test("Session terminated - requests return 404")
    func sessionTerminatedRequestsReturn404() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE to terminate session
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"]
        )
        let deleteResponse = await transport.handleRequest(deleteRequest)
        #expect(deleteResponse.statusCode == 200)

        // Try to use the terminated session - should return 404
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // GET with terminated session should also return 404
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ]
        )
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 404)
    }

    // MARK: - Unsupported Methods

    @Test("Unsupported method returns 405")
    func unsupportedMethodReturns405() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        let request = HTTPRequest(method: "PUT", headers: [:])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeader.allow] == "GET, POST, DELETE")
    }

    // MARK: - Protocol Version Validation

    @Test("Rejects unsupported protocol version")
    func rejectsUnsupportedProtocolVersion() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Then try with unsupported version
        let badRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.protocolVersion: "1999-01-01",
            ],
            body:
                #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(badRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - JSON Response Mode

    @Test("JSON response mode only requires application/json Accept header")
    func jsonResponseModeOnlyRequiresJsonAcceptHeader() async throws {
        let transport = HTTPServerTransport(
            options: .init(enableJsonResponse: true)
        )
        try await transport.connect()

        // Should succeed with only application/json (no text/event-stream required)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json",  // Only JSON, no SSE
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        // Start a task to send the response
        Task {
            try await Task.sleep(for: .milliseconds(50))
            let responseData =
                TestPayloads.initializeResult()
                .data(using: .utf8)!
            try await transport.send(responseData, relatedRequestId: .string("1"))
        }

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
    }

    @Test("JSON response mode rejects request without application/json Accept header")
    func jsonResponseModeRejectsWithoutJsonAccept() async throws {
        let transport = HTTPServerTransport(
            options: .init(enableJsonResponse: true)
        )
        try await transport.connect()

        // Should fail without application/json
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "text/plain",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
    }

    @Test("SSE mode requires both Accept types")
    func sseModeRequiresBothAcceptTypes() async throws {
        let transport = HTTPServerTransport(
            options: .init(enableJsonResponse: false)  // SSE mode (default)
        )
        try await transport.connect()

        // Should fail with only application/json (missing text/event-stream)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json",  // Missing text/event-stream
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("both"))
        }
    }

    @Test("JSON response mode returns JSON")
    func jsonResponseModeReturnsJson() async throws {
        let transport = HTTPServerTransport(
            options: .init(enableJsonResponse: true)
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        // Start a task to send the response
        Task {
            // Wait a bit for the request to be processed
            try await Task.sleep(for: .milliseconds(50))

            // Send a response
            let responseData =
                TestPayloads.initializeResult()
                .data(using: .utf8)!
            try await transport.send(responseData, relatedRequestId: .string("1"))
        }

        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
        #expect(response.body != nil)
        #expect(response.stream == nil)
    }

    // MARK: - Multiple Initialize Rejection

    @Test("Rejects double initialize")
    func rejectsDoubleInitialize() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        // First initialize
        let initRequest1 = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        let response1 = await transport.handleRequest(initRequest1)
        #expect(response1.statusCode == 200)

        let sessionId = response1.headers[HTTPHeader.sessionId]!

        // Second initialize - should fail
        let initRequest2 = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: sessionId,
            ],
            body:
                TestPayloads.initializeRequest(id: "2")
                .data(using: .utf8)
        )
        let response2 = await transport.handleRequest(initRequest2)
        #expect(response2.statusCode == 400)
    }

    // MARK: - DNS Rebinding Protection

    @Test("DNS rebinding protection allows valid host")
    func dnsRebindingProtectionAllowsValidHost() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test("DNS rebinding protection rejects invalid host")
    func dnsRebindingProtectionRejectsInvalidHost() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "evil.com:8080",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        // 421 Misdirected Request for invalid Host
        #expect(response.statusCode == 421)
    }

    @Test("DNS rebinding protection rejects missing host")
    func dnsRebindingProtectionRejectsMissingHost() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                // No Host header
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        // 421 Misdirected Request for missing Host
        #expect(response.statusCode == 421)
    }

    @Test("DNS rebinding protection allows wildcard port")
    func dnsRebindingProtectionAllowsWildcardPort() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost())  // Wildcard port
        )
        try await transport.connect()

        // Test with various ports
        for port in [8080, 3000, 9999] {
            let request = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                    HTTPHeader.host: "127.0.0.1:\(port)",
                ],
                body:
                    TestPayloads.initializeRequest()
                    .data(using: .utf8)
            )

            let response = await transport.handleRequest(request)
            // First request succeeds (200), subsequent ones fail (400) because already initialized
            #expect(response.statusCode == 200 || response.statusCode == 400)
        }
    }

    @Test("DNS rebinding protection allows valid origin")
    func dnsRebindingProtectionAllowsValidOrigin() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                HTTPHeader.origin: "http://localhost:8080",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test("DNS rebinding protection rejects invalid origin")
    func dnsRebindingProtectionRejectsInvalidOrigin() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                HTTPHeader.origin: "http://evil.com",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 403)
    }

    @Test("DNS rebinding protection allows request without origin")
    func dnsRebindingProtectionAllowsRequestWithoutOrigin() async throws {
        // Non-browser clients (like curl) don't send Origin header
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                // No Origin header
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test("DNS rebinding protection disabled by default")
    func dnsRebindingProtectionDisabledByDefault() async throws {
        // Without security settings, any host should be allowed
        let transport = HTTPServerTransport()
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "any-host.com:8080",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test("forBindAddress auto-enables for localhost")
    func forBindAddressAutoEnablesForLocalhost() {
        // Should return security settings for localhost addresses
        #expect(TransportSecuritySettings.forBindAddress(host: "127.0.0.1", port: 8080) != nil)
        #expect(TransportSecuritySettings.forBindAddress(host: "localhost", port: 3000) != nil)
        #expect(TransportSecuritySettings.forBindAddress(host: "::1", port: 9000) != nil)

        // Should return nil for other addresses (no protection needed)
        #expect(TransportSecuritySettings.forBindAddress(host: "0.0.0.0", port: 8080) == nil)
        #expect(TransportSecuritySettings.forBindAddress(host: "192.168.1.1", port: 8080) == nil)
    }

    @Test("DNS rebinding protection rejects invalid host on GET")
    func dnsRebindingProtectionRejectsInvalidHostOnGet() async throws {
        let transport = HTTPServerTransport(
            options: .init(security: .forLocalhost(port: 8080))
        )
        try await transport.connect()

        // Initialize first with valid host
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // GET with invalid host
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.host: "evil.com:8080",
            ]
        )
        let response = await transport.handleRequest(getRequest)
        #expect(response.statusCode == 421)
    }

    // MARK: - Protocol Version on GET/DELETE

    @Test("Rejects unsupported protocol version on GET")
    func rejectsUnsupportedProtocolVersionOnGet() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // GET with unsupported protocol version
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: "1999-01-01",
            ]
        )
        let response = await transport.handleRequest(getRequest)
        #expect(response.statusCode == 400)
    }

    @Test("Rejects unsupported protocol version on DELETE")
    func rejectsUnsupportedProtocolVersionOnDelete() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE with unsupported protocol version
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: "1999-01-01",
            ]
        )
        let response = await transport.handleRequest(deleteRequest)
        #expect(response.statusCode == 400)
    }

    @Test("Accepts requests without protocol version header")
    func acceptsRequestsWithoutProtocolVersionHeader() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Request without protocol version header should work
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                // No protocol version header
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    // MARK: - Session Closed Callback Edge Cases

    @Test("Session closed callback not called for invalid session")
    func sessionClosedCallbackNotCalledForInvalidSession() async throws {
        actor CallbackState {
            var called = false
            func markCalled() { called = true }
            func wasCalled() -> Bool { called }
        }
        let state = CallbackState()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "valid-session" },
                onSessionClosed: { _ in await state.markCalled() }
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Try to DELETE with invalid session ID
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "invalid-session"]
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 404)
        let called = await state.wasCalled()
        #expect(called == false)  // Callback should NOT be called for invalid session
    }

    @Test("DELETE without callback works")
    func deleteWithoutCallbackWorks() async throws {
        // No onSessionClosed callback provided
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE should work without callback
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"]
        )
        let response = await transport.handleRequest(deleteRequest)
        #expect(response.statusCode == 200)
    }

    // MARK: - Batch Request Handling

    @Test("Batch initialize request rejected")
    func batchInitializeRequestRejected() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { UUID().uuidString })
        )
        try await transport.connect()

        // Batch with initialize messages should be rejected
        let batchRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.batchRequest([
                    TestPayloads.initializeRequest(id: "1"),
                    TestPayloads.initializeRequest(id: "2", clientName: "test2"),
                ])
                .data(using: .utf8)
        )
        let response = await transport.handleRequest(batchRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - Uninitialized Server Handling

    @Test("Rejects requests to uninitialized server")
    func rejectsRequestsToUninitializedServer() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Send a non-initialize request without first initializing
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"1"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC error with "not initialized"
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    @Test("Rejects GET requests to uninitialized server")
    func rejectsGetRequestsToUninitializedServer() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Send a GET request without first initializing
        let request = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ]
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC error with "not initialized"
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    // MARK: - Stateless Mode

    @Test("Stateless mode accepts requests with any session ID")
    func statelessModeAcceptsAnySessionId() async throws {
        // No session ID generator = stateless mode
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // In stateless mode, requests with different session IDs should work
        for sessionId in ["session-1", "session-2", "random-id", ""] {
            var headers = [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ]
            if !sessionId.isEmpty {
                headers[HTTPHeader.sessionId] = sessionId
            }

            let request = HTTPRequest(
                method: "POST",
                headers: headers,
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8)
            )

            let response = await transport.handleRequest(request)
            // Notifications should return 202 regardless of session ID in stateless mode
            #expect(response.statusCode == 202)
        }
    }

    @Test("Stateless mode allows request without session ID")
    func statelessModeAllowsRequestWithoutSessionId() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Request without session ID should work in stateless mode
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                // No session ID header
            ],
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 202)
    }

    @Test("Stateless mode rejects requests before initialization")
    func statelessModeRejectsRequestsBeforeInit() async throws {
        // No session ID generator = stateless mode
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Try to send request without initializing first
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"1"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify error message mentions initialization
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    @Test("Stateless mode rejects GET requests before initialization")
    func statelessModeRejectsGetBeforeInit() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Try GET without initializing first
        let request = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"]
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    // MARK: - JSON-RPC Error Code Validation

    @Test("Parse error returns -32700")
    func parseErrorReturns32700() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send invalid JSON
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: "not valid json".data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
        }
    }

    @Test("Invalid request returns -32600")
    func invalidRequestReturns32600() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send message missing jsonrpc version (invalid JSON-RPC format)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.invalidRequest)"))
        }
    }

    @Test("Empty body returns parse error -32700")
    func emptyBodyReturnsParseError() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send empty body
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: nil
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
            #expect(text.contains("Empty request body"))
        }
    }

    @Test("Valid JSON but not JSON-RPC array returns parse error")
    func validJsonNotJsonRpcReturnsParseError() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send valid JSON but not a JSON-RPC message (not an object or array of objects)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"["string", 123, true]"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
        }
    }

    @Test("Wrong jsonrpc version returns invalid request error")
    func wrongJsonRpcVersionReturnsInvalidRequest() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Send message with wrong jsonrpc version
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"1.0","method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8)
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.invalidRequest)"))
            #expect(text.lowercased().contains("jsonrpc"))
        }
    }

    // MARK: - Session ID Validation Tests (per Python/TypeScript SDK patterns)

    @Test("Valid session IDs accepted")
    func validSessionIdsAccepted() async throws {
        // Valid session IDs: visible ASCII (0x21-0x7E)
        let validSessionIds = [
            "test-session-id",
            "1234567890",
            "session!@#$%^&*()_+-=[]{}|;:,.<>?/",
            "~",  // 0x7E
            "!",  // 0x21
            UUID().uuidString,
        ]

        for validId in validSessionIds {
            let transport = HTTPServerTransport(
                options: .init(sessionIdGenerator: { validId })
            )
            try await transport.connect()

            let initRequest = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                ],
                body:
                    TestPayloads.initializeRequest()
                    .data(using: .utf8)
            )

            let response = await transport.handleRequest(initRequest)
            #expect(response.statusCode == 200, "Session ID '\(validId)' should be accepted")
            #expect(response.headers[HTTPHeader.sessionId] == validId)
        }
    }

    @Test("Invalid session IDs rejected - space")
    func invalidSessionIdWithSpaceRejected() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "session with space" })
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 500)  // Internal error for invalid generated ID
    }

    @Test("Invalid session IDs rejected - control characters")
    func invalidSessionIdWithControlCharsRejected() async throws {
        let invalidIds = [
            "session\twith\ttab",    // Tab (0x09)
            "session\nwith\nnewline", // Newline (0x0A)
            "session\rwith\rcarriage", // Carriage return (0x0D)
            "session\u{7F}with\u{7F}del", // DEL (0x7F)
            "session\u{00}with\u{00}null", // NULL (0x00)
        ]

        for invalidId in invalidIds {
            let transport = HTTPServerTransport(
                options: .init(sessionIdGenerator: { invalidId })
            )
            try await transport.connect()

            let initRequest = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                ],
                body:
                    TestPayloads.initializeRequest()
                    .data(using: .utf8)
            )

            let response = await transport.handleRequest(initRequest)
            #expect(response.statusCode == 500, "Session ID with control chars should be rejected")
        }
    }

    @Test("Invalid session IDs rejected - empty string")
    func invalidSessionIdEmptyRejected() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "" })
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 500)  // Empty session ID is invalid
    }

    // MARK: - GET Priming Events Tests (per Python/TypeScript SDK patterns)

    @Test("GET stream receives priming event with event store")
    func getStreamReceivesPrimingEventWithEventStore() async throws {
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize with protocol version that supports priming events
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should receive priming event
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
            ]
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)

        // Verify priming event was stored
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1)  // At least one priming event
    }

    @Test("GET stream does not receive priming event for old protocol version")
    func getStreamNoPrimingEventForOldProtocol() async throws {
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize with old protocol version
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should NOT receive priming event for old protocol
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ]
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)

        // No priming event for old protocol
        let eventCount = await eventStore.eventCount
        #expect(eventCount == 0)
    }

    @Test("GET stream does not receive priming event without event store")
    func getStreamNoPrimingEventWithoutEventStore() async throws {
        // No event store configured
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should still work but no priming event
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ]
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
    }

    @Test("Priming event includes retry interval when configured")
    func primingEventIncludesRetryInterval() async throws {
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore,
                retryInterval: 5000  // 5 seconds
            )
        )
        try await transport.connect()

        // Initialize with new protocol version
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)

        // Read first event from stream to check for retry field
        if let stream = response.stream {
            var receivedData = Data()
            for try await chunk in stream {
                receivedData.append(chunk)
                break  // Just get first chunk (priming event)
            }
            let eventString = String(data: receivedData, encoding: .utf8) ?? ""
            #expect(eventString.contains("retry: 5000"))
        }
    }

    // MARK: - Resumability Tests (per Python/TypeScript SDK patterns)

    @Test("Event store stores events with unique IDs")
    func eventStoreStoresEventsWithUniqueIds() async throws {
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg1".utf8))
        let id2 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg2".utf8))
        let id3 = try await eventStore.storeEvent(streamId: "stream-2", message: Data("msg3".utf8))

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)

        let eventCount = await eventStore.eventCount
        #expect(eventCount == 3)
    }

    @Test("Event store replays events after last event ID")
    func eventStoreReplaysEventsAfterLastId() async throws {
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) { messages.append(text) }
            func getMessages() -> [String] { messages }
        }
        let collector = MessageCollector()
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg2".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg3".utf8))

        let replayedStreamId = try await eventStore.replayEventsAfter(id1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        let replayedMessages = await collector.getMessages()
        #expect(replayedStreamId == "stream-1")
        #expect(replayedMessages.count == 2)  // msg2 and msg3, not msg1
        #expect(replayedMessages.contains("msg2"))
        #expect(replayedMessages.contains("msg3"))
        #expect(!replayedMessages.contains("msg1"))
    }

    @Test("Event store only replays events from same stream")
    func eventStoreOnlyReplaysFromSameStream() async throws {
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) { messages.append(text) }
            func getMessages() -> [String] { messages }
        }
        let collector = MessageCollector()
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("stream1-msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-2", message: Data("stream2-msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("stream1-msg2".utf8))

        _ = try await eventStore.replayEventsAfter(id1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        let replayedMessages = await collector.getMessages()
        // Should only replay stream-1 messages after id1
        #expect(replayedMessages.count == 1)
        #expect(replayedMessages.contains("stream1-msg2"))
        #expect(!replayedMessages.contains("stream2-msg1"))
    }

    @Test("GET with Last-Event-ID replays events")
    func getWithLastEventIdReplaysEvents() async throws {
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Store some events directly
        let eventId = try await eventStore.storeEvent(
            streamId: "_GET_stream",
            message: Data(#"{"jsonrpc":"2.0","method":"test"}"#.utf8)
        )

        // GET with Last-Event-ID should trigger replay
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.lastEventId: eventId,
            ]
        )
        let response = await transport.handleRequest(getRequest)

        // Should return 200 with stream (replay mode)
        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
    }

    // MARK: - Protocol Version Negotiation Tests

    @Test("Protocol version stored after initialization")
    func protocolVersionStoredAfterInit() async throws {
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize with 2025-11-25
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Priming event should be stored (only for >= 2025-11-25)
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1)
    }

    // MARK: - Cache-Control Header Tests

    @Test("POST SSE response has correct Cache-Control header")
    func postSseResponseHasCorrectCacheControl() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.cacheControl] == "no-cache, no-transform")
    }

    @Test("GET SSE response has correct Cache-Control header")
    func getSseResponseHasCorrectCacheControl() async throws {
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        let getRequest = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"]
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.cacheControl] == "no-cache, no-transform")
    }

    // MARK: - Session Callback Tests (per Python/TypeScript SDK patterns)

    @Test("Session initialized callback called with session ID")
    func sessionInitializedCallbackCalled() async throws {
        actor SessionTracker {
            var sessionId: String?
            func set(_ id: String) { sessionId = id }
            func get() -> String? { sessionId }
        }
        let tracker = SessionTracker()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "callback-test-session" },
                onSessionInitialized: { sessionId in
                    await tracker.set(sessionId)
                }
            )
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )

        _ = await transport.handleRequest(initRequest)

        let capturedId = await tracker.get()
        #expect(capturedId == "callback-test-session")
    }

    @Test("Session closed callback called on DELETE")
    func sessionClosedCallbackCalledOnDelete() async throws {
        actor SessionTracker {
            var closedSessionId: String?
            func setClosed(_ id: String) { closedSessionId = id }
            func getClosed() -> String? { closedSessionId }
        }
        let tracker = SessionTracker()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "close-test-session" },
                onSessionClosed: { sessionId in
                    await tracker.setClosed(sessionId)
                }
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "close-test-session"]
        )
        _ = await transport.handleRequest(deleteRequest)

        let closedId = await tracker.getClosed()
        #expect(closedId == "close-test-session")
    }

    @Test("Session closed callback not invoked for invalid session DELETE")
    func sessionClosedCallbackNotInvokedForInvalidSessionDelete() async throws {
        actor CallCounter {
            var count = 0
            func increment() { count += 1 }
            func getCount() -> Int { count }
        }
        let counter = CallCounter()

        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "valid-session" },
                onSessionClosed: { _ in
                    await counter.increment()
                }
            )
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE with wrong session ID
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "wrong-session"]
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 404)
        let callCount = await counter.getCount()
        #expect(callCount == 0)  // Callback should NOT be called
    }

    // MARK: - Terminated State Tests

    @Test("Terminated stateless transport returns 404")
    func terminatedStatelessTransportReturns404() async throws {
        // Stateless mode
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Manually disconnect/close the transport
        await transport.disconnect()

        // Any subsequent request should return 404
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // GET should also return 404
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"]
        )
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 404)

        // Even initialize should return 404 after termination
        let reInitRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(id: "3")
                .data(using: .utf8)
        )
        let reInitResponse = await transport.handleRequest(reInitRequest)
        #expect(reInitResponse.statusCode == 404)
    }

    @Test("Terminated stateful transport returns 404 for all requests")
    func terminatedStatefulTransportReturns404ForAll() async throws {
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Close the transport directly (simulating server shutdown)
        await transport.close()

        // Any request should now return 404 - even with correct session ID
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8)
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // Verify the error message indicates termination
        if let body = postResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("terminated"))
        }
    }

    // MARK: - Stream Resumability Tests (Per MCP Spec)

    @Test("POST-initiated stream can be resumed via GET with Last-Event-ID")
    func postInitiatedStreamCanBeResumedViaGet() async throws {
        // Per spec: "This mechanism applies regardless of how the original SSE stream
        // was initiated—even if a stream was originally started for a specific client
        // request (via HTTP POST), the client will resume it via HTTP GET."
        let eventStore = InMemoryEventStore()
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { "test-session" },
                eventStore: eventStore
            )
        )
        try await transport.connect()

        // Initialize with protocol version 2025-11-25 (supports priming events)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest(id: "init", protocolVersion: Version.v2025_11_25)
                .data(using: .utf8)
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Send a POST request that starts an SSE stream
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"req-1"}"#.data(using: .utf8)
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 200)
        #expect(postResponse.stream != nil)

        // The event store should have events from the POST stream (priming event at minimum)
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1, "Event store should have at least one event from POST stream")

        // Get an event ID from the store to simulate client reconnection
        // We need to manually store an event to get an ID for the POST stream
        let testStreamId = "test-stream-\(UUID().uuidString)"
        let eventId = try await eventStore.storeEvent(
            streamId: testStreamId,
            message: #"{"jsonrpc":"2.0","result":{"tools":[]},"id":"req-1"}"#.data(using: .utf8)!
        )

        // Client reconnects via GET with Last-Event-ID (even though original was POST)
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
                HTTPHeader.lastEventId: eventId,
            ]
        )
        let getResponse = await transport.handleRequest(getRequest)

        // Should return 200 with stream (resumption mode)
        #expect(getResponse.statusCode == 200)
        #expect(getResponse.stream != nil)
        #expect(getResponse.headers[HTTPHeader.contentType] == "text/event-stream")
    }

    @Test("Cross-stream event isolation during replay")
    func crossStreamEventIsolationDuringReplay() async throws {
        // Per spec: "Server MUST NOT replay messages delivered on a different stream"
        let eventStore = InMemoryEventStore()

        // Store events for two different streams
        let stream1Id = "stream-1"
        let stream2Id = "stream-2"

        let event1_1 = try await eventStore.storeEvent(
            streamId: stream1Id,
            message: #"{"jsonrpc":"2.0","result":"stream1-msg1","id":"1"}"#.data(using: .utf8)!
        )
        _ = try await eventStore.storeEvent(
            streamId: stream2Id,
            message: #"{"jsonrpc":"2.0","result":"stream2-msg1","id":"2"}"#.data(using: .utf8)!
        )
        _ = try await eventStore.storeEvent(
            streamId: stream1Id,
            message: #"{"jsonrpc":"2.0","result":"stream1-msg2","id":"3"}"#.data(using: .utf8)!
        )
        _ = try await eventStore.storeEvent(
            streamId: stream2Id,
            message: #"{"jsonrpc":"2.0","result":"stream2-msg2","id":"4"}"#.data(using: .utf8)!
        )

        // Replay events after event1_1 (should only get stream1 events)
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) { messages.append(text) }
            func getMessages() -> [String] { messages }
        }
        let collector = MessageCollector()

        let replayedStreamId = try await eventStore.replayEventsAfter(event1_1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        // Should only replay stream-1 events
        #expect(replayedStreamId == stream1Id)
        let replayedMessages = await collector.getMessages()
        #expect(replayedMessages.count == 1, "Should only replay one event from stream-1")
        #expect(replayedMessages.contains { $0.contains("stream1-msg2") }, "Should contain stream1-msg2")
        #expect(!replayedMessages.contains { $0.contains("stream2") }, "Should NOT contain any stream-2 events")
    }

    @Test("Client sending JSON-RPC response returns 202 Accepted")
    func clientSendingResponseReturns202() async throws {
        // Per spec: For JSON-RPC response or notification input,
        // server returns 202 Accepted with no body
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Client sends a JSON-RPC response (e.g., in reply to a sampling request from server)
        // A response has "result" or "error" but no "method"
        let responseRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Sample response"}]},"id":"server-req-1"}"#.data(using: .utf8)
        )
        let response = await transport.handleRequest(responseRequest)

        // Per spec, responses should return 202 Accepted
        #expect(response.statusCode == 202)
        #expect(response.body == nil || response.body?.isEmpty == true, "202 response should have no body")
    }

    @Test("Client sending JSON-RPC error response returns 202 Accepted")
    func clientSendingErrorResponseReturns202() async throws {
        // Per spec: For JSON-RPC response (including error responses) input,
        // server returns 202 Accepted
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { "test-session" })
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
                TestPayloads.initializeRequest()
                .data(using: .utf8)
        )
        _ = await transport.handleRequest(initRequest)

        // Client sends a JSON-RPC error response (e.g., rejecting a sampling request)
        let errorResponseRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"User rejected sampling request"},"id":"server-req-1"}"#.data(using: .utf8)
        )
        let response = await transport.handleRequest(errorResponseRequest)

        // Per spec, error responses should also return 202 Accepted
        #expect(response.statusCode == 202)
    }

    @Test("Priming events are not replayed during resumption")
    func primingEventsNotReplayedDuringResumption() async throws {
        // Per spec and InMemoryEventStore design: priming events (empty data)
        // should be stored but NOT replayed as regular messages
        let eventStore = InMemoryEventStore()
        let streamId = "test-stream"

        // Store a priming event (empty data)
        let primingEventId = try await eventStore.storeEvent(streamId: streamId, message: Data())

        // Store a regular message
        _ = try await eventStore.storeEvent(
            streamId: streamId,
            message: #"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)!
        )

        // Replay from before priming event (using a fake "before" ID approach)
        // We'll replay from the priming event itself
        actor MessageCollector {
            var messages: [Data] = []
            func append(_ data: Data) { messages.append(data) }
            func getMessages() -> [Data] { messages }
        }
        let collector = MessageCollector()

        _ = try await eventStore.replayEventsAfter(primingEventId) { _, message in
            await collector.append(message)
        }

        let replayedMessages = await collector.getMessages()

        // Should only have 1 message (the regular one), not the priming event
        #expect(replayedMessages.count == 1, "Should only replay regular messages, not priming events")
        #expect(!replayedMessages.contains { $0.isEmpty }, "Should not contain empty (priming) events")
    }
}
