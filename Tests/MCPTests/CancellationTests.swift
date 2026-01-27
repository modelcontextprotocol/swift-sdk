import Foundation
import Testing

@testable import MCP

@Suite("Cancellation Tests")
struct CancellationTests {
    @Test("Client sends CancelledNotification")
    func testClientSendsCancellation() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Setup initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        _ = try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(50))

        // Send a ping request
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        try await Task.sleep(for: .milliseconds(10))

        // Cancel the request
        try await client.cancelRequest(context.requestID, reason: "Test cancellation")

        try await Task.sleep(for: .milliseconds(10))

        // Check that cancellation notification was sent
        let messages = await transport.sentMessages
        let lastMessage = messages.last ?? ""
        // Note: JSON encoding may escape forward slashes
        #expect(
            lastMessage.contains("notifications/cancelled")
                || lastMessage.contains("notifications\\/cancelled"))
        #expect(lastMessage.contains(context.requestID.description))

        await client.disconnect()
        initTask.cancel()
    }

    @Test("Client receives and processes CancelledNotification")
    func testClientReceivesCancellation() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Setup initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        _ = try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(50))

        // Send a request using send
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        // Send cancellation notification from server
        let cancellationTask = Task {
            try await Task.sleep(for: .milliseconds(50))
            let cancellation = CancelledNotification.message(
                .init(requestId: pingRequest.id, reason: "Server cancelled")
            )
            try await transport.queue(notification: cancellation)
        }

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
        initTask.cancel()
        cancellationTask.cancel()
    }

    @Test("RequestContext structure")
    func testRequestContextStructure() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        // Setup initialize response
        let initTask = Task {
            try await Task.sleep(for: .milliseconds(10))
            if let lastMessage = await transport.sentMessages.last,
                let data = lastMessage.data(using: .utf8),
                let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
            {
                let response = Initialize.response(
                    id: request.id,
                    result: .init(
                        protocolVersion: Version.latest,
                        capabilities: .init(),
                        serverInfo: .init(name: "TestServer", version: "1.0"),
                        instructions: nil
                    )
                )
                try await transport.queue(response: response)
            }
        }

        _ = try await client.connect(transport: transport)
        try await Task.sleep(for: .milliseconds(50))

        // Create a request with send
        let pingRequest = Ping.request()
        let context: RequestContext<Ping.Result> = try await client.send(pingRequest)

        // Verify the context has the correct requestID
        #expect(context.requestID == pingRequest.id)

        // Queue a response
        let responseTask = Task {
            try await Task.sleep(for: .milliseconds(50))
            let response = Ping.response(id: pingRequest.id)
            try await transport.queue(response: response)
        }

        // Await the result through the context
        let result = try await context.value
        #expect(result == Empty())

        await client.disconnect()
        initTask.cancel()
        responseTask.cancel()
    }

    @Test("CancelledNotification prevents response")
    func testCancellationPreventsResponse() async throws {
        let transport = MockTransport()
        let server = Server(name: "TestServer", version: "1.0", configuration: .default)

        // Register a slow handler
        await server.withMethodHandler(Ping.self) { _ in
            try await Task.sleep(for: .seconds(10))
            return Empty()
        }

        try await server.start(transport: transport)
        try await Task.sleep(for: .milliseconds(50))

        // Initialize the server first
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Wait for initialization
        try await Task.sleep(for: .milliseconds(100))

        // Send a ping request
        let pingRequest = Ping.request()
        try await transport.queue(request: pingRequest)

        try await Task.sleep(for: .milliseconds(100))

        // Send cancellation notification
        let cancellation = CancelledNotification.message(
            .init(requestId: pingRequest.id, reason: "Test cancellation")
        )
        try await transport.queue(notification: cancellation)

        // Wait for cancellation to be processed
        try await Task.sleep(for: .milliseconds(200))

        // Check that no response was sent (only initialize response should exist)
        let messages = await transport.sentMessages
        let responseMessages = messages.filter { !$0.contains("Initialize") }

        // Should not contain a Ping response
        for message in responseMessages {
            #expect(!message.contains("\"method\":\"ping\""))
        }

        await server.stop()
    }
}
