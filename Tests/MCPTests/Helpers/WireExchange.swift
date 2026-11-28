import Foundation
import Logging
import Testing

@testable import MCP

/// Drives a server with raw JSON-RPC messages and returns what it sends back.
///
/// Golden wire tests describe an exchange as JSON in, JSON out, so they
/// check the exact bytes a peer sees rather than Swift-level types.
struct WireExchange {
    let server: Server
    let transport: MockTransport

    init(server: Server, logger: Logger? = nil) {
        self.server = server
        transport = logger.map { MockTransport(logger: $0) } ?? MockTransport()
    }

    func start() async throws {
        try await server.start(transport: transport)
    }

    /// The server sent fewer messages than expected before the deadline.
    struct Timeout: Error, CustomStringConvertible {
        let expected: Int
        let received: Int
        let message: String

        var description: String {
            "Timed out waiting for \(expected) message(s), got \(received), after: \(message)"
        }
    }

    /// Sends `message` and waits until the server has sent `expecting` more messages.
    ///
    /// Throws ``Timeout`` when they don't arrive in time, so a caller that
    /// indexes the reply fails the test instead of trapping.
    @discardableResult
    func send(_ message: String, expecting count: Int = 1, timeout: Duration = .seconds(30))
        async throws -> [Value]
    {
        let before = await transport.sentData.count
        await transport.queue(data: Data(message.utf8))
        let deadline = ContinuousClock.now + timeout
        while await transport.sentData.count < before + count {
            guard ContinuousClock.now < deadline else {
                let received = await transport.sentData.count - before
                throw Timeout(expected: count, received: received, message: message)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sent = await transport.sentData
        return try sent[before...].map { try JSONDecoder().decode(Value.self, from: $0) }
    }

    func stop() async {
        await server.stop()
    }
}

/// Parses a JSON literal used as an expected wire message.
func wireJSON(_ text: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(text.utf8))
}

/// Records an issue unless `actual` contains every member of `expected`.
///
/// Objects match when each expected key matches; extra keys in `actual`
/// are allowed. Arrays and scalars must match exactly. Use `"<any>"` in
/// `expected` to accept any value.
func expectWire(
    _ actual: Value, matches expected: Value, path: String = "$",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if case .string("<any>") = expected { return }
    switch (actual, expected) {
    case (.object(let a), .object(let e)):
        for (key, value) in e {
            guard let member = a[key] else {
                Issue.record("Missing \(path).\(key)", sourceLocation: sourceLocation)
                continue
            }
            expectWire(member, matches: value, path: "\(path).\(key)", sourceLocation: sourceLocation)
        }
    case (.array(let a), .array(let e)) where a.count == e.count:
        for (index, pair) in zip(a, e).enumerated() {
            expectWire(pair.0, matches: pair.1, path: "\(path)[\(index)]", sourceLocation: sourceLocation)
        }
    case (.int(let a), .double(let e)) where Double(a) == e,
        (.double(let e), .int(let a)) where Double(a) == e:
        return
    default:
        if actual != expected {
            Issue.record("\(path): expected \(expected), got \(actual)", sourceLocation: sourceLocation)
        }
    }
}

/// Records an issue if `actual` has any of `keys` at its top level.
func expectWireLacks(
    _ actual: Value, _ keys: String..., sourceLocation: SourceLocation = #_sourceLocation
) {
    for key in keys where actual.objectValue?[key] != nil {
        Issue.record("Unexpected member \(key) in \(actual)", sourceLocation: sourceLocation)
    }
}
