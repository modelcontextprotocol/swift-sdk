import Foundation

/// Autocomplete functionality allows servers to provide argument completion
/// suggestions for prompts and resource templates.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/utilities/completion/

/// A reference to a prompt for completion requests.
///
/// Used in `completion/complete` requests to identify which prompt's arguments
/// should be autocompleted.
///
/// - SeeAlso: ``CompletionReference``
public struct PromptReference: Hashable, Codable, Sendable {
    /// The type discriminator, always "ref/prompt".
    public let type: String
    /// The name of the prompt to get completions for.
    public let name: String
    /// A human-readable title for the prompt, intended for UI display.
    /// If not provided, the `name` should be used for display.
    public let title: String?

    public init(name: String, title: String? = nil) {
        self.type = "ref/prompt"
        self.name = name
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, title
    }
}

/// A reference to a resource template for completion requests.
///
/// Used in `completion/complete` requests to identify which resource template's
/// URI parameters should be autocompleted.
///
/// - SeeAlso: ``CompletionReference``
public struct ResourceTemplateReference: Hashable, Codable, Sendable {
    /// The type discriminator, always "ref/resource".
    public let type: String
    /// The URI or URI template of the resource to get completions for.
    public let uri: String

    public init(uri: String) {
        self.type = "ref/resource"
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case type, uri
    }
}

/// A reference type identifying what to provide completions for.
///
/// Completion requests can provide suggestions for either:
/// - Prompt arguments (using ``PromptReference``)
/// - Resource template URI parameters (using ``ResourceTemplateReference``)
///
/// ## Example
///
/// ```swift
/// // Request completions for a prompt argument
/// let promptRef = CompletionReference.prompt(PromptReference(name: "greet"))
///
/// // Request completions for a resource template parameter
/// let resourceRef = CompletionReference.resource(ResourceTemplateReference(uri: "file:///{path}"))
/// ```
public enum CompletionReference: Hashable, Sendable {
    /// Reference to a prompt for argument completion.
    case prompt(PromptReference)
    /// Reference to a resource template for URI parameter completion.
    case resource(ResourceTemplateReference)
}

extension CompletionReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "ref/prompt":
            let ref = try PromptReference(from: decoder)
            self = .prompt(ref)
        case "ref/resource":
            let ref = try ResourceTemplateReference(from: decoder)
            self = .resource(ref)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown reference type: \(type)")
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

/// The argument being completed in a completion request.
///
/// This identifies which argument/parameter the user is currently typing
/// and provides the partial value for matching suggestions.
public struct CompletionArgument: Hashable, Codable, Sendable {
    /// The name of the argument or URI template parameter being completed.
    public let name: String
    /// The current partial value to use for completion matching.
    /// Servers should return suggestions that start with or contain this value.
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Additional context for completion requests.
///
/// Provides previously-resolved argument values that can be used to filter
/// or customize completion suggestions. For example, when completing a file path,
/// the previously-selected directory could be used to show only files in that directory.
public struct CompletionContext: Hashable, Codable, Sendable {
    /// Previously-resolved argument values in a URI template or prompt.
    /// Keys are argument names, values are their resolved values.
    public let arguments: [String: String]?

    public init(arguments: [String: String]? = nil) {
        self.arguments = arguments
    }
}

// MARK: - Completion Result

/// Completion suggestions returned by the server.
///
/// Contains an array of suggested values for the argument being completed,
/// along with pagination information if there are more results available.
///
/// ## Example
///
/// ```swift
/// // Return filtered suggestions
/// let suggestions = CompletionSuggestions(
///     values: ["Alice", "Bob", "Charlie"],
///     total: 3,
///     hasMore: false
/// )
///
/// // Return partial results with more available
/// let partialSuggestions = CompletionSuggestions(
///     values: Array(allValues.prefix(100)),
///     total: allValues.count,
///     hasMore: allValues.count > 100
/// )
///
/// // Or use the convenience initializer which handles truncation automatically
/// let autoTruncated = CompletionSuggestions(from: allValues)
/// ```
public struct CompletionSuggestions: Hashable, Codable, Sendable {
    /// The maximum number of values allowed per the MCP specification.
    public static let maxValues = 100

    /// An empty completion result, for use when no suggestions are available.
    ///
    /// Equivalent to `CompletionSuggestions(values: [], hasMore: false)`.
    public static let empty = CompletionSuggestions(values: [], hasMore: false)

    /// An array of completion values. Must not exceed 100 items per the MCP spec.
    public let values: [String]
    /// The total number of completion options available.
    /// This may exceed the number of values in the response if results are truncated.
    public let total: Int?
    /// Indicates whether there are additional completion options beyond
    /// those provided in the current response, even if the exact total is unknown.
    public let hasMore: Bool?

    /// Creates a completion suggestions result.
    ///
    /// - Parameters:
    ///   - values: The completion values. If more than 100 values are provided,
    ///             only the first 100 will be used per the MCP specification.
    ///   - total: The total number of completion options available.
    ///   - hasMore: Whether there are additional options beyond those provided.
    ///
    /// - Note: This initializer does not automatically set `total` or `hasMore` based on
    ///         the values array. Use ``init(from:)`` for automatic handling of these fields.
    public init(values: [String], total: Int? = nil, hasMore: Bool? = nil) {
        // Enforce the 100-item limit per MCP specification
        self.values = Array(values.prefix(Self.maxValues))
        self.total = total
        self.hasMore = hasMore
    }

    /// Creates a completion suggestions result from an array of values,
    /// automatically handling pagination fields.
    ///
    /// This convenience initializer:
    /// - Truncates values to the maximum of 100 allowed by the MCP specification
    /// - Sets `total` to the original count of all values
    /// - Sets `hasMore` to indicate whether values were truncated
    ///
    /// ## Example
    ///
    /// ```swift
    /// let allLanguages = ["python", "javascript", "typescript", "java", "go", "rust"]
    /// let filtered = allLanguages.filter { $0.hasPrefix(partialValue) }
    /// return Complete.Result(completion: CompletionSuggestions(from: filtered))
    /// ```
    ///
    /// - Parameter allValues: All available completion values. If more than 100 values
    ///                        are provided, only the first 100 will be returned.
    public init(from allValues: [String]) {
        let truncated = Array(allValues.prefix(Self.maxValues))
        self.values = truncated
        self.total = allValues.count
        self.hasMore = allValues.count > Self.maxValues
    }
}

// MARK: - Method

/// A request from the client to the server, to ask for completion options.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/utilities/completion/
public enum Complete: Method {
    public static let name = "completion/complete"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The reference to the prompt or resource template.
        public let ref: CompletionReference
        /// The argument information.
        public let argument: CompletionArgument
        /// Additional, optional context for completions.
        public let context: CompletionContext?
        /// Request metadata including progress token.
        public var _meta: RequestMeta?

        public init(
            ref: CompletionReference,
            argument: CompletionArgument,
            context: CompletionContext? = nil,
            _meta: RequestMeta? = nil
        ) {
            self.ref = ref
            self.argument = argument
            self.context = context
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        /// An empty completion result, for use when no suggestions are available.
        ///
        /// Equivalent to `Complete.Result(completion: .empty)`.
        public static let empty = Result(completion: .empty)

        /// The completion options.
        public let completion: CompletionSuggestions
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        /// Creates a completion result.
        ///
        /// - Parameters:
        ///   - completion: The completion suggestions.
        ///   - _meta: Optional metadata.
        ///   - extraFields: Additional fields for forward compatibility.
        public init(
            completion: CompletionSuggestions,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil
        ) {
            self.completion = completion
            self._meta = _meta
            self.extraFields = extraFields
        }

        /// Creates a completion result from an array of values,
        /// automatically handling pagination.
        ///
        /// This convenience initializer:
        /// - Truncates values to the maximum of 100 allowed by the MCP specification
        /// - Sets `total` to the original count of all values
        /// - Sets `hasMore` to indicate whether values were truncated
        ///
        /// ## Example
        ///
        /// ```swift
        /// server.withRequestHandler(Complete.self) { params, _ in
        ///     let allLanguages = ["python", "javascript", "typescript", "java", "go", "rust"]
        ///     let filtered = allLanguages.filter { $0.hasPrefix(params.argument.value) }
        ///     return Complete.Result(from: filtered)
        /// }
        /// ```
        ///
        /// - Parameter allValues: All available completion values.
        public init(from allValues: [String]) {
            self.completion = CompletionSuggestions(from: allValues)
            self._meta = nil
            self.extraFields = nil
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case completion, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            completion = try container.decode(CompletionSuggestions.self, forKey: .completion)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(completion, forKey: .completion)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}
