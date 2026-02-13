import Foundation

/// Types supporting the MCP elicitation flow.
///
/// Servers use elicitation to collect structured input from users via the client.
/// The schema subset mirrors the 2025-11-25 revision of the specification.
public enum Elicitation {
    /// Schema describing the expected response content.
    public struct RequestSchema: Hashable, Codable, Sendable {
        /// Supported top-level types. Currently limited to objects.
        public enum SchemaType: String, Hashable, Codable, Sendable {
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

    /// Elicitation mode indicating how user input is collected
    public enum Mode: String, Hashable, Codable, Sendable {
        /// Form-based elicitation (client displays UI)
        case form
        /// URL-based elicitation (client opens external URL)
        case url
    }
}

/// To request information from a user, servers send an `elicitation/create` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
public enum CreateElicitation: Method {
    public static let name = "elicitation/create"

    public enum Parameters: Hashable, Sendable {
        /// Form-based elicitation parameters
        case form(FormParameters)
        /// URL-based elicitation parameters
        case url(URLParameters)

        /// Parameters for form-based elicitation
        public struct FormParameters: Hashable, Codable, Sendable {
            /// Message displayed to the user describing the request
            public var message: String
            /// Elicitation mode (optional for backward compatibility, defaults to form)
            public var mode: Elicitation.Mode?
            /// Optional schema describing the expected response content
            public var requestedSchema: Elicitation.RequestSchema?
            /// Optional metadata
            public var _meta: Metadata?

            public init(
                message: String,
                mode: Elicitation.Mode? = nil,
                requestedSchema: Elicitation.RequestSchema? = nil,
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

    public struct Result: Hashable, Codable, Sendable {
        /// Indicates how the user responded to the request.
        public enum Action: String, Hashable, Codable, Sendable {
            case accept
            case decline
            case cancel
        }

        /// Selected action.
        public var action: Action
        /// Submitted content when action is `.accept`.
        public var content: [String: Value]?
        /// Optional metadata about this result
        public var _meta: Metadata?

        public init(
            action: Action,
            content: [String: Value]? = nil,
            _meta: Metadata? = nil,
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
        case mode, message, requestedSchema, metadata, url, elicitationId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Read mode field (may be missing for backward compatibility)
        let mode = try container.decodeIfPresent(Elicitation.Mode.self, forKey: .mode)

        // Discriminate based on mode
        if mode == .url {
            // URL mode
            let message = try container.decode(String.self, forKey: .message)
            let url = try container.decode(String.self, forKey: .url)
            let elicitationId = try container.decode(String.self, forKey: .elicitationId)
            let _meta = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
            self = .url(URLParameters(
                message: message,
                url: url,
                elicitationId: elicitationId,
                _meta: _meta))
        } else {
            // Form mode (default for backward compatibility)
            let message = try container.decode(String.self, forKey: .message)
            let requestedSchema = try container.decodeIfPresent(
                Elicitation.RequestSchema.self, forKey: .requestedSchema)
            let _meta = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
            self = .form(FormParameters(
                message: message,
                mode: mode,
                requestedSchema: requestedSchema,
                _meta: _meta))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .form(let params):
            try container.encode(params.message, forKey: .message)
            try container.encodeIfPresent(params.mode, forKey: .mode)
            try container.encodeIfPresent(params.requestedSchema, forKey: .requestedSchema)
            try container.encodeIfPresent(params._meta, forKey: .metadata)
        case .url(let params):
            try container.encode(params.message, forKey: .message)
            try container.encode(params.mode, forKey: .mode)
            try container.encode(params.url, forKey: .url)
            try container.encode(params.elicitationId, forKey: .elicitationId)
            try container.encodeIfPresent(params._meta, forKey: .metadata)
        }
    }
}

/// Notification sent when a URL-based elicitation is complete
public struct ElicitationCompleteNotification: Notification {
    public static let name = "notifications/elicitation/complete"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The elicitation ID that was completed
        public var elicitationId: String

        public init(elicitationId: String) {
            self.elicitationId = elicitationId
        }
    }
}
