import Foundation

/// The Model Context Protocol (MCP) provides a standardized way for servers to offer
/// autocompletion suggestions for the arguments of prompts and resource templates.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/

// MARK: - Reference Types

/// A reference to a prompt by name
public struct PromptReference: Hashable, Codable, Sendable {
    /// The prompt name
    public let name: String

    public init(name: String) {
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("ref/prompt", forKey: .type)
        try container.encode(name, forKey: .name)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "ref/prompt" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected ref/prompt type"
            )
        }
        name = try container.decode(String.self, forKey: .name)
    }
}

/// A reference to a resource by URI
public struct ResourceReference: Hashable, Codable, Sendable {
    /// The resource URI
    public let uri: String

    public init(uri: String) {
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case type, uri
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("ref/resource", forKey: .type)
        try container.encode(uri, forKey: .uri)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "ref/resource" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected ref/resource type"
            )
        }
        uri = try container.decode(String.self, forKey: .uri)
    }
}

/// A reference type for completion requests (either prompt or resource)
public enum CompletionReference: Hashable, Codable, Sendable {
    /// References a prompt by name
    case prompt(PromptReference)
    /// References a resource URI
    case resource(ResourceReference)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "ref/prompt":
            self = .prompt(try PromptReference(from: decoder))
        case "ref/resource":
            self = .resource(try ResourceReference(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown reference type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .prompt(let ref):
            try ref.encode(to: encoder)
        case .resource(let ref):
            try ref.encode(to: encoder)
        }
    }
}

// MARK: - Completion Request

/// To get completion suggestions, clients send a `completion/complete` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/
public enum Complete: Method {
    public static let name = "completion/complete"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The reference to what is being completed
        public let ref: CompletionReference
        /// The argument being completed
        public let argument: Argument
        /// Optional context with already-resolved arguments
        public let context: Context?

        public init(
            ref: CompletionReference,
            argument: Argument,
            context: Context? = nil
        ) {
            self.ref = ref
            self.argument = argument
            self.context = context
        }

        /// The argument being completed
        public struct Argument: Hashable, Codable, Sendable {
            /// The argument name
            public let name: String
            /// The current value (partial or complete)
            public let value: String

            public init(name: String, value: String) {
                self.name = name
                self.value = value
            }
        }

        /// Context containing already-resolved arguments
        public struct Context: Hashable, Codable, Sendable {
            /// A mapping of already-resolved argument names to their values
            public let arguments: [String: Value]

            public init(arguments: [String: Value]) {
                self.arguments = arguments
            }
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        /// The completion result
        public let completion: Completion

        public init(completion: Completion) {
            self.completion = completion
        }

        /// Completion result containing suggested values
        public struct Completion: Hashable, Codable, Sendable {
            /// Array of completion values (max 100 items)
            public let values: [String]
            /// Optional total number of available matches
            public let total: Int?
            /// Whether additional results exist
            public let hasMore: Bool?

            public init(
                values: [String],
                total: Int? = nil,
                hasMore: Bool? = nil
            ) {
                self.values = values
                self.total = total
                self.hasMore = hasMore
            }
        }
    }
}
