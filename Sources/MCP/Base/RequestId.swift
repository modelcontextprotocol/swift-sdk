import struct Foundation.UUID

/// A unique identifier for a request.
public enum RequestId: Hashable, Sendable {
    /// A string ID.
    case string(String)

    /// A number ID.
    case number(Int)

    /// Generates a random string ID.
    public static var random: RequestId {
        return .string(UUID().uuidString)
    }
}

/// Backwards compatibility alias for `RequestId`.
@available(*, deprecated, renamed: "RequestId")
public typealias ID = RequestId

// MARK: - ExpressibleByStringLiteral

extension RequestId: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension RequestId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(value)
    }
}

// MARK: - CustomStringConvertible

extension RequestId: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let str): return str
        case .number(let num): return String(num)
        }
    }
}

// MARK: - Codable

extension RequestId: Codable {
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
