import Foundation
import Testing

@testable import MCP

// MARK: - Test Helpers

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

private func makeInitializeBody(id: String = "1") -> Data {
    let json: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ] as [String: Any],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func makeNotificationBody(method: String = "notifications/initialized") -> Data {
    let json: [String: Any] = ["jsonrpc": "2.0", "method": method]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func makeRequestBody(id: String = "2", method: String = "tools/list") -> Data {
    let json: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": [:] as [String: Any],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func makeResponseBody(id: String = "2") -> Data {
    let json: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": ["tools": []] as [String: Any],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func makeStatefulPOSTRequest(
    body: Data,
    sessionID: String? = nil,
    authorization: String? = nil
) -> HTTPRequest {
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]
    if let sessionID {
        headers["Mcp-Session-Id"] = sessionID
    }
    if let authorization {
        headers[HTTPHeaderName.authorization] = authorization
    }
    return HTTPRequest(method: "POST", headers: headers, body: body)
}

private func makeGETRequest(sessionID: String, lastEventID: String? = nil) -> HTTPRequest {
    var headers: [String: String] = [
        "Accept": "text/event-stream",
        "Mcp-Session-Id": sessionID,
    ]
    if let lastEventID {
        headers["Last-Event-ID"] = lastEventID
    }
    return HTTPRequest(method: "GET", headers: headers)
}

private func makeDELETERequest(sessionID: String) -> HTTPRequest {
    HTTPRequest(
        method: "DELETE",
        headers: ["Mcp-Session-Id": sessionID]
    )
}

private func makeStatelessPOSTRequest(body: Data) -> HTTPRequest {
    HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json",
        ],
        body: body
    )
}

private func makeStatefulTransport(
    sessionIDGenerator: any SessionIDGenerator = UUIDSessionIDGenerator()
) -> StatefulHTTPServerTransport {
    StatefulHTTPServerTransport(
        sessionIDGenerator: sessionIDGenerator,
        validationPipeline: StandardValidationPipeline(validators: [])
    )
}

private let authResourceMetadataURL =
    URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")!
private let authResourceIdentifier = URL(string: "https://mcp.example.com/mcp")!

private func makeAuthenticatedStatefulTransport(
    challengeScopes: Set<String>? = nil,
    tokenValidator: @escaping BearerTokenValidator.TokenValidator
) -> StatefulHTTPServerTransport {
    let validator = BearerTokenValidator(
        resourceMetadataURL: authResourceMetadataURL,
        resourceIdentifier: authResourceIdentifier,
        tokenValidator: tokenValidator,
        challengeScopeProvider: { _, _ in challengeScopes }
    )
    return StatefulHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [
            validator,
            SessionValidator(),
        ])
    )
}

private func makeStatelessTransport() -> StatelessHTTPServerTransport {
    StatelessHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [])
    )
}

/// Drains an SSE stream, collecting raw SSE chunks.
private actor ChunkCollector {
    var chunks: [Data] = []
    func append(_ data: Data) { chunks.append(data) }
    func getChunks() -> [Data] { chunks }
}

private func drainSSEStream(
    _ response: HTTPResponse,
    maxChunks: Int = 10,
    timeout: Duration = .seconds(2)
) async -> [Data] {
    guard case .stream(let stream, _) = response else { return [] }
    let collector = ChunkCollector()
    let task = Task {
        for try await chunk in stream {
            await collector.append(chunk)
            if await collector.getChunks().count >= maxChunks { break }
        }
    }
    // Wait for stream to finish or timeout
    try? await Task.sleep(for: timeout)
    task.cancel()
    return await collector.getChunks()
}

/// Initializes a stateful transport session and returns the session ID.
/// Spawns a background task to consume the receive stream and send the init response.
private func initializeSession(
    transport: StatefulHTTPServerTransport,
    sessionID: String? = nil
) async throws -> String {
    try await transport.connect()

    let initBody = makeInitializeBody()

    // Background task: read the init request from receive() and send back a response
    let respondTask = Task {
        let stream = await transport.receive()
        for try await data in stream {
            // Check if this is the initialize request
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let method = json["method"] as? String, method == "initialize",
                let id = json["id"]
            {
                let idString: String
                if let s = id as? String { idString = s }
                else if let n = id as? Int { idString = String(n) }
                else { continue }

                let responseJSON: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": idString,
                    "result": [
                        "protocolVersion": "2025-11-25",
                        "serverInfo": ["name": "test", "version": "1.0"],
                        "capabilities": [:] as [String: Any],
                    ] as [String: Any],
                ]
                let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
                try await transport.send(responseData)
                return
            }
        }
    }

    let response = await transport.handleRequest(
        makeStatefulPOSTRequest(body: initBody)
    )

    // Extract session ID
    guard let sid = response.headers[HTTPHeaderName.sessionID] else {
        throw MCPError.internalError("No session ID in init response")
    }

    // Drain the SSE stream so the response task can complete
    if case .stream(let stream, _) = response {
        Task { for try await _ in stream {} }
    }

    // Wait for the respond task
    try? await respondTask.value

    return sid
}

// MARK: - StatefulHTTPServerTransport Tests

@Suite("StatefulHTTPServerTransport Tests")
struct StatefulHTTPServerTransportTests {

    // MARK: - Lifecycle

    @Test("Connect succeeds")
    func testConnectSucceeds() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        await transport.disconnect()
    }

    @Test("Double connect throws")
    func testDoubleConnectThrows() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        do {
            try await transport.connect()
            Issue.record("Expected error on double connect")
        } catch {
            // Expected
        }
        await transport.disconnect()
    }

    @Test("Send after disconnect throws connectionClosed")
    func testSendAfterDisconnectThrows() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        await transport.disconnect()
        do {
            try await transport.send(Data("test".utf8))
            Issue.record("Expected connectionClosed error")
        } catch let error as MCPError {
            #expect(error == .connectionClosed)
        }
    }

    // MARK: - POST Initialize

    @Test("Initialize creates session and returns SSE stream")
    func testInitializeCreatesSession() async throws {
        let transport = makeStatefulTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: "test-session-42")
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeInitializeBody())
        )

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeaderName.sessionID] == "test-session-42")

        if case .stream = response {
            // Expected
        } else {
            Issue.record("Expected .stream response, got \(response)")
        }

        // Drain stream
        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    @Test("Initialize with invalid session ID returns 500")
    func testInitializeWithInvalidSessionIDReturns500() async throws {
        // Control character \t is 0x09, outside valid range 0x21-0x7E
        let transport = makeStatefulTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: "bad\tsession")
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeInitializeBody())
        )

        #expect(response.statusCode == 500)
    }

    @Test("Custom SessionIDGenerator is used")
    func testCustomSessionIDGenerator() async throws {
        let transport = makeStatefulTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: "custom-id-abc")
        )
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeInitializeBody())
        )

        #expect(response.headers[HTTPHeaderName.sessionID] == "custom-id-abc")

        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    @Test("Default UUIDSessionIDGenerator produces valid session ID")
    func testDefaultGeneratorProducesUUID() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeInitializeBody())
        )

        let sessionID = response.headers[HTTPHeaderName.sessionID]
        #expect(sessionID != nil)
        // UUID format: 8-4-4-4-12 hex chars
        if let sid = sessionID {
            #expect(sid.count == 36)
            #expect(sid.contains("-"))
        }

        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    // MARK: - POST Notification

    @Test("Notification returns 202 Accepted")
    func testNotificationReturns202() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeNotificationBody(),
                sessionID: sessionID
            )
        )

        #expect(response.statusCode == 202)
        await transport.disconnect()
    }

    @Test("Notification yields to receive stream")
    func testNotificationYieldsToReceive() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let notificationBody = makeNotificationBody(method: "notifications/test")

        // Start receiving
        let receiveTask = Task<Data?, any Error> {
            let stream = await transport.receive()
            for try await data in stream {
                // Skip init request if still in stream
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let method = json["method"] as? String, method == "notifications/test"
                {
                    return data
                }
            }
            return nil
        }

        // Small delay to let receive() start
        try await Task.sleep(for: .milliseconds(50))

        _ = await transport.handleRequest(
            makeStatefulPOSTRequest(body: notificationBody, sessionID: sessionID)
        )

        let received = try await receiveTask.value
        #expect(received != nil)

        await transport.disconnect()
    }

    // MARK: - POST Request/Response

    @Test("POST request returns SSE stream")
    func testRequestReturnsSSEStream() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeRequestBody(id: "req-1"),
                sessionID: sessionID
            )
        )

        #expect(response.statusCode == 200)
        if case .stream = response {
            // Expected
        } else {
            Issue.record("Expected .stream response")
        }

        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    @Test("Response is routed to matching request SSE stream")
    func testResponseRoutedToRequestStream() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let requestID = "route-test-1"

        // POST a request
        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeRequestBody(id: requestID, method: "tools/list"),
                sessionID: sessionID
            )
        )

        guard case .stream(let stream, _) = response else {
            Issue.record("Expected .stream response")
            return
        }

        // Collect SSE chunks in background
        let collectTask = Task {
            var chunks: [Data] = []
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return chunks
        }

        // Give stream time to start
        try await Task.sleep(for: .milliseconds(50))

        // Consume the request from receive and send the response
        let responseBody = makeResponseBody(id: requestID)
        try await transport.send(responseBody)

        // Collect all SSE chunks
        let chunks = try await collectTask.value

        // Should have at least one chunk containing the response data
        let allText = chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(allText.contains("data:"))
        #expect(allText.contains(requestID))

        await transport.disconnect()
    }

    // MARK: - GET Stream

    @Test("GET returns standalone SSE stream")
    func testGetReturnsSSEStream() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeGETRequest(sessionID: sessionID)
        )

        #expect(response.statusCode == 200)
        if case .stream = response {
            // Expected
        } else {
            Issue.record("Expected .stream response for GET")
        }

        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    @Test("Server-initiated message routed to GET stream")
    func testServerMessageRoutedToGetStream() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        // Open GET stream
        let getResponse = await transport.handleRequest(
            makeGETRequest(sessionID: sessionID)
        )

        guard case .stream(let stream, _) = getResponse else {
            Issue.record("Expected .stream response for GET")
            return
        }

        // Collect chunks
        let collectTask = Task {
            var chunks: [Data] = []
            for try await chunk in stream {
                chunks.append(chunk)
                // priming + message
                if chunks.count >= 2 { break }
            }
            return chunks
        }

        try await Task.sleep(for: .milliseconds(50))

        // Send a notification (server-initiated)
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/test",
            "params": [:] as [String: Any],
        ]
        let notifData = try JSONSerialization.data(withJSONObject: notification)
        try await transport.send(notifData)

        let chunks = try await collectTask.value
        let allText = chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(allText.contains("data:"))
        // JSONSerialization may escape "/" as "\/" in some configurations
        #expect(allText.contains("notifications/test") || allText.contains("notifications\\/test"))

        await transport.disconnect()
    }

    @Test("Second GET returns 409 Conflict")
    func testSecondGetReturns409() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        // First GET
        let first = await transport.handleRequest(makeGETRequest(sessionID: sessionID))
        #expect(first.statusCode == 200)

        // Second GET
        let second = await transport.handleRequest(makeGETRequest(sessionID: sessionID))
        #expect(second.statusCode == 409)

        if case .stream(let stream, _) = first {
            Task { for try await _ in stream {} }
        }
        await transport.disconnect()
    }

    // MARK: - DELETE

    @Test("DELETE terminates session")
    func testDeleteTerminatesSession() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeDELETERequest(sessionID: sessionID)
        )

        #expect(response.statusCode == 200)
    }

    @Test("Requests after DELETE return 404")
    func testRequestsAfterDeleteReturn404() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        // DELETE
        _ = await transport.handleRequest(makeDELETERequest(sessionID: sessionID))

        // POST after delete
        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeRequestBody(),
                sessionID: sessionID
            )
        )

        #expect(response.statusCode == 404)
    }

    // MARK: - Terminated State

    @Test("All methods return 404 when terminated")
    func testAllMethodsReturn404WhenTerminated() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)
        await transport.disconnect()

        let post = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeRequestBody(), sessionID: sessionID)
        )
        #expect(post.statusCode == 404)

        let get = await transport.handleRequest(makeGETRequest(sessionID: sessionID))
        #expect(get.statusCode == 404)

        let delete = await transport.handleRequest(makeDELETERequest(sessionID: sessionID))
        #expect(delete.statusCode == 404)
    }

    // MARK: - Error Cases

    @Test("Unsupported method returns 405")
    func testUnsupportedMethodReturns405() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            HTTPRequest(
                method: "PUT",
                headers: ["Mcp-Session-Id": sessionID],
                body: Data("test".utf8)
            )
        )

        #expect(response.statusCode == 405)
        await transport.disconnect()
    }

    @Test("Empty body returns 400")
    func testEmptyBodyReturns400() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: Data(), sessionID: sessionID)
        )

        #expect(response.statusCode == 400)
        await transport.disconnect()
    }

    @Test("Invalid JSON body returns 400")
    func testInvalidJSONReturns400() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: Data("not json".utf8), sessionID: sessionID)
        )

        #expect(response.statusCode == 400)
        await transport.disconnect()
    }

    // MARK: - OAuth Bearer Validation

    @Test("Bearer auth validator returns 401 with challenge when authorization is missing")
    func testBearerAuthValidatorMissingAuthorizationReturns401() async throws {
        let transport = makeAuthenticatedStatefulTransport(
            challengeScopes: ["files:read"]
        ) { _, _, _ in
            .valid(BearerTokenInfo())
        }
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(body: makeInitializeBody())
        )

        #expect(response.statusCode == 401)
        let challenge = response.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("Bearer ") == true)
        #expect(
            challenge?.contains("resource_metadata=\"\(authResourceMetadataURL.absoluteString)\"")
                == true
        )
        #expect(challenge?.contains("scope=\"files:read\"") == true)

        await transport.disconnect()
    }

    @Test("Bearer auth validator returns 400 when authorization header is malformed")
    func testBearerAuthValidatorMalformedAuthorizationReturns400() async throws {
        let transport = makeAuthenticatedStatefulTransport { _, _, _ in .valid(BearerTokenInfo()) }
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeInitializeBody(),
                authorization: "Basic dGVzdA=="
            )
        )

        #expect(response.statusCode == 400)
        #expect(response.headers[HTTPHeaderName.wwwAuthenticate] == nil)

        await transport.disconnect()
    }

    @Test("Bearer auth validator returns 401 invalid_token for rejected token")
    func testBearerAuthValidatorInvalidTokenReturns401() async throws {
        let transport = makeAuthenticatedStatefulTransport { _, _, _ in
            .invalidToken(errorDescription: "Token expired")
        }
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeInitializeBody(),
                authorization: "Bearer expired-token"
            )
        )

        #expect(response.statusCode == 401)
        let challenge = response.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("error=\"invalid_token\"") == true)
        #expect(challenge?.contains("error_description=\"Token expired\"") == true)
        #expect(
            challenge?.contains("resource_metadata=\"\(authResourceMetadataURL.absoluteString)\"")
                == true
        )

        await transport.disconnect()
    }

    @Test("Bearer auth validator returns 403 insufficient_scope with scope challenge")
    func testBearerAuthValidatorInsufficientScopeReturns403() async throws {
        let transport = makeAuthenticatedStatefulTransport { token, _, context in
            if context.isInitializationRequest, token == "init-token" {
                return .valid(BearerTokenInfo())
            }
            if token == "read-only-token" {
                return .insufficientScope(
                    requiredScopes: ["files:read", "files:write"],
                    errorDescription: "Additional file write permission required"
                )
            }
            return .invalidToken(errorDescription: "Unknown token")
        }
        try await transport.connect()

        let initResponse = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeInitializeBody(),
                authorization: "Bearer init-token"
            )
        )
        let sessionID = initResponse.headers[HTTPHeaderName.sessionID]
        #expect(sessionID != nil)

        guard let sessionID else {
            await transport.disconnect()
            return
        }

        let response = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeNotificationBody(),
                sessionID: sessionID,
                authorization: "Bearer read-only-token"
            )
        )

        #expect(response.statusCode == 403)
        let challenge = response.headers[HTTPHeaderName.wwwAuthenticate]
        #expect(challenge?.contains("error=\"insufficient_scope\"") == true)
        #expect(challenge?.contains("scope=\"files:read files:write\"") == true)
        #expect(
            challenge?.contains("resource_metadata=\"\(authResourceMetadataURL.absoluteString)\"")
                == true
        )
        #expect(
            challenge?.contains(
                "error_description=\"Additional file write permission required\""
            ) == true
        )

        await transport.disconnect()
    }

    // MARK: - Resumability

    @Test("GET with Last-Event-ID replays stored events")
    func testGetWithLastEventIDReplaysEvents() async throws {
        let transport = makeStatefulTransport()
        let sessionID = try await initializeSession(transport: transport)

        // POST a request to create events in the store
        let requestID = "resume-test"
        let postResponse = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: makeRequestBody(id: requestID),
                sessionID: sessionID
            )
        )

        guard case .stream(let postStream, _) = postResponse else {
            Issue.record("Expected .stream")
            return
        }

        // Collect the priming event to get its ID
        let eventIDHolder = ChunkCollector()
        let collectTask = Task {
            for try await chunk in postStream {
                await eventIDHolder.append(chunk)
                break  // Just get the first chunk (priming)
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Send the response to create a stored event
        try await transport.send(makeResponseBody(id: requestID))

        try? await collectTask.value

        // Parse event ID from the collected priming event
        let collectedChunks = await eventIDHolder.getChunks()
        let primingEventID: String? = collectedChunks.first.flatMap { chunk in
            let text = String(decoding: chunk, as: UTF8.self)
            guard let range = text.range(of: "id: ") else { return nil }
            let afterID = text[range.upperBound...]
            guard let newline = afterID.firstIndex(of: "\n") else { return nil }
            return String(afterID[..<newline])
        }

        // Now try to resume with GET + Last-Event-ID
        if let eventID = primingEventID {
            let getResponse = await transport.handleRequest(
                makeGETRequest(sessionID: sessionID, lastEventID: eventID)
            )
            // Should succeed (200) and replay events
            #expect(getResponse.statusCode == 200)

            if case .stream(let stream, _) = getResponse {
                Task { for try await _ in stream {} }
            }
        }

        await transport.disconnect()
    }
}

// MARK: - StatelessHTTPServerTransport Tests

@Suite("StatelessHTTPServerTransport Tests")
struct StatelessHTTPServerTransportTests {

    // MARK: - Lifecycle

    @Test("Connect succeeds")
    func testConnectSucceeds() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        await transport.disconnect()
    }

    @Test("Double connect throws")
    func testDoubleConnectThrows() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        do {
            try await transport.connect()
            Issue.record("Expected error on double connect")
        } catch {
            // Expected
        }
        await transport.disconnect()
    }

    @Test("Send after disconnect throws connectionClosed")
    func testSendAfterDisconnectThrows() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        await transport.disconnect()
        do {
            try await transport.send(Data("test".utf8))
            Issue.record("Expected connectionClosed error")
        } catch let error as MCPError {
            #expect(error == .connectionClosed)
        }
    }

    // MARK: - POST Request/Response

    @Test("Request waits for response then returns JSON")
    func testRequestWaitsForResponse() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let requestBody = makeRequestBody(id: "42", method: "tools/list")
        let responseBody = makeResponseBody(id: "42")

        // handleRequest blocks waiting for response
        let handleTask = Task {
            await transport.handleRequest(
                makeStatelessPOSTRequest(body: requestBody)
            )
        }

        // Give handleRequest time to register the waiter
        try await Task.sleep(for: .milliseconds(50))

        // Consume the request from receive and send the response
        try await transport.send(responseBody)

        let httpResponse = await handleTask.value
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.bodyData == responseBody)
        #expect(httpResponse.headers[HTTPHeaderName.contentType] == ContentType.json)

        await transport.disconnect()
    }

    @Test("Notification returns 202 Accepted")
    func testNotificationReturns202() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatelessPOSTRequest(body: makeNotificationBody())
        )

        #expect(response.statusCode == 202)
        await transport.disconnect()
    }

    @Test("Notification yields to receive stream")
    func testNotificationYieldsToReceive() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let notificationBody = makeNotificationBody(method: "notifications/test")

        // Start receiving
        let receiveTask = Task {
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await Task.sleep(for: .milliseconds(50))

        _ = await transport.handleRequest(
            makeStatelessPOSTRequest(body: notificationBody)
        )

        let received = try await receiveTask.value
        #expect(received == notificationBody)

        await transport.disconnect()
    }

    // MARK: - Unsupported Methods

    @Test("GET returns 405 Method Not Allowed")
    func testGetReturns405() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            HTTPRequest(method: "GET", headers: ["Accept": "text/event-stream"])
        )

        #expect(response.statusCode == 405)
        await transport.disconnect()
    }

    @Test("DELETE returns 405 Method Not Allowed")
    func testDeleteReturns405() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            HTTPRequest(method: "DELETE")
        )

        #expect(response.statusCode == 405)
        await transport.disconnect()
    }

    // MARK: - Error Cases

    @Test("Empty body returns 400")
    func testEmptyBodyReturns400() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatelessPOSTRequest(body: Data())
        )

        #expect(response.statusCode == 400)
        await transport.disconnect()
    }

    @Test("Invalid JSON body returns 400")
    func testInvalidJSONReturns400() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let response = await transport.handleRequest(
            makeStatelessPOSTRequest(body: Data("not json".utf8))
        )

        #expect(response.statusCode == 400)
        await transport.disconnect()
    }

    // MARK: - Terminated State

    @Test("After disconnect returns 404")
    func testAfterDisconnectReturns404() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        await transport.disconnect()

        let response = await transport.handleRequest(
            makeStatelessPOSTRequest(body: makeRequestBody())
        )

        #expect(response.statusCode == 404)
    }

    @Test("Disconnect cancels waiting requests")
    func testDisconnectCancelsWaitingRequests() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let requestBody = makeRequestBody(id: "cancel-test")

        // Start a request that will block
        let handleTask = Task {
            await transport.handleRequest(
                makeStatelessPOSTRequest(body: requestBody)
            )
        }

        try await Task.sleep(for: .milliseconds(50))

        // Disconnect while request is pending
        await transport.disconnect()

        let response = await handleTask.value
        // Should return error (500 or similar) since waiter was cancelled
        #expect(response.statusCode == 500)
    }
}

// MARK: - HTTPContextProviding / Server.currentHandlerContext

@Suite("Server.currentHandlerContext Tests")
struct ServerHandlerContextTests {

    // MARK: Stateful transport — HTTPContextProviding

    @Test("Stateful: httpRequestContext returns in-flight request, cleared after response")
    func testStatefulContextLifecycle() async throws {
        let sessionID = "test-session"
        let transport = makeStatefulTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID)
        )
        _ = try await initializeSession(transport: transport, sessionID: sessionID)

        // POST a tools/list request with a distinctive Authorization header and path.
        let body = makeRequestBody(id: "42", method: "tools/list")
        let httpRequest = HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Mcp-Session-Id": sessionID,
                "Authorization": "Bearer token-xyz",
            ],
            body: body,
            path: "/mcp"
        )
        let response = await transport.handleRequest(httpRequest)
        #expect(response.statusCode == 200)

        // In-flight: context surfaces through the protocol lookup.
        let inFlight = await transport.httpRequestContext(for: .string("42"))
        #expect(inFlight != nil)
        #expect(inFlight?.header("Authorization") == "Bearer token-xyz")
        #expect(inFlight?.path == "/mcp")

        // Drain the SSE stream in the background so the response routes cleanly.
        if case .stream(let stream, _) = response {
            Task { for try await _ in stream {} }
        }

        // Send the response — transport clears the context alongside the SSE map.
        try await transport.send(makeResponseBody(id: "42"))
        try await Task.sleep(for: .milliseconds(50))

        let afterResponse = await transport.httpRequestContext(for: .string("42"))
        #expect(afterResponse == nil)
    }

    @Test("Stateful: context cleared on session termination")
    func testStatefulContextClearedOnTerminate() async throws {
        let sessionID = "term-session"
        let transport = makeStatefulTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID)
        )
        _ = try await initializeSession(transport: transport, sessionID: sessionID)

        // Register an in-flight request to populate the context map.
        let body = makeRequestBody(id: "7", method: "tools/list")
        _ = await transport.handleRequest(
            makeStatefulPOSTRequest(
                body: body,
                sessionID: sessionID,
                authorization: "Bearer keep"
            )
        )
        #expect(await transport.httpRequestContext(for: .string("7")) != nil)

        // DELETE terminates the session.
        _ = await transport.handleRequest(makeDELETERequest(sessionID: sessionID))

        #expect(await transport.httpRequestContext(for: .string("7")) == nil)
    }

    // MARK: Stateless transport — HTTPContextProviding

    @Test("Stateless: context available during handling, cleared after response")
    func testStatelessContextLifecycle() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let httpRequest = HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": "Bearer stateless-token",
            ],
            body: makeRequestBody(id: "99", method: "tools/list"),
            path: "/mcp"
        )

        // handleRequest blocks until a response is sent — run it concurrently.
        let handleTask = Task { await transport.handleRequest(httpRequest) }

        // Give the handler time to register its waiter (and store the context).
        try await Task.sleep(for: .milliseconds(50))

        let inFlight = await transport.httpRequestContext(for: .string("99"))
        #expect(inFlight != nil)
        #expect(inFlight?.header("Authorization") == "Bearer stateless-token")
        #expect(inFlight?.path == "/mcp")

        // Send the response to unblock the waiter.
        try await transport.send(makeResponseBody(id: "99"))
        _ = await handleTask.value

        let afterResponse = await transport.httpRequestContext(for: .string("99"))
        #expect(afterResponse == nil)

        await transport.disconnect()
    }

    @Test("Stateless: unknown request id returns nil")
    func testStatelessContextUnknownID() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let none = await transport.httpRequestContext(for: .string("does-not-exist"))
        #expect(none == nil)
        await transport.disconnect()
    }

    // MARK: Server integration — end-to-end

    @Test("Server handler reads HTTP context via Server.currentHandlerContext")
    func testServerHandlerReadsHTTPContext() async throws {
        actor Captured {
            var auth: String?
            var path: String?
            var id: ID?
            func record(auth: String?, path: String?, id: ID?) {
                self.auth = auth
                self.path = path
                self.id = id
            }
        }
        let captured = Captured()

        let transport = makeStatelessTransport()
        let server = Server(name: "TestServer", version: "1.0")

        await server.withMethodHandler(CallTool.self) { _ in
            let ctx = Server.currentHandlerContext
            await captured.record(
                auth: ctx?.httpContext?.header("Authorization"),
                path: ctx?.httpContext?.path,
                id: ctx?.id
            )
            return CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)])
        }

        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "call-1",
            "method": "tools/call",
            "params": ["name": "whoami"] as [String: Any],
        ])
        let httpRequest = HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": "Bearer server-integration-token",
            ],
            body: body,
            path: "/mcp"
        )

        let httpResponse = await transport.handleRequest(httpRequest)
        #expect(httpResponse.statusCode == 200)

        #expect(await captured.auth == "Bearer server-integration-token")
        #expect(await captured.path == "/mcp")
        #expect(await captured.id == .string("call-1"))
    }

    @Test("Non-HTTP transport yields nil httpContext")
    func testNonHTTPTransportNilContext() async throws {
        actor Captured {
            var httpContext: HTTPRequest?
            var sawDispatch = false
            func set(_ v: HTTPRequest?) { httpContext = v; sawDispatch = true }
        }
        let captured = Captured()

        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        // Start first — `start` calls registerDefaultHandlers which would otherwise
        // clobber our override.
        try await server.start(transport: transport)

        // Override the Ping handler so we can observe the task-local during dispatch.
        await server.withMethodHandler(Ping.self) { _ in
            await captured.set(Server.currentHandlerContext?.httpContext)
            return Empty()
        }

        try await transport.queue(request: Ping.request(.init()))

        // Wait for dispatch.
        try await Task.sleep(for: .milliseconds(100))

        #expect(await captured.sawDispatch == true)
        #expect(await captured.httpContext == nil)

        await server.stop()
        await transport.disconnect()
    }
}
