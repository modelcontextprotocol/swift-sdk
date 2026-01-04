import Foundation
import Testing

@testable import MCP

// MARK: - RequestInfo Tests

@Suite("RequestInfo Tests")
struct RequestInfoTests {

    @Test("RequestInfo stores headers")
    func testRequestInfoStoresHeaders() {
        let headers = ["Content-Type": "application/json", "X-Custom": "test"]
        let requestInfo = RequestInfo(headers: headers)

        #expect(requestInfo.headers == headers)
    }

    @Test("RequestInfo.header() performs case-insensitive lookup")
    func testRequestInfoHeaderCaseInsensitive() {
        let headers = ["Content-Type": "application/json", "X-Custom-Header": "value"]
        let requestInfo = RequestInfo(headers: headers)

        // Case-insensitive lookup
        #expect(requestInfo.header("content-type") == "application/json")
        #expect(requestInfo.header("CONTENT-TYPE") == "application/json")
        #expect(requestInfo.header("Content-Type") == "application/json")
        #expect(requestInfo.header("x-custom-header") == "value")
        #expect(requestInfo.header("X-CUSTOM-HEADER") == "value")
    }

    @Test("RequestInfo.header() returns nil for missing headers")
    func testRequestInfoHeaderMissing() {
        let requestInfo = RequestInfo(headers: ["Content-Type": "application/json"])

        #expect(requestInfo.header("X-Missing") == nil)
        #expect(requestInfo.header("Authorization") == nil)
    }

    @Test("RequestInfo is Hashable and Sendable")
    func testRequestInfoIsHashableAndSendable() {
        let requestInfo1 = RequestInfo(headers: ["X-Test": "value"])
        let requestInfo2 = RequestInfo(headers: ["X-Test": "value"])
        let requestInfo3 = RequestInfo(headers: ["X-Test": "other"])

        // Hashable
        #expect(requestInfo1 == requestInfo2)
        #expect(requestInfo1 != requestInfo3)

        // Sendable (compilation test - this compiles if Sendable)
        let _: @Sendable () -> RequestInfo = { requestInfo1 }
    }
}

// MARK: - RequestMeta.relatedTaskId Tests

@Suite("RequestMeta.relatedTaskId Tests")
struct RequestMetaRelatedTaskIdTests {

    @Test("relatedTaskId extracts task ID from additionalFields")
    func testRelatedTaskIdExtractsTaskId() {
        let meta = RequestMeta(additionalFields: [
            "io.modelcontextprotocol/related-task": .object(["taskId": .string("task-abc123")])
        ])

        #expect(meta.relatedTaskId == "task-abc123")
    }

    @Test("relatedTaskId returns nil when no related task metadata")
    func testRelatedTaskIdNilWhenNoMetadata() {
        let meta = RequestMeta()

        #expect(meta.relatedTaskId == nil)
    }

    @Test("relatedTaskId returns nil when additionalFields is nil")
    func testRelatedTaskIdNilWhenAdditionalFieldsNil() {
        let meta = RequestMeta(progressToken: .string("token"))

        #expect(meta.relatedTaskId == nil)
    }

    @Test("relatedTaskId returns nil when key is missing")
    func testRelatedTaskIdNilWhenKeyMissing() {
        let meta = RequestMeta(additionalFields: [
            "other-key": .object(["taskId": .string("task-123")])
        ])

        #expect(meta.relatedTaskId == nil)
    }

    @Test("relatedTaskId returns nil when taskId is not a string")
    func testRelatedTaskIdNilWhenTaskIdNotString() {
        let meta = RequestMeta(additionalFields: [
            "io.modelcontextprotocol/related-task": .object(["taskId": .double(123)])
        ])

        #expect(meta.relatedTaskId == nil)
    }

    @Test("relatedTaskId returns nil when value is not an object")
    func testRelatedTaskIdNilWhenNotObject() {
        let meta = RequestMeta(additionalFields: [
            "io.modelcontextprotocol/related-task": .string("not-an-object")
        ])

        #expect(meta.relatedTaskId == nil)
    }

    @Test("relatedTaskId works with progressToken also set")
    func testRelatedTaskIdWithProgressToken() {
        let meta = RequestMeta(
            progressToken: .string("progress-123"),
            additionalFields: [
                "io.modelcontextprotocol/related-task": .object(["taskId": .string("task-xyz")])
            ]
        )

        #expect(meta.progressToken == .string("progress-123"))
        #expect(meta.relatedTaskId == "task-xyz")
    }
}

/// Tests for RequestHandlerContext functionality.
///
/// These tests verify that handlers have access to request context information
/// and can make bidirectional requests, matching the TypeScript SDK's
/// `RequestHandlerExtra` and Python SDK's `RequestContext` / `Context`.
///
/// Based on:
/// - TypeScript: `packages/core/test/shared/protocol.test.ts`
/// - TypeScript: `test/integration/test/taskLifecycle.test.ts`
/// - Python: `tests/server/fastmcp/test_server.py` (test_context_injection)
/// - Python: `tests/server/fastmcp/test_elicitation.py`
/// - Python: `tests/issues/test_176_progress_token.py`

// MARK: - Server RequestHandlerContext Tests

@Suite("Server.RequestHandlerContext Tests")
struct ServerRequestHandlerContextTests {

    // MARK: - requestId Tests

    /// Test that handlers can access context.requestId.
    /// Based on Python SDK's test_context_injection: `assert ctx.request_id is not None`
    @Test("Handler can access context.requestId")
    func testHandlerCanAccessRequestId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track the requestId received in handler
        actor RequestIdTracker {
            var receivedRequestId: RequestId?
            func set(_ id: RequestId) { receivedRequestId = id }
        }
        let tracker = RequestIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, context in
            // Handler accesses context.requestId - this is what we're testing
            await tracker.set(context.requestId)
            return CallTool.Result(content: [.text("Request ID: \(context.requestId)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "test_tool", arguments: [:])

        // Verify handler received a valid requestId
        let receivedId = await tracker.receivedRequestId
        #expect(receivedId != nil, "Handler should have access to requestId")

        // Verify the response mentions the request ID
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("Request ID:"), "Response should contain request ID")
        }

        await client.disconnect()
    }

    /// Test that context.requestId matches the actual JSON-RPC request ID.
    @Test("context.requestId matches JSON-RPC request ID")
    func testRequestIdMatchesJsonRpcId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor RequestIdTracker {
            var receivedRequestIds: [RequestId] = []
            func add(_ id: RequestId) { receivedRequestIds.append(id) }
        }
        let tracker = RequestIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, context in
            await tracker.add(context.requestId)
            return ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            await tracker.add(context.requestId)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Make multiple requests
        _ = try await client.send(ListTools.request())
        _ = try await client.callTool(name: "test_tool", arguments: [:])
        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let receivedIds = await tracker.receivedRequestIds
        #expect(receivedIds.count == 3, "Should have received 3 request IDs")

        // Verify all IDs are unique (each request gets a unique ID)
        let uniqueIds = Set(receivedIds.map { "\($0)" })
        #expect(uniqueIds.count == 3, "Each request should have a unique ID")

        await client.disconnect()
    }

    // MARK: - _meta Tests

    /// Test that handlers can access context._meta when present.
    /// Based on TypeScript SDK's `extra._meta` access tests.
    @Test("Handler can access context._meta when present")
    func testHandlerCanAccessMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor MetaTracker {
            var receivedMeta: RequestMeta?
            func set(_ meta: RequestMeta?) { receivedMeta = meta }
        }
        let tracker = MetaTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Handler accesses context._meta - this is what we're testing
            await tracker.set(context._meta)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call tool WITH _meta containing progressToken
        _ = try await client.send(
            CallTool.request(.init(
                name: "test_tool",
                arguments: [:],
                _meta: RequestMeta(progressToken: .string("test-token-123"))
            ))
        )

        let receivedMeta = await tracker.receivedMeta
        #expect(receivedMeta != nil, "Handler should have access to _meta")
        #expect(receivedMeta?.progressToken == .string("test-token-123"), "progressToken should match")

        await client.disconnect()
    }

    /// Test that context._meta is nil when not provided in request.
    @Test("context._meta is nil when not provided")
    func testMetaIsNilWhenNotProvided() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor MetaTracker {
            var receivedMeta: RequestMeta? = RequestMeta()  // Initialize to non-nil
            var wasSet = false
            func set(_ meta: RequestMeta?) {
                receivedMeta = meta
                wasSet = true
            }
        }
        let tracker = MetaTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            await tracker.set(context._meta)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call tool WITHOUT _meta
        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let wasSet = await tracker.wasSet
        let receivedMeta = await tracker.receivedMeta
        #expect(wasSet, "Handler should have been called")
        #expect(receivedMeta == nil, "context._meta should be nil when not provided")

        await client.disconnect()
    }

    /// Test using context._meta?.progressToken as a convenience pattern.
    /// Based on Python SDK's test_176_progress_token.py showing progressToken access via context.
    @Test("context._meta?.progressToken convenience pattern")
    func testProgressTokenFromContextMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor ProgressTracker {
            var updates: [(token: ProgressToken, progress: Double)] = []
            func add(token: ProgressToken, progress: Double) {
                updates.append((token, progress))
            }
        }
        let progressTracker = ProgressTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "progress_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Use context._meta?.progressToken instead of request._meta?.progressToken
            // This is the convenience pattern we're testing
            if let progressToken = context._meta?.progressToken {
                try await context.sendProgress(token: progressToken, progress: 0.5, total: 1.0)
                try await context.sendProgress(token: progressToken, progress: 1.0, total: 1.0)
            }
            return CallTool.Result(content: [.text("Done")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        await client.onNotification(ProgressNotification.self) { message in
            await progressTracker.add(token: message.params.progressToken, progress: message.params.progress)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call tool with progressToken in _meta
        _ = try await client.send(
            CallTool.request(.init(
                name: "progress_tool",
                arguments: [:],
                _meta: RequestMeta(progressToken: .string("ctx-token"))
            ))
        )

        try await Task.sleep(for: .milliseconds(100))

        let updates = await progressTracker.updates
        #expect(updates.count == 2, "Should receive 2 progress notifications")
        #expect(updates.allSatisfy { $0.token == .string("ctx-token") }, "All tokens should match")

        await client.disconnect()
    }

    // MARK: - context.elicit() Tests

    /// Test that handlers can use context.elicit() for bidirectional elicitation.
    /// Based on TypeScript SDK's `extra.sendRequest({ method: 'elicitation/create' })` tests
    /// in test/integration/test/taskLifecycle.test.ts and test/integration/test/server.test.ts.
    @Test("Handler can use context.elicit() for form elicitation")
    func testContextElicitForm() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "askName", description: "Ask user for name", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Use context.elicit() instead of server.elicit()
            // This is the bidirectional request pattern from TypeScript's extra.sendRequest()
            let result = try await context.elicit(
                message: "What is your name?",
                requestedSchema: ElicitationSchema(
                    properties: ["name": .string(StringSchema(title: "Name"))],
                    required: ["name"]
                )
            )

            if result.action == .accept, let name = result.content?["name"]?.stringValue {
                return CallTool.Result(content: [.text("Hello, \(name)!")])
            } else {
                return CallTool.Result(content: [.text("No name provided")], isError: true)
            }
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }
            #expect(formParams.message == "What is your name?")
            return ElicitResult(action: .accept, content: ["name": .string("Bob")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "askName", arguments: [:])

        #expect(result.isError == nil)
        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Hello, Bob!")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    /// Test that context.elicit() handles user decline.
    @Test("context.elicit() handles user decline")
    func testContextElicitDecline() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "confirm", description: "Confirm", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            let result = try await context.elicit(
                message: "Confirm?",
                requestedSchema: ElicitationSchema(
                    properties: ["ok": .boolean(BooleanSchema(title: "OK"))]
                )
            )

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Accepted")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "confirm", arguments: [:])

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Declined")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    // MARK: - Sampling from Handlers
    // Note: For sampling from within request handlers, use server.createMessage() which is
    // thoroughly tested in SamplingTests.swift. The context provides elicit() and elicitUrl()
    // convenience methods (tested above), matching Python's ctx.elicit() pattern. Sampling
    // is done via the server directly, matching TypeScript's pattern where extra.sendRequest()
    // is generic and server.createMessage() is the convenience method.

    // MARK: - authInfo Tests

    /// Test that context.authInfo is nil for non-HTTP transports.
    /// Based on TypeScript SDK's `extra.authInfo` which is only populated for authenticated HTTP connections.
    @Test("context.authInfo is nil for InMemoryTransport")
    func testAuthInfoNilForInMemoryTransport() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor AuthInfoTracker {
            var receivedAuthInfo: AuthInfo?
            var wasChecked = false
            func set(_ authInfo: AuthInfo?) {
                receivedAuthInfo = authInfo
                wasChecked = true
            }
        }
        let tracker = AuthInfoTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Handler accesses context.authInfo - should be nil for InMemoryTransport
            await tracker.set(context.authInfo)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let wasChecked = await tracker.wasChecked
        let receivedAuthInfo = await tracker.receivedAuthInfo
        #expect(wasChecked, "Handler should have been called")
        #expect(receivedAuthInfo == nil, "authInfo should be nil for InMemoryTransport")

        await client.disconnect()
    }

    // MARK: - requestInfo Tests

    /// Test that context.requestInfo is nil for non-HTTP transports.
    /// Based on TypeScript SDK's `extra.requestInfo` which is only populated for HTTP connections.
    @Test("context.requestInfo is nil for InMemoryTransport")
    func testRequestInfoNilForInMemoryTransport() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor RequestInfoTracker {
            var receivedRequestInfo: RequestInfo?
            var wasChecked = false
            func set(_ requestInfo: RequestInfo?) {
                receivedRequestInfo = requestInfo
                wasChecked = true
            }
        }
        let tracker = RequestInfoTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Handler accesses context.requestInfo - should be nil for InMemoryTransport
            await tracker.set(context.requestInfo)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let wasChecked = await tracker.wasChecked
        let receivedRequestInfo = await tracker.receivedRequestInfo
        #expect(wasChecked, "Handler should have been called")
        #expect(receivedRequestInfo == nil, "requestInfo should be nil for InMemoryTransport")

        await client.disconnect()
    }

    // MARK: - taskId Tests

    /// Test that context.taskId extracts task ID from _meta when present.
    /// Based on TypeScript SDK's `extra.taskId` which is extracted from `_meta[RELATED_TASK_META_KEY]`.
    @Test("context.taskId extracts task ID from _meta")
    func testContextTaskIdFromMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor TaskIdTracker {
            var receivedTaskId: String?
            var wasChecked = false
            func set(_ taskId: String?) {
                receivedTaskId = taskId
                wasChecked = true
            }
        }
        let tracker = TaskIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "task_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Handler accesses context.taskId - convenience property
            await tracker.set(context.taskId)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call tool with related task metadata in _meta
        _ = try await client.send(
            CallTool.request(.init(
                name: "task_tool",
                arguments: [:],
                _meta: RequestMeta(additionalFields: [
                    "io.modelcontextprotocol/related-task": .object(["taskId": .string("test-task-123")])
                ])
            ))
        )

        let wasChecked = await tracker.wasChecked
        let receivedTaskId = await tracker.receivedTaskId
        #expect(wasChecked, "Handler should have been called")
        #expect(receivedTaskId == "test-task-123", "context.taskId should extract task ID from _meta")

        await client.disconnect()
    }

    /// Test that context.taskId is nil when no related task metadata.
    @Test("context.taskId is nil when no related task metadata")
    func testContextTaskIdNilWhenNoTaskMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor TaskIdTracker {
            var receivedTaskId: String? = "initial"  // Initialize to non-nil
            var wasChecked = false
            func set(_ taskId: String?) {
                receivedTaskId = taskId
                wasChecked = true
            }
        }
        let tracker = TaskIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            await tracker.set(context.taskId)
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Call tool WITHOUT related task metadata
        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let wasChecked = await tracker.wasChecked
        let receivedTaskId = await tracker.receivedTaskId
        #expect(wasChecked, "Handler should have been called")
        #expect(receivedTaskId == nil, "context.taskId should be nil when no related task metadata")

        await client.disconnect()
    }

    // MARK: - closeSSEStream Tests

    /// Test that context.closeSSEStream is nil for non-HTTP transports.
    /// Based on TypeScript SDK's `extra.closeSSEStream` which is only available for HTTP/SSE transports.
    @Test("context.closeSSEStream is nil for InMemoryTransport")
    func testCloseSSEStreamNilForInMemoryTransport() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor StreamClosureTracker {
            var closeSSEStreamWasNil = false
            var closeStandaloneSSEStreamWasNil = false
            func set(closeSSE: Bool, closeStandalone: Bool) {
                closeSSEStreamWasNil = closeSSE
                closeStandaloneSSEStreamWasNil = closeStandalone
            }
        }
        let tracker = StreamClosureTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "Test", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Check that SSE stream closures are nil for InMemoryTransport
            await tracker.set(
                closeSSE: context.closeSSEStream == nil,
                closeStandalone: context.closeStandaloneSSEStream == nil
            )
            return CallTool.Result(content: [.text("OK")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_tool", arguments: [:])

        let closeSSEStreamWasNil = await tracker.closeSSEStreamWasNil
        let closeStandaloneSSEStreamWasNil = await tracker.closeStandaloneSSEStreamWasNil
        #expect(closeSSEStreamWasNil, "closeSSEStream should be nil for InMemoryTransport")
        #expect(closeStandaloneSSEStreamWasNil, "closeStandaloneSSEStream should be nil for InMemoryTransport")

        await client.disconnect()
    }
}

// MARK: - Client RequestHandlerContext Tests

@Suite("Client.RequestHandlerContext Tests")
struct ClientRequestHandlerContextTests {

    /// Test that client handlers can access context.requestId.
    @Test("Client handler can access context.requestId")
    func testClientHandlerCanAccessRequestId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor RequestIdTracker {
            var receivedRequestId: RequestId?
            func set(_ id: RequestId) { receivedRequestId = id }
        }
        let tracker = RequestIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "elicitTool", description: "Elicit", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(.form(ElicitRequestFormParams(
                message: "Test",
                requestedSchema: ElicitationSchema(properties: ["x": .string(StringSchema())])
            )))
            return CallTool.Result(content: [.text("Action: \(result.action)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, context in
            // Client handler accesses context.requestId
            await tracker.set(context.requestId)
            return ElicitResult(action: .accept, content: ["x": .string("test")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "elicitTool", arguments: [:])

        let receivedId = await tracker.receivedRequestId
        #expect(receivedId != nil, "Client handler should have access to requestId")

        await client.disconnect()
    }

    /// Test that client handlers can access context.taskId when present.
    /// This matches the server's context.taskId convenience property.
    @Test("Client handler can access context.taskId")
    func testClientHandlerCanAccessTaskId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor TaskIdTracker {
            var receivedTaskId: String?
            var wasChecked = false
            func set(_ id: String?) {
                receivedTaskId = id
                wasChecked = true
            }
        }
        let tracker = TaskIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "elicitTool", description: "Elicit", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            // Send elicitation with task metadata
            let result = try await server.elicit(.form(ElicitRequestFormParams(
                message: "Test",
                requestedSchema: ElicitationSchema(properties: ["x": .string(StringSchema())]),
                _meta: RequestMeta(additionalFields: [
                    "io.modelcontextprotocol/related-task": .object(["taskId": .string("client-task-456")])
                ])
            )))
            return CallTool.Result(content: [.text("Action: \(result.action)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, context in
            // Client handler accesses context.taskId - convenience property matching server context
            await tracker.set(context.taskId)
            return ElicitResult(action: .accept, content: ["x": .string("test")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "elicitTool", arguments: [:])

        let wasChecked = await tracker.wasChecked
        let receivedTaskId = await tracker.receivedTaskId
        #expect(wasChecked, "Client handler should have been called")
        #expect(receivedTaskId == "client-task-456", "context.taskId should extract task ID from _meta")

        await client.disconnect()
    }

    /// Test that client context.taskId is nil when no related task metadata.
    @Test("Client context.taskId is nil when no related task metadata")
    func testClientContextTaskIdNilWhenNoTaskMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor TaskIdTracker {
            var receivedTaskId: String? = "initial"  // Initialize to non-nil
            var wasChecked = false
            func set(_ id: String?) {
                receivedTaskId = id
                wasChecked = true
            }
        }
        let tracker = TaskIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "elicitTool", description: "Elicit", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            // Send elicitation WITHOUT task metadata
            let result = try await server.elicit(.form(ElicitRequestFormParams(
                message: "Test",
                requestedSchema: ElicitationSchema(properties: ["x": .string(StringSchema())])
            )))
            return CallTool.Result(content: [.text("Action: \(result.action)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, context in
            await tracker.set(context.taskId)
            return ElicitResult(action: .accept, content: ["x": .string("test")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "elicitTool", arguments: [:])

        let wasChecked = await tracker.wasChecked
        let receivedTaskId = await tracker.receivedTaskId
        #expect(wasChecked, "Client handler should have been called")
        #expect(receivedTaskId == nil, "context.taskId should be nil when no related task metadata")

        await client.disconnect()
    }

    /// Test that client handlers can access context._meta when present.
    @Test("Client handler can access context._meta")
    func testClientHandlerCanAccessMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor MetaTracker {
            var receivedMeta: RequestMeta?
            func set(_ meta: RequestMeta?) { receivedMeta = meta }
        }
        let tracker = MetaTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "elicitTool", description: "Elicit", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let result = try await server.elicit(.form(ElicitRequestFormParams(
                message: "Test",
                requestedSchema: ElicitationSchema(properties: ["x": .string(StringSchema())]),
                _meta: RequestMeta(progressToken: .string("server-token"))
            )))
            return CallTool.Result(content: [.text("Action: \(result.action)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, context in
            // Client handler accesses context._meta
            await tracker.set(context._meta)
            return ElicitResult(action: .accept, content: ["x": .string("test")])
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "elicitTool", arguments: [:])

        let receivedMeta = await tracker.receivedMeta
        #expect(receivedMeta != nil, "Client handler should have access to _meta")
        #expect(receivedMeta?.progressToken == .string("server-token"), "progressToken should match")

        await client.disconnect()
    }
}

// MARK: - Additional Context Tests from Python/TypeScript SDKs

/// Additional tests based on patterns from Python and TypeScript SDKs.
/// These tests ensure feature parity across SDK implementations.
@Suite("Additional RequestHandlerContext Tests")
struct AdditionalRequestHandlerContextTests {

    // MARK: - context.elicitUrl() Tests

    /// Test that handlers can use context.elicitUrl() for URL elicitation.
    /// Based on Python SDK's ctx.session.elicit_url() and ctx.elicit_url() tests.
    @Test("Handler can use context.elicitUrl() for URL elicitation")
    func testContextElicitUrl() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize access", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // Use context.elicitUrl() instead of server.elicit()
            // This is the convenience method pattern from Python's ctx.elicit_url()
            let result = try await context.elicitUrl(
                message: "Please authorize access to files",
                url: "https://example.com/oauth/authorize",
                elicitationId: "file-auth-123"
            )

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Authorized")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { params, _ in
            guard case .url(let urlParams) = params else {
                return ElicitResult(action: .decline)
            }
            #expect(urlParams.message == "Please authorize access to files")
            #expect(urlParams.elicitationId == "file-auth-123")
            #expect(urlParams.url == "https://example.com/oauth/authorize")
            return ElicitResult(action: .accept)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        #expect(result.isError == nil)
        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Authorized")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    /// Test that context.elicitUrl() handles user decline.
    @Test("context.elicitUrl() handles user decline")
    func testContextElicitUrlDecline() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "authorize", description: "Authorize", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            let result = try await context.elicitUrl(
                message: "Authorize?",
                url: "https://example.com/oauth",
                elicitationId: "auth-decline-test"
            )

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Authorized")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(url: Client.Capabilities.Elicitation.URL())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "authorize", arguments: [:])

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Declined")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    // MARK: - context.elicit() Cancel Action Test

    /// Test that context.elicit() handles cancel action.
    /// Based on TypeScript SDK's cancel action tests.
    @Test("context.elicit() handles cancel action")
    func testContextElicitCancel() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "confirm", description: "Confirm action", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            let result = try await context.elicit(
                message: "Confirm this action?",
                requestedSchema: ElicitationSchema(
                    properties: ["confirm": .boolean(BooleanSchema(title: "Confirm"))]
                )
            )

            return switch result.action {
            case .accept: CallTool.Result(content: [.text("Accepted")])
            case .decline: CallTool.Result(content: [.text("Declined")])
            case .cancel: CallTool.Result(content: [.text("Cancelled")])
            }
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        await client.withElicitationHandler { _, _ in
            return ElicitResult(action: .cancel)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "confirm", arguments: [:])

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Cancelled")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    // MARK: - Multiple Sequential Elicitation Requests

    /// Test multiple sequential elicitation requests within a single handler.
    /// Based on TypeScript SDK's test for handling multiple sequential elicitation requests.
    @Test("Handler can make multiple sequential elicitation requests")
    func testMultipleSequentialElicitationRequests() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "wizard", description: "Multi-step wizard", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, context in
            // First elicitation - get name
            let nameResult = try await context.elicit(
                message: "What is your name?",
                requestedSchema: ElicitationSchema(
                    properties: ["name": .string(StringSchema(title: "Name"))],
                    required: ["name"]
                )
            )

            guard nameResult.action == .accept,
                  let name = nameResult.content?["name"]?.stringValue else {
                return CallTool.Result(content: [.text("Name step failed")], isError: true)
            }

            // Second elicitation - get age
            let ageResult = try await context.elicit(
                message: "What is your age?",
                requestedSchema: ElicitationSchema(
                    properties: ["age": .number(NumberSchema(isInteger: true, title: "Age"))],
                    required: ["age"]
                )
            )

            guard ageResult.action == .accept,
                  let age = ageResult.content?["age"]?.intValue else {
                return CallTool.Result(content: [.text("Age step failed")], isError: true)
            }

            // Third elicitation - get city
            let cityResult = try await context.elicit(
                message: "What is your city?",
                requestedSchema: ElicitationSchema(
                    properties: ["city": .string(StringSchema(title: "City"))],
                    required: ["city"]
                )
            )

            guard cityResult.action == .accept,
                  let city = cityResult.content?["city"]?.stringValue else {
                return CallTool.Result(content: [.text("City step failed")], isError: true)
            }

            return CallTool.Result(content: [.text("Hello \(name), age \(age), from \(city)!")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: Client.Capabilities.Elicitation.Form())
        ))

        actor RequestCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = RequestCounter()

        await client.withElicitationHandler { params, _ in
            await counter.increment()
            guard case .form(let formParams) = params else {
                return ElicitResult(action: .decline)
            }

            if formParams.message.contains("name") {
                return ElicitResult(action: .accept, content: ["name": .string("Alice")])
            } else if formParams.message.contains("age") {
                return ElicitResult(action: .accept, content: ["age": .int(30)])
            } else if formParams.message.contains("city") {
                return ElicitResult(action: .accept, content: ["city": .string("New York")])
            }
            return ElicitResult(action: .decline)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "wizard", arguments: [:])

        let requestCount = await counter.count
        #expect(requestCount == 3, "Should have made 3 elicitation requests")

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Hello Alice, age 30, from New York!")
        } else {
            Issue.record("Expected text content")
        }

        await client.disconnect()
    }

    // MARK: - Sampling Handler Context Access Tests

    /// Test that sampling handler can access context.requestId.
    /// Based on Python SDK's sampling callback context access patterns.
    @Test("Sampling handler can access context.requestId")
    func testSamplingHandlerCanAccessRequestId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor RequestIdTracker {
            var receivedRequestId: RequestId?
            func set(_ id: RequestId) { receivedRequestId = id }
        }
        let tracker = RequestIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "askLLM", description: "Ask LLM", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let params = SamplingParameters(
                messages: [.user("Hello")],
                maxTokens: 100
            )
            let result = try await server.createMessage(params)
            return CallTool.Result(content: [.text("LLM said: \(result.model)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(sampling: .init()))

        await client.withSamplingHandler { _, context in
            // Sampling handler accesses context.requestId
            await tracker.set(context.requestId)
            return ClientSamplingRequest.Result(
                model: "test-model",
                stopReason: .endTurn,
                role: .assistant,
                content: [.text("Hello from LLM")]
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "askLLM", arguments: [:])

        let receivedId = await tracker.receivedRequestId
        #expect(receivedId != nil, "Sampling handler should have access to requestId")

        await client.disconnect()
    }

    /// Test that sampling handler can access context._meta when present.
    @Test("Sampling handler can access context._meta")
    func testSamplingHandlerCanAccessMeta() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor MetaTracker {
            var receivedMeta: RequestMeta?
            func set(_ meta: RequestMeta?) { receivedMeta = meta }
        }
        let tracker = MetaTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "askLLM", description: "Ask LLM", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            var params = SamplingParameters(
                messages: [.user("Hello")],
                maxTokens: 100
            )
            params._meta = RequestMeta(progressToken: .string("sampling-token-123"))
            let result = try await server.createMessage(params)
            return CallTool.Result(content: [.text("LLM said: \(result.model)")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(sampling: .init()))

        await client.withSamplingHandler { _, context in
            // Sampling handler accesses context._meta
            await tracker.set(context._meta)
            return ClientSamplingRequest.Result(
                model: "test-model",
                stopReason: .endTurn,
                role: .assistant,
                content: [.text("Hello from LLM")]
            )
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "askLLM", arguments: [:])

        let receivedMeta = await tracker.receivedMeta
        #expect(receivedMeta != nil, "Sampling handler should have access to _meta")
        #expect(receivedMeta?.progressToken == .string("sampling-token-123"), "progressToken should match")

        await client.disconnect()
    }

    // MARK: - Roots Handler Context Access Tests

    /// Test that roots handler can access context.requestId.
    /// Based on Python SDK's list_roots callback context access patterns.
    @Test("Roots handler can access context.requestId")
    func testRootsHandlerCanAccessRequestId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor RequestIdTracker {
            var receivedRequestId: RequestId?
            func set(_ id: RequestId) { receivedRequestId = id }
        }
        let tracker = RequestIdTracker()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "getRoots", description: "Get roots", inputSchema: [:])
            ])
        }

        await server.withRequestHandler(CallTool.self) { [server] _, _ in
            let roots = try await server.listRoots()
            return CallTool.Result(content: [.text("Found \(roots.count) roots")])
        }

        let client = Client(name: "TestClient", version: "1.0.0")
        await client.setCapabilities(Client.Capabilities(roots: .init(listChanged: true)))

        // Use withRootsHandler with context parameter
        await client.withRootsHandler { context in
            // Roots handler accesses context.requestId
            await tracker.set(context.requestId)
            return [Root(uri: "file:///test/path", name: "Test Root")]
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "getRoots", arguments: [:])

        let receivedId = await tracker.receivedRequestId
        #expect(receivedId != nil, "Roots handler should have access to requestId")

        if case .text(let text, _, _) = result.content.first {
            #expect(text == "Found 1 roots")
        }

        await client.disconnect()
    }
}
