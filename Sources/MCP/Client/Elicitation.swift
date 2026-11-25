import Foundation

/// Types supporting the MCP elicitation flow.
///
/// Servers use elicitation to collect structured input from users via the client.
/// The schema subset mirrors the 2025-11-25 revision of the specification.
public enum Elicitation {
    /// Schema describing the expected response content.
    public struct RequestSchema: Hashable, Codable, Sendable {
        /// Supported top-level types. Currently limited to objects.
        ///
        /// Frozen: no case is added in 1.x (the root of a requested schema is an object).
        public enum SchemaType: String, Hashable, Codable, Sendable {
            /// A JSON object whose properties are the requested fields.
            case object
        }

        /// Schema title presented to users.
        public var title: String?
        /// Schema description providing additional guidance.
        public var description: String?
        /// Raw JSON Schema fragments describing the requested fields.
        public var properties: [String: Value]
        /// List of required field keys.
        public var required: [String]?
        /// Top-level schema type. Defaults to `object`.
        public var type: SchemaType

        /// Creates a requested schema.
        public init(
            title: String? = nil,
            description: String? = nil,
            properties: [String: Value] = [:],
            required: [String]? = nil,
            type: SchemaType = .object
        ) {
            self.title = title
            self.description = description
            self.properties = properties
            self.required = required
            self.type = type
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, properties, required, type
        }
    }

    /// Elicitation mode indicating how user input is collected.
    ///
    /// New modes can appear in a later revision, so a `switch` needs a `default`. A mode the
    /// SDK does not know decodes as itself.
    public struct Mode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// Form-based elicitation (client displays UI)
        public static let form = Mode(rawValue: "form")
        /// URL-based elicitation (client opens external URL)
        public static let url = Mode(rawValue: "url")
    }
}

/// To request information from a user, servers send an `elicitation/create` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
public enum CreateElicitation: Method {
    public static let name = "elicitation/create"

    /// No other case is added in 1.x: a kind from a later revision is ``unknown(mode:_:)``.
    public enum Parameters: Hashable, Sendable {
        /// Form-based elicitation parameters
        case form(FormParameters)
        /// URL-based elicitation parameters
        case url(URLParameters)
        /// A mode the SDK does not know, from a later revision: the mode and the
        /// whole `params` as received. It is encoded as received.
        case unknown(mode: Elicitation.Mode, Value)

        /// Parameters for form-based elicitation
        public struct FormParameters: Hashable, Codable, Sendable {
            /// Message displayed to the user describing the request
            public var message: String
            /// Elicitation mode (optional for backward compatibility, defaults to form)
            public var mode: Elicitation.Mode?
            /// Schema describing the expected response content (required per spec)
            public var requestedSchema: Elicitation.RequestSchema
            /// Optional metadata
            public var _meta: Metadata?

            /// Creates form elicitation parameters.
            ///
            /// A `nil` mode omits `mode` from the wire, which receivers read as `form`.
            public init(
                message: String,
                mode: Elicitation.Mode? = nil,
                requestedSchema: Elicitation.RequestSchema = .init(),
                _meta: Metadata? = nil
            ) {
                self.message = message
                self.mode = mode
                self.requestedSchema = requestedSchema
                self._meta = _meta
            }
        }

        /// Parameters for URL-based elicitation
        public struct URLParameters: Hashable, Codable, Sendable {
            /// Message displayed to the user describing the request
            public var message: String
            /// Elicitation mode (always "url")
            public var mode: Elicitation.Mode
            /// URL for the user to visit
            public var url: String
            /// Unique identifier for this elicitation
            public var elicitationId: String
            /// Optional metadata
            public var _meta: Metadata?

            /// Creates URL elicitation parameters, with `mode` set to `url`.
            public init(
                message: String,
                url: String,
                elicitationId: String,
                _meta: Metadata? = nil
            ) {
                self.message = message
                self.mode = .url
                self.url = url
                self.elicitationId = elicitationId
                self._meta = _meta
            }
        }
    }

    /// The result of `elicitation/create`.
    public struct Result: Hashable, Codable, Sendable {
        /// Indicates how the user responded to the request.
        ///
        /// Frozen: no case is added in 1.x (unchanged since 2025-06-18).
        public enum Action: String, Hashable, Codable, Sendable {
            /// The user accepted the request: for a form, with the requested content.
            case accept
            /// The user explicitly declined the request.
            case decline
            /// The user dismissed the request without choosing.
            case cancel
        }

        /// Selected action.
        public var action: Action
        /// Submitted content when action is `.accept`.
        public var content: [String: Value]?
        /// Optional metadata about this result
        public var _meta: Metadata?

        /// Creates an elicitation result.
        public init(
            action: Action,
            content: [String: Value]? = nil,
            _meta: Metadata? = nil
        ) {
            self.action = action
            self.content = content
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case action, content, _meta
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(_meta, forKey: ._meta)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(Action.self, forKey: .action)
            content = try container.decodeIfPresent([String: Value].self, forKey: .content)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

// MARK: - Codable

extension CreateElicitation.Parameters: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode, message, requestedSchema, url, elicitationId
        case _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Read mode field (may be missing for backward compatibility)
        let mode = try container.decodeIfPresent(Elicitation.Mode.self, forKey: .mode)

        // Discriminate based on mode
        if let mode, mode != .url, mode != .form {
            self = .unknown(mode: mode, try UnknownBlock.decode(from: decoder))
        } else if mode == .url {
            // URL mode
            let message = try container.decode(String.self, forKey: .message)
            let url = try container.decode(String.self, forKey: .url)
            let elicitationId = try container.decode(String.self, forKey: .elicitationId)
            let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            self = .url(URLParameters(
                message: message,
                url: url,
                elicitationId: elicitationId,
                _meta: _meta))
        } else {
            // Form mode (default for backward compatibility)
            let message = try container.decode(String.self, forKey: .message)
            let requestedSchema = try container.decode(
                Elicitation.RequestSchema.self, forKey: .requestedSchema)
            let _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            self = .form(FormParameters(
                message: message,
                mode: mode,
                requestedSchema: requestedSchema,
                _meta: _meta))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(let mode, let params) = self {
            try UnknownBlock.encode(params, kind: mode.rawValue, key: "mode", to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .form(let params):
            try container.encode(params.message, forKey: .message)
            try container.encodeIfPresent(params.mode, forKey: .mode)
            try container.encodeIfPresent(params.requestedSchema, forKey: .requestedSchema)
            try container.encodeIfPresent(params._meta, forKey: ._meta)
        case .url(let params):
            try container.encode(params.message, forKey: .message)
            try container.encode(params.mode, forKey: .mode)
            try container.encode(params.url, forKey: .url)
            try container.encode(params.elicitationId, forKey: .elicitationId)
            try container.encodeIfPresent(params._meta, forKey: ._meta)
        case .unknown:
            return
        }
    }
}

/// Notification sent when a URL-based elicitation is complete
public struct ElicitationCompleteNotification: Notification {
    public static let name = "notifications/elicitation/complete"

    /// The parameters of `notifications/elicitation/complete`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The elicitation ID that was completed
        public var elicitationId: String

        /// Creates the parameters for a completed elicitation.
        public init(elicitationId: String) {
            self.elicitationId = elicitationId
        }
    }
}
