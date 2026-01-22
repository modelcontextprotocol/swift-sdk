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
/// Progress tokens MUST be unique across all active requests.
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

    /// Creates a unique progress token using UUID.
    public static func unique() -> ProgressToken {
        .string(UUID().uuidString)
    }
}

/// Metadata that can be included in request parameters.
///
/// This structure represents the `_meta` field in MCP request parameters,
/// which can contain a progress token for receiving progress notifications.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress
public struct RequestMeta: Hashable, Codable, Sendable {
    /// The underlying fields dictionary.
    public var fields: [String: Value]

    /// The progress token for receiving progress notifications.
    ///
    /// If specified, the caller is requesting out-of-band progress notifications
    /// for this request. The value of this parameter is an opaque token that will
    /// be attached to any subsequent notifications. The receiver is not obligated
    /// to provide these notifications.
    public var progressToken: ProgressToken? {
        get {
            guard let value = fields["progressToken"] else { return nil }
            if let stringValue = value.stringValue {
                return .string(stringValue)
            } else if let intValue = value.intValue {
                return .integer(intValue)
            }
            return nil
        }
        set {
            if let token = newValue {
                switch token {
                case .string(let s):
                    fields["progressToken"] = .string(s)
                case .integer(let i):
                    fields["progressToken"] = .int(i)
                }
            } else {
                fields.removeValue(forKey: "progressToken")
            }
        }
    }

    /// Creates request metadata.
    ///
    /// - Parameters:
    ///   - progressToken: Optional progress token for receiving progress notifications.
    ///     If specified, the caller is requesting out-of-band progress notifications for this request.
    ///   - additionalFields: Optional dictionary of additional metadata fields.
    ///     These fields will be included in the `_meta` object alongside the progress token.
    public init(progressToken: ProgressToken? = nil, additionalFields: [String: Value] = [:]) {
        self.fields = additionalFields
        self.progressToken = progressToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: Value].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
