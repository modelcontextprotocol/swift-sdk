import Foundation
import Logging
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
                    protocolVersion: Version.latestHandshake,
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
        try await transport.waitForSentMessages()

        #expect(await transport.sentMessages.count == 1)

        let messages = await transport.sentMessages
        if let response = messages.first {
            #expect(response.contains("serverInfo"))
        }

        // Clean up
        await server.stop()
        await transport.disconnect()
    }

    @Test("Initialize response includes server metadata")
    func testServerInitializeMetadata() async throws {
        let transport = MockTransport()
        let icons = [
            Icon(
                src: "https://example.com/icon-light.png",
                mimeType: "image/png",
                sizes: ["48x48"],
                theme: .light
            ),
            Icon(
                src: "https://example.com/icon-dark.svg",
                mimeType: "image/svg+xml",
                sizes: ["any"],
                theme: .dark
            ),
        ]
        let server = Server(
            name: "TestServer",
            version: "1.0",
            title: "Test Server",
            description: "A server used for testing",
            websiteUrl: "https://example.com",
            icons: icons,
            instructions: "Use this server for tests"
        )

        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latestHandshake,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))
        try await server.start(transport: transport)
        try await Task.sleep(for: .milliseconds(200))

        let response: Response<Initialize>? = await transport.decodeLastSentMessage()
        let result = try #require(response).result.get()
        #expect(result.serverInfo.name == "TestServer")
        #expect(result.serverInfo.version == "1.0")
        #expect(result.serverInfo.title == "Test Server")
        #expect(result.serverInfo.description == "A server used for testing")
        #expect(result.serverInfo.websiteUrl == "https://example.com")
        #expect(result.serverInfo.icons == icons)
        #expect(result.instructions == "Use this server for tests")

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
                    protocolVersion: Version.latestHandshake,
                    capabilities: .init(),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Wait for message processing and hook execution
        try await transport.waitForSentMessages()

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
                    protocolVersion: Version.latestHandshake,
                    capabilities: .init(),
                    clientInfo: .init(name: "BlockedClient", version: "1.0")
                )
            ))

        // Wait for message processing
        try await transport.waitForSentMessages()

        #expect(await transport.sentMessages.count >= 1)

        let messages = await transport.sentMessages
        if let response = messages.first {
            #expect(response.contains("error"))
            #expect(response.contains("Client not allowed"))
        }

        await server.stop()
        await transport.disconnect()
    }

    @Test(
        "Initialize hook - gates clients in both protocol modes",
        arguments: [Client.ProtocolMode.handshake, .automatic])
    func testInitializeHookGatesClient(mode: Client.ProtocolMode) async throws {
        actor Seen {
            var names: [String] = []
            func add(_ name: String) { names.append(name) }
        }
        actor ServerList {
            var all: [Server] = []
            func add(_ server: Server) { all.append(server) }
        }
        let seen = Seen()
        let servers = ServerList()
        func connect(_ name: String) async throws -> Client {
            let server = Server(name: "TestServer", version: "1.0")
            await servers.add(server)
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: serverTransport) { clientInfo, _ in
                await seen.add(clientInfo.name)
                if clientInfo.name == "BlockedClient" {
                    throw MCPError.invalidRequest("Client not allowed")
                }
            }
            let client = Client(name: name, version: "1.0", configuration: .init(protocolMode: mode))
            try await client.connect(transport: clientTransport)
            return client
        }

        // Without a stateless request hook, an `.automatic` client cannot
        // bypass the initialize hook: it falls back to `initialize`.
        let allowed = try await connect("AllowedClient")
        #expect(await allowed.negotiatedProtocolVersion == Version.v2025_11_25)
        await allowed.disconnect()

        do {
            _ = try await connect("BlockedClient")
            Issue.record("Expected the initialize hook to refuse the client")
        } catch let error as MCPError {
            #expect(error.code == -32600)
            #expect(error.localizedDescription.contains("Client not allowed"))
        }
        #expect(await seen.names == ["AllowedClient", "BlockedClient"])
        for server in await servers.all { await server.stop() }
    }

    @Test("JSON-RPC batch processing")
    func testJSONRPCBatchProcessing() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "TestServer", version: "1.0")

        // Connect transports
        try await clientTransport.connect()
        try await serverTransport.connect()

        // Start receiving messages on client side
        let receiveTask = Task {
            var responses: [String] = []
            for try await data in await clientTransport.receive() {
                if let response = String(data: data, encoding: .utf8) {
                    responses.append(response)
                }
                // Stop after receiving 2 responses (initialize + batch)
                if responses.count == 2 {
                    break
                }
            }
            return responses
        }

        // Start the server
        try await server.start(transport: serverTransport)

        // Initialize the server first
        let initRequest = Initialize.request(
            .init(
                protocolVersion: Version.latestHandshake,
                capabilities: .init(),
                clientInfo: .init(name: "TestClient", version: "1.0")
            )
        )
        let initData = try JSONEncoder().encode(AnyRequest(initRequest))
        try await clientTransport.send(initData)

        // Wait for initialization
        try await Task.sleep(for: .milliseconds(100))

        // Create a batch with multiple requests
        let batchJSON = """
            [
                {"jsonrpc":"2.0","id":1,"method":"ping","params":{}},
                {"jsonrpc":"2.0","id":2,"method":"ping","params":{}}
            ]
            """
        let batchData = batchJSON.data(using: .utf8)!
        try await clientTransport.send(batchData)

        // Wait for batch processing
        try await Task.sleep(for: .milliseconds(200))

        // Get responses
        let responses = try await receiveTask.value
        #expect(responses.count == 2)

        // Verify the batch response (second response)
        if responses.count >= 2 {
            let batchResponse = responses[1]

            // Should be an array
            #expect(batchResponse.hasPrefix("["))
            #expect(batchResponse.hasSuffix("]"))

            // Should contain both request IDs
            #expect(batchResponse.contains("\"id\":1"))
            #expect(batchResponse.contains("\"id\":2"))
        }

        await server.stop()
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }
}

@Suite("Server default handlers")
struct ServerDefaultHandlerTests {
    @Test("a stopped server and client are released")
    func released() async throws {
        weak var weakServer: Server?
        weak var weakClient: Client?
        do {
            let server = Server(name: "s", version: "1", capabilities: .init(logging: .init(), tools: .init()))
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: serverTransport)
            let client = Client(name: "c", version: "1", configuration: .handshake)
            try await client.connect(transport: clientTransport)
            _ = try await client.listTools()
            await client.disconnect()
            await server.stop()
            weakServer = server
            weakClient = client
        }
        // The receive loops end shortly after the transports close.
        for _ in 0..<500 where weakServer != nil || weakClient != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakServer == nil)
        #expect(weakClient == nil)
    }

    @Test("start keeps a handler registered before it")
    func startKeepsHandlers() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let pinged = AsyncStream<Void>.makeStream()
        await server.withMethodHandler(Ping.self) { _ in
            pinged.continuation.yield()
            return Empty()
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        try await client.connect(transport: clientTransport)
        try await client.ping()
        // The handler ran before the response: without it, next() returns nil.
        pinged.continuation.finish()
        var iterator = pinged.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("logging/setLevel filters log messages on a handshake connection")
    func setLevelFilters() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(logging: .init(), tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            try await server.log(level: .debug, data: "hidden")
            try await server.log(level: .warning, data: "shown")
            return .init(content: [])
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "c", version: "1", configuration: .handshake)
        let received = AsyncStream<String>.makeStream()
        await client.onNotification(LogMessageNotification.self) { message in
            received.continuation.yield(message.params.data.stringValue ?? "")
        }
        try await client.connect(transport: clientTransport)
        try await client.setLoggingLevel(.info)
        _ = try await client.callTool(name: "log")
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == "shown")
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Server lifecycle")
struct ServerLifecycleTests {
    @Test("restarting a server keeps one notifications/cancelled handler")
    func oneCancellationHandler() async throws {
        let server = Server(name: "s", version: "1")
        let log = LogCollector()
        for round in 0..<3 {
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair(
                logger: Logger(label: "mcp.test.lifecycle") { _ in log })
            let peer = RawPeer(clientTransport)
            try await peer.start()
            try await server.start(transport: serverTransport)
            if round == 2 {
                try await peer.send(
                    #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"gone"}}"#)
                try await peer.sync("after")
            }
            await server.stop()
            await peer.stop()
        }
        #expect(log.count(of: "Received cancellation notification") == 1)
    }

    @Test("stop cancels the handlers still running")
    func stopCancelsHandlers() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let (ended, endedSink) = AsyncStream<Bool>.makeStream()
        await server.withMethodHandler(CallTool.self) { _ in
            startedSink.yield()
            do {
                try await Task.sleep(for: .seconds(30))
                endedSink.yield(false)
            } catch {
                endedSink.yield(Task.isCancelled)
            }
            return .init(content: [])
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let peer = RawPeer(clientTransport)
        try await peer.start()
        try await server.start(transport: serverTransport)
        try await peer.send(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#)
        for await _ in started { break }
        await server.stop()
        let result = await outcome(within: .seconds(1)) { () -> Bool in
            for await cancelled in ended { return cancelled }
            return false
        }
        guard case .returned(let cancelled) = result else {
            Issue.record("the handler was still running 1 s after stop()")
            return
        }
        #expect(cancelled)
        await peer.stop()
    }
}

/// Collects the messages logged through every logger it backs.
private final class LogCollector: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
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
        lock.withLock { messages.append(message.description) }
    }

    func count(of message: String) -> Int {
        lock.withLock { messages.filter { $0 == message }.count }
    }
}
