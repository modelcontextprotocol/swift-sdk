import Foundation
import Testing

@testable import MCP

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
