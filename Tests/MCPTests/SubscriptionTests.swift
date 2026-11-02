import Foundation
import Logging
import Testing

@testable import MCP

private func makeListenServer(
    capabilities: Server.Capabilities = .init(
        prompts: .init(listChanged: true), resources: .init(subscribe: true, listChanged: true),
        tools: .init(listChanged: true))
) -> Server {
    Server(name: "listen", version: "1.0", capabilities: capabilities)
}

/// Connects a stateless client to `server` over an in-memory pair.
private func connect(
    _ server: Server, mode: Client.ProtocolMode = .automatic
) async throws -> Client {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: mode))
    try await client.connect(transport: clientTransport)
    return client
}

/// Collects notifications of one type with their subscription id.
private actor Inbox {
    var received: [(method: String, subscriptionID: ID?)] = []
    func add(_ method: String, _ id: ID?) { received.append((method, id)) }
    var methods: [String] { received.map(\.method) }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private struct TimedOut: Error {}

/// Runs `body`, throwing ``TimedOut`` when it has not finished after
/// `limit`; a body that never returns is abandoned.
private func within<T: Sendable>(
    _ limit: Duration = .seconds(5), _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let (outcomes, outcome) = AsyncStream<Result<T, Swift.Error>>.makeStream()
    let work = Task {
        do { outcome.yield(.success(try await body())) } catch { outcome.yield(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        outcome.yield(.failure(TimedOut()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    for await result in outcomes { return try result.get() }
    throw TimedOut()
}

/// Connects a stateless client through `transport`, answering
/// `server/discover` with `capabilities`.
private func connect(_ transport: ListenScript, capabilities: String) async throws -> Client {
    let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
    let connecting = Task { try await client.connect(transport: transport) }
    let discover = try await transport.message(1)
    try await transport.reply(
        to: discover,
        #""result":{"supportedVersions":["2026-07-28"],"capabilities":\#(capabilities),"resultType":"complete"}"#)
    _ = try await within { try await connecting.value }
    return client
}

private func resourceSubscriptions(of listen: [String: Value]) -> Value? {
    listen["params"]?.objectValue?["notifications"]?.objectValue?["resourceSubscriptions"]
}

@Suite("Subscription Tests", .timeLimit(.minutes(1)))
struct SubscriptionTests {
    @Test("listen is acknowledged with the subset the server supports")
    func testAcknowledgement() async throws {
        let server = makeListenServer(capabilities: .init(tools: .init(listChanged: true)))
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let subscription = try await client.listen(
            .init(
                toolsListChanged: true, promptsListChanged: true, resourcesListChanged: true,
                resourceSubscriptions: ["test://a"]))
        #expect(subscription.notifications == SubscriptionFilter(toolsListChanged: true))
        await subscription.cancel()
    }

    @Test("Notifications reach listen streams that requested them, tagged with the stream id")
    func testDelivery() async throws {
        let server = makeListenServer()
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let inbox = Inbox()
        await client.onNotification(ToolListChangedNotification.self) { message in
            await inbox.add(ToolListChangedNotification.name, message._meta?.subscriptionID)
        }
        await client.onNotification(PromptListChangedNotification.self) { message in
            await inbox.add(PromptListChangedNotification.name, message._meta?.subscriptionID)
        }
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await inbox.add(message.params.uri, message._meta?.subscriptionID)
        }

        let subscription = try await client.listen(
            .init(toolsListChanged: true, resourceSubscriptions: ["test://watched"]))
        try await server.notify(PromptListChangedNotification.message())
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://other")))
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://watched")))
        try await server.notify(ToolListChangedNotification.message())

        // The handlers also open the automatic list-change stream; look at this one only.
        @Sendable func onStream() async -> [String] {
            await inbox.received.filter { $0.subscriptionID == subscription.id }.map(\.method)
        }
        #expect(await eventually { await onStream().count == 2 })
        #expect(await onStream() == ["test://watched", ToolListChangedNotification.name])
        await subscription.cancel()
    }

    @Test("Cancelling a subscription ends the server's stream")
    func testCancel() async throws {
        let server = makeListenServer()
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let subscription = try await client.listen(.init(toolsListChanged: true))
        #expect(await server.openSubscriptionCount == 1)
        await subscription.cancel()
        #expect(await eventually { await server.openSubscriptionCount == 0 })
        await #expect(throws: CancellationError.self) { try await subscription.finished() }
    }

    @Test("closeSubscriptions ends streams with the listen result")
    func testGracefulClose() async throws {
        let server = makeListenServer()
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let subscription = try await client.listen(.init(toolsListChanged: true))
        await server.closeSubscriptions()
        try await subscription.finished()
        #expect(await server.openSubscriptionCount == 0)
    }

    @Test("listen requires a stateless connection")
    func testHandshakeRejected() async throws {
        let server = makeListenServer()
        let client = try await connect(server, mode: .handshake)
        defer { Task { await client.disconnect(); await server.stop() } }

        await #expect(throws: MCPError.self) { try await client.listen(.init(toolsListChanged: true)) }
    }

    @Test("List changes are sent on the connection only to handshake sessions")
    func testNotifyByEra() async throws {
        for (mode, expected) in [(Client.ProtocolMode.handshake, 1), (.automatic, 0)] {
            let server = makeListenServer()
            let client = try await connect(server, mode: mode)
            let inbox = Inbox()
            await client.onNotification(ToolListChangedNotification.self) { message in
                await inbox.add(ToolListChangedNotification.name, message._meta?.subscriptionID)
            }
            try await server.notify(ToolListChangedNotification.message())
            // A later request flushes any notification sent before it.
            try await client.ping()
            #expect(await inbox.received.filter { $0.subscriptionID == nil }.count == expected)
            await client.disconnect()
            await server.stop()
        }
    }

    @Test("Filter and acknowledgement encode with spec member names")
    func testWire() throws {
        let filter = SubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["test://a"])
        expectWire(
            try Value(filter),
            matches: try wireJSON(#"{"toolsListChanged":true,"resourceSubscriptions":["test://a"]}"#))
        var meta = Metadata()
        meta.subscriptionID = .number(7)
        let ack = Message<SubscriptionsAcknowledgedNotification>(
            method: SubscriptionsAcknowledgedNotification.name, params: .init(notifications: filter),
            _meta: meta)
        expectWire(
            try Value(ack),
            matches: try wireJSON(
                #"{"method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["test://a"]},"_meta":{"io.modelcontextprotocol/subscriptionId":7}}}"#
            ))
    }

    // MARK: Automatic streams

    @Test("Handlers for list changes open a background listen stream")
    func testAutomaticListChangeStream() async throws {
        let server = makeListenServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        defer { Task { await client.disconnect(); await server.stop() } }

        let inbox = Inbox()
        await client.onNotification(ToolListChangedNotification.self) { message in
            await inbox.add(ToolListChangedNotification.name, message._meta?.subscriptionID)
        }
        try await client.connect(transport: clientTransport)
        #expect(await eventually { await server.openSubscriptionCount == 1 })
        try await server.notify(ToolListChangedNotification.message())
        #expect(await eventually { await inbox.methods == [ToolListChangedNotification.name] })
        #expect(await inbox.received.first?.subscriptionID != nil)

        // A new handler widens the stream; the old one is closed.
        await client.onNotification(PromptListChangedNotification.self) { message in
            await inbox.add(PromptListChangedNotification.name, message._meta?.subscriptionID)
        }
        #expect(
            await eventually {
                try? await server.notify(PromptListChangedNotification.message())
                return await inbox.methods.contains(PromptListChangedNotification.name)
            })
        #expect(await eventually { await server.openSubscriptionCount == 1 })

        await client.disconnect()
        #expect(await eventually { await server.openSubscriptionCount == 0 })
    }

    @Test("No automatic stream when the server does not send list changes")
    func testNoAutomaticStreamWithoutCapability() async throws {
        let server = makeListenServer(capabilities: .init(tools: .init()))
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }
        await client.onNotification(ToolListChangedNotification.self) { _ in }
        try await client.ping()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.openSubscriptionCount == 0)
    }

    @Test("Resource subscriptions share one background stream at 2026-07-28")
    func testResourceSubscriptions() async throws {
        let server = makeListenServer()
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let inbox = Inbox()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await inbox.add(message.params.uri, message._meta?.subscriptionID)
        }
        try await client.subscribeToResource(uri: "test://a")
        try await client.subscribeToResource(uri: "test://a")
        try await client.subscribeToResource(uri: "test://b")
        #expect(await client.subscribedResourceURIs == ["test://a", "test://b"])
        #expect(await eventually { await server.openSubscriptionCount == 1 })

        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://a")))
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://c")))
        #expect(await eventually { await inbox.methods == ["test://a"] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inbox.methods == ["test://a"])

        try await client.unsubscribeFromResource(uri: "test://a")
        try await client.unsubscribeFromResource(uri: "test://a")
        #expect(await eventually {
            await client.notificationStream?.notifications.resourceSubscriptions == ["test://b"]
        })
        #expect(await client.subscribedResourceURIs == ["test://b"])
        #expect(await eventually { await server.openSubscriptionCount == 1 })

        // A stream the server ends is forgotten, so subscribing reopens it.
        await server.closeSubscriptions()
        #expect(await eventually { await client.subscribedResourceURIs.isEmpty })
        try await client.subscribeToResource(uri: "test://b")
        #expect(await client.subscribedResourceURIs == ["test://b"])
        #expect(await eventually { await server.openSubscriptionCount == 1 })
    }

    @Test("subscribeToResource fails when the server does not send resource updates")
    func testResourceSubscriptionUnsupported() async throws {
        let server = makeListenServer(capabilities: .init(resources: .init(listChanged: true)))
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }
        await #expect(throws: MCPError.self) { try await client.subscribeToResource(uri: "test://a") }
        #expect(await client.subscribedResourceURIs.isEmpty)
        #expect(await eventually { await server.openSubscriptionCount == 0 })
    }

    @Test("A replacement stream that fails to open leaves the working stream open")
    func testFailedReplacementKeepsStream() async throws {
        let server = makeListenServer()
        await server.withSubscriptionAuthorizer { filter, _ in
            if filter.promptsListChanged == true { throw MCPError.invalidRequest("no prompts") }
            return filter
        }
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let inbox = Inbox()
        await client.onNotification(ToolListChangedNotification.self) { message in
            await inbox.add(message.method, message._meta?.subscriptionID)
        }
        #expect(await eventually { await server.openSubscriptionCount == 1 })
        await client.onNotification(PromptListChangedNotification.self) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.openSubscriptionCount == 1)

        try await server.notify(ToolListChangedNotification.message())
        #expect(await eventually { await inbox.methods == [ToolListChangedNotification.name] })
    }

    @Test("The reopen delay doubles from one second up to a minute")
    func testReopenDelay() {
        #expect(Client.notificationStreamDelay(failures: 1) == .seconds(1))
        #expect(Client.notificationStreamDelay(failures: 2) == .seconds(2))
        #expect(Client.notificationStreamDelay(failures: 4) == .seconds(8))
        #expect(Client.notificationStreamDelay(failures: 7) == .seconds(60))
        #expect(Client.notificationStreamDelay(failures: 1000) == .seconds(60))
    }

    @Test("A background stream that fails is reopened after a delay")
    func testFailedStreamReopens() async throws {
        let transport = ListenScript()
        let client = Client(name: "probe", version: "1.0", configuration: .init(protocolMode: .automatic))
        let connecting = Task { try await client.connect(transport: transport) }
        let discover = try await transport.message(1)
        try await transport.reply(
            to: discover,
            #""result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}},"resultType":"complete"}"#)
        _ = try await connecting.value
        defer { Task { await client.disconnect() } }

        await client.onNotification(ToolListChangedNotification.self) { _ in }
        let listen = try await transport.message(2)
        #expect(listen["method"] == "subscriptions/listen")
        try await transport.acknowledge(listen)
        try await transport.reply(to: listen, #""error":{"code":-32603,"message":"stream reset"}"#)

        let reopened = try await transport.message(3, timeout: .seconds(3))
        #expect(reopened["method"] == "subscriptions/listen")
        #expect(reopened["id"] != listen["id"])
    }

    @Test("The reopen delay keeps growing while acknowledged streams fail at once")
    func testReopenBackoffGrows() async throws {
        let transport = ListenScript()
        let client = try await connect(transport, capabilities: #"{"tools":{"listChanged":true}}"#)
        defer { Task { await client.disconnect() } }

        await client.onNotification(ToolListChangedNotification.self) { _ in }
        for (count, failures) in [(2, 1), (3, 2), (4, 3)] {
            let listen = try await transport.message(count, timeout: .seconds(4))
            #expect(listen["method"] == "subscriptions/listen")
            try await transport.acknowledge(listen)
            try await transport.reply(to: listen, #""error":{"code":-32603,"message":"stream reset"}"#)
            #expect(await eventually { await client.notificationStreamFailures == failures })
        }
        #expect(Client.notificationStreamDelay(failures: await client.notificationStreamFailures) == .seconds(4))
    }

    @Test("A failed reopen keeps the subscribed resources and retries")
    func testFailedReopenKeepsSubscriptions() async throws {
        let transport = ListenScript()
        let client = try await connect(transport, capabilities: #"{"resources":{"subscribe":true}}"#)
        defer { Task { await client.disconnect() } }

        let subscribing = Task { try await client.subscribeToResource(uri: "test://a") }
        let first = try await transport.message(2)
        try await transport.acknowledge(first, #"{"resourceSubscriptions":["test://a"]}"#)
        try await within { try await subscribing.value }

        // The stream fails, and so does its first reopening.
        try await transport.reply(to: first, #""error":{"code":-32603,"message":"stream reset"}"#)
        let second = try await transport.message(3, timeout: .seconds(3))
        #expect(resourceSubscriptions(of: second) == ["test://a"])
        try await transport.reply(to: second, #""error":{"code":-32603,"message":"restarting"}"#)

        let third = try await transport.message(4, timeout: .seconds(4))
        #expect(third["method"] == "subscriptions/listen")
        #expect(resourceSubscriptions(of: third) == ["test://a"])
        try await transport.acknowledge(third, #"{"resourceSubscriptions":["test://a"]}"#)
        #expect(await eventually { await client.subscribedResourceURIs == ["test://a"] })
    }

    @Test("A replaced stream delivers the notifications the client still wants")
    func testReplacedStreamDelivers() async throws {
        let transport = ListenScript()
        let client = try await connect(transport, capabilities: #"{"resources":{"subscribe":true}}"#)
        defer { Task { await transport.releaseCancellations(); await client.disconnect() } }

        let inbox = Inbox()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await inbox.add(message.params.uri, message._meta?.subscriptionID)
        }
        let subscribingA = Task { try await client.subscribeToResource(uri: "test://a") }
        let first = try await transport.message(2)
        try await transport.acknowledge(first, #"{"resourceSubscriptions":["test://a"]}"#)
        try await within { try await subscribingA.value }

        // The replaced stream stays open while its cancellation is held.
        await transport.holdCancellations()
        let subscribingB = Task { try await client.subscribeToResource(uri: "test://b") }
        let second = try await transport.message(3)
        try await transport.acknowledge(second, #"{"resourceSubscriptions":["test://a","test://b"]}"#)
        try await within { try await subscribingB.value }
        let cancel = try await transport.message(4)
        #expect(cancel["method"] == "notifications/cancelled")

        // Published before the server registered the successor, so only
        // the replaced stream carries them.
        try await transport.resourceUpdated("test://c", on: first)
        try await transport.resourceUpdated("test://a", on: first)
        try await transport.resourceUpdated("test://b", on: second)
        #expect(await eventually { await inbox.methods.contains("test://b") })
        #expect(await inbox.methods == ["test://a", "test://b"])
    }

    @Test("subscribeToResource fails during and after disconnect")
    func testSubscribeAroundDisconnect() async throws {
        let transport = ListenScript()
        let client = try await connect(transport, capabilities: #"{"resources":{"subscribe":true}}"#)

        let subscribing = Task { try await client.subscribeToResource(uri: "test://a") }
        let first = try await transport.message(2)
        try await transport.acknowledge(first, #"{"resourceSubscriptions":["test://a"]}"#)
        try await within { try await subscribing.value }

        // disconnect() waits while it closes the stream; subscribe meanwhile.
        await transport.holdCancellations()
        let closing = Task { await client.disconnect() }
        _ = try await transport.message(3)
        let during = Task { try await client.subscribeToResource(uri: "test://b") }
        _ = try await transport.message(4)
        await transport.releaseCancellations()
        await #expect(throws: MCPError.self) { try await within(.seconds(2)) { try await during.value } }
        try await within { await closing.value }

        await #expect(throws: MCPError.self) {
            try await within(.seconds(2)) { try await client.subscribeToResource(uri: "test://c") }
        }
    }

    @Test("Server caps listen streams and resource URIs, and removes duplicates")
    func testServerLimits() async throws {
        let server = Server(
            name: "listen", version: "1.0",
            capabilities: .init(resources: .init(subscribe: true), tools: .init(listChanged: true)),
            configuration: .init(maxSubscriptionStreams: 1, maxResourceSubscriptions: 2))
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let first = try await client.listen(.init(resourceSubscriptions: ["test://a", "test://a", "test://b"]))
        #expect(first.notifications.resourceSubscriptions == ["test://a", "test://b"])
        await #expect {
            _ = try await client.listen(.init(toolsListChanged: true))
        } throws: { error in
            (error as? MCPError)?.code == -32600
        }
        await first.cancel()
        #expect(await eventually { await server.openSubscriptionCount == 0 })
        await #expect {
            _ = try await client.listen(.init(resourceSubscriptions: ["test://a", "test://b", "test://c"]))
        } throws: { error in
            (error as? MCPError)?.code == -32602
        }
        let long = "test://" + String(repeating: "x", count: Server.maxSubscriptionURILength)
        await #expect(throws: MCPError.self) { _ = try await client.listen(.init(resourceSubscriptions: [long])) }
    }

    @Test("The subscription authorizer narrows the filter with the caller's context")
    func testAuthorizerNarrows() async throws {
        let server = makeListenServer()
        await server.withSubscriptionAuthorizer { filter, context in
            var narrowed = filter
            narrowed.resourceSubscriptions = filter.resourceSubscriptions?.filter { $0.hasPrefix("public://") }
            #expect(context.isStateless)
            return narrowed
        }
        let client = try await connect(server)
        defer { Task { await client.disconnect(); await server.stop() } }

        let subscription = try await client.listen(.init(resourceSubscriptions: ["public://a", "private://b"]))
        #expect(subscription.notifications.resourceSubscriptions == ["public://a"])
        await #expect(throws: MCPError.self) { try await client.subscribeToResource(uri: "private://c") }
        await subscription.cancel()
    }

    @Test("notify(_:to:) reaches only the streams of matching callers")
    func testTargetedNotify() async throws {
        let server = makeListenServer()
        let first = try await connect(server)
        defer { Task { await first.disconnect(); await server.stop() } }

        let inbox = Inbox()
        await first.onNotification(ResourceUpdatedNotification.self) { message in
            await inbox.add(message.params.uri, message._meta?.subscriptionID)
        }
        let subscription = try await first.listen(.init(resourceSubscriptions: ["test://a"]))
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://a")), to: { _ in false })
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "test://a")), to: { $0.clientInfo?.name == "probe" })
        #expect(await eventually { await inbox.received.count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(await inbox.received.count == 1)
        #expect(await inbox.received.first?.subscriptionID == subscription.id)
        await subscription.cancel()
    }
}

/// A transport that records what the client sends and replies by script.
private actor ListenScript: Transport {
    nonisolated let logger = Logger(label: "listen-script", factory: { _ in SwiftLogNoOpLogHandler() })
    private(set) var sent: [[String: Value]] = []
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var holdingCancellations = false
    private var heldCancellations: [CheckedContinuation<Void, Never>] = []

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    func connect() async throws {}
    func disconnect() async {
        releaseCancellations()
        continuation.finish()
    }
    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
    func send(_ data: Data) async throws {
        let message = try JSONDecoder().decode(Value.self, from: data).objectValue ?? [:]
        sent.append(message)
        if holdingCancellations, message["method"] == "notifications/cancelled" {
            await withCheckedContinuation { heldCancellations.append($0) }
        }
    }

    /// Makes sending `notifications/cancelled` wait until
    /// ``releaseCancellations()``.
    func holdCancellations() { holdingCancellations = true }

    func releaseCancellations() {
        holdingCancellations = false
        for held in heldCancellations { held.resume() }
        heldCancellations = []
    }

    /// Waits until `count` messages were sent and returns the last one.
    func message(_ count: Int, timeout: Duration = .seconds(2)) async throws -> [String: Value] {
        let deadline = ContinuousClock.now + timeout
        while sent.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(sent.dropFirst(count - 1).first)
    }

    func reply(to message: [String: Value], _ body: String) throws {
        let id = String(decoding: try JSONEncoder().encode(try #require(message["id"])), as: UTF8.self)
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),\#(body)}"#.utf8))
    }

    func acknowledge(_ listen: [String: Value], _ notifications: String = #"{"toolsListChanged":true}"#) throws {
        let id = String(decoding: try JSONEncoder().encode(try #require(listen["id"])), as: UTF8.self)
        continuation.yield(
            Data(
                #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":\#(notifications),"_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)}}}"#
                    .utf8))
    }

    /// Sends `notifications/resources/updated` for `uri` on the stream of `listen`.
    func resourceUpdated(_ uri: String, on listen: [String: Value]) throws {
        let id = String(decoding: try JSONEncoder().encode(try #require(listen["id"])), as: UTF8.self)
        continuation.yield(
            Data(
                #"{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"\#(uri)","_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)}}}"#
                    .utf8))
    }
}
