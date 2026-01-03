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
}
