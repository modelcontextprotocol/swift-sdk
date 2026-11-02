import Foundation

@testable import MCP

/// A client end of an `InMemoryTransport` pair that sends raw JSON-RPC and
/// records every message it receives, for tests that need exact control of
/// the wire.
actor RawPeer {
    private let transport: InMemoryTransport
    private var reader: Task<Void, Never>?
    private(set) var received: [Value] = []

    init(_ transport: InMemoryTransport) {
        self.transport = transport
    }

    /// Connects and starts recording received messages.
    func start() async throws {
        try await transport.connect()
        let stream = await transport.receive()
        reader = Task {
            do {
                for try await data in stream {
                    guard let value = try? JSONDecoder().decode(Value.self, from: data) else { continue }
                    self.record(value)
                }
            } catch {}
        }
    }

    private func record(_ value: Value) { received.append(value) }

    func send(_ json: String) async throws {
        try await transport.send(Data(json.utf8))
    }

    /// The first received message that matches, waiting at most `timeout`.
    func first(
        within timeout: Duration = .seconds(5), where predicate: @Sendable (Value) -> Bool
    ) async -> Value? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let match = received.first(where: predicate) { return match }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Sends `initialize` and `notifications/initialized` at 2025-11-25.
    func initialize(capabilities: String = "{}") async throws {
        try await send(
            #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":\#(capabilities),"clientInfo":{"name":"raw","version":"1"}}}"#
        )
        guard await first(where: { $0.objectValue?["id"] == "init" }) != nil else {
            throw MCPError.internalError("No initialize response")
        }
        try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    /// Sends a ping and waits for its response: every message the server
    /// received before it has been read by its receive loop.
    func sync(_ id: String) async throws {
        try await send(#"{"jsonrpc":"2.0","id":"\#(id)","method":"ping"}"#)
        guard await first(where: { $0.objectValue?["id"]?.stringValue == id }) != nil else {
            throw MCPError.internalError("No ping response")
        }
    }

    func stop() async {
        reader?.cancel()
        await transport.disconnect()
    }
}
