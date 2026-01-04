import Foundation
import Testing

@testable import MCP

@Suite("Server Tests")
struct ServerTests {
    @Test("Start and stop server")
    func testServerStartAndStop() async throws {
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        #expect(await transport.isConnected == false)
        try await server.start(transport: transport)
        #expect(await transport.isConnected == true)
        await server.stop()
        #expect(await transport.isConnected == false)
    }

    @Test("Initialize request handling")
    func testServerHandleInitialize() async throws {
        let transport = MockTransport()

        // Queue an initialize request
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Start the server
        let server: Server = Server(
            name: "TestServer",
            version: "1.0"
        )
        try await server.start(transport: transport)

        // Wait for message processing and response
        let received = await transport.waitForSentMessageCount(1)
        #expect(received, "Timed out waiting for initialize response")

        #expect(await transport.sentMessages.count == 1)

        let messages = await transport.sentMessages
        if let response = messages.first {
            #expect(response.contains("serverInfo"))
        }

        // Clean up
        await server.stop()
        await transport.disconnect()
    }

    @Test("Initialize hook - successful")
    func testInitializeHookSuccess() async throws {
        let transport = MockTransport()

        actor TestState {
            var hookCalled = false
            func setHookCalled() { hookCalled = true }
            func wasHookCalled() -> Bool { hookCalled }
        }

        let state = TestState()
        let server = Server(name: "TestServer", version: "1.0")

        // Start with the hook directly
        try await server.start(transport: transport) { clientInfo, capabilities in
            #expect(clientInfo.name == "TestClient")
            #expect(clientInfo.version == "1.0")
            await state.setHookCalled()
        }

        // Wait for server to initialize
        try await Task.sleep(for: .milliseconds(10))

        // Queue an initialize request
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Wait for message processing and hook execution
        try await Task.sleep(for: .milliseconds(500))

        #expect(await state.wasHookCalled() == true)
        #expect(await transport.sentMessages.count >= 1)

        let messages = await transport.sentMessages
        if let response = messages.first {
            #expect(response.contains("serverInfo"))
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test("Initialize hook - rejection")
    func testInitializeHookRejection() async throws {
        let transport = MockTransport()

        let server = Server(name: "TestServer", version: "1.0")

        try await server.start(transport: transport) { clientInfo, _ in
            if clientInfo.name == "BlockedClient" {
                throw MCPError.invalidRequest("Client not allowed")
            }
        }

        // Wait for server to initialize
        try await Task.sleep(for: .milliseconds(10))

        // Queue an initialize request from blocked client
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "BlockedClient", version: "1.0")
                )
            ))

        // Wait for message processing
        try await Task.sleep(for: .milliseconds(200))

        #expect(await transport.sentMessages.count >= 1)

        let messages = await transport.sentMessages
        if let response = messages.first {
            #expect(response.contains("error"))
            #expect(response.contains("Client not allowed"))
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test("JSON-RPC batch processing")
    func testJSONRPCBatchProcessing() async throws {
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        // Start the server
        try await server.start(transport: transport)

        // Initialize the server first
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            )
        )

        // Wait for server to initialize and respond
        try await Task.sleep(for: .milliseconds(100))

        // Clear sent messages
        await transport.clearMessages()

        // Create a batch with multiple requests
        let batchJSON = """
            [
                {"jsonrpc":"2.0","id":1,"method":"ping","params":{}},
                {"jsonrpc":"2.0","id":2,"method":"ping","params":{}}
            ]
            """
        let batch = try JSONDecoder().decode([AnyRequest].self, from: batchJSON.data(using: .utf8)!)

        // Send the batch request
        try await transport.queue(batch: batch)

        // Wait for batch processing
        try await Task.sleep(for: .milliseconds(100))

        // Verify response
        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 1)

        if let batchResponse = sentMessages.first {
            // Should be an array
            #expect(batchResponse.hasPrefix("["))
            #expect(batchResponse.hasSuffix("]"))

            // Should contain both request IDs
            #expect(batchResponse.contains("\"id\":1"))
            #expect(batchResponse.contains("\"id\":2"))
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test("Invalid JSON-RPC message returns error")
    func testInvalidJsonRpcMessageReturnsError() async throws {
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        try await server.start(transport: transport)

        // Initialize first
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            )
        )

        // Wait for init response
        let initReceived = await transport.waitForSentMessageCount(1)
        #expect(initReceived, "Timed out waiting for init response")
        await transport.clearMessages()

        // Send invalid JSON-RPC message (missing jsonrpc field)
        // This tests that the server properly validates incoming messages
        let invalidMessage = #"{"method":"ping","id":"1"}"#
        await transport.queueRaw(invalidMessage)

        // Wait for error response with polling instead of fixed sleep
        let errorReceived = await transport.waitForSentMessage { message in
            message.contains("error")
        }
        #expect(errorReceived, "Timed out waiting for error response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1)

        // Should get an error response
        if let response = messages.first {
            #expect(response.contains("error"))
        }

        await server.stop()
        await transport.disconnect()
    }

    // MARK: - Ping Before Initialization Tests
    // Based on Python SDK: test_ping_request_before_initialization

    @Test("Ping request allowed before initialization")
    func testPingRequestAllowedBeforeInitialization() async throws {
        // Per MCP spec, ping requests should be allowed before initialization
        // This is important for health checks and connection verification
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        try await server.start(transport: transport)

        // Send ping request BEFORE sending initialize request
        let pingRequest = """
            {"jsonrpc":"2.0","method":"ping","id":42}
            """
        await transport.queueRaw(pingRequest)

        // Wait for ping response
        let pingReceived = await transport.waitForSentMessage { message in
            message.contains("\"id\":42") || message.contains("\"id\": 42")
        }
        #expect(pingReceived, "Timed out waiting for ping response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1, "Should have received a response")

        // Verify we got a successful response (not an error about not being initialized)
        if let response = messages.first {
            #expect(response.contains("\"result\""), "Should have a result, not an error")
            #expect(!response.contains("\"error\""), "Should not be an error response")
        }

        await server.stop()
        await transport.disconnect()
    }

    // MARK: - Requests Before Initialization Behavior (Server level)
    //
    // MCP spec says clients "SHOULD NOT" send requests before initialization.
    // Swift SDK aligns with Python SDK behavior: blocks at Server level for all transports.
    //
    // SDK behavior comparison:
    // - Python: Blocks non-ping requests at session level (all transports)
    // - TypeScript: Server allows requests; HTTP transport blocks for session management
    // - Swift: Blocks non-ping requests at Server level (all transports) - matches Python
    //
    // We chose Python's approach for consistency across transports and better spec alignment.

    @Test("Server blocks non-ping requests before initialization (default strict mode)")
    func testServerBlocksRequestsBeforeInitialization() async throws {
        // MCP spec (lifecycle.mdx) says:
        // "The client SHOULD NOT send requests other than pings before the server
        // has responded to the initialize request."
        //
        // Swift SDK enforces this at the Server level (like Python), not just at
        // HTTP transport level (like TypeScript). This provides consistent behavior
        // across all transports.

        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(prompts: .init())
            // Uses default configuration which has strict: true
        )

        // Register a prompts handler
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [])
        }

        try await server.start(transport: transport)

        // Send prompts/list request BEFORE initialize
        let promptsRequest = """
            {"jsonrpc":"2.0","method":"prompts/list","id":1}
            """
        await transport.queueRaw(promptsRequest)

        // Wait for response
        let responseReceived = await transport.waitForSentMessage { message in
            message.contains("\"id\":1") || message.contains("\"id\": 1")
        }
        #expect(responseReceived, "Timed out waiting for response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1, "Should have received a response")

        // Server should reject the request with an error
        if let response = messages.first {
            #expect(response.contains("\"error\""), "Should be an error response")
            #expect(
                response.contains("not initialized") || response.contains("Server is not initialized"),
                "Error should indicate initialization required: \(response)"
            )
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test("Server allows requests before initialization in lenient mode")
    func testServerAllowsRequestsBeforeInitializationInLenientMode() async throws {
        // Lenient mode matches TypeScript SDK's server-level behavior
        let transport = MockTransport()
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(prompts: .init()),
            configuration: .lenient
        )

        // Register a prompts handler
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [])
        }

        try await server.start(transport: transport)

        // Send prompts/list request BEFORE initialize
        let promptsRequest = """
            {"jsonrpc":"2.0","method":"prompts/list","id":1}
            """
        await transport.queueRaw(promptsRequest)

        // Wait for response
        let responseReceived = await transport.waitForSentMessage { message in
            message.contains("\"id\":1") || message.contains("\"id\": 1")
        }
        #expect(responseReceived, "Timed out waiting for response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1, "Should have received a response")

        // Lenient mode: processes the request and returns result
        if let response = messages.first {
            #expect(response.contains("\"result\""), "Lenient mode should process requests before init")
        }

        await server.stop()
        await transport.disconnect()
    }

    // MARK: - Protocol Version Negotiation Tests
    // Based on Python SDK: test_server_session_initialize_with_older_protocol_version

    @Test("Server responds with client's requested protocol version when supported")
    func testServerRespondsWithClientRequestedProtocolVersion() async throws {
        // When a client requests an older but supported protocol version,
        // the server should respond with that version, not the latest
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        try await server.start(transport: transport)

        // Client requests older supported version
        let olderVersion = Version.v2024_11_05
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: olderVersion,
                    capabilities: .init(),
                    clientInfo: .init(name: "OlderClient", version: "1.0")
                )
            )
        )

        // Wait for response
        let received = await transport.waitForSentMessageCount(1)
        #expect(received, "Timed out waiting for initialize response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1)

        // Verify the server responded with the requested protocol version
        if let response = messages.first {
            #expect(response.contains("serverInfo"))
            #expect(response.contains("protocolVersion"))
            // Server should echo back the client's requested version
            #expect(
                response.contains("\"\(olderVersion)\""),
                "Server should respond with client's requested version \(olderVersion), got: \(response)"
            )
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test("Server defaults to latest version for unsupported client version")
    func testServerDefaultsToLatestForUnsupportedVersion() async throws {
        // When a client requests an unsupported version, server should use latest
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0")

        try await server.start(transport: transport)

        // Client requests unsupported version
        let unsupportedVersion = "2023-01-01"
        let request = Initialize.request(
            .init(
                protocolVersion: unsupportedVersion,
                capabilities: .init(),
                clientInfo: .init(name: "OldClient", version: "1.0")
            )
        )
        try await transport.queue(request: request)

        // Wait for response
        let received = await transport.waitForSentMessageCount(1)
        #expect(received, "Timed out waiting for initialize response")

        let messages = await transport.sentMessages
        #expect(messages.count >= 1)

        // Verify the server responded with the latest version (negotiation fallback)
        if let response = messages.first {
            #expect(response.contains("serverInfo"))
            #expect(response.contains("protocolVersion"))
            #expect(
                response.contains("\"\(Version.latest)\""),
                "Server should fall back to latest version for unsupported client version, got: \(response)"
            )
        }

        await server.stop()
        await transport.disconnect()
    }
}
