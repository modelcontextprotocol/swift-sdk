import Foundation
import Testing

@testable import MCP

/// Tests for full client-server roundtrip flows through the HTTP transport layer
/// with a real MCP Server instance.
///
/// These tests follow the TypeScript SDK patterns from:
/// - `test/integration/test/stateManagementStreamableHttp.test.ts`
@Suite("Full Roundtrip Tests")
struct FullRoundtripTests {

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
        // Register tool list handler
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "greet",
                    description: "A simple greeting tool",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Name to greet"]
                        ]
                    ]
                ),
                Tool(
                    name: "add",
                    description: "Adds two numbers",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "a": ["type": "number", "description": "First number"],
                            "b": ["type": "number", "description": "Second number"]
                        ],
                        "required": ["a", "b"]
                    ]
                ),
            ])
        }

        // Register tool call handler
        await server.withRequestHandler(CallTool.self) { request, _ in
            switch request.name {
            case "greet":
                let name = request.arguments?["name"]?.stringValue ?? "World"
                return CallTool.Result(content: [.text("Hello, \(name)!")])

            case "add":
                let a = request.arguments?["a"]?.doubleValue ?? 0
                let b = request.arguments?["b"]?.doubleValue ?? 0
                return CallTool.Result(content: [.text("Result: \(a + b)")])

            default:
                return CallTool.Result(content: [.text("Unknown tool: \(request.name)")], isError: true)
            }
        }
    }


    // MARK: - 2.1 Multiple client connections (stateless mode)

    @Test("Multiple client connections in stateless mode")
    func multipleClientConnectionsStateless() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        // Create transport in stateless mode (no sessionIdGenerator)
        let transport = HTTPServerTransport()
        try await server.start(transport: transport)

        // Client 1 initializes
        let init1 = TestPayloads.initializeRequest(id: "c1-init", clientName: "client1")
        let response1 = await transport.handleRequest(TestPayloads.postRequest(body: init1))
        #expect(response1.statusCode == 200)
        #expect(response1.headers[HTTPHeader.sessionId] == nil, "Stateless mode should not return session ID")

        // Client 1 lists tools
        let listTools1 = TestPayloads.listToolsRequest(id: "c1-list")
        let toolsResponse1 = await transport.handleRequest(TestPayloads.postRequest(body: listTools1))
        #expect(toolsResponse1.statusCode == 200)

        if let body = toolsResponse1.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("greet"), "Should list greet tool")
        }

        // Client 2 initializes (separate connection)
        let init2 = TestPayloads.initializeRequest(id: "c2-init", clientName: "client2")
        let response2 = await transport.handleRequest(TestPayloads.postRequest(body: init2))
        #expect(response2.statusCode == 200)

        // Client 2 calls a tool
        let callTool2 = TestPayloads.callToolRequest(id: "c2-call", name: "greet", arguments: ["name": "Client2"])
        let toolResponse2 = await transport.handleRequest(TestPayloads.postRequest(body: callTool2))
        #expect(toolResponse2.statusCode == 200)

        if let body = toolResponse2.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Hello, Client2!"), "Should return greeting for Client2")
        }
    }

    // MARK: - 2.2 Operate with session management (stateful mode)

    @Test("Operate with session management in stateful mode")
    func operateWithSessionManagement() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize and get session ID
        let initRequest = TestPayloads.initializeRequest(id: "init", clientName: "test-client")
        let initResponse = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse.statusCode == 200)
        #expect(initResponse.headers[HTTPHeader.sessionId] == sessionId, "Should return session ID")

        // Make subsequent request with session ID - should succeed
        let listTools = TestPayloads.listToolsRequest(id: "list")
        let toolsResponse = await transport.handleRequest(TestPayloads.postRequest(body: listTools, sessionId: sessionId))
        #expect(toolsResponse.statusCode == 200)

        if let body = toolsResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("greet"), "Should list greet tool")
            #expect(text.contains("add"), "Should list add tool")
        }

        // Make request without session ID - should fail
        let noSessionRequest = await transport.handleRequest(TestPayloads.postRequest(body: listTools))
        #expect(noSessionRequest.statusCode == 400, "Should reject request without session ID in stateful mode")
    }

    // MARK: - 2.3 Full tool call roundtrip

    @Test("Full tool call roundtrip with real server")
    func fullToolCallRoundtrip() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Step 1: Initialize
        let initRequest = TestPayloads.initializeRequest()
        let initResponse = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse.statusCode == 200)

        if let body = initResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("protocolVersion"), "Init response should include protocolVersion")
            #expect(text.contains("capabilities"), "Init response should include capabilities")
        }

        // Step 2: List tools
        let listToolsRequest = """
            {"jsonrpc":"2.0","method":"tools/list","id":"2"}
            """
        let listResponse = await transport.handleRequest(TestPayloads.postRequest(body: listToolsRequest, sessionId: sessionId))
        #expect(listResponse.statusCode == 200)

        if let body = listResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("greet"), "Should include greet tool")
            #expect(text.contains("add"), "Should include add tool")
        }

        // Step 3: Call greet tool
        let greetRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"3","params":{"name":"greet","arguments":{"name":"MCP Swift"}}}
            """
        let greetResponse = await transport.handleRequest(TestPayloads.postRequest(body: greetRequest, sessionId: sessionId))
        #expect(greetResponse.statusCode == 200)

        if let body = greetResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Hello, MCP Swift!"), "Should return correct greeting")
        }

        // Step 4: Call add tool
        let addRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"4","params":{"name":"add","arguments":{"a":5,"b":3}}}
            """
        let addResponse = await transport.handleRequest(TestPayloads.postRequest(body: addRequest, sessionId: sessionId))
        #expect(addResponse.statusCode == 200)

        if let body = addResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Result: 8"), "Should return correct sum")
        }
    }

    // MARK: - 2.4 Protocol version negotiation

    @Test("Protocol version negotiation stores correct version")
    func protocolVersionNegotiation() async throws {
        let server = createTestServer()

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize with specific protocol version
        let initRequest = TestPayloads.initializeRequest()
        let initResponse = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))
        #expect(initResponse.statusCode == 200)

        // Verify response includes the negotiated version
        if let body = initResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("protocolVersion"), "Response should include protocol version")
            #expect(text.contains(Version.v2024_11_05) || text.contains("2025"), "Response should include a valid version")
        }

        // Verify subsequent requests work with the protocol version header
        let pingRequest = """
            {"jsonrpc":"2.0","method":"ping","id":"2"}
            """
        let headers = [
            HTTPHeader.accept: "application/json, text/event-stream",
            HTTPHeader.contentType: "application/json",
            HTTPHeader.sessionId: sessionId,
            HTTPHeader.protocolVersion: Version.v2024_11_05,
        ]
        let pingResponse = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: headers,
            body: pingRequest.data(using: .utf8)
        ))
        #expect(pingResponse.statusCode == 200)
    }

    @Test("Reject mismatched protocol version")
    func rejectMismatchedProtocolVersion() async throws {
        let server = createTestServer()

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize first
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send request with different protocol version
        let pingRequest = """
            {"jsonrpc":"2.0","method":"ping","id":"2"}
            """
        let headers = [
            HTTPHeader.accept: "application/json, text/event-stream",
            HTTPHeader.contentType: "application/json",
            HTTPHeader.sessionId: sessionId,
            HTTPHeader.protocolVersion: "9999-99-99",  // Invalid version
        ]
        let response = await transport.handleRequest(HTTPRequest(
            method: "POST",
            headers: headers,
            body: pingRequest.data(using: .utf8)
        ))

        // Should reject the mismatched version
        #expect(response.statusCode == 400, "Should reject mismatched protocol version")
    }

    // MARK: - Additional Integration Tests

    @Test("Unknown tool returns error")
    func unknownToolReturnsError() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Call unknown tool
        let unknownToolRequest = """
            {"jsonrpc":"2.0","method":"tools/call","id":"2","params":{"name":"nonexistent","arguments":{}}}
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: unknownToolRequest, sessionId: sessionId))
        #expect(response.statusCode == 200)  // JSON-RPC error is 200 with error in body

        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Unknown tool") || text.contains("isError"), "Should indicate error for unknown tool")
        }
    }

    @Test("Batch requests work correctly")
    func batchRequestsWorkCorrectly() async throws {
        let server = createTestServer()
        await setUpToolHandlers(server)

        let sessionId = UUID().uuidString
        let transport = HTTPServerTransport(
            options: .init(sessionIdGenerator: { sessionId })
        )
        try await server.start(transport: transport)

        // Initialize
        let initRequest = TestPayloads.initializeRequest()
        _ = await transport.handleRequest(TestPayloads.postRequest(body: initRequest))

        // Send batch request with multiple tool calls
        let batchRequest = """
            [
                {"jsonrpc":"2.0","method":"tools/call","id":"b1","params":{"name":"greet","arguments":{"name":"Alice"}}},
                {"jsonrpc":"2.0","method":"tools/call","id":"b2","params":{"name":"add","arguments":{"a":10,"b":20}}}
            ]
            """
        let response = await transport.handleRequest(TestPayloads.postRequest(body: batchRequest, sessionId: sessionId))
        #expect(response.statusCode == 200)

        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Hello, Alice!"), "Should include first tool result")
            #expect(text.contains("Result: 30"), "Should include second tool result")
        }
    }
}
