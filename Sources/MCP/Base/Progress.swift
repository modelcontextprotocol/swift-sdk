/// Progress tracking for long-running operations.
///
/// Clients can include a `progressToken` in request metadata (`_meta.progressToken`)
/// to receive progress notifications during operation execution.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/progress/

/// Metadata that can be attached to any request via the `_meta` field.
///
/// This is used primarily for progress tracking, but can also carry
/// arbitrary additional metadata.
public struct RequestMeta: Hashable, Codable, Sendable {
    /// If specified, the caller is requesting out-of-band progress notifications
    /// for this request. The value is an opaque token that will be attached to
    /// any subsequent progress notifications.
    public var progressToken: ProgressToken?

    /// Additional metadata fields.
    public var additionalFields: [String: Value]?

    public init(
        progressToken: ProgressToken? = nil,
        additionalFields: [String: Value]? = nil
    ) {
        self.progressToken = progressToken
        self.additionalFields = additionalFields
    }

    private enum CodingKeys: String, CodingKey {
        case progressToken
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progressToken = try container.decodeIfPresent(ProgressToken.self, forKey: .progressToken)

        // Decode additional fields
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var extra: [String: Value] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue == CodingKeys.progressToken.stringValue {
                continue
            }
            if let value = try? dynamicContainer.decode(Value.self, forKey: key) {
                extra[key.stringValue] = value
            }
        }
        additionalFields = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(progressToken, forKey: .progressToken)

        // Encode additional fields
        if let additional = additionalFields {
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in additional {
                if let codingKey = DynamicCodingKey(stringValue: key) {
                    try dynamicContainer.encode(value, forKey: codingKey)
                }
            }
        }
    }
}

/// A token used to associate progress notifications with a specific request.
///
/// Progress tokens can be either strings or integers.
public enum ProgressToken: Hashable, Sendable {
    case string(String)
    case integer(Int)
}

extension ProgressToken: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                ProgressToken.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string or integer for ProgressToken"
                )
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

extension ProgressToken: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ProgressToken: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

/// Notification sent to report progress on a long-running operation.
///
/// Servers send progress notifications to inform clients about the status
/// of operations that may take significant time to complete.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/progress/
public struct ProgressNotification: Notification {
    public static let name: String = "notifications/progress"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The progress token from the original request's `_meta.progressToken`.
        public let progressToken: ProgressToken

        /// The current progress value. Should increase monotonically.
        public let progress: Double

        /// The total progress value, if known.
        public let total: Double?

        /// An optional human-readable message describing the current progress.
        public let message: String?

        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(
            progressToken: ProgressToken,
            progress: Double,
            total: Double? = nil,
            message: String? = nil,
            _meta: [String: Value]? = nil
        ) {
            self.progressToken = progressToken
            self.progress = progress
            self.total = total
            self.message = message
            self._meta = _meta
        }
    }
}

// MARK: - Progress Callback

/// Progress information received during a long-running operation.
///
/// This struct is passed to progress callbacks when using `send(_:onProgress:)`.
public struct Progress: Sendable, Hashable {
    /// The current progress value. Increases monotonically.
    public let value: Double

    /// The total progress value, if known.
    public let total: Double?

    /// An optional human-readable message describing current progress.
    public let message: String?

    public init(value: Double, total: Double? = nil, message: String? = nil) {
        self.value = value
        self.total = total
        self.message = message
    }
}

/// A callback invoked when a progress notification is received.
///
/// This is used by the client to receive progress updates for specific requests
/// when using `send(_:onProgress:)`.
public typealias ProgressCallback = @Sendable (Progress) async -> Void

// MARK: - Progress Tracker (Server-Side)

/// An actor for tracking and sending cumulative progress during a request.
///
/// This follows the Python SDK's `ProgressContext` pattern, providing a convenient
/// way to track cumulative progress and send notifications without manually
/// tracking the current value.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { request, context in
///     guard let token = request._meta?.progressToken else {
///         return CallTool.Result(content: [.text("Done")])
///     }
///
///     let tracker = ProgressTracker(token: token, total: 100, context: context)
///
///     try await tracker.advance(by: 25, message: "Loading...")
///     try await tracker.advance(by: 50, message: "Processing...")
///     try await tracker.advance(by: 25, message: "Completing...")
///
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public actor ProgressTracker {
    /// The progress token from the request.
    public let token: ProgressToken

    /// The total progress value, if known.
    public let total: Double?

    /// The request handler context for sending notifications.
    private let context: Server.RequestHandlerContext

    /// The current cumulative progress value.
    public private(set) var current: Double = 0

    /// Creates a new progress tracker.
    ///
    /// - Parameters:
    ///   - token: The progress token from the request's `_meta.progressToken`
    ///   - total: The total progress value, if known
    ///   - context: The request handler context for sending notifications
    public init(
        token: ProgressToken,
        total: Double? = nil,
        context: Server.RequestHandlerContext
    ) {
        self.token = token
        self.total = total
        self.context = context
    }

    /// Advance progress by the given amount and send a notification.
    ///
    /// - Parameters:
    ///   - amount: The amount to add to the current progress
    ///   - message: An optional human-readable message describing current progress
    public func advance(by amount: Double, message: String? = nil) async throws {
        current += amount
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message
        )
    }

    /// Set progress to a specific value and send a notification.
    ///
    /// Use this when you want to set progress to an absolute value rather than
    /// incrementing. The progress value should still increase monotonically.
    ///
    /// - Parameters:
    ///   - value: The new progress value
    ///   - message: An optional human-readable message describing current progress
    public func set(to value: Double, message: String? = nil) async throws {
        current = value
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message
        )
    }

    /// Send a progress notification without changing the current value.
    ///
    /// Use this to update the message without changing the progress value.
    ///
    /// - Parameter message: A human-readable message describing current progress
    public func update(message: String) async throws {
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message
        )
    }
}
