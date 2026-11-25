import Foundation
import Logging
import Testing

@testable import MCP

// Regression tests for the request lifecycle: registration before send,
// handlers outside the receive loop, batches, and server error replies.

/// Records every message sent through a transport, in order.
private actor RecordingTransport: Transport {
    nonisolated let logger = Logger(label: "test.recording")
    private let base: any Transport
    private(set) var sent: [Value] = []

    init(_ base: any Transport) { self.base = base }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws {
        if let value = try? JSONDecoder().decode(Value.self, from: data) { sent.append(value) }
        try await base.send(data)
    }
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() { continuation.yield(data) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Methods of the sent messages, `nil` for responses.
    var methods: [String?] { sent.map { $0.objectValue?["method"]?.stringValue } }
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func makeServer(configuration: Server.Configuration = .default) async -> Server {
    let server = Server(
        name: "fixes", version: "1.0",
        capabilities: .init(logging: .init(), tools: .init()), configuration: configuration)
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [Tool(name: "era", description: nil, inputSchema: ["type": "object"])])
    }
    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "log":
            try await server.log(level: .info, data: "hello")
            return .init(content: [.text(text: "logged", annotations: nil, _meta: nil)])
        case "progress":
            if let token = params._meta?.progressToken {
                try await server.notify(ProgressNotification.message(.init(progressToken: token, progress: 1)))
            }
            return .init(content: [.text(text: "done", annotations: nil, _meta: nil)])
        case "sample":
            let result = try await server.requestSampling(
                messages: [.user(.text("Hi"))], maxTokens: 10)
            if case .text(let text)? = result.content.asArray.first {
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
            }
            return .init(content: [])
        case "confirm":
            guard params.inputResponses?["ok"]?.elicitation?.action == .accept else {
                return .inputRequired(["ok": .elicitation(message: "Proceed?")])
            }
            return .init(content: [.text(text: "confirmed", annotations: nil, _meta: nil)])
        default:
            let stateless = Server.currentHandlerContext?.isStateless == true
            return .init(content: [.text(text: stateless ? "stateless" : "handshake", annotations: nil, _meta: nil)])
        }
    }
    return server
}

private func text(_ result: CallTool.Result) -> String? {
    if case .text(let text, _, _)? = result.content.first { return text }
    return nil
}

@Suite("Request lifecycle", .timeLimit(.minutes(1)))
struct RequestLifecycleTests {
    @Test("cancelRequest right after send always cancels, and never overtakes the request")
    func cancelRightAfterSend() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let recorder = RecordingTransport(clientEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        try await client.connect(transport: recorder)

        for _ in 0..<20 {
            let context = try await client.send(Ping.request())
            try await client.cancelRequest(context.requestID)
            await #expect(throws: CancellationError.self) { _ = try await context.value }
        }
        // Every cancellation follows its request on the wire.
        let sent = await recorder.sent
        var seen: Set<String> = []
        for message in sent {
            let object = message.objectValue
            if let id = object?["id"], object?["method"]?.stringValue == Ping.name {
                seen.insert("\(id)")
            }
            if object?["method"]?.stringValue == CancelledNotification.name,
                let id = object?["params"]?.objectValue?["requestId"]
            {
                #expect(seen.contains("\(id)"))
            }
        }
        await client.disconnect()
        await server.stop()
    }

    @Test("A notification handler can wait for a request on the same client")
    func notificationHandlerAwaitsRequest() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let listed = Flag()
        await client.onNotification(LogMessageNotification.self) { _ in
            _ = try await client.listTools()
            await listed.set()
        }
        try await client.connect(transport: clientEnd)
        let (content, _) = try await client.callTool(name: "log")
        #expect(content == [.text(text: "logged", annotations: nil, _meta: nil)])
        #expect(await eventually { await listed.isSet })
        await client.disconnect()
        await server.stop()
    }

    @Test("A server-to-client request handler can wait for a request on the same client")
    func requestHandlerAwaitsRequest() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(
            name: "c", version: "1", capabilities: .init(sampling: .init()), configuration: .handshake)
        await client.withSamplingHandler { _ in
            let (tools, _) = try await client.listTools()
            return .init(model: "m", role: .assistant, content: .text("\(tools.count) tools"))
        }
        try await client.connect(transport: clientEnd)
        let (content, _) = try await client.callTool(name: "sample")
        #expect(content == [.text(text: "1 tools", annotations: nil, _meta: nil)])
        await client.disconnect()
        await server.stop()
    }

    @Test("The server cancels its request: the client handler stops and does not answer")
    func serverCancelsItsRequest() async throws {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await serverEnd.connect()
        let replies = await serverEnd.receive()
        let client = Client(
            name: "c", version: "1", capabilities: .init(roots: .init()), configuration: .handshake)
        let started = Flag()
        let cancelled = Flag()
        await client.withRootsHandler {
            await started.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await cancelled.set()
            }
            return []
        }

        let connecting = Task { try await client.connect(transport: clientEnd) }
        var iterator = replies.makeAsyncIterator()
        // Answer initialize by hand.
        let initialize = try JSONDecoder().decode(Value.self, from: try #require(await iterator.next()))
        let id = try #require(initialize.objectValue?["id"])
        let result = Initialize.Result(
            protocolVersion: Version.v2025_11_25, capabilities: .init(),
            serverInfo: .init(name: "s", version: "1"), instructions: nil)
        let response: Value = ["jsonrpc": "2.0", "id": id, "result": try Value(result)]
        try await serverEnd.send(try JSONEncoder().encode(response))
        _ = try await connecting.value
        _ = try await iterator.next()  // notifications/initialized

        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"r1","method":"roots/list"}"#.utf8))
        #expect(await eventually { await started.isSet })
        try await serverEnd.send(
            Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r1"}}"#.utf8))
        #expect(await eventually { await cancelled.isSet })

        // A ping still gets its answer, and it is the next message: no reply to r1.
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#.utf8))
        let next = try JSONDecoder().decode(Value.self, from: try #require(await iterator.next()))
        #expect(next.objectValue?["id"] == "p1")
        await client.disconnect()
    }

    @Test("Progress notifications of a request are handled before its response is delivered")
    func progressBeforeResponse() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let handled = Flag()
        await client.onNotification(ProgressNotification.self) { _ in
            try await Task.sleep(for: .milliseconds(50))
            await handled.set()
        }
        try await client.connect(transport: clientEnd)
        _ = try await client.callTool(name: "progress", meta: Metadata(progressToken: .unique()))
        #expect(await handled.isSet)
        await client.disconnect()
        await server.stop()
    }

    @Test("A notification handler can await a request started elsewhere")
    func handlerAwaitsOtherRequest() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let finished = Flag()
        let gate = AsyncStream<RequestContext<CallTool.Result>>.makeStream()
        await client.onNotification(LogMessageNotification.self) { _ in
            for await call in gate.stream {
                _ = try await call.value
                break
            }
            await finished.set()
        }
        try await client.connect(transport: clientEnd)
        // The handler for this log notification waits for a later call.
        _ = try await client.callTool(name: "log")
        let other = try await client.callTool(name: "era", meta: nil) as RequestContext<CallTool.Result>
        gate.continuation.yield(other)
        #expect(await eventually { await finished.isSet })
        await client.disconnect()
        await server.stop()
    }

    @Test("Handlers registered for notifications/cancelled run outside the receive loop")
    func cancelledHandlerMayAwait() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let answered = Flag()
        await client.onNotification(CancelledNotification.self) { _ in
            _ = try await client.callTool(name: "era")
            await answered.set()
        }
        try await client.connect(transport: clientEnd)
        try await server.notify(CancelledNotification.message(.init(requestId: "unknown", reason: nil)))
        #expect(await eventually { await answered.isSet })
        await client.disconnect()
        await server.stop()
    }

    @Test("Cancelling the task that awaits a request cancels the request")
    func cancellingTheTaskCancels() async throws {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await serverEnd.connect()
        var incoming = await serverEnd.receive().makeAsyncIterator()
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let connecting = Task { try await client.connect(transport: clientEnd) }
        let initialize = try JSONDecoder().decode(Value.self, from: try #require(await incoming.next()))
        let id = try #require(initialize.objectValue?["id"])
        let result = Initialize.Result(
            protocolVersion: Version.v2025_11_25, capabilities: .init(tools: .init()),
            serverInfo: .init(name: "s", version: "1"), instructions: nil)
        try await serverEnd.send(try JSONEncoder().encode(["jsonrpc": "2.0", "id": id, "result": try Value(result)] as Value))
        _ = try await connecting.value
        _ = try await incoming.next()  // notifications/initialized

        let context: RequestContext<CallTool.Result> = try await client.callTool(name: "slow")
        let call = try JSONDecoder().decode(Value.self, from: try #require(await incoming.next()))
        let waiter = Task { try await context.value }
        // The request is shared: another task that awaits it fails too.
        let other = Task { try await context.value }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        await #expect(throws: CancellationError.self) { _ = try await other.value }
        let cancel = try JSONDecoder().decode(Value.self, from: try #require(await incoming.next()))
        #expect(cancel.objectValue?["method"] == "notifications/cancelled")
        #expect(cancel.objectValue?["params"]?.objectValue?["requestId"] == call.objectValue?["id"])
        await client.disconnect()
    }

    @Test("cancelRequest during a later round of an exchange sends one notifications/cancelled")
    func cancelRoundOnce() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let retried = Flag()
        let retryCancelled = Flag()
        await server.withMethodHandler(CallTool.self) { params in
            guard params.inputResponses != nil else {
                return .inputRequired(["ok": .elicitation(message: "Proceed?")])
            }
            await retried.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await retryCancelled.set()
                throw error
            }
            return .init(content: [])
        }
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let recorder = RecordingTransport(clientEnd)
        let client = Client(name: "c", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { _ in .init(action: .accept, content: [:]) }
        try await client.connect(transport: recorder)
        #expect(await client.isStateless)

        let context = try await client.send(CallTool.request(.init(name: "slow")))
        #expect(await eventually { await retried.isSet })
        try await client.cancelRequest(context.requestID)
        await #expect(throws: (any Error).self) { _ = try await context.value }
        #expect(await eventually { await retryCancelled.isSet })
        // A second cancellation would go out before this later request.
        try await client.ping()
        let cancellations = await recorder.sent.filter {
            $0.objectValue?["method"]?.stringValue == CancelledNotification.name
        }
        #expect(cancellations.count == 1)
        await client.disconnect()
        await server.stop()
    }

    @Test("A connect replaced during discovery does not initialize the new connection")
    func connectReplacedDuringDiscovery() async throws {
        let (firstEnd, silentEnd) = await InMemoryTransport.createConnectedPair()
        try await silentEnd.connect()
        var probes = await silentEnd.receive().makeAsyncIterator()
        let client = Client(name: "c", version: "1")
        let connecting = Task { try await client.connect(transport: firstEnd) }
        let discover = try JSONDecoder().decode(Value.self, from: try #require(await probes.next()))
        #expect(discover.objectValue?["method"] == "server/discover")

        // The first discovery fails with the release of its connection.
        let server = await makeServer()
        let (secondEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let recorder = RecordingTransport(secondEnd)
        try await client.connect(transport: recorder)
        await #expect(throws: MCPError.internalError("Client disconnected")) { try await connecting.value }
        #expect(await client.isStateless)
        #expect(await !recorder.methods.contains(Initialize.name))
        await client.disconnect()
        await server.stop()
        await silentEnd.disconnect()
    }
}

@Suite("Server-to-client request limits", .timeLimit(.minutes(1)))
struct ServerToClientLimitTests {
    /// A raw server end with an initialized handshake client.
    private func connected(
        configuration: Client.Configuration = .handshake, capabilities: Client.Capabilities = .init(roots: .init())
    ) async throws -> (Client, InMemoryTransport, AsyncThrowingStream<Data, Swift.Error>.Iterator) {
        let client = Client(name: "c", version: "1", capabilities: capabilities, configuration: configuration)
        let (serverEnd, incoming) = try await connect(client)
        return (client, serverEnd, incoming)
    }

    /// Connects `client`, again if it is connected, to a new raw server end.
    private func connect(
        _ client: Client
    ) async throws -> (InMemoryTransport, AsyncThrowingStream<Data, Swift.Error>.Iterator) {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await serverEnd.connect()
        var incoming = await serverEnd.receive().makeAsyncIterator()
        let connecting = Task { try await client.connect(transport: clientEnd) }
        let initialize = try JSONDecoder().decode(Value.self, from: try #require(await incoming.next()))
        let id = try #require(initialize.objectValue?["id"])
        let result = Initialize.Result(
            protocolVersion: Version.v2025_11_25, capabilities: .init(),
            serverInfo: .init(name: "s", version: "1"), instructions: nil)
        try await serverEnd.send(try JSONEncoder().encode(["jsonrpc": "2.0", "id": id, "result": try Value(result)] as Value))
        _ = try await connecting.value
        _ = try await incoming.next()  // notifications/initialized
        return (serverEnd, incoming)
    }

    @Test("At most the configured number of handlers run at once; the rest wait")
    func concurrencyLimit() async throws {
        var configuration = Client.Configuration.handshake
        configuration.maxConcurrentServerRequests = 2
        let (client, serverEnd, incoming) = try await connected(configuration: configuration)
        var replies = incoming
        let running = Counter()
        let (release, open) = AsyncStream<Void>.makeStream()
        await client.withRootsHandler {
            await running.increment()
            for await _ in release { break }
            return []
        }
        for index in 0..<5 {
            try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"r\#(index)","method":"roots/list"}"#.utf8))
        }
        // Two start; the other three wait while those two run.
        let deadline = ContinuousClock.now + .seconds(30)
        while await running.value < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await running.value == 2)
        for _ in 0..<5 { open.yield() }
        var answered: Set<String> = []
        while answered.count < 5 {
            let reply = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
            if let id = reply.objectValue?["id"]?.stringValue { answered.insert(id) }
        }
        #expect(await running.value == 5)
        await client.disconnect()
    }

    @Test("A cancelled handler keeps its slot until it returns")
    func cancelledHandlerKeepsSlot() async throws {
        var configuration = Client.Configuration.handshake
        configuration.maxConcurrentServerRequests = 1
        let (client, serverEnd, incoming) = try await connected(configuration: configuration)
        var replies = incoming
        let running = Counter()
        let (release, open) = AsyncStream<Void>.makeStream()
        await client.withRootsHandler {
            await running.increment()
            // Ignores cancellation until released.
            await Task { for await _ in release { break } }.value
            return []
        }
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"a","method":"roots/list"}"#.utf8))
        #expect(await eventually { await running.value == 1 })
        try await serverEnd.send(
            Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a"}}"#.utf8))
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"b","method":"roots/list"}"#.utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await running.value == 1)
        open.yield()
        open.yield()
        let answered = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(answered.objectValue?["id"] == "b")
        #expect(await running.value == 2)
        await client.disconnect()
    }

    @Test("A handler still running after a reconnect keeps its slot")
    func reconnectKeepsDrainingSlot() async throws {
        var configuration = Client.Configuration.handshake
        configuration.maxConcurrentServerRequests = 1
        let (client, firstEnd, _) = try await connected(configuration: configuration)
        let running = Counter()
        let (release, open) = AsyncStream<Void>.makeStream()
        await client.withRootsHandler {
            await running.increment()
            // Ignores cancellation until released.
            await Task { for await _ in release { break } }.value
            return []
        }
        try await firstEnd.send(Data(#"{"jsonrpc":"2.0","id":"a","method":"roots/list"}"#.utf8))
        #expect(await eventually { await running.value == 1 })

        // The new connection cancels the old handler, which keeps running.
        let (secondEnd, incoming) = try await connect(client)
        var replies = incoming
        try await secondEnd.send(Data(#"{"jsonrpc":"2.0","id":"b","method":"roots/list"}"#.utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await running.value == 1)
        open.yield()
        open.yield()
        let answered = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(answered.objectValue?["id"] == "b")
        #expect(await running.value == 2)
        await client.disconnect()
    }

    @Test("A ping is answered while every handler slot is busy")
    func pingWhileBusy() async throws {
        var configuration = Client.Configuration.handshake
        configuration.maxConcurrentServerRequests = 1
        let (client, serverEnd, incoming) = try await connected(configuration: configuration)
        var replies = incoming
        let (release, open) = AsyncStream<Void>.makeStream()
        await client.withRootsHandler {
            for await _ in release { break }
            return []
        }
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"busy","method":"roots/list"}"#.utf8))
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#.utf8))
        let pong = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(pong.objectValue?["id"] == "p")
        #expect(pong.objectValue?["result"] == [:])
        open.yield()
        let answered = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(answered.objectValue?["id"] == "busy")
        await client.disconnect()
    }

    @Test("A request whose id is already running is refused")
    func duplicateID() async throws {
        let (client, serverEnd, incoming) = try await connected()
        var replies = incoming
        let (release, open) = AsyncStream<Void>.makeStream()
        await client.withRootsHandler {
            for await _ in release { break }
            return []
        }
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"dup","method":"roots/list"}"#.utf8))
        try await Task.sleep(for: .milliseconds(50))
        try await serverEnd.send(Data(#"{"jsonrpc":"2.0","id":"dup","method":"roots/list"}"#.utf8))
        let refused = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(refused.objectValue?["error"]?.objectValue?["code"] == -32600)
        open.yield()
        let answered = try JSONDecoder().decode(Value.self, from: try #require(await replies.next()))
        #expect(answered.objectValue?["result"] != nil)
        await client.disconnect()
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}


@Suite("Batches", .timeLimit(.minutes(1)))
struct BatchTests {
    @Test("Batched requests on a stateless connection carry _meta and run the round-trip loop")
    func statelessBatch() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { _ in .init(action: .accept, content: [:]) }
        try await client.connect(transport: clientEnd)
        #expect(await client.isStateless)

        nonisolated(unsafe) var era: Task<CallTool.Result, Error>?
        nonisolated(unsafe) var confirm: Task<CallTool.Result, Error>?
        try await client.withBatch { batch in
            era = try await batch.addRequest(CallTool.request(.init(name: "era")))
            confirm = try await batch.addRequest(CallTool.request(.init(name: "confirm")))
        }
        #expect(text(try await #require(era).value) == "stateless")
        #expect(text(try await #require(confirm).value) == "confirmed")
        await client.disconnect()
        await server.stop()
    }

    @Test("A batch at 2025-11-25 is sent as one array and answered")
    func handshakeBatch() async throws {
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let recorder = RecordingTransport(clientEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        try await client.connect(transport: recorder)

        nonisolated(unsafe) var tasks: [Task<CallTool.Result, Error>] = []
        try await client.withBatch { batch in
            for _ in 0..<3 {
                tasks.append(try await batch.addRequest(CallTool.request(.init(name: "era"))))
            }
        }
        for task in tasks {
            #expect(text(try await task.value) == "handshake")
        }
        #expect(await recorder.sent.contains { $0.arrayValue?.count == 3 })
        await client.disconnect()
        await server.stop()
    }

    @Test("A batch whose body throws fails the requests it added")
    func throwingBody() async throws {
        struct Stop: Error {}
        let server = await makeServer()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        try await client.connect(transport: clientEnd)

        nonisolated(unsafe) var added: Task<CallTool.Result, Error>?
        await #expect(throws: Stop.self) {
            try await client.withBatch { batch in
                added = try await batch.addRequest(CallTool.request(.init(name: "era")))
                throw Stop()
            }
        }
        await #expect(throws: Stop.self) { _ = try await #require(added).value }
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Server replies", .timeLimit(.minutes(1)))
struct ServerReplyTests {
    /// Sends raw lines to a started server; returns what it sent back
    /// within a short time.
    private func exchange(_ server: Server, _ lines: [String]) async throws -> [Value] {
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        try await clientEnd.connect()
        let replies = await clientEnd.receive()
        let collected = Task { () -> [Value] in
            var values: [Value] = []
            for try await data in replies {
                values.append(try JSONDecoder().decode(Value.self, from: data))
            }
            return values
        }
        for line in lines { try await clientEnd.send(Data(line.utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        await clientEnd.disconnect()
        await server.stop()
        return (try? await collected.value) ?? []
    }

    @Test("A strict server ignores a notification before initialize")
    func strictNotification() async throws {
        let server = await makeServer(configuration: .strict)
        let replies = try await exchange(server, [
            #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
        ])
        // Only the request is answered.
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["id"] == 7)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("A strict server takes notifications/cancelled from a 2026-07-28 client")
    func strictStatelessCancel() async throws {
        let server = Server(
            name: "strict", version: "1", capabilities: .init(tools: .init()), configuration: .strict)
        let started = Flag()
        let cancelled = Flag()
        await server.withMethodHandler(CallTool.self) { _ in
            await started.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await cancelled.set()
                throw error
            }
            return .init(content: [])
        }
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverEnd)
        let client = Client(name: "c", version: "1", configuration: .init(protocolMode: .automatic))
        try await client.connect(transport: clientEnd)
        #expect(await client.isStateless)
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: "slow")
        #expect(await eventually { await started.isSet })
        try await client.cancelRequest(context.requestID)
        #expect(await eventually { await cancelled.isSet })
        await client.disconnect()
        await server.stop()
    }

    @Test("A message that cannot be read is answered with a null id")
    func unreadableMessage() async throws {
        let server = await makeServer()
        let replies = try await exchange(server, [#"{"jsonrpc":"2.0","bogus":true}"#])
        #expect(replies.count == 1)
        #expect(replies.first?.objectValue?["id"] == .null)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32700)
    }

    @Test("An empty batch is answered with a null id")
    func emptyBatch() async throws {
        let server = await makeServer()
        let replies = try await exchange(server, ["[]"])
        #expect(replies.first?.objectValue?["id"] == .null)
        #expect(replies.first?.objectValue?["error"]?.objectValue?["code"] == -32600)
    }

    @Test("Behind the stateless HTTP transport every initialize is answered")
    func sessionlessInitialize() async throws {
        let server = await makeServer(configuration: .strict)
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        func post(_ body: String, version: String? = nil) async -> HTTPResponse {
            var headers = ["Content-Type": "application/json", "Accept": "application/json"]
            if let version { headers[HTTPHeaderName.protocolVersion] = version }
            return await transport.handleRequest(
                HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8)))
        }
        let initialize =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        for _ in 0..<3 {
            let response = await post(initialize)
            let body = try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
            #expect(body.objectValue?["result"]?.objectValue?["protocolVersion"] == "2025-06-18")
        }
        // A strict server serves handshake requests without a session.
        let call = await post(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"era"}}"#, version: "2025-06-18")
        let body = try JSONDecoder().decode(Value.self, from: try #require(call.bodyData))
        #expect(body.objectValue?["error"] == nil)

        // Without capabilities to check, a strict server lets the client
        // answer its requests: the sampling request goes out on the stream.
        var headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        headers[HTTPHeaderName.protocolVersion] = "2025-06-18"
        let sampling = Task {
            await transport.handleRequest(
                HTTPRequest(
                    method: "POST", headers: headers,
                    body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sample"}}"#.utf8)))
        }
        let response = await sampling.value
        guard case .stream(let events, _) = response else {
            Issue.record("expected an SSE stream, got \(response.statusCode)")
            await server.stop()
            return
        }
        for try await chunk in events {
            #expect(String(decoding: chunk, as: UTF8.self).contains("sampling/createMessage"))
            break
        }
        await server.stop()
    }

    /// A POST to a sessionless transport at a handshake revision, without
    /// `_meta` version.
    private func sessionlessPost(
        _ transport: StatelessHTTPServerTransport, _ body: String, version: String? = "2025-11-25",
        accept: String = "application/json", headers extra: [String: String] = [:]
    ) async -> HTTPResponse {
        var headers = ["Content-Type": "application/json", "Accept": accept]
        if let version { headers[HTTPHeaderName.protocolVersion] = version }
        headers.merge(extra) { $1 }
        return await transport.handleRequest(HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8)))
    }

    /// The JSON-RPC message of an SSE event.
    private func message(_ event: Data) throws -> Value {
        let text = String(decoding: event, as: UTF8.self)
        let data = text.split(separator: "\n").filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).drop(while: { $0 == " " }) }.joined(separator: "\n")
        return try JSONDecoder().decode(Value.self, from: Data(data.utf8))
    }

    @Test("Behind the stateless HTTP transport the round-trip bridge sends input requests")
    func sessionlessBridge() async throws {
        let server = await makeServer()
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let response = await sessionlessPost(
            transport, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"confirm"}}"#,
            accept: "application/json, text/event-stream")
        guard case .stream(let events, _) = response else {
            Issue.record("expected an SSE stream, got \(response.statusCode): \(response.bodyData.map { String(decoding: $0, as: UTF8.self) } ?? "")")
            return
        }
        var iterator = events.makeAsyncIterator()
        let elicitation = try message(try #require(await iterator.next()))
        #expect(elicitation.objectValue?["method"] == "elicitation/create")
        let id = try #require(elicitation.objectValue?["id"])
        let answer: Value = ["jsonrpc": "2.0", "id": id, "result": ["action": "accept", "content": [:]]]
        let accepted = await sessionlessPost(
            transport, String(decoding: try JSONEncoder().encode(answer), as: UTF8.self))
        #expect(accepted.statusCode == 202)
        let result = try message(try #require(await iterator.next()))
        #expect(result.objectValue?["id"] == 1)
        let content = result.objectValue?["result"]?.objectValue?["content"]?.arrayValue
        #expect(content?.first?.objectValue?["text"] == "confirmed")
    }

    @Test("Behind the stateless HTTP transport the hooks gate handshake requests")
    func sessionlessHooks() async throws {
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"era"}}"#
        let initialize =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        func error(_ response: HTTPResponse) throws -> Int? {
            let body = try JSONDecoder().decode(Value.self, from: try #require(response.bodyData))
            return body.objectValue?["error"]?.objectValue?["code"]?.intValue
        }

        // An initialize hook alone cannot gate requests without a session.
        let gated = await makeServer()
        let gatedTransport = StatelessHTTPServerTransport()
        try await gated.start(transport: gatedTransport, initializeHook: { _, _ in })
        #expect(try error(await sessionlessPost(gatedTransport, initialize, version: nil)) == nil)
        #expect(try error(await sessionlessPost(gatedTransport, call)) == -32600)
        await gated.stop()

        // The stateless hook runs before each of them, with the HTTP request.
        let hooked = await makeServer()
        let hookedTransport = StatelessHTTPServerTransport()
        try await hooked.start(
            transport: hookedTransport, initializeHook: { _, _ in },
            statelessRequestHook: { clientInfo, _ in
                #expect(clientInfo == nil)
                guard Server.currentHandlerContext?.httpContext?.header("Authorization") == "Bearer ok" else {
                    throw MCPError.invalidRequest("Not authorized")
                }
            })
        #expect(try error(await sessionlessPost(hookedTransport, initialize, version: nil)) == nil)
        #expect(try error(await sessionlessPost(hookedTransport, call)) == -32600)
        #expect(
            try error(await sessionlessPost(hookedTransport, call, headers: ["Authorization": "Bearer ok"])) == nil)
        await hooked.stop()
    }
}
