@testable import MCP

/// The result of waiting for an operation with a deadline.
enum Outcome<T: Sendable>: Sendable {
    case returned(T)
    case threw(any Error)
    case timedOut

    var error: (any Error)? {
        if case .threw(let error) = self { return error }
        return nil
    }

    var mcpError: MCPError? { error as? MCPError }

    var didTimeOut: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

/// Waits at most `limit` for `operation` to finish.
///
/// A pending request does not respond to task cancellation, so a task group
/// can't time out a request that never completes. This helper leaves the
/// operation running and returns `.timedOut` instead. Call
/// `Client.disconnect()` afterwards so an abandoned request is resumed.
func outcome<T: Sendable>(
    within limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async -> Outcome<T> {
    let (stream, continuation) = AsyncStream<Outcome<T>>.makeStream()
    Task {
        do {
            continuation.yield(.returned(try await operation()))
        } catch {
            continuation.yield(.threw(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        continuation.yield(.timedOut)
    }
    defer {
        timer.cancel()
        continuation.finish()
    }
    for await first in stream {
        return first
    }
    return .timedOut
}
