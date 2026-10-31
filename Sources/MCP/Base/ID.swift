import struct Foundation.UUID
import struct os.OSAllocatedUnfairLock

/// A unique identifier for a request.
public enum ID: Hashable, Sendable {
    /// A string ID.
    case string(String)

    /// A number ID.
    case number(Int)

    /// Process-wide counter for monotonic numeric request IDs.
    ///
    /// Integer IDs are JSON-RPC 2.0–valid and avoid silent hangs against servers
    /// that only accept numeric `id` values (e.g. Apple's `mcpbridge`).
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    /// Generates a monotonic numeric ID suitable for outbound client requests.
    public static var random: ID {
        .number(
            counter.withLock { value in
                value += 1
                return value
            }
        )
    }

    /// Generates a random UUID string ID (previous `random` behavior).
    public static var randomUUID: ID {
        .string(UUID().uuidString)
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
