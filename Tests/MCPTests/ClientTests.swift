import Foundation
import Testing

@testable import MCP

@Suite("Client Tests")
struct ClientTests {
    @Test("Client connect and disconnect")
    func testClientConnectAndDisconnect() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        #expect(await transport.isConnected == false)
        try await client.connect(transport: transport)
        #expect(await transport.isConnected == true)
        await client.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test(
        "Initialize request",
        .timeLimit(.minutes(1))
    )
    func testClientInitialize() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(for: .milliseconds(10))

        // Create a task for initialize that we'll cancel
        let initTask = Task {
            try await client.initialize()
        }

        // Give it a moment to send the request
        try await Task.sleep(for: .milliseconds(10))

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages.first?.contains(Initialize.name) == true)
        #expect(await transport.sentMessages.first?.contains(client.name) == true)
        #expect(await transport.sentMessages.first?.contains(client.version) == true)

        // Cancel the initialize task
        initTask.cancel()

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test(
        "Ping request",
        .timeLimit(.minutes(1))
    )
    func testClientPing() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(for: .milliseconds(10))

        // Create a task for the ping that we'll cancel
        let pingTask = Task {
            try await client.ping()
        }

        // Give it a moment to send the request
        try await Task.sleep(for: .milliseconds(10))

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages.first?.contains(Ping.name) == true)

        // Cancel the ping task
        pingTask.cancel()

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Connection failure handling")
    func testClientConnectionFailure() async {
        let transport = MockTransport()
        await transport.setFailConnect(true)
        let client = Client(name: "TestClient", version: "1.0")

        do {
            try await client.connect(transport: transport)
            #expect(Bool(false), "Expected connection to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }

    @Test("Send failure handling")
    func testClientSendFailure() async throws {
        let transport = MockTransport()
        await transport.setFailSend(true)
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)

        do {
            try await client.ping()
            #expect(Bool(false), "Expected ping to fail")
        } catch let error as MCPError {
            if case MCPError.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }

    @Test("Strict configuration - capabilities check")
    func testStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.strict
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        try await client.connect(transport: transport)

        // Create a task for listPrompts
        let promptsTask = Task<Void, Swift.Error> {
            do {
                _ = try await client.listPrompts()
                #expect(Bool(false), "Expected listPrompts to fail in strict mode")
            } catch let error as MCPError {
                if case MCPError.methodNotFound = error {
                    #expect(Bool(true))
                } else {
                    #expect(Bool(false), "Expected methodNotFound error, got \(error)")
                }
            } catch {
                #expect(Bool(false), "Expected MCP.Error")
            }
        }

        // Give it a short time to execute the task
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task if it's still running
        promptsTask.cancel()

        // Disconnect client
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Non-strict configuration - capabilities check")
    func testNonStrictConfiguration() async throws {
        let transport = MockTransport()
        let config = Client.Configuration.default
        let client = Client(name: "TestClient", version: "1.0", configuration: config)

        try await client.connect(transport: transport)

        // Wait a bit for any setup to complete
        try await Task.sleep(for: .milliseconds(10))

        // Send the listPrompts request and immediately provide an error response
        let promptsTask = Task {
            do {
                // Start the request
                try await Task.sleep(for: .seconds(1))

                // Get the last sent message and extract the request ID
                if let lastMessage = await transport.sentMessages.last,
                    let data = lastMessage.data(using: .utf8),
                    let decodedRequest = try? JSONDecoder().decode(
                        Request<ListPrompts>.self, from: data)
                {

                    // Create an error response with the same ID
                    let errorResponse = Response<ListPrompts>(
                        id: decodedRequest.id,
                        error: MCPError.methodNotFound("Test: Prompts capability not available")
                    )
                    try await transport.queue(response: errorResponse)

                    // Try the request now that we have a response queued
                    do {
                        _ = try await client.listPrompts()
                        #expect(Bool(false), "Expected listPrompts to fail in non-strict mode")
                    } catch let error as MCPError {
                        if case MCPError.methodNotFound = error {
                            #expect(Bool(true))
                        } else {
                            #expect(Bool(false), "Expected methodNotFound error, got \(error)")
                        }
                    } catch {
                        #expect(Bool(false), "Expected MCP.Error")
                    }
                }
            } catch {
                // Ignore task cancellation
                if !(error is CancellationError) {
                    throw error
                }
            }
        }

        // Wait for the task to complete or timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .milliseconds(500))
            promptsTask.cancel()
        }

        // Wait for the task to complete
        _ = await promptsTask.result

        // Cancel the timeout task
        timeoutTask.cancel()

        // Disconnect client
        await client.disconnect()
    }
}
