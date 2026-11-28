import Foundation
import Logging
import Testing

@testable import MCP

// SEP-2260: sampling and elicitation requests belong to a client request.
// 2026-07-28 has no server-to-client requests, so the SEP holds there: the
// server throws, in a handler and outside one. At 2025-11-25 the server sends
// the request anyway and logs one warning for each method sent while it
// handles no client request.

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Results {
    private(set) var models: [String?] = []
    func add(_ model: String?) { models.append(model) }
}

/// A connected server and handshake client, sharing a logger that captures
/// warnings.
private struct Connection {
    let server: Server
    let client: Client
    let log: CapturingLogHandler
    let gate = Gate()
    let late = Results()

    /// Connects a new client, to a new server or, after `previous` was
    /// closed, to its server started again with the same log. The client
    /// uses the handshake unless `configuration` says otherwise.
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    static func make(
        restarting previous: Connection? = nil, configuration: Client.Configuration = .handshake
    ) async throws -> Connection {
        let log = previous?.log ?? CapturingLogHandler()
        let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair(
            logger: Logger(label: "test") { _ in log })
        let server = previous?.server ?? Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        let connection = Connection(
            server: server,
            client: Client(
                name: "c", version: "1",
                capabilities: .init(sampling: .init(), elicitation: .init(), roots: .init()),
                configuration: configuration),
            log: log)
        await connection.register()
        try await server.start(transport: serverEnd)
        try await connection.client.connect(transport: clientEnd)
        return connection
    }

    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    private func register() async {
        let gate = gate, late = late
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            guard let server else { throw MCPError.internalError("gone") }
            switch params.name {
            case "sample":
                _ = try await server.requestSampling(messages: [.user("Hi")], maxTokens: 10)
            case "elicit":
                _ = try await server.requestElicitation(message: "Name?", requestedSchema: .init())
            case "bridge":
                guard params.inputResponses?["model"] != nil else {
                    return .inputRequired(["model": .sampling(.init(messages: [.user("Hi")], maxTokens: 10))])
                }
            case "later":
                // The task inherits the handler context, but runs after the
                // handler returned.
                Task {
                    await gate.wait()
                    let result = try? await server.requestSampling(messages: [.user("Hi")], maxTokens: 10)
                    await late.add(result?.model)
                }
            default:
                break
            }
            return .init(content: [.text(text: "done")])
        }
        await client.withSamplingHandler { _ in .init(model: "m", role: .assistant, content: .text("ok")) }
        await client.withElicitationHandler { _ in .init(action: .decline) }
        await client.withRootsHandler { [] }
    }

    var warnings: [String] { log.messages.filter { $0.contains("SEP-2260") } }

    func close() async {
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Request association (SEP-2260)", .timeLimit(.minutes(1)))
struct RequestAssociationTests {
    @Test("Requests sent from a handler or by the bridge, and roots/list: no warning")
    @available(*, deprecated, message: "Tests the deprecated roots API (SEP-2577)")
    func associated() async throws {
        let connection = try await Connection.make()
        defer { Task { await connection.close() } }
        for tool in ["sample", "elicit", "bridge"] {
            _ = try await connection.client.callTool(name: tool)
        }
        // roots/list is not checked: 2025-11-25 asks for roots after list_changed.
        _ = try await connection.server.listRoots()
        #expect(connection.warnings.isEmpty)
    }

    @Test("A request outside a handler is sent, with one warning for each method")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func outsideHandler() async throws {
        let connection = try await Connection.make()
        defer { Task { await connection.close() } }
        for _ in 0..<2 {
            let result = try await connection.server.requestSampling(messages: [.user("Hi")], maxTokens: 10)
            #expect(result.model == "m")
        }
        #expect(connection.warnings.count == 1)
        #expect(connection.warnings.first?.hasPrefix("sampling/createMessage was sent while the server handled no client request") == true)

        let answer = try await connection.server.requestElicitation(message: "Name?", requestedSchema: .init())
        #expect(answer.action == .decline)
        #expect(connection.warnings.count == 2)
        #expect(connection.warnings.last?.hasPrefix("elicitation/create was sent") == true)
    }

    @Test("A restarted server warns again for a new client")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func restart() async throws {
        let first = try await Connection.make()
        _ = try await first.server.requestSampling(messages: [.user("Hi")], maxTokens: 10)
        #expect(first.warnings.count == 1)
        await first.close()

        let second = try await Connection.make(restarting: first)
        defer { Task { await second.close() } }
        let result = try await second.server.requestSampling(messages: [.user("Hi")], maxTokens: 10)
        #expect(result.model == "m")
        #expect(second.warnings.count == 2)
    }

    @Test("A request after the handler returned is sent, with a warning")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func afterHandler() async throws {
        let connection = try await Connection.make()
        defer { Task { await connection.close() } }
        _ = try await connection.client.callTool(name: "later")
        await connection.gate.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while await connection.late.models.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await connection.late.models == ["m"])
        #expect(connection.warnings.count == 1)
    }

    @Test("At 2026-07-28 a request from a handler throws")
    @available(*, deprecated, message: "Uses the deprecated roots and sampling APIs (SEP-2577)")
    func statelessInHandler() async throws {
        let connection = try await Connection.make(configuration: .init())
        defer { Task { await connection.close() } }
        await #expect(throws: MCPError.invalidRequest("sampling/createMessage cannot be sent at protocol version 2026-07-28")) {
            _ = try await connection.client.callTool(name: "sample")
        }
        #expect(connection.warnings.isEmpty)
    }

    @Test("At 2026-07-28 a request outside a handler throws, with no warning")
    @available(*, deprecated, message: "Tests the deprecated roots and sampling APIs (SEP-2577)")
    func statelessOutsideHandler() async throws {
        // The client connected with server/discover: the connection served a
        // stateless request.
        let connection = try await Connection.make(configuration: .init())
        defer { Task { await connection.close() } }
        let server = connection.server
        #expect(
            await refusal { _ = try await server.requestSampling(messages: [.user("Hi")], maxTokens: 10) }
                == .invalidRequest("sampling/createMessage cannot be sent at protocol version 2026-07-28"))
        #expect(
            await refusal { _ = try await server.requestElicitation(message: "Name?", requestedSchema: .init()) }
                == .invalidRequest("elicitation/create cannot be sent at protocol version 2026-07-28"))
        #expect(
            await refusal { _ = try await server.listRoots() }
                == .invalidRequest("roots/list cannot be sent at protocol version 2026-07-28"))
        #expect(connection.warnings.isEmpty)
    }

    @Test("A server that serves no handshake revision throws before any request")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func statelessOnlyServer() async throws {
        let (_, serverEnd) = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "s", version: "1", capabilities: .init(),
            configuration: .init(protocolVersions: Version.stateless))
        try await server.start(transport: serverEnd)
        defer { Task { await server.stop() } }
        #expect(
            await refusal { _ = try await server.requestSampling(messages: [.user("Hi")], maxTokens: 10) }
                == .invalidRequest("sampling/createMessage cannot be sent at protocol version 2026-07-28"))
    }

    @Test("Behind a sessionless transport a request outside a handler throws")
    @available(*, deprecated, message: "Tests the deprecated sampling API (SEP-2577)")
    func sessionlessOutsideHandler() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init())
        try await server.start(transport: StatelessHTTPServerTransport())
        defer { Task { await server.stop() } }
        #expect(
            await refusal { _ = try await server.requestSampling(messages: [.user("Hi")], maxTokens: 10) }
                == .invalidRequest(
                    "sampling/createMessage cannot be sent outside a client request: the transport has no stream for it"))
    }
}

/// The error `request` throws in a detached task, which handles no client
/// request; `nil` when it returns.
private func refusal(_ request: @escaping @Sendable () async throws -> Void) async -> MCPError? {
    await Task.detached {
        do {
            try await request()
            return nil
        } catch {
            return error as? MCPError
        }
    }.value
}
