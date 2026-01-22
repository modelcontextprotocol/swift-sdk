import Foundation

/// Progress notifications are used to report progress on long-running operations.
///
/// The sender (either client or server) that issued the original request may
/// include a progress token in the request's `_meta` field. If the receiver
/// supports progress reporting, it can send progress notifications
/// containing that token to indicate how the operation is proceeding.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress
public struct ProgressNotification: Notification {
    public static let name: String = "notifications/progress"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The progress token from the original request.
        ///
        /// This is used to associate the progress notification with its
        /// originating request.
        public let progressToken: ProgressToken

        /// The current progress value.
        ///
        /// This should increase monotonically as the operation proceeds.
        /// It represents the amount of work completed so far.
        public let progress: Double

        /// The total expected progress value, if known.
        ///
        /// When provided, `progress / total` can be used to calculate
        /// a percentage completion.
        public let total: Double?

        /// An optional human-readable message describing the current progress.
        public let message: String?

        public init(
            progressToken: ProgressToken,
            progress: Double,
            total: Double? = nil,
            message: String? = nil
        ) {
            self.progressToken = progressToken
            self.progress = progress
            self.total = total
            self.message = message
        }
    }
}

/// A token used to associate progress notifications with their originating request.
///
/// Progress tokens can be either strings or integers.
public enum ProgressToken: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Progress token must be a string or integer"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}
