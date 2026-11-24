import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@Suite("Client receive loop termination", .timeLimit(.minutes(1)))
struct ClientReceiveLoopTerminationTests {
    private func connectedClient(_ transport: EndableTransport) async throws -> Client {
        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        try await client.connect(transport: transport)
        return client
    }

    @Test(
        "A request in flight fails when the receive stream ends",
        arguments: [EndableTransport.StreamMode.shared, .freshPerReceive]
    )
    func inFlightRequestFailsWhenStreamEnds(mode: EndableTransport.StreamMode) async throws {
        let transport = EndableTransport(mode: mode)
        let client = try await connectedClient(transport)

        let context = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        await transport.finishStream()

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after the stream ended")
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
    }

    @Test(
        "The receive loop does not call receive() again after the stream ends",
        arguments: [EndableTransport.StreamMode.shared, .freshPerReceive]
    )
    func receiveLoopStopsWhenStreamEnds(mode: EndableTransport.StreamMode) async throws {
        let transport = EndableTransport(mode: mode)
        let client = try await connectedClient(transport)
        #expect(await transport.receiveCallCount == 1)

        let context = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        await transport.finishStream()
        _ = await outcome(within: .seconds(2)) { try await context.value }
        try await Task.sleep(for: .milliseconds(100))

        let count = await transport.receiveCallCount
        #expect(count == 1, "receive() was called \(count) times")

        await client.disconnect()
    }

    @Test("A request sent after the receive stream ended fails right away")
    func requestAfterStreamEndedFails() async throws {
        let transport = EndableTransport(mode: .shared)
        let client = try await connectedClient(transport)

        let first = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        await transport.finishStream()
        _ = await outcome(within: .seconds(2)) { try await first.value }

        let second = await outcome(within: .seconds(2)) { try await client.ping() }
        #expect(!second.didTimeOut, "the request never completed on a closed connection")
        // The client is disconnected once the transport has closed the connection.
        #expect(second.mcpError == .internalError("Client connection not initialized"))

        await client.disconnect()
    }

    @Test("A batch built while the connection closed fails and isn't sent")
    func batchRequestAfterConnectionClosedFails() async throws {
        let transport = EndableTransport(mode: .shared)
        let client = try await connectedClient(transport)
        let inFlight = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)

        let added = BatchTasks()
        await #expect(throws: MCPError.connectionClosed) {
            try await client.withBatch { batch in
                await added.append(try await batch.addRequest(Ping.request()))
                await transport.finishStream()
                // The request in flight fails once the client has handled the close.
                _ = await outcome(within: .seconds(2)) { try await inFlight.value }
                // Adding to a batch of a closed connection throws.
                await added.append(try await batch.addRequest(Ping.request()))
            }
        }
        #expect(await transport.sentBatchCount == 0)

        let tasks = await added.tasks
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        let result = await outcome(within: .seconds(2)) { try await task.value }
        #expect(!result.didTimeOut, "the batch request never completed on a closed connection")
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
    }

    @Test("A replaced connection closing does not affect the current one")
    func replacedConnectionClosingKeepsCurrentConnection() async throws {
        let first = EndableTransport(mode: .freshPerReceive)
        let second = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(first)
        try await client.connect(transport: second)

        let context = try await client.send(Ping.request())
        try await second.waitUntilSent(Ping.name)
        await first.finishStream()

        let early = await outcome(within: .milliseconds(200)) { try await context.value }
        #expect(early.didTimeOut, "closing the replaced connection failed a request on the current one")

        await second.finishStream()
        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
    }

    @Test("Connecting again disconnects the previous connection")
    func connectingAgainDisconnectsPreviousConnection() async throws {
        let first = EndableTransport(mode: .freshPerReceive)
        let second = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(first)

        let context = try await client.send(Ping.request())
        try await first.waitUntilSent(Ping.name)
        try await client.connect(transport: second)

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "a request on the previous connection never completed")
        #expect(result.mcpError == .internalError("Client disconnected"))
        #expect(await first.disconnectCount == 1)

        await client.disconnect()
    }

    @Test("A request handler can reconnect, and answers on the connection it came from")
    func requestHandlerCanReconnect() async throws {
        let first = EndableTransport(mode: .freshPerReceive)
        let second = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(first)

        let (reconnected, reconnectedContinuation) = AsyncStream<Void>.makeStream()
        // Not a ping: a ping runs outside the handler slots, while the
        // reconnect must spare the handler in its slot that called it.
        _ = await client.withMethodHandler(ListRoots.self) { _ in
            try await client.connect(transport: second)
            reconnectedContinuation.yield()
            return .init(roots: [])
        }

        let request = ListRoots.request()
        await first.deliverFromServer(try JSONEncoder().encode(request))

        let result = await outcome(within: .seconds(2)) {
            for await _ in reconnected { return true }
            return false
        }
        #expect(!result.didTimeOut, "connect(transport:) never returned inside the handler")
        try await first.waitUntilSentResponse(to: request.id)
        #expect(await second.sentResponseIDs.isEmpty)
        #expect(await second.sentMethods.contains(Initialize.name))
        #expect(await first.disconnectCount == 1)

        await client.disconnect()
    }

    @Test("disconnect() while connect() releases the previous connection stops the connect")
    func disconnectDuringReconnectWins() async throws {
        let first = EndableTransport(mode: .freshPerReceive)
        let second = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(first)
        await first.holdNextDisconnect()

        let connecting = Task { try await client.connect(transport: second) }
        try await first.waitUntilDisconnectIsHeld()
        await client.disconnect()
        await first.releaseHeldDisconnect()

        let result = await outcome(within: .seconds(2)) { try await connecting.value }
        #expect(result.mcpError == .internalError("Client disconnected"))
        #expect(await !second.sentMethods.contains(Initialize.name))
        #expect(await first.disconnectCount == 1)
    }

    @Test("A replaced message loop doesn't call receive() again after a retryable error")
    func replacedLoopStopsAfterRetryableError() async throws {
        let first = EndableTransport(mode: .freshPerReceive, finishesStreamOnDisconnect: false)
        let second = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(first)
        try await client.connect(transport: second)

        await first.finishStream(throwing: Errno.resourceTemporarilyUnavailable)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await first.receiveCallCount == 1)

        await client.disconnect()
    }

    @Test("A request in flight fails with the error the receive stream ended with")
    func inFlightRequestFailsWithStreamError() async throws {
        let transport = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(transport)

        let context = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        let failure = MCPError.transportError(POSIXError(.ECONNRESET))
        await transport.finishStream(throwing: failure)

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after the stream failed")
        #expect(result.mcpError == failure)

        await client.disconnect()
    }

    @Test("An error that is not an MCPError is reported as a transport error")
    func otherStreamErrorIsWrapped() async throws {
        struct StreamFailure: Error {}
        let transport = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(transport)

        let context = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        await transport.finishStream(throwing: StreamFailure())

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after the stream failed")
        #expect(result.mcpError == .transportError(StreamFailure()))

        await client.disconnect()
    }

    @Test("connect() fails when the receive stream ends before initialize is answered")
    func connectFailsWhenStreamEndsDuringInitialize() async throws {
        let transport = EndableTransport(mode: .shared, respondsToInitialize: false)
        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)

        let connecting = Task { try await client.connect(transport: transport) }
        try await transport.waitUntilSent(Initialize.name)
        await transport.finishStream()

        let result = await outcome(within: .seconds(2)) { try await connecting.value }
        #expect(!result.didTimeOut, "connect() never returned after the stream ended")
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
    }

    @Test("A request in flight on a stateless connection fails when the receive stream ends")
    func statelessInFlightRequestFailsWhenStreamEnds() async throws {
        let transport = EndableTransport(mode: .freshPerReceive, servesStateless: true)
        let client = Client(name: "TestClient", version: "1.0")
        // Opens the background listen stream.
        await client.onNotification(ToolListChangedNotification.self) { _ in }
        try await client.connect(transport: transport)
        #expect(await client.isStateless)
        let opened = await outcome(within: .seconds(2)) {
            while await client.notificationStream == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(!opened.didTimeOut, "the background listen stream never opened")

        let context = try await client.send(ListTools.request(.init()))
        try await transport.waitUntilSent(ListTools.name)
        await transport.finishStream()

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after the stream ended")
        #expect(result.mcpError == .connectionClosed)
        #expect(await client.notificationStream == nil)
        // The failed listen stream is not reopened on the closed connection.
        try await Task.sleep(for: Client.notificationStreamBaseDelay + .milliseconds(300))
        #expect(await transport.sentMethods.filter { $0 == SubscriptionsListen.name }.count == 1)

        await client.disconnect()
    }

    @Test("connect() fails when the receive stream ends before server/discover is answered")
    func automaticConnectFailsWhenStreamEndsDuringDiscovery() async throws {
        let transport = EndableTransport(mode: .shared, respondsToInitialize: false)
        let client = Client(name: "TestClient", version: "1.0")

        let connecting = Task { try await client.connect(transport: transport) }
        try await transport.waitUntilSent(ServerDiscover.name)
        await transport.finishStream()

        let result = await outcome(within: .seconds(2)) { try await connecting.value }
        #expect(!result.didTimeOut, "connect() never returned after the stream ended")
        #expect(result.mcpError == .connectionClosed)
        #expect(await !transport.sentMethods.contains(Initialize.name))

        await client.disconnect()
    }

    @Test("disconnect() still fails requests in flight with its own error")
    func disconnectKeepsItsError() async throws {
        let transport = EndableTransport(mode: .freshPerReceive)
        let client = try await connectedClient(transport)

        let context = try await client.send(Ping.request())
        try await transport.waitUntilSent(Ping.name)
        await client.disconnect()

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(result.mcpError == .internalError("Client disconnected"))
    }

    @Test("A stdio server closing its output fails the request in flight")
    func stdioEndOfFileFailsInFlightRequest() async throws {
        let (clientInput, serverOutput) = try FileDescriptor.pipe()
        let (serverInput, clientOutput) = try FileDescriptor.pipe()
        // Closing clientOutput also ends the fake server's blocking read if the
        // test fails early. serverOutput is closed below to send end of file.
        defer {
            try? clientOutput.close()
            try? serverInput.close()
            try? clientInput.close()
        }
        let transport = StdioTransport(input: clientInput, output: clientOutput, logger: nil)
        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)

        // Answers initialize, then reads notifications/initialized and the ping.
        let server = Task.detached {
            let initialize = try Self.readLine(from: serverInput)
            try serverOutput.writeAll(try Self.initializeResponse(to: initialize) + Data("\n".utf8))
            _ = try Self.readLine(from: serverInput)
            _ = try Self.readLine(from: serverInput)
        }

        try await client.connect(transport: transport)
        let context = try await client.send(Ping.request())
        let served = await outcome(within: .seconds(5)) { try await server.value }
        #expect(!served.didTimeOut && served.error == nil, "the fake server didn't read the ping")
        try serverOutput.close()

        let result = await outcome(within: .seconds(5)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after end of file")
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
    }

    @Test("An in-memory peer disconnecting fails the request in flight")
    func inMemoryPeerDisconnectFailsInFlightRequest() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await serverTransport.connect()

        // Answers initialize, reads notifications/initialized and the ping,
        // then disconnects.
        let server = Task {
            var messages = await serverTransport.receive().makeAsyncIterator()
            guard let initialize = try await messages.next() else { return }
            try await serverTransport.send(try Self.initializeResponse(to: initialize))
            _ = try await messages.next()
            _ = try await messages.next()
            await serverTransport.disconnect()
        }

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        try await client.connect(transport: clientTransport)
        let context = try await client.send(Ping.request())

        let result = await outcome(within: .seconds(2)) { try await context.value }
        #expect(!result.didTimeOut, "the request never completed after the peer disconnected")
        #expect(result.mcpError == .connectionClosed)

        await client.disconnect()
        _ = await outcome(within: .seconds(1)) { try await server.value }
    }

    private static func initializeResponse(to requestData: Data) throws -> Data {
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: requestData)
        let response = Initialize.response(
            id: request.id,
            result: .init(
                protocolVersion: Version.latest,
                capabilities: .init(),
                serverInfo: .init(name: "TestServer", version: "1.0"),
                instructions: nil
            )
        )
        return try JSONEncoder().encode(response)
    }

    /// Reads one newline-terminated message. The server ends of the pipes stay
    /// blocking; `StdioTransport` only changes the client ends.
    private static func readLine(from descriptor: FileDescriptor) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = try withUnsafeMutableBytes(of: &byte) { try descriptor.read(into: $0) }
            if count == 0 { throw MCPError.connectionClosed }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
        }
    }
}

/// Collects the tasks returned by `Batch.addRequest(_:)` inside a batch body.
private actor BatchTasks {
    private(set) var tasks: [Task<Ping.Result, Swift.Error>] = []

    func append(_ task: Task<Ping.Result, Swift.Error>) {
        tasks.append(task)
    }
}
