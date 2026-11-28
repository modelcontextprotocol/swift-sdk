import Foundation
import Logging
import Testing

@testable import MCP

@Suite("Cancellation Tests")
struct CancellationTests {
    @Test("Client sends CancelledNotification")
    func testClientSendsCancellation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server
        try await server.start(transport: serverTransport)

        let pingRequest = Ping.request()
        let received = Flag()
        await server.onNotification(CancelledNotification.self) { message in
            if message.params.requestId == pingRequest.id { await received.set() }
        }

        // Connect client
        _ = try await client.connect(transport: clientTransport)

        // Send a ping request
        let context = try await client.send(pingRequest)

        // Cancel the request
        try await client.cancelRequest(context.requestID, reason: "Test cancellation")

        // Verify cancellation was sent (server should have received it)
        #expect(await eventually { await received.isSet })

        await client.disconnect()
        await server.stop()
    }

    @Test("Cancelling connect does not cancel initialize on the wire")
    func testCancelledConnectSendsNoCancellation() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let connecting = Task { try await client.connect(transport: transport) }
        try await transport.waitForSentMessages()
        connecting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await connecting.value }
        try await Task.sleep(for: .milliseconds(100))
        let methods = await transport.sentData.compactMap {
            (try? JSONDecoder().decode(Value.self, from: $0))?.objectValue?["method"]?.stringValue
        }
        #expect(methods == [Initialize.name])
        await client.disconnect()
    }

    @Test("Client receives and processes CancelledNotification")
    func testClientReceivesCancellation() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)

        // Register a slow ping handler (must be after start to override default)
        let started = Flag()
        await server.withMethodHandler(Ping.self) { _ in
            await started.set()
            try await Task.sleep(for: .seconds(5))
            return Empty()
        }
        _ = try await client.connect(transport: clientTransport)

        // Send a request using send
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        // Server cancels the request while it's being awaited
        #expect(await eventually { await started.isSet })
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

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

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

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
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
            return .init(content: [.text(text: "Result for \(params.name)")], isError: false)
        }

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Use the callTool overload that returns RequestContext (non-async version)
        let context = try await client.startToolCall(name: "testTool", arguments: ["test": "value"])

        // Verify we got a context
        #expect(context.requestID != ID(stringLiteral: ""))

        // Get the result
        let result = try await context.value
        #expect(result.content == [.text(text: "Result for testTool")])
        #expect(result.isError == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("Cancel callTool using RequestContext overload")
    func testCancelCallToolWithRequestContext() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init())
        )

        // Register a tool handler that takes time
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [Tool(name: "slowTool", description: "A slow tool", inputSchema: .object([:]))])
        }

        let started = Flag()
        await server.withMethodHandler(CallTool.self) { params in
            await started.set()
            try await Task.sleep(for: .seconds(5))
            return .init(content: [.text(text: "Should not reach here")], isError: false)
        }

        // Start server and connect client
        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Use the callTool overload that returns RequestContext (non-async version)
        let context = try await client.startToolCall(name: "slowTool", arguments: [:])

        // Cancel once the tool is running
        #expect(await eventually { await started.isSet })
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

        let client = Client(name: "TestClient", version: "1.0", configuration: .handshake)
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init()
        )

        // Start server and connect client
        try await server.start(transport: serverTransport)

        // Register a slow handler (must be after start to override default)
        let started = Flag()
        await server.withMethodHandler(Ping.self) { _ in
            await started.set()
            try await Task.sleep(for: .seconds(10))
            return Empty()
        }
        _ = try await client.connect(transport: clientTransport)

        // Send a ping request
        let pingRequest = Ping.request()
        let context = try await client.send(pingRequest)

        // Cancel the request while it's being awaited
        #expect(await eventually { await started.isSet })
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

    @Test(
        "A cancellation that arrives before the handler is registered cancels it",
        .timeLimit(.minutes(1)))
    func testCancellationBeforeHandlerRegistration() async throws {
        let transport = GatedContextTransport(gating: .string("call-1"))
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            CallTool.Result(content: [.text(text: "ran", annotations: nil, _meta: nil)])
        }
        try await server.start(transport: transport)
        // Registered after the server's own handler, so it runs after it.
        await server.onNotification(CancelledNotification.self) { _ in
            transport.note("cancellation handled")
        }

        var events = transport.events.makeAsyncIterator()
        let encoder = JSONEncoder()
        await transport.deliver(
            try encoder.encode(CallTool.request(id: .string("call-1"), .init(name: "t"))))
        while let event = await events.next(), event != "context call-1" {}

        // The handler task is not registered while its context lookup waits.
        await transport.deliver(
            try encoder.encode(CancelledNotification.message(.init(requestId: .string("call-1")))))
        while let event = await events.next(), event != "cancellation handled" {}
        await transport.release()

        var outcome: String?
        while let event = await events.next() {
            if event.hasPrefix("sent ") || event == "log Request cancelled" {
                outcome = event
                break
            }
        }
        #expect(outcome == "log Request cancelled")
        await server.stop()
    }

    @Test(
        "A cancellation for a batched request that has not started yet is kept",
        .timeLimit(.minutes(1)))
    func testCancellationOfQueuedBatchRequest() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            if params.name == "first" {
                // The batch runs its items one after another: "second" waits for this.
                _ = await eventually { await gate.isOpen }
            }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let peer = RawPeer(clientEnd)
        try await peer.start()
        try await peer.initialize()

        try await peer.send(
            #"[{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"first"}},{"jsonrpc":"2.0","id":"b","method":"tools/call","params":{"name":"second"}}]"#
        )
        #expect(await eventually { await !gate.names.isEmpty })
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"b"}}"#)
        try await peer.sync("after-cancel")
        await gate.open()

        let batch = await peer.first { $0.arrayValue != nil }
        let ids = batch?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(ids == ["a"])
        #expect(await gate.names == ["first"])
        await peer.stop()
        await server.stop()
    }

    /// A raw peer, initialized at 2025-11-25, of `server` started on an
    /// in-memory pair.
    private func connect(_ server: Server) async throws -> RawPeer {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let peer = RawPeer(clientEnd)
        try await peer.start()
        try await peer.initialize()
        return peer
    }

    /// A `tools/call` request for the tool `name`, at 2026-07-28 when `stateless`.
    private func call(_ id: String, _ name: String, stateless: Bool = false) -> String {
        let meta =
            stateless
            ? #","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
            : ""
        return #"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(name)"\#(meta)}}"#
    }

    @Test(
        "A request whose id is in flight is refused with -32600, and the first is answered",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func testDuplicateInFlightIDIsRefused(stateless: Bool) async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            _ = await eventually { await gate.isOpen }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let peer = try await connect(server)

        try await peer.send(call("x", "first", stateless: stateless))
        #expect(await eventually { await gate.names == ["first"] })
        try await peer.send(call("x", "second", stateless: stateless))
        // The refusal is sent before the receive loop reads the ping.
        try await peer.sync("after-duplicate")
        let refusals = await peer.received.filter { $0.objectValue?["id"] == "x" }
        #expect(refusals.count == 1)
        let error = refusals.first?.objectValue?["error"]?.objectValue
        #expect(error?["code"] == -32600)
        #expect(error?["message"]?.stringValue?.contains("A request with id x is already in progress") == true)
        #expect(await gate.names == ["first"])

        await gate.open()
        let answered = await peer.first { $0.objectValue?["id"] == "x" && $0.objectValue?["result"] != nil }
        let content = answered?.objectValue?["result"]?.objectValue?["content"]?.arrayValue
        #expect(content?.first?.objectValue?["text"] == "first")
        try await peer.sync("after-answer")
        #expect(await peer.received.filter { $0.objectValue?["id"] == "x" }.count == 2)
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A refusal of an id in flight that cannot be sent is logged, and the next message is handled",
        .timeLimit(.minutes(1)))
    func testFailedRefusalIsLogged() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            _ = await eventually { await gate.isOpen }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let transport = ControlledSendTransport(failing: { $0.contains("already in progress") })
        try await server.start(transport: transport)
        var events = transport.events.makeAsyncIterator()

        await transport.deliver(call("x", "first"))
        #expect(await eventually { await gate.names == ["first"] })
        await transport.deliver(call("x", "second"))
        await transport.deliver(#"{"jsonrpc":"2.0","id":"after","method":"ping"}"#)

        // The receive loop sends the refusal before it reads the ping.
        var seen: [String] = []
        while let event = await events.next() {
            seen.append(event)
            if event.hasPrefix("sent "), event.contains(#""id":"after""#) { break }
        }
        #expect(seen.contains { $0.hasPrefix("failed ") && $0.contains("already in progress") })
        #expect(seen.contains("log Failed to send error response"))
        #expect(await gate.names == ["first"])
        await gate.open()
        await server.stop()
    }

    @Test(
        "A request may reuse an id once its response is sent, while the server still sends it",
        .timeLimit(.minutes(1)),
        arguments: [
            // Answered by its handler.
            #"{"jsonrpc":"2.0","id":"x","method":"ping"}"#,
            // Refused before a handler runs.
            #"{"jsonrpc":"2.0","id":"x","method":"unknown/method"}"#,
            // A listen stream refused before it opens: no teardown follows.
            #"{"jsonrpc":"2.0","id":"x","method":"subscriptions/listen","params":{"notifications":{}}}"#,
        ])
    func testIDIsFreeOnceItsResponseIsSent(first: String) async throws {
        let server = Server(name: "TestServer", version: "1.0")
        // The first reply for "x" reaches the client, and the server's send
        // of it does not return until the reuse was handled.
        let transport = ControlledSendTransport(holdingFirst: { $0.contains(#""id":"x""#) })
        try await server.start(transport: transport)
        var events = transport.events.makeAsyncIterator()

        await transport.deliver(first)
        while let event = await events.next(), !(event.hasPrefix("sent ") && event.contains(#""id":"x""#)) {}
        await transport.deliver(#"{"jsonrpc":"2.0","id":"x","method":"ping"}"#)

        var reply: Value?
        while let event = await events.next() {
            guard event.hasPrefix("sent "), event.contains(#""id":"x""#) else { continue }
            reply = try JSONDecoder().decode(Value.self, from: Data(event.dropFirst("sent ".count).utf8))
            break
        }
        #expect(reply?.objectValue?["error"] == nil)
        #expect(reply?.objectValue?["result"] != nil)
        await transport.release()
        await server.stop()
    }

    @Test(
        "Cancelling a request after a duplicate of its id was refused cancels its handler",
        .timeLimit(.minutes(1)))
    func testCancellationAfterRefusedDuplicate() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let started = BatchGate()
        let cancelled = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await started.ran(params.name)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await cancelled.ran(params.name)
                throw error
            }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let peer = try await connect(server)

        try await peer.send(call("x", "first"))
        #expect(await eventually { await started.names == ["first"] })
        try await peer.send(call("x", "second"))
        try await peer.sync("after-duplicate")
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"x"}}"#)
        #expect(await eventually { await cancelled.names == ["first"] })
        try await peer.sync("after-cancel")
        // Only the refusal: the cancelled request is not answered.
        let replies = await peer.received.filter { $0.objectValue?["id"] == "x" }
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32600)
        #expect(await started.names == ["first"])
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A batched request whose id is in flight or repeated in the batch is refused with -32600",
        .timeLimit(.minutes(1)))
    func testDuplicateIDsInBatchAreRefused() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            if params.name == "first" {
                _ = await eventually { await gate.isOpen }
            }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let peer = try await connect(server)

        try await peer.send(call("x", "first"))
        #expect(await eventually { await gate.names == ["first"] })
        try await peer.send("[\(call("x", "in-flight")),\(call("y", "other")),\(call("y", "repeated"))]")
        let batch = try #require(await peer.first { $0.arrayValue != nil }?.arrayValue)
        let replies = batch.map { reply in
            let object = reply.objectValue
            return "\(object?["id"]?.stringValue ?? "-") \(object?["error"]?.objectValue?["code"]?.intValue ?? 0)"
        }
        #expect(replies == ["x -32600", "y 0", "y -32600"])
        #expect(await gate.names == ["first", "other"])

        await gate.open()
        let answered = await peer.first { $0.objectValue?["id"] == "x" && $0.objectValue?["result"] != nil }
        #expect(answered != nil)
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A handler that returns after its request was cancelled sends no response",
        .timeLimit(.minutes(1)))
    func testSwallowedCancellationSendsNoResponse() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let started = Flag()
        let swallowed = Flag()
        await server.withMethodHandler(CallTool.self) { params in
            await started.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Returns a result although it was cancelled.
                await swallowed.set()
            }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let peer = try await connect(server)

        try await peer.send(call("x", "swallow"))
        #expect(await eventually { await started.isSet })
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"x"}}"#)
        #expect(await eventually { await swallowed.isSet })
        // The handler's result would be sent before the answer to this ping.
        try await peer.sync("after-cancel")
        #expect(await peer.received.contains { $0.objectValue?["id"] == "x" } == false)
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A batched handler that returns after its request was cancelled adds no reply",
        .timeLimit(.minutes(1)))
    func testSwallowedCancellationInBatchAddsNoReply() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            if params.name == "swallow" {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // Returns a result although it was cancelled.
                }
            }
            return CallTool.Result(content: [.text(text: params.name, annotations: nil, _meta: nil)])
        }
        let peer = try await connect(server)

        try await peer.send("[\(call("a", "swallow")),\(call("b", "other"))]")
        #expect(await eventually { await gate.names == ["swallow"] })
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a"}}"#)

        let batch = await peer.first { $0.arrayValue != nil }
        let ids = batch?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(ids == ["b"])
        await peer.stop()
        await server.stop()
    }

    @Test(
        "A request that reuses the id of a cancelled request still running can be cancelled",
        .timeLimit(.minutes(1)))
    func testReusedIDOfCancelledRequestCanBeCancelled() async throws {
        let server = Server(name: "TestServer", version: "1.0", capabilities: .init(tools: .init()))
        let gate = BatchGate()
        let cancelled = BatchGate()
        let firstReturned = Flag()
        await server.withMethodHandler(CallTool.self) { params in
            await gate.ran(params.name)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await cancelled.ran(params.name)
                if params.name == "first" {
                    // Keeps running after its cancellation until the gate opens.
                    _ = await eventually { await gate.isOpen }
                    await firstReturned.set()
                    return CallTool.Result(content: [])
                }
                throw error
            }
            return CallTool.Result(content: [])
        }
        let peer = try await connect(server)

        try await peer.send(call("x", "first"))
        #expect(await eventually { await gate.names == ["first"] })
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"x"}}"#)
        #expect(await eventually { await cancelled.names == ["first"] })

        // The client may use the id again: the request is no longer in flight.
        try await peer.send(call("x", "second"))
        #expect(await eventually { await gate.names == ["first", "second"] })
        // The first request ends; its cleanup leaves the second's entry.
        await gate.open()
        #expect(await eventually { await firstReturned.isSet })
        try await peer.sync("after-first")
        try await peer.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"x"}}"#)
        #expect(await eventually { await cancelled.names == ["first", "second"] })
        try await peer.sync("after-second")
        #expect(await peer.received.contains { $0.objectValue?["id"] == "x" } == false)
        await peer.stop()
        await server.stop()
    }
}

private actor BatchGate {
    private(set) var isOpen = false
    private(set) var names: [String] = []
    func open() { isOpen = true }
    func ran(_ name: String) { names.append(name) }
}

/// A transport whose HTTP context lookup for one request waits until the
/// test releases it. It reports the context lookup, every message the server
/// sends and every message the server logs as events.
private actor GatedContextTransport: Transport, HTTPContextProviding {
    nonisolated let logger: Logger
    nonisolated let events: AsyncStream<String>
    private nonisolated let eventSink: AsyncStream<String>.Continuation
    private let incoming: AsyncThrowingStream<Data, Swift.Error>
    private let incomingSink: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let gatedID: ID
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(gating id: ID) {
        let (events, eventSink) = AsyncStream<String>.makeStream()
        self.events = events
        self.eventSink = eventSink
        logger = Logger(label: "mcp.test.gated") { _ in EventLogHandler(sink: eventSink) }
        (incoming, incomingSink) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        gatedID = id
    }

    func connect() async throws {}

    func disconnect() async {
        incomingSink.finish()
        release()
    }

    func send(_ data: Data) async throws {
        eventSink.yield("sent " + String(decoding: data, as: UTF8.self))
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { incoming }

    func deliver(_ data: Data) { incomingSink.yield(data) }

    nonisolated func note(_ event: String) { eventSink.yield(event) }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    func httpRequestContext(for id: ID) async -> HTTPRequest? {
        guard id == gatedID, !released else { return nil }
        eventSink.yield("context \(id)")
        await withCheckedContinuation { gate = $0 }
        return nil
    }
}

/// A transport that reports every message the server sends, or fails to
/// send, and every message it logs as events. A send that `failing` matches
/// throws. The first send that `holdingFirst` matches is reported, as if it
/// reached the client, and then waits in `send` until the test releases it.
private actor ControlledSendTransport: Transport {
    nonisolated let logger: Logger
    nonisolated let events: AsyncStream<String>
    private nonisolated let eventSink: AsyncStream<String>.Continuation
    private let incoming: AsyncThrowingStream<Data, Swift.Error>
    private let incomingSink: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var holding: (@Sendable (String) -> Bool)?
    private let failing: @Sendable (String) -> Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(
        holdingFirst holding: (@Sendable (String) -> Bool)? = nil,
        failing: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        let (events, eventSink) = AsyncStream<String>.makeStream()
        self.events = events
        self.eventSink = eventSink
        logger = Logger(label: "mcp.test.controlled-send") { _ in EventLogHandler(sink: eventSink) }
        (incoming, incomingSink) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.holding = holding
        self.failing = failing
    }

    func connect() async throws {}

    func disconnect() async {
        incomingSink.finish()
        release()
    }

    func send(_ data: Data) async throws {
        let message = String(decoding: data, as: UTF8.self)
        if failing(message) {
            eventSink.yield("failed " + message)
            throw MCPError.internalError("Send failed")
        }
        eventSink.yield("sent " + message)
        if !released, let holding, holding(message) {
            self.holding = nil
            await withCheckedContinuation { held.append($0) }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { incoming }

    func deliver(_ data: String) { incomingSink.yield(Data(data.utf8)) }

    func release() {
        released = true
        for send in held { send.resume() }
        held = []
    }
}

/// Reports each log message as a `log <message>` event.
private struct EventLogHandler: LogHandler {
    let sink: AsyncStream<String>.Continuation
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        sink.yield("log \(message)")
    }
}
