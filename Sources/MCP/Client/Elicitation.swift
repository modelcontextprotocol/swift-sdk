import Foundation

/// Elicitation allows servers to request additional information from users
/// through the client. This enables interactive workflows where the server
/// needs user input during an operation.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/client/elicitation/

// MARK: - Schema Types

/// Format constraints for string fields in elicitation forms.
///
/// These formats provide validation hints to the client for user input fields.
/// The client may use these to provide appropriate input controls or validation.
public enum StringSchemaFormat: String, Hashable, Codable, Sendable {
    /// Email address format (e.g., "user@example.com")
    case email
    /// URI format (e.g., "https://example.com/path")
    case uri
    /// Date format (ISO 8601 date, e.g., "2024-01-15")
    case date
    /// Date-time format (ISO 8601 date-time, e.g., "2024-01-15T10:30:00Z")
    case dateTime = "date-time"
}

/// Schema definition for string input fields in elicitation forms.
///
/// Use this to request text input from the user, optionally with validation constraints
/// like minimum/maximum length, pattern (regex), or format requirements.
///
/// ```swift
/// // Simple text field
/// let nameField = StringSchema(title: "Name", description: "Your full name")
///
/// // Email field with validation
/// let emailField = StringSchema(
///     title: "Email",
///     format: .email,
///     defaultValue: "user@example.com"
/// )
///
/// // Field with regex pattern validation
/// let zipCode = StringSchema(
///     title: "ZIP Code",
///     pattern: "^[0-9]{5}$"
/// )
/// ```
public struct StringSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var pattern: String?
    public var format: StringSchemaFormat?
    public var defaultValue: String?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, minLength, maxLength, pattern, format
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        format: StringSchemaFormat? = nil,
        defaultValue: String? = nil
    ) {
        self.type = "string"
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.format = format
        self.defaultValue = defaultValue
    }
}

/// Schema definition for numeric input fields in elicitation forms.
///
/// Use this to request number or integer input from the user, optionally with
/// minimum/maximum constraints.
///
/// ```swift
/// // Integer field for age
/// let ageField = NumberSchema(isInteger: true, title: "Age", minimum: 0, maximum: 150)
///
/// // Decimal field for price
/// let priceField = NumberSchema(title: "Price", minimum: 0.0)
/// ```
public struct NumberSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var minimum: Double?
    public var maximum: Double?
    public var defaultValue: Double?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, minimum, maximum
        case defaultValue = "default"
    }

    public init(
        isInteger: Bool = false,
        title: String? = nil,
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        defaultValue: Double? = nil
    ) {
        self.type = isInteger ? "integer" : "number"
        self.title = title
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }
}

/// Schema definition for boolean (checkbox/toggle) fields in elicitation forms.
///
/// Use this to request a yes/no or true/false choice from the user.
///
/// ```swift
/// let agreeField = BooleanSchema(
///     title: "I agree to the terms",
///     description: "You must accept the terms to continue",
///     defaultValue: false
/// )
/// ```
public struct BooleanSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var defaultValue: Bool?

    private enum CodingKeys: String, CodingKey {
        case type, title, description
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        defaultValue: Bool? = nil
    ) {
        self.type = "boolean"
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
    }
}

/// An option in a titled enum with a value and display label.
public struct TitledEnumOption: Hashable, Codable, Sendable {
    /// The constant value for this option.
    public let const: String
    /// The display label for this option.
    public let title: String

    public init(const: String, title: String) {
        self.const = const
        self.title = title
    }
}

/// Schema definition for single-select enum fields without display titles.
public struct UntitledEnumSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var enumValues: [String]
    public var defaultValue: String?

    private enum CodingKeys: String, CodingKey {
        case type, title, description
        case enumValues = "enum"
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        enumValues: [String],
        defaultValue: String? = nil
    ) {
        self.type = "string"
        self.title = title
        self.description = description
        self.enumValues = enumValues
        self.defaultValue = defaultValue
    }
}

/// Schema definition for single-select enum fields with display titles.
public struct TitledEnumSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var oneOf: [TitledEnumOption]
    public var defaultValue: String?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, oneOf
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        oneOf: [TitledEnumOption],
        defaultValue: String? = nil
    ) {
        self.type = "string"
        self.title = title
        self.description = description
        self.oneOf = oneOf
        self.defaultValue = defaultValue
    }
}

/// Schema definition for legacy enum fields with enumNames (non-standard).
public struct LegacyTitledEnumSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var enumValues: [String]
    public var enumNames: [String]?
    public var defaultValue: String?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, enumNames
        case enumValues = "enum"
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        enumValues: [String],
        enumNames: [String]? = nil,
        defaultValue: String? = nil
    ) {
        self.type = "string"
        self.title = title
        self.description = description
        self.enumValues = enumValues
        self.enumNames = enumNames
        self.defaultValue = defaultValue
    }
}

// MARK: - Multi-Select Enum Schemas

/// Items definition for untitled multi-select enum.
public struct UntitledMultiSelectItems: Hashable, Codable, Sendable {
    public let type: String
    public var enumValues: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case enumValues = "enum"
    }

    public init(enumValues: [String]) {
        self.type = "string"
        self.enumValues = enumValues
    }
}

/// Schema definition for multi-select enum fields without display titles.
public struct UntitledMultiSelectEnumSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var minItems: Int?
    public var maxItems: Int?
    public var items: UntitledMultiSelectItems
    public var defaultValue: [String]?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, minItems, maxItems, items
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        enumValues: [String],
        defaultValue: [String]? = nil
    ) {
        self.type = "array"
        self.title = title
        self.description = description
        self.minItems = minItems
        self.maxItems = maxItems
        self.items = UntitledMultiSelectItems(enumValues: enumValues)
        self.defaultValue = defaultValue
    }
}

/// Items definition for titled multi-select enum.
public struct TitledMultiSelectItems: Hashable, Codable, Sendable {
    public var anyOf: [TitledEnumOption]

    public init(anyOf: [TitledEnumOption]) {
        self.anyOf = anyOf
    }
}

/// Schema definition for multi-select enum fields with display titles.
public struct TitledMultiSelectEnumSchema: Hashable, Codable, Sendable {
    public let type: String
    public var title: String?
    public var description: String?
    public var minItems: Int?
    public var maxItems: Int?
    public var items: TitledMultiSelectItems
    public var defaultValue: [String]?

    private enum CodingKeys: String, CodingKey {
        case type, title, description, minItems, maxItems, items
        case defaultValue = "default"
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        options: [TitledEnumOption],
        defaultValue: [String]? = nil
    ) {
        self.type = "array"
        self.title = title
        self.description = description
        self.minItems = minItems
        self.maxItems = maxItems
        self.items = TitledMultiSelectItems(anyOf: options)
        self.defaultValue = defaultValue
    }
}

/// A primitive schema definition for form fields in elicitation requests.
///
/// This enum represents all the field types that can be used in an elicitation form.
/// Each case corresponds to a specific input type with its own validation and display options.
///
/// ## Supported Field Types
///
/// - **string**: Text input with optional format validation (email, URI, date)
/// - **number**: Numeric input (integer or decimal) with optional min/max
/// - **boolean**: Checkbox or toggle for true/false values
/// - **untitledEnum**: Single-select dropdown with simple string values
/// - **titledEnum**: Single-select dropdown with separate values and display labels
/// - **untitledMultiSelect**: Multi-select list with simple string values
/// - **titledMultiSelect**: Multi-select list with separate values and display labels
///
/// ## Example
///
/// ```swift
/// let schema = ElicitationSchema(properties: [
///     "name": .string(StringSchema(title: "Name")),
///     "age": .number(NumberSchema(isInteger: true, title: "Age", minimum: 0)),
///     "agree": .boolean(BooleanSchema(title: "Accept terms")),
///     "color": .untitledEnum(UntitledEnumSchema(title: "Color", enumValues: ["red", "green", "blue"]))
/// ])
/// ```
public enum PrimitiveSchemaDefinition: Hashable, Sendable {
    case string(StringSchema)
    case number(NumberSchema)
    case boolean(BooleanSchema)
    case untitledEnum(UntitledEnumSchema)
    case titledEnum(TitledEnumSchema)
    case legacyTitledEnum(LegacyTitledEnumSchema)
    case untitledMultiSelect(UntitledMultiSelectEnumSchema)
    case titledMultiSelect(TitledMultiSelectEnumSchema)
}

extension PrimitiveSchemaDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, oneOf, enumValues = "enum", enumNames, items
    }

    private enum ItemsCodingKeys: String, CodingKey {
        case enumValues = "enum", anyOf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "string":
            // Check if it's an enum type (has enum or oneOf)
            if container.contains(.oneOf) {
                let schema = try TitledEnumSchema(from: decoder)
                self = .titledEnum(schema)
            } else if container.contains(.enumValues) {
                // Check for enumNames (legacy format)
                if container.contains(.enumNames) {
                    let schema = try LegacyTitledEnumSchema(from: decoder)
                    self = .legacyTitledEnum(schema)
                } else {
                    let schema = try UntitledEnumSchema(from: decoder)
                    self = .untitledEnum(schema)
                }
            } else {
                let schema = try StringSchema(from: decoder)
                self = .string(schema)
            }
        case "array":
            // Multi-select enum - check items for anyOf (titled) or enum (untitled)
            if container.contains(.items) {
                let itemsContainer = try container.nestedContainer(
                    keyedBy: ItemsCodingKeys.self, forKey: .items)
                if itemsContainer.contains(.anyOf) {
                    let schema = try TitledMultiSelectEnumSchema(from: decoder)
                    self = .titledMultiSelect(schema)
                } else {
                    let schema = try UntitledMultiSelectEnumSchema(from: decoder)
                    self = .untitledMultiSelect(schema)
                }
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "Array type must have items property")
            }
        case "number", "integer":
            let schema = try NumberSchema(from: decoder)
            self = .number(schema)
        case "boolean":
            let schema = try BooleanSchema(from: decoder)
            self = .boolean(schema)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown primitive schema type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let schema):
            try schema.encode(to: encoder)
        case .number(let schema):
            try schema.encode(to: encoder)
        case .boolean(let schema):
            try schema.encode(to: encoder)
        case .untitledEnum(let schema):
            try schema.encode(to: encoder)
        case .titledEnum(let schema):
            try schema.encode(to: encoder)
        case .legacyTitledEnum(let schema):
            try schema.encode(to: encoder)
        case .untitledMultiSelect(let schema):
            try schema.encode(to: encoder)
        case .titledMultiSelect(let schema):
            try schema.encode(to: encoder)
        }
    }
}

// MARK: - Elicitation Request

/// Parameters for a form-mode elicitation request.
public struct ElicitRequestFormParams: Hashable, Codable, Sendable {
    /// The elicitation mode (optional, defaults to "form").
    public var mode: String?
    /// The message to present to the user describing what information is being requested.
    public var message: String
    /// A restricted subset of JSON Schema defining the form fields.
    public var requestedSchema: ElicitationSchema
    /// Request metadata including progress token.
    public var _meta: RequestMeta?
    /// Task augmentation metadata. If present, the receiver should run the elicitation
    /// as a background task and return `CreateTaskResult` instead of `ElicitResult`.
    public var task: TaskMetadata?

    public init(
        mode: String? = nil,
        message: String,
        requestedSchema: ElicitationSchema,
        _meta: RequestMeta? = nil,
        task: TaskMetadata? = nil
    ) {
        self.mode = mode
        self.message = message
        self.requestedSchema = requestedSchema
        self._meta = _meta
        self.task = task
    }
}

/// The schema for an elicitation form, defining the fields and their types.
public struct ElicitationSchema: Hashable, Codable, Sendable {
    /// The JSON Schema dialect (optional).
    public var schema: String?
    /// Must be "object".
    public let type: String
    /// The form field definitions.
    public var properties: [String: PrimitiveSchemaDefinition]
    /// The list of required field names.
    public var required: [String]?

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case type, properties, required
    }

    public init(
        schema: String? = nil,
        properties: [String: PrimitiveSchemaDefinition],
        required: [String]? = nil
    ) {
        self.schema = schema
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

// MARK: - Elicitation Result

/// The action taken by the user in response to an elicitation request.
public enum ElicitAction: String, Hashable, Codable, Sendable {
    /// User submitted the form/confirmed the action.
    case accept
    /// User explicitly declined the action.
    case decline
    /// User dismissed without making an explicit choice.
    case cancel
}

/// A value that can be returned in elicitation form content.
public enum ElicitValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case strings([String])
}

extension ElicitValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try to decode as each type
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else {
            throw DecodingError.typeMismatch(
                ElicitValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String, Int, Double, Bool, or [String]"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .strings(let value):
            try container.encode(value)
        }
    }
}

/// The result of an elicitation request.
public struct ElicitResult: ResultWithExtraFields {
    public typealias ResultCodingKeys = CodingKeys

    /// The user action in response to the elicitation.
    public var action: ElicitAction
    /// The submitted form data, only present when action is "accept".
    public var content: [String: ElicitValue]?
    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?
    /// Additional fields not defined in the schema (for forward compatibility).
    public var extraFields: [String: Value]?

    public init(
        action: ElicitAction,
        content: [String: ElicitValue]? = nil,
        _meta: [String: Value]? = nil,
        extraFields: [String: Value]? = nil
    ) {
        self.action = action
        self.content = content
        self._meta = _meta
        self.extraFields = extraFields
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case action, content, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(ElicitAction.self, forKey: .action)
        content = try container.decodeIfPresent([String: ElicitValue].self, forKey: .content)
        _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
        extraFields = try Self.decodeExtraFields(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(_meta, forKey: ._meta)
        try encodeExtraFields(to: encoder)
    }
}

// MARK: - URL Mode Elicitation

/// Parameters for a URL-mode elicitation request.
///
/// URL mode is used for out-of-band flows like OAuth or credential collection,
/// where the user needs to navigate to an external URL.
public struct ElicitRequestURLParams: Hashable, Codable, Sendable {
    /// The elicitation mode (must be "url").
    public let mode: String
    /// The message to present to the user explaining why the interaction is needed.
    public var message: String
    /// The ID of the elicitation, which must be unique within the context of the server.
    /// The client MUST treat this ID as an opaque value.
    public var elicitationId: String
    /// The URL that the user should navigate to.
    public var url: String
    /// Request metadata including progress token.
    public var _meta: RequestMeta?
    /// Task augmentation metadata. If present, the receiver should run the elicitation
    /// as a background task and return `CreateTaskResult` instead of `ElicitResult`.
    public var task: TaskMetadata?

    public init(
        message: String,
        elicitationId: String,
        url: String,
        _meta: RequestMeta? = nil,
        task: TaskMetadata? = nil
    ) {
        self.mode = "url"
        self.message = message
        self.elicitationId = elicitationId
        self.url = url
        self._meta = _meta
        self.task = task
    }
}

/// Parameters for elicitation requests (either form or URL mode).
public enum ElicitRequestParams: Hashable, Sendable {
    case form(ElicitRequestFormParams)
    case url(ElicitRequestURLParams)
}

extension ElicitRequestParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "form"

        switch mode {
        case "url":
            let params = try ElicitRequestURLParams(from: decoder)
            self = .url(params)
        default:
            let params = try ElicitRequestFormParams(from: decoder)
            self = .form(params)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .form(let params):
            try params.encode(to: encoder)
        case .url(let params):
            try params.encode(to: encoder)
        }
    }
}

/// Notification from the server to the client, informing it of completion
/// of an out-of-band (URL mode) elicitation request.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/
public struct ElicitationCompleteNotification: Notification {
    public static let name = "notifications/elicitation/complete"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The ID of the elicitation that completed.
        public var elicitationId: String
        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(elicitationId: String, _meta: [String: Value]? = nil) {
            self.elicitationId = elicitationId
            self._meta = _meta
        }
    }
}

// MARK: - Error Codes

/// Error code indicating URL elicitation is required.
///
/// This error is returned when a server requires the client to perform
/// URL-mode elicitation but the client doesn't support it.
///
/// - Note: Prefer using `ErrorCode.urlElicitationRequired` or
///   throwing `MCPError.urlElicitationRequired(elicitations:)` directly.
@available(*, deprecated, renamed: "ErrorCode.urlElicitationRequired")
public let URLElicitationRequiredErrorCode: Int = ErrorCode.urlElicitationRequired

/// Error data for `URLElicitationRequiredError`.
///
/// Servers return this when a request cannot be processed until one or more
/// URL mode elicitations are completed. The error response includes this data
/// in the `data` field with the error code `-32042`.
///
/// Example error response:
/// ```json
/// {
///   "jsonrpc": "2.0",
///   "id": 2,
///   "error": {
///     "code": -32042,
///     "message": "This request requires more information.",
///     "data": {
///       "elicitations": [
///         {
///           "mode": "url",
///           "elicitationId": "...",
///           "url": "https://example.com/...",
///           "message": "..."
///         }
///       ]
///     }
///   }
/// }
/// ```
public struct ElicitationRequiredErrorData: Hashable, Codable, Sendable {
    /// List of URL mode elicitations that must be completed.
    public var elicitations: [ElicitRequestURLParams]

    public init(elicitations: [ElicitRequestURLParams]) {
        self.elicitations = elicitations
    }
}

// MARK: - Method

/// Server requests additional information from the user via the client.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/client/elicitation/
public enum Elicit: Method {
    public static let name = "elicitation/create"

    public typealias Parameters = ElicitRequestParams
    public typealias Result = ElicitResult
}
