import Foundation

/// The standard and custom request headers of the Streamable HTTP transport
/// at protocol 2026-07-28 and later (SEP-2243).
///
/// - `Mcp-Method` carries the JSON-RPC method of every POST.
/// - `Mcp-Name` carries `params.name` of `tools/call` and `prompts/get`,
///   `params.uri` of `resources/read`, and `params.taskId` of `tasks/get`,
///   `tasks/update` and `tasks/cancel` (SEP-2663).
/// - `Mcp-Param-<Name>` mirrors a `tools/call` argument whose input schema
///   property has `"x-mcp-header": "<Name>"`.
///
/// Values that are not printable ASCII, or that have leading or trailing
/// whitespace, are sent as `=?base64?<Base64 of UTF-8>?=`.
public enum MCPRequestHeaders {
    /// The `Mcp-Method` header: the JSON-RPC method of the request.
    public static let method = "Mcp-Method"
    /// The `Mcp-Name` header: the tool or prompt name, the resource URI, or
    /// the task identifier.
    public static let name = "Mcp-Name"
    /// The prefix of `Mcp-Param-<Name>` headers, which mirror tool arguments.
    public static let parameterPrefix = "Mcp-Param-"

    /// The JSON Schema keyword that designates a mirrored argument.
    public static let schemaKeyword = "x-mcp-header"

    private static let base64Prefix = "=?base64?"
    private static let base64Suffix = "?="

    // MARK: - Value encoding

    /// Encodes a header value, wrapping it in Base64 when it is not safe as-is.
    public static func encode(_ value: String) -> String {
        // Some HTTP stacks drop empty header values; send them wrapped.
        let safe =
            !value.isEmpty
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
            && value.first.map { $0 != " " } ?? true
            && value.last.map { $0 != " " } ?? true
            && !(value.hasPrefix(base64Prefix) && value.hasSuffix(base64Suffix))
        guard safe else {
            return base64Prefix + Data(value.utf8).base64EncodedString() + base64Suffix
        }
        return value
    }

    /// Decodes a header value: unwraps `=?base64?...?=` and trims surrounding
    /// whitespace. Returns `nil` for malformed Base64 or invalid UTF-8.
    public static func decode(_ header: String) -> String? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix(base64Prefix), value.hasSuffix(base64Suffix),
            value.count >= base64Prefix.count + base64Suffix.count
        else { return value }
        let payload = String(value.dropFirst(base64Prefix.count).dropLast(base64Suffix.count))
        guard payload.count % 4 == 0,
            payload.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
            let data = Data(base64Encoded: payload),
            data.base64EncodedString() == payload,
            let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded
    }

    /// The header text of a primitive argument: strings as-is, booleans as
    /// `true`/`false`, integers in decimal. `nil` for null, non-integral
    /// numbers, arrays and objects.
    public static func render(_ value: Value) -> String? {
        switch value {
        case .string(let string): return string
        case .bool(let bool): return bool ? "true" : "false"
        case .int(let int): return String(int)
        case .double(let double) where double.rounded() == double && abs(double) < 9_007_199_254_740_992:
            return String(Int(double))
        default: return nil
        }
    }

    // MARK: - Standard headers

    /// The `Mcp-Name` value of a request: `params.name` for `tools/call` and
    /// `prompts/get`, `params.uri` for `resources/read`, `params.taskId` for
    /// `tasks/get`, `tasks/update` and `tasks/cancel`.
    public static func nameValue(method: String, params: Value?) -> String? {
        let object = params?.objectValue
        return nameValue(
            method: method, name: object?["name"]?.stringValue, uri: object?["uri"]?.stringValue,
            taskID: object?["taskId"]?.stringValue)
    }

    /// The `Mcp-Name` value of a request from its `params.name`,
    /// `params.uri` and `params.taskId`.
    static func nameValue(method: String, name: String?, uri: String?, taskID: String?) -> String? {
        switch method {
        case CallTool.name, GetPrompt.name: return name
        case ReadResource.name: return uri
        case GetTask.name, UpdateTask.name, CancelTask.name: return taskID
        default: return nil
        }
    }

    // MARK: - Custom headers

    /// An argument mirrored into an `Mcp-Param-<Name>` header.
    public struct Parameter: Hashable, Sendable {
        /// The header name suffix from `x-mcp-header`.
        public let headerName: String
        /// The path of the argument in `arguments`.
        public let path: [String]
        /// The schema `type` of the argument: `string`, `integer` or `boolean`.
        public let type: String

        /// The full header name, `Mcp-Param-<Name>`.
        public var fieldName: String { parameterPrefix + headerName }
    }

    /// Why an `x-mcp-header` annotation is invalid.
    public struct InvalidAnnotation: Error, CustomStringConvertible, Sendable {
        /// A readable reason, prefixed with the property path when one applies.
        public let description: String
    }

    /// The most `x-mcp-header` annotations of one tool.
    public static let maxAnnotations = 64

    /// The deepest `properties` nesting searched for annotations, and the
    /// deepest subschema nesting inspected for misplaced ones: a subschema
    /// nested deeper is not read, so an annotation there is ignored.
    public static let maxSchemaDepth = 32

    /// The mirrored arguments of a tool input schema.
    ///
    /// Annotations are read on properties reachable through `properties`
    /// from the schema root. `$ref` is not followed. An annotation anywhere
    /// else (under `items`, `prefixItems`, `additionalProperties`,
    /// `anyOf`/`oneOf`/`allOf`, `not`, `if`/`then`/`else`, `$defs`,
    /// `patternProperties` or another subschema keyword, or on the root)
    /// makes the schema invalid, down to ``maxSchemaDepth`` subschemas from
    /// the root; below that it is neither rejected nor mirrored.
    ///
    /// - Throws: ``InvalidAnnotation`` when a header name is empty, not an
    ///   HTTP token, or duplicated (case-insensitively), when the property
    ///   type is not `string`, `integer` or `boolean`, when an annotation is
    ///   not statically reachable through `properties`, when the schema has
    ///   more than ``maxAnnotations`` annotations, or when `properties` nest
    ///   deeper than ``maxSchemaDepth``. Descriptions name the property path,
    ///   escaped and truncated, never the annotation itself.
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#schema-extension
    public static func parameters(in schema: Value) throws -> [Parameter] {
        var found: [Parameter] = []
        var names: Set<String> = []
        func walk(_ schema: Value, path: [String]) throws {
            guard let properties = schema.objectValue?["properties"]?.objectValue else { return }
            guard path.count < maxSchemaDepth else {
                throw InvalidAnnotation(description: "\(describe(path)): properties nested deeper than \(maxSchemaDepth)")
            }
            for key in properties.keys.sorted() {
                guard let property = properties[key]?.objectValue else { continue }
                let propertyPath = path + [key]
                if let annotation = property[schemaKeyword] {
                    let location = describe(propertyPath)
                    guard let name = annotation.stringValue, !name.isEmpty else {
                        throw InvalidAnnotation(description: "\(location): empty or non-string \(schemaKeyword)")
                    }
                    guard name.unicodeScalars.allSatisfy(isTokenCharacter) else {
                        throw InvalidAnnotation(description: "\(location): \(schemaKeyword) is not a valid HTTP header name")
                    }
                    let type = property["type"]?.stringValue ?? ""
                    guard ["string", "integer", "boolean"].contains(type) else {
                        throw InvalidAnnotation(description: "\(location): this type cannot be mirrored")
                    }
                    guard names.insert(name.lowercased()).inserted else {
                        throw InvalidAnnotation(description: "\(location): duplicate header name")
                    }
                    guard names.count <= maxAnnotations else {
                        throw InvalidAnnotation(description: "more than \(maxAnnotations) \(schemaKeyword) annotations")
                    }
                    found.append(Parameter(headerName: name, path: propertyPath, type: type))
                }
                try walk(.object(property), path: propertyPath)
            }
        }
        try walk(schema, path: [])
        try rejectUnreachableAnnotations(in: schema)
        return found
    }

    /// Keywords whose value is one subschema (JSON Schema 2020-12 and draft-07).
    private static let subschemaKeywords: Set<String> = [
        "items", "additionalItems", "additionalProperties", "unevaluatedItems", "unevaluatedProperties",
        "not", "if", "then", "else", "contains", "propertyNames",
    ]
    /// Keywords whose value is an array of subschemas.
    private static let subschemaArrayKeywords: Set<String> = ["prefixItems", "allOf", "anyOf", "oneOf", "items"]
    /// Keywords whose value maps names to subschemas.
    private static let subschemaMapKeywords: Set<String> = [
        "properties", "$defs", "definitions", "patternProperties", "dependentSchemas", "dependencies",
    ]

    /// Throws for an annotation that is not on a property reached through
    /// a chain of `properties` keys from the root. Subschemas are found by
    /// keyword, so values such as `default`, `const` or `enum`, which may
    /// hold any JSON, are not read. Subschemas more than ``maxSchemaDepth``
    /// levels down are not read either, so that a deep schema without
    /// annotations stays valid.
    private static func rejectUnreachableAnnotations(in schema: Value) throws {
        func visit(_ schema: Value, path: [String], depth: Int, onChain: Bool) throws {
            guard let object = schema.objectValue else { return }
            if object[schemaKeyword] != nil, !onChain || path.isEmpty {
                throw InvalidAnnotation(
                    description: "\(describe(path)): \(schemaKeyword) is not statically reachable through properties")
            }
            guard depth < maxSchemaDepth else { return }
            for key in object.keys.sorted() {
                guard let value = object[key] else { continue }
                switch value {
                case .object(let members) where subschemaMapKeywords.contains(key):
                    for name in members.keys.sorted() {
                        // A property's path is its name, as in `parameters(in:)`.
                        let child = key == "properties" ? path + [name] : path + [key, name]
                        try visit(members[name]!, path: child, depth: depth + 1, onChain: onChain && key == "properties")
                    }
                case .object where subschemaKeywords.contains(key):
                    try visit(value, path: path + [key], depth: depth + 1, onChain: false)
                case .array(let items) where subschemaArrayKeywords.contains(key):
                    for (index, item) in items.enumerated() {
                        try visit(item, path: path + ["\(key)[\(index)]"], depth: depth + 1, onChain: false)
                    }
                default:
                    continue
                }
            }
        }
        try visit(schema, path: [], depth: 0, onChain: true)
    }

    /// A property path for messages: control and non-ASCII characters
    /// escaped, at most 128 characters.
    static func describe(_ path: [String]) -> String {
        sanitized(path.isEmpty ? "(root)" : path.joined(separator: "."))
    }

    /// Peer text for logs and errors: characters outside printable ASCII
    /// replaced with `?`, at most `limit` characters.
    package static func sanitized(_ text: String, limit: Int = 128) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(limit) {
            scalars.append((0x20...0x7E).contains(scalar.value) ? scalar : "?")
        }
        let result = String(scalars)
        return text.unicodeScalars.count > limit ? result + "..." : result
    }

    /// RFC 9110 `tchar`.
    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        default: return "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
        }
    }

    /// The argument at `path`, or `nil` when absent or null.
    static func argument(at path: [String], in arguments: Value?) -> Value? {
        var current = arguments
        for key in path {
            current = current?.objectValue?[key]
        }
        if current == .null { return nil }
        return current
    }

    /// The `Mcp-Param-*` headers for a `tools/call`.
    public static func parameterHeaders(_ parameters: [Parameter], arguments: Value?) -> [String: String] {
        var headers: [String: String] = [:]
        for parameter in parameters {
            guard let value = argument(at: parameter.path, in: arguments),
                let text = render(value)
            else { continue }
            headers[parameter.fieldName] = encode(text)
        }
        return headers
    }

    /// Checks `Mcp-Param-*` headers against `tools/call` arguments.
    ///
    /// A header must be present exactly when its argument is present and not
    /// null, and its decoded value must equal the rendered argument.
    /// Returns a description of the first mismatch.
    static func validate(
        _ parameters: [Parameter], arguments: Value?, header: (String) -> String?
    ) -> String? {
        for parameter in parameters {
            let raw = header(parameter.fieldName)
            let value = argument(at: parameter.path, in: arguments)
            switch (raw, value) {
            case (nil, nil):
                continue
            case (nil, .some):
                return "Missing \(parameter.fieldName) header"
            case (.some, nil):
                return "\(parameter.fieldName) header sent for an absent argument"
            case (.some(let raw), .some(let value)):
                guard let decoded = decode(raw) else {
                    return "\(parameter.fieldName) header has invalid Base64"
                }
                guard let expected = render(value) else {
                    return "\(parameter.fieldName) argument is not a primitive value"
                }
                guard decoded == expected else {
                    return "\(parameter.fieldName) header does not match the argument"
                }
            }
        }
        return nil
    }
}

extension Tool {
    /// The arguments this tool mirrors into `Mcp-Param-*` headers (SEP-2243).
    ///
    /// - Throws: ``MCPRequestHeaders/InvalidAnnotation`` for an invalid
    ///   `x-mcp-header` annotation.
    public func headerParameters() throws -> [MCPRequestHeaders.Parameter] {
        try MCPRequestHeaders.parameters(in: inputSchema)
    }
}
