import Foundation

/// A context object that wraps a pending request, providing both the request ID
/// and a Task handle for the asynchronous operation.
///
/// This allows you to track and cancel in-flight requests by sending
/// a CancelledNotification to the receiver (client or server).
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
public struct RequestContext<Output: Sendable & Decodable>: Sendable {
    /// The unique identifier for this request.
    public let requestID: ID

    /// The Task representing the asynchronous work for this request.
    private let requestTask: Task<Output, Error>

    /// Convenience property to await the result.
    ///
    /// Cancelling the task that awaits it cancels the request, as
    /// `Client.cancelRequest(_:reason:)` does: it throws `CancellationError`.
    /// The request is shared, so every task that awaits `value` gets that
    /// error. To wait from a task that may be cancelled without ending the
    /// request, await `Task { try await context.value }.value` instead.
    ///
    /// Example:
    /// ```swift
    /// let context = try await client.send(request)
    /// let result = try await context.value
    /// ```
    public var value: Output {
        get async throws {
            try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: { [requestTask] in
                requestTask.cancel()
            }
        }
    }

    public init(requestID: ID, requestTask: Task<Output, Error>) {
        self.requestID = requestID
        self.requestTask = requestTask
    }
}
