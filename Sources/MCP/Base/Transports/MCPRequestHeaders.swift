import Foundation

/// The standard and custom request headers of the Streamable HTTP transport
/// at protocol 2026-07-28 and later (SEP-2243).
///
/// - `Mcp-Method` carries the JSON-RPC method of every POST.
/// - `Mcp-Name` carries `params.name` of `tools/call` and `prompts/get`, and
///   `params.uri` of `resources/read`.
/// - `Mcp-Param-<Name>` mirrors a `tools/call` argument whose input schema
///   property has `"x-mcp-header": "<Name>"`.
///
/// Values that are not printable ASCII, or that have leading or trailing
/// whitespace, are sent as `=?base64?<Base64 of UTF-8>?=`.
public enum MCPRequestHeaders {
    public static let method = "Mcp-Method"
    public static let name = "Mcp-Name"
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
    /// `prompts/get`, `params.uri` for `resources/read`.
    public static func nameValue(method: String, params: Value?) -> String? {
        let object = params?.objectValue
        return nameValue(method: method, name: object?["name"]?.stringValue, uri: object?["uri"]?.stringValue)
    }

    /// The `Mcp-Name` value of a request from its `params.name` and
    /// `params.uri`.
    static func nameValue(method: String, name: String?, uri: String?) -> String? {
        switch method {
        case CallTool.name, GetPrompt.name: return name
        case ReadResource.name: return uri
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
        public let description: String
    }

    /// The most `x-mcp-header` annotations of one tool.
    public static let maxAnnotations = 64

    /// The deepest `properties` nesting searched for annotations.
    public static let maxSchemaDepth = 32

    /// The mirrored arguments of a tool input schema.
    ///
    /// Annotations are read on properties reachable through `properties`
    /// from the schema root. `$ref` is not followed.
    ///
    /// - Throws: ``InvalidAnnotation`` when a header name is empty, not an
    ///   HTTP token, or duplicated (case-insensitively), when the property
    ///   type is not `string`, `integer` or `boolean`, when the schema has
    ///   more than ``maxAnnotations`` annotations, or when `properties` nest
    ///   deeper than ``maxSchemaDepth``. Descriptions name the property path,
    ///   escaped and truncated, never the annotation itself.
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
        return found
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
