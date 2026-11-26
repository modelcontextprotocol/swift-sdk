import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// A codable value.
///
/// Frozen: no case is added in 1.x (the cases are the JSON data model, plus `data`).
public enum Value: Hashable, Sendable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number that is an integer.
    case int(Int)
    /// A JSON number that is a floating-point value.
    case double(Double)
    /// A JSON string.
    case string(String)
    /// Binary data, encoded as a `data:` URL string with its MIME type, if any.
    ///
    /// A plain decode gives this case for a string that is a whole `data:`
    /// URL. ``Value/init(from:)`` gives the rules. The SDK's own message
    /// paths keep strings as written. The typed decode of a handler's
    /// parameters or of a request's result is a plain decode, so a tool
    /// argument or `structuredContent` can hold this case.
    ///
    /// This case encodes as `data:<mimeType>;base64,<payload>`, with
    /// `text/plain` for a `nil` MIME type. The spelling of the decoded
    /// string is not kept: `data:,hi` encodes as
    /// `data:text/plain;base64,aGk=`.
    case data(mimeType: String? = nil, Data)
    /// A JSON array.
    case array([Value])
    /// A JSON object.
    case object([String: Value])

    /// Create a `Value` from an `Encodable` value.
    /// - Parameter value: The encodable value
    /// - Returns: A value
    public init<T: Encodable>(_ value: T) throws {
        if let valueAsValue = value as? Value {
            self = valueAsValue
        } else {
            let data = try JSONEncoder().encode(value)
            self = try JSONDecoder().decode(Value.self, from: data)
        }
    }

    /// Creates a `Value` that encodes to the same JSON as `value`: strings,
    /// including `data:` URLs, stay strings.
    static func preservingStrings<T: Encodable>(_ value: T) throws -> Value {
        if let valueAsValue = value as? Value { return valueAsValue }
        let decoder = JSONDecoder()
        decoder.userInfo[.valuePreservesStrings] = true
        return try decoder.decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// The value a plain `JSONDecoder` gives for the JSON this value encodes
    /// to: `data:` URL strings become `.data`.
    var decodingDataURLs: Value {
        (try? JSONDecoder().decode(Value.self, from: JSONEncoder().encode(self))) ?? self
    }

    /// Returns whether the value is `null`.
    public var isNull: Bool {
        return self == .null
    }

    /// Returns the `Bool` value if the value is a `bool`,
    /// otherwise returns `nil`.
    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// Returns the `Int` value if the value is an `integer`,
    /// otherwise returns `nil`.
    public var intValue: Int? {
        guard case let .int(value) = self else { return nil }
        return value
    }

    /// Returns the `Double` value if the value is a `double`,
    /// otherwise returns `nil`.
    public var doubleValue: Double? {
        guard case let .double(value) = self else { return nil }
        return value
    }

    /// Returns the underlying number as a `Double`, regardless of
    /// whether the value is an `int` or a `double`.
    ///
    /// JSON has a single `number` type with no distinction between
    /// integers and floating-point — but Swift's `JSONEncoder` writes
    /// whole-number `Double`s without a decimal point, and the decoder
    /// in `Value.init(from:)` tries `Int` first. So `Value.double(0)`
    /// round-trips through JSON to `Value.int(0)`, and `doubleValue`
    /// returns `nil`.
    ///
    /// This accessor coerces both `.int(_)` and `.double(_)` to
    /// `Double`, which is what most consumers want when reading
    /// numeric tool arguments (coordinates, dimensions, angles): the
    /// value is a number, regardless of whether the JSON shape was
    /// `0` or `0.0`.
    ///
    /// Returns `nil` for any non-numeric case.
    public var numberValue: Double? {
        switch self {
        case .int(let value):    return Double(value)
        case .double(let value): return value
        default:                 return nil
        }
    }

    /// Returns the `String` value if the value is a `string`,
    /// otherwise returns `nil`.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// Returns the data value and optional MIME type if the value is `data`,
    /// otherwise returns `nil`.
    public var dataValue: (mimeType: String?, Data)? {
        guard case let .data(mimeType: mimeType, data) = self else { return nil }
        return (mimeType: mimeType, data)
    }

    /// Returns the `[Value]` value if the value is an `array`,
    /// otherwise returns `nil`.
    public var arrayValue: [Value]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    /// Returns the `[String: Value]` value if the value is an `object`,
    /// otherwise returns `nil`.
    public var objectValue: [String: Value]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

// MARK: - Codable

extension CodingUserInfoKey {
    /// When `true` in a decoder's `userInfo`, ``Value`` decodes `data:` URL
    /// strings as `.string` instead of `.data`.
    static let valuePreservesStrings = CodingUserInfoKey(rawValue: "mcp.value.preservesStrings")!
}

extension Value {
    /// A `Value` decoded with strings as written: a `data:` URL stays a
    /// string, at any depth. It encodes as its value.
    struct Preserved: Hashable, Codable, Sendable {
        let value: Value

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = .null
            } else if let bool = try? container.decode(Bool.self) {
                value = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                value = .int(int)
            } else if let double = try? container.decode(Double.self) {
                value = .double(double)
            } else if let string = try? container.decode(String.self) {
                value = .string(string)
            } else if let array = try? container.decode([Preserved].self) {
                value = .array(array.map(\.value))
            } else if let object = try? container.decode([String: Preserved].self) {
                value = .object(object.mapValues(\.value))
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value type not found")
            }
        }
    }
}

extension Value: Codable {
    /// Creates a value from a decoder.
    ///
    /// The decoder tries `null`, `Bool`, `Int`, `Double`, `String`, an array
    /// and an object, in this order. A string becomes
    /// ``Value/data(mimeType:_:)`` when all of these are true:
    ///
    /// - The whole string is a `data:` URL (RFC 2397). It starts with
    ///   `data:` in lowercase, with no space before it.
    /// - Before the `,`, it has only a media type, then an optional
    ///   `;charset=<value>`, then an optional `;base64`.
    /// - The payload decodes: it is valid base64, or its `%XX` escapes are
    ///   well-formed.
    ///
    /// Other strings stay ``Value/string(_:)``, for example `DATA:,hi`, a
    /// `data:` URL with a `;name=` parameter, or text with a `data:` URL
    /// after its start.
    ///
    /// The SDK's own message paths keep strings as written: the message
    /// decoders of `Client` and `Server`, type-erased requests and
    /// responses, and handler results. The typed decode of a handler's
    /// parameters, and of a result before a request returns it, is a plain
    /// decode. Thus a `Value` field, such as a tool argument or
    /// `structuredContent`, can hold `.data`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            if decoder.userInfo[.valuePreservesStrings] as? Bool != true,
                Data.isDataURL(string: value),
                case let (mimeType, data)? = Data.parseDataURL(value)
            {
                self = .data(mimeType: mimeType, data)
            } else {
                self = .string(value)
            }
        } else if let value = try? container.decode([Value].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Value].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Value type not found")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case let .data(mimeType, value):
            try container.encode(value.dataURLEncoded(mimeType: mimeType))
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null:
            return ""
        case .bool(let value):
            return value.description
        case .int(let value):
            return value.description
        case .double(let value):
            return value.description
        case .string(let value):
            return value.description
        case let .data(mimeType, value):
            return value.dataURLEncoded(mimeType: mimeType)
        case .array(let value):
            return value.description
        case .object(let value):
            return value.description
        }
    }
}

// MARK: - ExpressibleByNilLiteral

extension Value: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: - ExpressibleByBooleanLiteral

extension Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

// MARK: - ExpressibleByFloatLiteral

extension Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

// MARK: - ExpressibleByStringLiteral

extension Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: - ExpressibleByArrayLiteral

extension Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self = .array(elements)
    }
}

// MARK: - ExpressibleByDictionaryLiteral

extension Value: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) {
        var dictionary: [String: Value] = [:]
        for (key, value) in elements {
            dictionary[key] = value
        }
        self = .object(dictionary)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension Value: ExpressibleByStringInterpolation {
    /// Builds the string of a ``Value/string(_:)`` from an interpolated literal.
    public struct StringInterpolation: StringInterpolationProtocol {
        var stringValue: String

        /// Creates an empty interpolation, reserving capacity for the literal.
        public init(literalCapacity: Int, interpolationCount: Int) {
            self.stringValue = ""
            self.stringValue.reserveCapacity(literalCapacity + interpolationCount)
        }

        /// Appends a literal segment.
        public mutating func appendLiteral(_ literal: String) {
            self.stringValue.append(literal)
        }

        /// Appends the `description` of an interpolated value.
        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
            self.stringValue.append(value.description)
        }
    }

    public init(stringInterpolation: StringInterpolation) {
        self = .string(stringInterpolation.stringValue)
    }
}

// MARK: - Standard Library Type Extensions

extension Bool {
    /// Creates a boolean value from a `Value` instance.
    ///
    /// In strict mode, only `.bool` values are converted. In non-strict mode, the following conversions are supported:
    /// - Integers: `1` is `true`, `0` is `false`
    /// - Doubles: `1.0` is `true`, `0.0` is `false`
    /// - Strings (lowercase only):
    ///   - `true`: "true", "t", "yes", "y", "on", "1"
    ///   - `false`: "false", "f", "no", "n", "off", "0"
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.bool` values. Defaults to `true`
    /// - Returns: A boolean value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Bool(Value.bool(true)) // Returns true
    ///   Bool(Value.int(1), strict: false) // Returns true
    ///   Bool(Value.string("yes"), strict: false) // Returns true
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .bool(let b):
            self = b
        case .int(let i) where !strict:
            switch i {
            case 0: self = false
            case 1: self = true
            default: return nil
            }
        case .double(let d) where !strict:
            switch d {
            case 0.0: self = false
            case 1.0: self = true
            default: return nil
            }
        case .string(let s) where !strict:
            switch s {
            case "true", "t", "yes", "y", "on", "1":
                self = true
            case "false", "f", "no", "n", "off", "0":
                self = false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

extension Int {
    /// Creates an integer value from a `Value` instance.
    ///
    /// In strict mode, only `.int` values are converted. In non-strict mode, the following conversions are supported:
    /// - Doubles: Converted if they can be represented exactly as integers
    /// - Strings: Parsed if they contain a valid integer representation
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.int` values. Defaults to `true`
    /// - Returns: An integer value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Int(Value.int(42)) // Returns 42
    ///   Int(Value.double(42.0), strict: false) // Returns 42
    ///   Int(Value.string("42"), strict: false) // Returns 42
    ///   Int(Value.double(42.5), strict: false) // Returns nil
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .int(let i):
            self = i
        case .double(let d) where !strict:
            guard let intValue = Int(exactly: d) else { return nil }
            self = intValue
        case .string(let s) where !strict:
            guard let intValue = Int(s) else { return nil }
            self = intValue
        default:
            return nil
        }
    }
}

extension Double {
    /// Creates a double value from a `Value` instance.
    ///
    /// In strict mode, converts from `.double` and `.int` values. In non-strict mode, the following conversions are supported:
    /// - Integers: Converted to their double representation
    /// - Strings: Parsed if they contain a valid floating-point representation
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.double` and `.int` values. Defaults to `true`
    /// - Returns: A double value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Double(Value.double(42.5)) // Returns 42.5
    ///   Double(Value.int(42)) // Returns 42.0
    ///   Double(Value.string("42.5"), strict: false) // Returns 42.5
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .double(let d):
            self = d
        case .int(let i):
            self = Double(i)
        case .string(let s) where !strict:
            guard let doubleValue = Double(s) else { return nil }
            self = doubleValue
        default:
            return nil
        }
    }
}

extension String {
    /// Creates a string value from a `Value` instance.
    ///
    /// In strict mode, only `.string` values are converted. In non-strict mode, the following conversions are supported:
    /// - Integers: Converted to their string representation
    /// - Doubles: Converted to their string representation
    /// - Booleans: Converted to "true" or "false"
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.string` values. Defaults to `true`
    /// - Returns: A string value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   String(Value.string("hello")) // Returns "hello"
    ///   String(Value.int(42), strict: false) // Returns "42"
    ///   String(Value.bool(true), strict: false) // Returns "true"
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .string(let s):
            self = s
        case .int(let i) where !strict:
            self = String(i)
        case .double(let d) where !strict:
            self = String(d)
        case .bool(let b) where !strict:
            self = String(b)
        default:
            return nil
        }
    }
}
