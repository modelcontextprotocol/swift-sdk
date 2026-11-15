import Foundation
import Testing

@testable import MCP

// MARK: - Test Helpers

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

private actor InitializationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
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

private func makeCancellationBody(id: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "method": CancelledNotification.name,
        "params": ["requestId": id],
    ] as [String: Any])
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

private struct LegacyHTTPContextProvider: HTTPContextProviding {
    func httpRequestContext(for id: ID) async -> HTTPRequest? { nil }
}

// MARK: - StatefulHTTPServerTransport Tests

@Suite("StatefulHTTPServerTransport Tests")
struct StatefulHTTPServerTransportTests {

    @Test("Concurrent initialization callers share one successful startup")
    func concurrentInitializationRunsOnce() async throws {
        let initialization = AsyncInitialization<Int>()
        let counter = InitializationCounter()
        let results = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await initialization.value {
                        await counter.increment()
                        try? await Task.sleep(for: .milliseconds(20))
                        return 42
                    }
                }
            }
            var values: [Int] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0 == 42 })
        #expect(await counter.count == 1)
    }

    @Test("Stateless cancellation identity respects explicit identity and credentials")
    func stableClientIdentitySelection() {
        #expect(HTTPRequest.stableClientIdentity(
            headers: ["mCp-ClIeNt-IdEnTiTy": "stable-capability", "Authorization": "Bearer token"],
            connectionIdentity: "channel"
        ) == "stable-capability")
        #expect(HTTPRequest.stableClientIdentity(
            headers: ["Authorization": "Bearer token"], connectionIdentity: "channel"
        ) == nil)
        #expect(HTTPRequest.stableClientIdentity(
            headers: ["Cookie": "session=value"], connectionIdentity: "channel"
        ) == nil)
        #expect(HTTPRequest.stableClientIdentity(
            headers: [:], connectionIdentity: "channel"
        ) == "channel")
    }

    @Test("HTTP context providers can omit optional stream closing")
    func httpContextProviderStreamClosingDefaultsToNoOp() async {
        let provider = LegacyHTTPContextProvider()
        await provider.closeRequestStream(for: .string("request"))
    }

    @Test("Numeric and string JSON-RPC IDs keep separate HTTP request contexts")
    func numericAndStringRequestIDsHaveSeparateContexts() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        let stringBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "1", "method": "ping", "params": [:] as [String: Any],
        ] as [String: Any])
        let numberBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:] as [String: Any],
        ] as [String: Any])
        let stringResponse = await transport.handleRequest(makeStatefulPOSTRequest(body: stringBody))
        let numberResponse = await transport.handleRequest(makeStatefulPOSTRequest(body: numberBody))
        guard case .stream = stringResponse, case .stream = numberResponse else {
            Issue.record("Expected both requests to have separate response streams")
            await transport.disconnect()
            return
        }

        let stringContext = try #require(await transport.httpRequestContext(for: .string("1")))
        let numberContext = try #require(await transport.httpRequestContext(for: .number(1)))
        #expect(JSONRPCMessageKind.jsonRPCID(inBody: try #require(stringContext.body)) == .string("1"))
        #expect(JSONRPCMessageKind.jsonRPCID(inBody: try #require(numberContext.body)) == .number(1))
        await transport.disconnect()
    }

    @Test("Stateful transport rejects duplicate active JSON-RPC IDs without replacing the stream")
    func duplicateActiveStatefulRequestIDIsRejected() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "duplicate", "method": "tools/list", "params": [:] as [String: Any],
        ] as [String: Any])
        let first = await transport.handleRequest(makeStatefulPOSTRequest(body: body))
        guard case .stream(let firstStream, _) = first else {
            Issue.record("Expected first request to retain an SSE response stream")
            await transport.disconnect()
            return
        }

        let duplicate = await transport.handleRequest(makeStatefulPOSTRequest(body: body))
        #expect(duplicate.statusCode == 409)
        let duplicateJSON = try #require(duplicate.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(duplicateJSON["id"] as? String == "duplicate")

        try await transport.send(try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "duplicate", "result": ["tools": []],
        ] as [String: Any]))
        let chunks = await drainSSEStream(.stream(firstStream, headers: [:]), maxChunks: 3, timeout: .milliseconds(100))
        #expect(chunks.contains { String(decoding: $0, as: UTF8.self).contains("\"id\":\"duplicate\"") })
        await transport.disconnect()
    }

    @Test("Modern subscriptions/listen receives an acknowledgement and tagged notifications")
    func modernSubscriptionsListenReceivesAcknowledgementAndTaggedNotifications() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        let listenID = "stateful-listen-1"
        let listenBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": listenID,
            "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(makeStatefulPOSTRequest(body: listenBody))
        guard case .stream(let stream, let headers) = response else {
            Issue.record("Expected subscriptions/listen to return an SSE stream")
            await transport.disconnect()
            return
        }
        #expect(headers[HTTPHeaderName.sessionID] == nil)

        let acknowledgment = Data("""
            {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"\(ProtocolMetaKey.subscriptionId)":"\(listenID)"}}}
            """.utf8)
        let notification = Data("""
            {"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
            """.utf8)
        try await transport.send(notification)
        try await transport.send(acknowledgment)
        try await transport.send(notification)

        var iterator = stream.makeAsyncIterator()
        var firstMessage: [String: Any]?
        for _ in 0..<4 {
            guard let frame = try await iterator.next() else { break }
            if let message = Self.jsonFromSSE(frame) {
                firstMessage = message
                break
            }
        }
        let acknowledgmentJSON = try #require(firstMessage)
        if acknowledgmentJSON["method"] as? String == "notifications/subscriptions/acknowledged" {
            let acknowledgmentParams = try #require(acknowledgmentJSON["params"] as? [String: Any])
            #expect(acknowledgmentParams["notifications"] as? [String: Any] != nil)

            let notificationFrame = try await iterator.next()
            let notificationJSON = try #require(notificationFrame.flatMap(Self.jsonFromSSE))
            let params = try #require(notificationJSON["params"] as? [String: Any])
            let meta = try #require(params["_meta"] as? [String: Any])
            #expect(notificationJSON["method"] as? String == "notifications/tools/list_changed")
            #expect(meta[ProtocolMetaKey.subscriptionId] as? String == listenID)
        } else {
            Issue.record("Expected the subscription acknowledgment before change notifications")
            let notificationParams = try #require(acknowledgmentJSON["params"] as? [String: Any])
            let notificationMeta = notificationParams["_meta"] as? [String: Any]
            #expect(notificationMeta?[ProtocolMetaKey.subscriptionId] as? String == listenID)
        }

        await transport.closeRequestStream(for: .string(listenID))
        await transport.disconnect()
    }

    @Test("Modern stateful request receives progress notification for its token")
    func modernRequestReceivesMatchingProgressNotification() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "progress-request", "method": "tools/call",
            "params": ["_meta": [
                "progressToken": "progress-token",
                ProtocolMetaKey.protocolVersion: "2026-07-28",
            ]],
        ] as [String: Any])
        let response = await transport.handleRequest(makeStatefulPOSTRequest(body: requestBody))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected request SSE stream")
            await transport.disconnect()
            return
        }
        let progress = Data("""
            {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"progress-token","progress":0.5}}
            """.utf8)
        try await transport.send(progress)
        var iterator = stream.makeAsyncIterator()
        var delivered: [String: Any]?
        for _ in 0..<2 {
            guard let frame = try await iterator.next() else { break }
            if Self.jsonFromSSE(frame)?["method"] as? String == "notifications/progress" {
                delivered = Self.jsonFromSSE(frame)
                break
            }
        }
        #expect(delivered?["method"] as? String == "notifications/progress")
        await transport.closeRequestStream(for: .string("progress-request"))
        await transport.disconnect()
    }

    @Test("Modern stateful progress routing preserves integer and string token types")
    func modernProgressTokensKeepJSONValueType() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()

        func request(id: String, token: Any) async throws -> HTTPResponse {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["_meta": [
                    "progressToken": token,
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                ]],
            ] as [String: Any])
            return await transport.handleRequest(makeStatefulPOSTRequest(body: body))
        }
        let integerResponse = try await request(id: "integer-token", token: 1)
        let stringResponse = try await request(id: "string-token", token: "1")
        func sendProgress(_ token: Any, _ progress: Double) async throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "notifications/progress",
                "params": ["progressToken": token, "progress": progress],
            ] as [String: Any])
            try await transport.send(data)
        }
        try await sendProgress(1, 0.25)
        try await sendProgress("1", 0.75)
        let integerFrames = await drainSSEStream(integerResponse, maxChunks: 2, timeout: .milliseconds(80))
        let stringFrames = await drainSSEStream(stringResponse, maxChunks: 3, timeout: .milliseconds(80))
        let integerEvents = integerFrames.compactMap(Self.jsonFromSSE)
        let stringEvents = stringFrames.compactMap(Self.jsonFromSSE)
        #expect(integerEvents.count == 1)
        #expect((integerEvents.first?["params"] as? [String: Any])?["progressToken"] as? Int == 1)
        #expect(stringEvents.count == 1)
        #expect((stringEvents.first?["params"] as? [String: Any])?["progressToken"] as? String == "1")
        await transport.disconnect()
    }

    @Test("Modern stateful header validation rejects a mismatched method header")
    func modernStatefulHeaderMismatchIsRejected() async throws {
        let transport = StatefulHTTPServerTransport()
        try await transport.connect()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/tools/list_changed",
            "params": ["_meta": [ProtocolMetaKey.protocolVersion: "2026-07-28"]],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Host": "localhost:3000", HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json, text/event-stream",
                HTTPHeaderName.protocolVersion: "2026-07-28", "Mcp-Method": "notifications/prompts/list_changed",
            ], body: body
        ))
        #expect(response.statusCode == 400)
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32020)
        await transport.disconnect()
    }

    @Test("Malformed stateful subscriptions/listen error preserves request ID")
    func malformedStatefulListenPreservesRequestID() async throws {
        let transport = makeStatefulTransport()
        try await transport.connect()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 72, "method": "subscriptions/listen", "params": [:] as [String: Any],
        ] as [String: Any])
        let response = await transport.handleRequest(makeStatefulPOSTRequest(body: body))
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["id"] as? Int == 72)
        await transport.disconnect()
    }

    fileprivate static func jsonFromSSE(_ frame: Data) -> [String: Any]? {
        let text = String(decoding: frame, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
    }

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

    @Test("Schema provider rejects direct annotated calls before tools/list")
    func directAnnotatedCallUsesSchemaProvider() async throws {
        let transport = makeStatelessTransport()
        let server = Server(name: "schema-provider-test", version: "1.0")
        let callCounter = InitializationCounter()
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Tool(
                name: "lookup", description: nil,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["tenant": .object([
                        "type": .string("string"), "x-mcp-header": .string("Tenant"),
                    ])]),
                    "required": .array([.string("tenant")]),
                ])
            )])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            await callCounter.increment()
            return .init(content: [.text(text: "called", annotations: nil, _meta: nil)], isError: false)
        }
        try await server.start(transport: transport)
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 82, "method": "tools/call",
            "params": [
                "name": "lookup", "arguments": ["tenant": "acme"],
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.contentType: ContentType.json],
            body: body,
            clientIdentity: "direct-call-client"
        ))
        #expect(response.statusCode == 400)
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["id"] as? Int == 82)
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32020)
        #expect(await callCounter.count == 0)
        await server.stop()
    }

    @Test("Schema provider follows pagination for direct annotated calls")
    func directAnnotatedCallOnLaterToolPageUsesSchemaProvider() async throws {
        let transport = makeStatelessTransport()
        let server = Server(name: "schema-provider-pagination-test", version: "1.0")
        let callCounter = InitializationCounter()
        await server.withMethodHandler(ListTools.self) { params in
            if params.cursor == nil {
                return ListTools.Result(tools: [Tool(
                    name: "first-page-tool", description: nil,
                    inputSchema: .object(["type": .string("object")])
                )], nextCursor: "page-2")
            }
            return ListTools.Result(tools: [Tool(
                name: "lookup", description: nil,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["tenant": .object([
                        "type": .string("string"), "x-mcp-header": .string("Tenant"),
                    ])]),
                    "required": .array([.string("tenant")]),
                ])
            )])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            await callCounter.increment()
            return .init(content: [.text(text: "called", annotations: nil, _meta: nil)], isError: false)
        }
        try await server.start(transport: transport)
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 83, "method": "tools/call",
            "params": [
                "name": "lookup", "arguments": ["tenant": "acme"],
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                "Mcp-Param-Tenant": "acme",
            ],
            body: body,
            clientIdentity: "later-page-client"
        ))
        #expect(response.statusCode == 200)
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["id"] as? Int == 83)
        #expect(await callCounter.count == 1)
        await server.stop()
    }

    @Test("Calls to tools absent from tools/list reach the registered handler")
    func directUnlistedToolCallReachesHandler() async throws {
        let transport = makeStatelessTransport()
        let server = Server(name: "unlisted-tool-test", version: "1.0")
        let listCounter = InitializationCounter()
        let callCounter = InitializationCounter()
        await server.withMethodHandler(ListTools.self) { _ in
            await listCounter.increment()
            return ListTools.Result(tools: [])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            await callCounter.increment()
            return .init(content: [.text(text: "called", annotations: nil, _meta: nil)], isError: false)
        }
        try await server.start(transport: transport)
        for id in [84, 87] {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": [
                    "name": "diagnostic-tool", "arguments": [:] as [String: String],
                    "_meta": [
                        ProtocolMetaKey.protocolVersion: "2026-07-28",
                        ProtocolMetaKey.clientCapabilities: [String: Any](),
                    ],
                ],
            ] as [String: Any])
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST",
                headers: [HTTPHeaderName.contentType: ContentType.json],
                body: body,
                clientIdentity: "unlisted-tool-client"
            ))
            #expect(response.statusCode == 200)
        }
        #expect(await listCounter.count == 1)
        #expect(await callCounter.count == 2)
        await server.stop()
    }

    @Test("Tool-list notifications invalidate cached HTTP schemas")
    func toolsListChangedInvalidatesCachedSchemas() async throws {
        let transport = makeStatelessTransport()
        let server = Server(name: "schema-invalidation-test", version: "1.0")
        let listCounter = InitializationCounter()
        let callCounter = InitializationCounter()
        await server.withMethodHandler(ListTools.self) { _ in
            await listCounter.increment()
            if await listCounter.count == 1 {
                return ListTools.Result(tools: [Tool(
                    name: "lookup", description: nil,
                    inputSchema: .object(["type": .string("object")])
                )])
            }
            return ListTools.Result(tools: [Tool(
                name: "lookup", description: nil,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["tenant": .object([
                        "type": .string("string"), "x-mcp-header": .string("Tenant"),
                    ])]),
                    "required": .array([.string("tenant")]),
                ])
            )])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            await callCounter.increment()
            return .init(content: [.text(text: "called", annotations: nil, _meta: nil)], isError: false)
        }
        try await server.start(transport: transport)

        let metadata: [String: Any] = [
            ProtocolMetaKey.protocolVersion: "2026-07-28",
            ProtocolMetaKey.clientCapabilities: [String: Any](),
        ]
        let listBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 85, "method": "tools/list",
            "params": ["_meta": metadata],
        ] as [String: Any])
        let listResponse = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.contentType: ContentType.json],
            body: listBody,
            clientIdentity: "schema-change-client"
        ))
        #expect(listResponse.statusCode == 200)

        try await server.notify(ToolListChangedNotification.message())

        let callBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 86, "method": "tools/call",
            "params": ["name": "lookup", "arguments": ["tenant": "acme"], "_meta": metadata],
        ] as [String: Any])
        let callResponse = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.contentType: ContentType.json],
            body: callBody,
            clientIdentity: "schema-change-client"
        ))
        #expect(callResponse.statusCode == 400)
        let json = try #require(callResponse.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32020)
        #expect(await listCounter.count == 2)
        #expect(await callCounter.count == 0)
        await server.stop()
    }

    @Test("Modern stateless header validation rejects missing method header and preserves request ID")
    func modernStatelessMissingMethodHeaderIsRejected() async throws {
        let transport = StatelessHTTPServerTransport()
        try await transport.connect()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 81, "method": "subscriptions/listen",
            "params": [
                "_meta": [ProtocolMetaKey.protocolVersion: "2026-07-28"],
                "notifications": ["toolsListChanged": true],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Host": "localhost:3000", HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json, text/event-stream",
                HTTPHeaderName.protocolVersion: "2026-07-28",
            ], body: body
        ))
        #expect(response.statusCode == 400)
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["id"] as? Int == 81)
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32020)
        await transport.disconnect()
    }

    @Test("Modern stateless progress routing preserves integer and string token types")
    func statelessProgressTokensKeepJSONValueType() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        func makeRequest(id: String, token: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["_meta": [
                    "progressToken": token,
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                ]],
            ] as [String: Any])
        }
        let headers = [
            HTTPHeaderName.contentType: ContentType.json,
            HTTPHeaderName.accept: "application/json, text/event-stream",
        ]
        let integerResponse = await transport.handleRequest(HTTPRequest(method: "POST", headers: headers, body: try makeRequest(id: "integer", token: 1)))
        let stringResponse = await transport.handleRequest(HTTPRequest(method: "POST", headers: headers, body: try makeRequest(id: "string", token: "1")))
        let progressEvents: [(Any, Double)] = [(1, 0.25), ("1", 0.75)]
        for (token, value) in progressEvents {
            try await transport.send(JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "notifications/progress",
                "params": ["progressToken": token, "progress": value],
            ] as [String: Any]))
        }
        let integerEvents = (await drainSSEStream(integerResponse, maxChunks: 1, timeout: .milliseconds(80))).compactMap(StatefulHTTPServerTransportTests.jsonFromSSE)
        let stringEvents = (await drainSSEStream(stringResponse, maxChunks: 2, timeout: .milliseconds(80))).compactMap(StatefulHTTPServerTransportTests.jsonFromSSE)
        #expect(integerEvents.count == 1)
        #expect((integerEvents.first?["params"] as? [String: Any])?["progressToken"] as? Int == 1)
        #expect(stringEvents.count == 1)
        #expect((stringEvents.first?["params"] as? [String: Any])?["progressToken"] as? String == "1")
        await transport.disconnect()
    }

    @Test("Malformed stateless subscriptions/listen error preserves request ID")
    func malformedStatelessListenPreservesRequestID() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 82, "method": "subscriptions/listen", "params": [:] as [String: Any],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(method: "POST", headers: [:], body: body))
        let json = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["id"] as? Int == 82)
        await transport.disconnect()
    }

    @Test("Modern subscriptions/listen opens an SSE stream with an acknowledgement")
    func testModernSubscriptionsListenOpensSSEStreamWithAcknowledgement() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "listen-1",
            "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ] as [String: Any])
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json, text/event-stream",
            ],
            body: requestBody
        )

        let response = await transport.handleRequest(request)
        guard case .stream(let stream, let headers) = response else {
            Issue.record("Expected subscriptions/listen to return an SSE stream")
            await transport.disconnect()
            return
        }
        #expect(response.statusCode == 200)
        #expect(headers[HTTPHeaderName.contentType] == ContentType.sse)
        #expect(headers[HTTPHeaderName.sessionID] == nil)

        try await transport.send(try JSONEncoder().encode(
            SubscriptionsAcknowledgedNotification.message(
                .init(
                    subscriptionId: .string("listen-1"),
                    notifications: .init(toolsListChanged: true)
                )
            )
        ))

        var iterator = stream.makeAsyncIterator()
        let firstFrame = try await iterator.next()
        let frameText = firstFrame.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let jsonText = frameText
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("data: ") })
            .map { String($0.dropFirst(6)) }
        let acknowledgement = try jsonText.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? nil
        #expect(acknowledgement?["method"] as? String == "notifications/subscriptions/acknowledged")
        let params = acknowledgement?["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        #expect(meta?[ProtocolMetaKey.subscriptionId] as? String == "listen-1")

        await transport.closeRequestStream(for: .string("listen-1"))
        await transport.disconnect()
    }

    @Test("Modern listen stream delivers only opted-in notifications with subscription metadata")
    func testModernListenStreamFiltersAndTagsNotifications() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "listen-2",
            "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.contentType: ContentType.json,
                    HTTPHeaderName.accept: "application/json, text/event-stream",
                ],
                body: requestBody
            )
        )
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected subscriptions/listen to return an SSE stream")
            await transport.disconnect()
            return
        }

        let excluded = Data(#"{"jsonrpc":"2.0","method":"notifications/prompts/list_changed"}"#.utf8)
        let included = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        try await transport.send(included)
        try await transport.send(try JSONEncoder().encode(
            SubscriptionsAcknowledgedNotification.message(
                .init(
                    subscriptionId: .string("listen-2"),
                    notifications: .init(toolsListChanged: true)
                )
            )
        ))
        try await transport.send(excluded)
        try await transport.send(included)

        var iterator = stream.makeAsyncIterator()
        let acknowledgementFrame = try await iterator.next()
        let notificationFrame = try await iterator.next()
        let acknowledgementText = acknowledgementFrame.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let frameText = notificationFrame.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let jsonText = frameText
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("data: ") })
            .map { String($0.dropFirst(6)) }
        let notification = try jsonText.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? nil
        let params = notification?["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        #expect(acknowledgementText.contains("notifications\\/subscriptions\\/acknowledged"))
        #expect(notification?["method"] as? String == "notifications/tools/list_changed")
        #expect(meta?[ProtocolMetaKey.subscriptionId] as? String == "listen-2")

        await transport.closeRequestStream(for: .string("listen-2"))
        await transport.disconnect()
    }

    @Test("Duplicate active listen IDs do not replace another client's stream or context")
    func duplicateActiveListenIDIsRejectedWithoutOverwritingState() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let sharedID = "shared-listen-id"

        func request(client: String) throws -> HTTPRequest {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": sharedID,
                "method": "subscriptions/listen",
                "params": [
                    "_meta": [
                        ProtocolMetaKey.protocolVersion: "2026-07-28",
                        ProtocolMetaKey.clientCapabilities: [String: Any](),
                    ],
                    "notifications": ["toolsListChanged": true],
                ],
            ] as [String: Any])
            return HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.contentType: ContentType.json,
                    HTTPHeaderName.accept: "application/json, text/event-stream",
                    "X-Test-Client": client,
                ],
                body: body
            )
        }

        let firstResponse = await transport.handleRequest(try request(client: "first"))
        guard case .stream = firstResponse else {
            Issue.record("Expected the first listen to open an SSE stream")
            await transport.disconnect()
            return
        }
        let secondResponse = await transport.handleRequest(try request(client: "second"))
        #expect(secondResponse.statusCode == 409)

        let context = try #require(await transport.httpRequestContext(for: .string(sharedID)))
        #expect(context.header("X-Test-Client") == "first")

        await transport.disconnect()
    }

    @Test("Stateless cancellation only reaches a request with the same authorization principal")
    func statelessCancellationIsScopedToAuthorizationPrincipal() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let requestStream = await transport.receive()
        var iterator = requestStream.makeAsyncIterator()
        let requestID = "shared-request-id"

        let activeRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json",
                HTTPHeaderName.authorization: "Bearer first-client",
            ],
            body: makeRequestBody(id: requestID)
        )
        let responseTask = Task { await transport.handleRequest(activeRequest) }
        _ = try #require(await iterator.next())

        let otherClientCancellation = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.authorization: "Bearer other-client",
            ],
            body: try makeCancellationBody(id: requestID)
        )
        _ = await transport.handleRequest(otherClientCancellation)

        let sentinelNotification = makeNotificationBody(method: "notifications/initialized")
        _ = await transport.handleRequest(makeStatelessPOSTRequest(body: sentinelNotification))
        let forwarded = try #require(await iterator.next())
        let forwardedJSON = try #require(
            JSONSerialization.jsonObject(with: forwarded) as? [String: Any]
        )
        #expect(forwardedJSON["method"] as? String == "notifications/initialized")

        let ownerCancellation = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.authorization: "Bearer first-client",
            ],
            body: try makeCancellationBody(id: requestID)
        )
        _ = await transport.handleRequest(ownerCancellation)
        let forwardedCancellation = try #require(await iterator.next())
        let cancellationJSON = try #require(
            JSONSerialization.jsonObject(with: forwardedCancellation) as? [String: Any]
        )
        #expect(cancellationJSON["method"] as? String == CancelledNotification.name)

        await transport.disconnect()
        _ = await responseTask.value
    }

    @Test("Stateless cancellation supports an adapter-supplied identity without credentials")
    func statelessCancellationSupportsAdapterIdentity() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let requestStream = await transport.receive()
        var iterator = requestStream.makeAsyncIterator()
        let requestID = "unauthenticated-request"

        let activeRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json",
            ],
            body: makeRequestBody(id: requestID),
            clientIdentity: "application-user-42"
        )
        let responseTask = Task { await transport.handleRequest(activeRequest) }
        _ = try #require(await iterator.next())

        let ownerCancellation = HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.contentType: ContentType.json],
            body: try makeCancellationBody(id: requestID),
            clientIdentity: "application-user-42"
        )
        _ = await transport.handleRequest(ownerCancellation)
        let forwardedCancellation = try #require(await iterator.next())
        let cancellationJSON = try #require(
            JSONSerialization.jsonObject(with: forwardedCancellation) as? [String: Any]
        )
        #expect(cancellationJSON["method"] as? String == CancelledNotification.name)

        await transport.disconnect()
        _ = await responseTask.value
    }

    @Test("Numeric and string listen IDs keep separate HTTP request contexts")
    func numericAndStringListenIDsHaveSeparateContexts() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        func request(_ id: Any) throws -> HTTPRequest {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "method": "subscriptions/listen",
                "params": [
                    "_meta": [
                        ProtocolMetaKey.protocolVersion: "2026-07-28",
                        ProtocolMetaKey.clientCapabilities: [String: Any](),
                    ],
                    "notifications": ["toolsListChanged": true],
                ],
            ] as [String: Any])
            return HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.contentType: ContentType.json,
                    HTTPHeaderName.accept: "application/json, text/event-stream",
                ],
                body: body
            )
        }

        let stringResponse = await transport.handleRequest(try request("1"))
        let numberResponse = await transport.handleRequest(try request(1))
        guard case .stream = stringResponse, case .stream = numberResponse else {
            Issue.record("Expected both listen requests to have separate streams")
            await transport.disconnect()
            return
        }
        let stringContext = try #require(await transport.httpRequestContext(for: .string("1")))
        let numberContext = try #require(await transport.httpRequestContext(for: .number(1)))
        #expect(JSONRPCMessageKind.jsonRPCID(inBody: try #require(stringContext.body)) == .string("1"))
        #expect(JSONRPCMessageKind.jsonRPCID(inBody: try #require(numberContext.body)) == .number(1))
        await transport.disconnect()
    }

    @Test("Modern acknowledgments are routed only to their originating listen stream")
    func modernAcknowledgmentIsIsolatedToItsListenStream() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()

        func listenRequest(_ id: String) throws -> HTTPRequest {
            let body = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "method": "subscriptions/listen",
                "params": [
                    "_meta": [
                        ProtocolMetaKey.protocolVersion: "2026-07-28",
                        ProtocolMetaKey.clientCapabilities: [String: Any](),
                    ],
                    "notifications": ["toolsListChanged": true],
                ],
            ] as [String: Any])
            return HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.contentType: ContentType.json,
                    HTTPHeaderName.accept: "application/json, text/event-stream",
                ],
                body: body
            )
        }

        let firstResponse = await transport.handleRequest(try listenRequest("listen-a"))
        let secondResponse = await transport.handleRequest(try listenRequest("listen-b"))
        guard case .stream(let firstStream, _) = firstResponse,
            case .stream(let secondStream, _) = secondResponse
        else {
            Issue.record("Expected both subscriptions to return SSE streams")
            await transport.disconnect()
            return
        }

        func acknowledgment(_ id: String) -> Data {
            Data("""
                {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"\(ProtocolMetaKey.subscriptionId)":"\(id)"}}}
                """.utf8)
        }
        try await transport.send(acknowledgment("listen-a"))
        try await transport.send(acknowledgment("listen-b"))
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        let firstFrameValue = try await firstIterator.next()
        let firstFrame = try #require(firstFrameValue)
        let secondFrameValue = try await secondIterator.next()
        let secondFrame = try #require(secondFrameValue)
        await transport.closeRequestStream(for: .string("listen-a"))
        await transport.closeRequestStream(for: .string("listen-b"))
        #expect(await transport.httpRequestContext(for: .string("listen-a")) == nil)
        #expect(await transport.httpRequestContext(for: .string("listen-b")) == nil)

        func message(from frame: Data) throws -> [String: Any] {
            let text = String(decoding: frame, as: UTF8.self)
            let line = try #require(text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }))
            return try #require(
                JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            )
        }
        let firstMessage = try message(from: firstFrame)
        let firstMeta = (firstMessage["params"] as? [String: Any])?["_meta"] as? [String: Any]
        #expect(firstMeta?[ProtocolMetaKey.subscriptionId] as? String == "listen-a")
        let secondMessage = try message(from: secondFrame)
        let secondMeta = (secondMessage["params"] as? [String: Any])?["_meta"] as? [String: Any]
        #expect(secondMeta?[ProtocolMetaKey.subscriptionId] as? String == "listen-b")
        await transport.disconnect()
    }

    @Test("Modern listen only delivers notification types accepted in the acknowledgment")
    func modernListenHonorsAcknowledgedNotificationSubset() async throws {
        let transport = makeStatelessTransport()
        try await transport.connect()
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "listen-subset",
            "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    ProtocolMetaKey.protocolVersion: "2026-07-28",
                    ProtocolMetaKey.clientCapabilities: [String: Any](),
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.contentType: ContentType.json,
                HTTPHeaderName.accept: "application/json, text/event-stream",
            ],
            body: requestBody
        ))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected subscriptions/listen to return an SSE stream")
            await transport.disconnect()
            return
        }
        let acknowledgment = Data("""
            {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{},"_meta":{"\(ProtocolMetaKey.subscriptionId)":"listen-subset"}}}
            """.utf8)
        let toolsChanged = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        try await transport.send(acknowledgment)
        try await transport.send(toolsChanged)
        await transport.closeRequestStream(for: .string("listen-subset"))

        var methods: [String] = []
        for try await frame in stream {
            let text = String(decoding: frame, as: UTF8.self)
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
                let json = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(6).utf8)
                ) as? [String: Any],
                let method = json["method"] as? String
            else { continue }
            methods.append(method)
        }
        #expect(methods == [SubscriptionsAcknowledgedNotification.name])
        await transport.disconnect()
    }

    @Test("Modern validation errors preserve request ID and use JSON-RPC invalid params")
    func testModernValidationErrorPreservesRequestID() async throws {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [ProtocolVersionValidator()])
        )
        try await transport.connect()
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 101,
            "method": "server/discover",
            "params": [:] as [String: Any],
        ] as [String: Any])

        let response = await transport.handleRequest(
            HTTPRequest(
                method: "POST",
                headers: [HTTPHeaderName.protocolVersion: "2026-07-28"],
                body: requestBody
            )
        )
        let body = try #require(response.bodyData)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])

        #expect(response.statusCode == 400)
        #expect(envelope["id"] as? Int == 101)
        #expect(error["code"] as? Int == -32602)

        await transport.disconnect()
    }

    @Test("Modern method-not-found maps to HTTP 404")
    func testModernMethodNotFoundUsesHTTP404() async throws {
        let transport = makeStatelessTransport()
        let server = Server(name: "TestServer", version: "1.0")
        try await server.start(transport: transport)
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 102, "method": "unknown/method",
            "params": ["_meta": [
                ProtocolMetaKey.protocolVersion: "2026-07-28",
                ProtocolMetaKey.clientCapabilities: [String: Any](),
            ]],
        ] as [String: Any])
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: [HTTPHeaderName.contentType: ContentType.json, HTTPHeaderName.accept: "application/json, text/event-stream"],
            body: requestBody
        ))
        #expect(response.statusCode == 404)
        let envelope = try #require(response.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
        await server.stop()
    }

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
