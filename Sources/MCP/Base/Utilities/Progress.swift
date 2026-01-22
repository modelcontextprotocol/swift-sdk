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
    /// The progress token for receiving progress notifications.
    ///
    /// If specified, the caller is requesting out-of-band progress notifications
    /// for this request. The value of this parameter is an opaque token that will
    /// be attached to any subsequent notifications. The receiver is not obligated
    /// to provide these notifications.
    public var progressToken: ProgressToken?

    /// Additional metadata fields.
    ///
    /// This allows for extension with custom metadata fields.
    public var additionalFields: [String: Value]?

    /// Creates an empty request metadata.
    public init() {
        self.progressToken = nil
        self.additionalFields = nil
    }

    /// Creates request metadata with a progress token.
    ///
    /// - Parameter progressToken: The progress token for receiving progress notifications.
    public init(progressToken: ProgressToken?) {
        self.progressToken = progressToken
        self.additionalFields = nil
    }

    /// Creates request metadata with a progress token and additional fields.
    ///
    /// - Parameters:
    ///   - progressToken: The progress token for receiving progress notifications.
    ///   - additionalFields: Additional metadata fields.
    public init(progressToken: ProgressToken?, additionalFields: [String: Value]?) {
        self.progressToken = progressToken
        self.additionalFields = additionalFields
    }

    private enum CodingKeys: String, CodingKey {
        case progressToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progressToken = try container.decodeIfPresent(ProgressToken.self, forKey: .progressToken)

        // Decode additional fields
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var additional: [String: Value] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue != CodingKeys.progressToken.rawValue {
                if let value = try? dynamicContainer.decode(Value.self, forKey: key) {
                    additional[key.stringValue] = value
                }
            }
        }
        additionalFields = additional.isEmpty ? nil : additional
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(progressToken, forKey: .progressToken)

        // Encode additional fields
        if let additional = additionalFields {
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in additional {
                if key != CodingKeys.progressToken.rawValue {
                    try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key)!)
                }
            }
        }
    }
}

/// A dynamic coding key for encoding/decoding arbitrary string keys.
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
