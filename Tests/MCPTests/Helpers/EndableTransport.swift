import Logging

import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

/// A transport whose receive stream a test can end, cleanly or with an error,
/// without calling `disconnect()`. It answers `initialize` by itself and counts
/// `receive()` calls. With `servesStateless`, it also answers `server/discover`
/// for 2026-07-28, with tools that change, and acknowledges
/// `subscriptions/listen`.
actor EndableTransport: Transport {
    /// How `receive()` hands out streams.
    enum StreamMode: Sendable {
        /// The same stored stream on every call, like `StdioTransport`.
        case shared
        /// A new stream on every call, like `InMemoryTransport`.
        case freshPerReceive
    }

    private struct Envelope: Decodable {
        let id: ID?
        let method: String?
    }

    let logger = Logger(
        label: "mcp.test.endable-transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    let mode: StreamMode
    let respondsToInitialize: Bool
    let servesStateless: Bool
    let finishesStreamOnDisconnect: Bool

    private(set) var receiveCallCount = 0
    private(set) var disconnectCount = 0
    private(set) var sentBatchCount = 0
    private(set) var sentMethods: [String] = []
    private(set) var sentResponseIDs: [ID] = []

    private let sharedStream: AsyncThrowingStream<Data, Swift.Error>
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var buffered: [Data] = []
    private var holdsNextDisconnect = false
    private var heldDisconnect: CheckedContinuation<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        mode: StreamMode,
        respondsToInitialize: Bool = true,
        servesStateless: Bool = false,
        finishesStreamOnDisconnect: Bool = true
    ) {
        self.mode = mode
        self.respondsToInitialize = respondsToInitialize
        self.servesStateless = servesStateless
        self.finishesStreamOnDisconnect = finishesStreamOnDisconnect
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.sharedStream = stream
        self.continuation = mode == .shared ? continuation : nil
    }

    func connect() async throws {}

    func disconnect() async {
        disconnectCount += 1
        if holdsNextDisconnect {
            holdsNextDisconnect = false
            await withCheckedContinuation { heldDisconnect = $0 }
        }
        guard finishesStreamOnDisconnect else { return }
        continuation?.finish()
        continuation = nil
    }

    /// Makes the next `disconnect()` wait until `releaseHeldDisconnect()`.
    func holdNextDisconnect() {
        holdsNextDisconnect = true
    }

    func releaseHeldDisconnect() {
        heldDisconnect?.resume()
        heldDisconnect = nil
    }

    func waitUntilDisconnectIsHeld(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while heldDisconnect == nil {
            guard ContinuousClock.now < deadline else {
                throw MCPError.internalError("disconnect() was never called")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Records the method of each message, the ID of each response, and
    /// counts batches. Like `StdioTransport` after the server closes its
    /// output, sending keeps working after the receive stream has ended.
    func send(_ data: Data) async throws {
        if data.first == UInt8(ascii: "[") {
            sentBatchCount += 1
            return
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return }
        if let method = envelope.method {
            sentMethods.append(method)
        } else if let id = envelope.id {
            sentResponseIDs.append(id)
        }
        if respondsToInitialize, envelope.method == Initialize.name, let id = envelope.id {
            let response = Initialize.response(
                id: id,
                result: .init(
                    protocolVersion: Version.latestHandshake,
                    capabilities: .init(),
                    serverInfo: .init(name: "TestServer", version: "1.0"),
                    instructions: nil
                )
            )
            deliver(try encoder.encode(response))
        }
        if servesStateless, envelope.method == ServerDiscover.name, let id = envelope.id {
            let response = ServerDiscover.response(
                id: id,
                result: .init(
                    supportedVersions: Version.stateless,
                    capabilities: .init(tools: .init(listChanged: true))
                )
            )
            deliver(try encoder.encode(response))
        }
        if servesStateless, envelope.method == SubscriptionsListen.name, let id = envelope.id {
            var meta = Metadata()
            meta.subscriptionID = id
            let ack = Message<SubscriptionsAcknowledgedNotification>(
                method: SubscriptionsAcknowledgedNotification.name,
                params: .init(notifications: .init(toolsListChanged: true)),
                _meta: meta)
            deliver(try encoder.encode(ack))
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        receiveCallCount += 1
        switch mode {
        case .shared:
            return sharedStream
        case .freshPerReceive:
            let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
            self.continuation = continuation
            for data in buffered {
                continuation.yield(data)
            }
            buffered.removeAll()
            return stream
        }
    }

    /// Ends the current receive stream, as a server closing its end of the
    /// connection would.
    func finishStream(throwing error: (any Swift.Error)? = nil) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    /// Waits until a message for `method` has been sent.
    func waitUntilSent(_ method: String, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !sentMethods.contains(method) {
            guard ContinuousClock.now < deadline else {
                throw MCPError.internalError("\(method) was never sent")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until a response to the request with `id` has been sent.
    func waitUntilSentResponse(to id: ID, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !sentResponseIDs.contains(id) {
            guard ContinuousClock.now < deadline else {
                throw MCPError.internalError("no response to \(id) was sent")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Delivers a message from the server to the client.
    func deliverFromServer(_ data: Data) {
        deliver(data)
    }

    private func deliver(_ data: Data) {
        if let continuation {
            continuation.yield(data)
        } else {
            buffered.append(data)
        }
    }
}
