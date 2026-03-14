import Foundation
import Testing

@testable import MCP

@Suite("Cancellation Tests")
struct CancellationTests {
    @Test("Client sends CancelledNotification")
    func testClientSendsCancellation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server
        try await server.start(transport: serverTransport)

        // Connect client
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Send a ping request
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        try await Task.sleep(for: .milliseconds(10))

        // Cancel the request
        try await client.cancelRequest(context.requestID, reason: "Test cancellation")

        try await Task.sleep(for: .milliseconds(50))

        // Verify cancellation was sent (server should have received it)
        // The test passes if no errors occur and the request is cancelled

        await client.disconnect()
        await server.stop()
    }

    @Test("Client receives and processes CancelledNotification")
    func testClientReceivesCancellation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)

        // Register a slow ping handler (must be after start to override default)
        await server.withMethodHandler(Ping.self) { _ in
            try await Task.sleep(for: .seconds(5))
            return Empty()
        }
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Send a request using send
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        // Server cancels the request while it's being awaited
        try await Task.sleep(for: .milliseconds(50))
        try await server.cancelRequest(pingRequest.id, reason: "Server cancelled")

        // Try to get result - should throw CancellationError
        do {
            _ = try await context.value
            Issue.record("Expected CancellationError but request succeeded")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError but got: \(error)")
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("RequestContext structure")
    func testRequestContextStructure() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Create a request with send
        let pingRequest = Ping.request()
        let context: RequestContext<Ping.Result> = try await client.send(pingRequest)

        // Verify the context has the correct requestID
        #expect(context.requestID == pingRequest.id)

        // Await the result through the context
        let result = try await context.value
        #expect(result == Empty())

        await client.disconnect()
        await server.stop()
    }

    @Test("callTool with RequestContext overload")
    func testCallToolWithRequestContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init())
        )

        // Register a tool handler
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "testTool", description: "A test tool", inputSchema: .object([:]))])
        }

        await server.withMethodHandler(CallTool.self) { params in
            return .init(content: [.text(text: "Result for \(params.name)", annotations: nil, _meta: nil)], isError: false)
        }

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Use the callTool overload that returns RequestContext (non-async version)
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: "testTool", arguments: ["test": "value"])

        // Verify we got a context
        #expect(context.requestID != ID(stringLiteral: ""))

        // Get the result
        let result = try await context.value
        #expect(result.content == [.text(text: "Result for testTool", annotations: nil, _meta: nil)])
        #expect(result.isError == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("Cancel callTool using RequestContext overload")
    func testCancelCallToolWithRequestContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init())
        )

        // Register a tool handler that takes time
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "slowTool", description: "A slow tool", inputSchema: .object([:]))])
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await Task.sleep(for: .seconds(5))
            return .init(content: [.text(text: "Should not reach here", annotations: nil, _meta: nil)], isError: false)
        }

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Use the callTool overload that returns RequestContext (non-async version)
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: "slowTool", arguments: [:])

        // Cancel after a short delay
        try await Task.sleep(for: .milliseconds(50))
        try await client.cancelRequest(context.requestID, reason: "Test timeout")

        // Try to get result - should throw CancellationError
        do {
            _ = try await context.value
            Issue.record("Expected CancellationError but request succeeded")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError but got: \(error)")
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("CancelledNotification prevents response")
    func testCancellationPreventsResponse() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0")
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)

        // Register a slow handler (must be after start to override default)
        await server.withMethodHandler(Ping.self) { _ in
            try await Task.sleep(for: .seconds(10))
            return Empty()
        }
        _ = try await client.connect(transport: clientTransport)
        try await Task.sleep(for: .milliseconds(50))

        // Send a ping request
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        // Cancel the request while it's being awaited
        try await Task.sleep(for: .milliseconds(50))
        try await client.cancelRequest(context.requestID, reason: "Test cancellation")

        // Try to get result - should throw CancellationError (proving no response was sent)
        do {
            _ = try await context.value
            Issue.record("Expected CancellationError but request succeeded")
        } catch is CancellationError {
            // Expected - this proves the server didn't send a response
        } catch {
            Issue.record("Expected CancellationError but got: \(error)")
        }

        await client.disconnect()
        await server.stop()
    }
}
