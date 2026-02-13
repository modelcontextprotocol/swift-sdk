import Foundation

/// The Model Context Protocol supports cancellation of requests through
/// notification messages. Either side can send a cancellation notification
/// to indicate that a previously-issued request should be cancelled.
///
/// Cancellation is advisory: the receiver should make a best-effort attempt
/// to cancel the operation, but may not always be able to do so.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
public struct CancelledNotification: Notification {
    public static let name: String = "notifications/cancelled"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the request to cancel.
        ///
        /// This MUST correspond to the ID of a request previously issued
        /// in the same direction.
        public let requestId: ID

        /// An optional human-readable reason for the cancellation.
        public let reason: String?

        public init(requestId: ID, reason: String? = nil) {
            self.requestId = requestId
            self.reason = reason
        }
    }
}
