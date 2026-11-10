import struct Foundation.UUID

/// A unique identifier for a request.
public enum ID: Hashable, Sendable {
    /// A string ID.
    case string(String)

    /// A number ID.
    case number(Int)

    /// Generates a random string ID.
    public static var random: ID {
        return .string(UUID().uuidString)
    }
}

extension ID {
    /// Unambiguous key for transport bookkeeping. JSON-RPC string and numeric
    /// ids share their textual description, so maps must retain the id kind.
    package var transportKey: String {
        switch self {
        case .string(let value): "string:\(value)"
        case .number(let value): "number:\(value)"
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension ID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension ID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(value)
    }
}

// MARK: - CustomStringConvertible

extension ID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let str): return str
        case .number(let num): return String(num)
        }
    }
}

// MARK: - Codable

extension ID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else if container.decodeNil() {
            // Handle unspecified/null IDs as empty string
            self = .string("")
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "ID must be string or number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str): try container.encode(str)
        case .number(let num): try container.encode(num)
        }
    }
}
