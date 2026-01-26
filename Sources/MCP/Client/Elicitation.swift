import Foundation

/// Types supporting the MCP elicitation flow.
///
/// Servers use elicitation to collect structured input from users via the client.
/// The schema subset mirrors the 2025-06-18 revision of the specification.
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
}

/// To request information from a user, servers send an `elicitation/create` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
public enum CreateElicitation: Method {
    public static let name = "elicitation/create"

    public struct Parameters: Hashable, Codable, Sendable {
        /// Message displayed to the user describing the request.
        public var message: String
        /// Optional schema describing the expected response content.
        public var requestedSchema: Elicitation.RequestSchema?
        /// Optional provider-specific metadata.
        public var metadata: [String: Value]?

        public init(
            message: String,
            requestedSchema: Elicitation.RequestSchema? = nil,
            metadata: [String: Value]? = nil
        ) {
            self.message = message
            self.requestedSchema = requestedSchema
            self.metadata = metadata
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
