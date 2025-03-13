import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// A codable value.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(mimeType: String? = nil, Data)
    case array([Value])
    case object([String: Value])

    /// Create a `Value` from a `Codable` value.
    /// - Parameter value: The codable value
    /// - Returns: A value
    public init<T: Codable>(_ value: T) throws {
        if let valueAsValue = value as? Value {
            self = valueAsValue
        } else {
            let data = try JSONEncoder().encode(value)
            self = try JSONDecoder().decode(Value.self, from: data)
        }
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

extension Value: Codable {
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
            if Data.isDataURL(string: value),
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
    public struct StringInterpolation: StringInterpolationProtocol {
        var stringValue: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            self.stringValue = ""
            self.stringValue.reserveCapacity(literalCapacity + interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            self.stringValue.append(literal)
        }

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
