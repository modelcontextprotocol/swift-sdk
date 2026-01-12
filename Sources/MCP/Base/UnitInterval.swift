/// A value constrained to the range 0.0 to 1.0, inclusive.
///
/// `UnitInterval` represents a normalized value that is guaranteed to be within
/// the unit interval [0, 1]. This type is commonly used for representing
/// priorities in sampling request model preferences.
///
/// The type provides safe initialization that returns `nil` for values outside
/// the valid range, ensuring that all instances contain valid unit interval values.
///
/// - Example:
///   ```swift
///   let zero: UnitInterval = 0 // 0.0
///   let half = UnitInterval(0.5)! // 0.5
///   let one: UnitInterval = 1.0 // 1.0
///   let invalid = UnitInterval(1.5) // nil
///   ```
public struct UnitInterval: Hashable, Sendable {
    private let value: Double

    /// Creates a unit interval value from a `Double`.
    ///
    /// - Parameter value: A double value that must be in the range 0.0...1.0
    /// - Returns: A `UnitInterval` instance if the value is valid, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   let valid = UnitInterval(0.75) // Optional(0.75)
    ///   let invalid = UnitInterval(-0.1) // nil
    ///   let boundary = UnitInterval(1.0) // Optional(1.0)
    ///   ```
    public init?(_ value: Double) {
        guard (0...1).contains(value) else { return nil }
        self.value = value
    }

    /// The underlying double value.
    ///
    /// This property provides access to the raw double value that is guaranteed
    /// to be within the range [0, 1].
    ///
    /// - Returns: The double value between 0.0 and 1.0, inclusive
    public var doubleValue: Double { value }
}

// MARK: - Comparable

extension UnitInterval: Comparable {
    public static func < (lhs: UnitInterval, rhs: UnitInterval) -> Bool {
        lhs.value < rhs.value
    }
}

// MARK: - CustomStringConvertible

extension UnitInterval: CustomStringConvertible {
    public var description: String { "\(value)" }
}

// MARK: - Codable

extension UnitInterval: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let doubleValue = try container.decode(Double.self)
        guard let interval = UnitInterval(doubleValue) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Value \(doubleValue) is not in range 0...1")
            )
        }
        self = interval
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - ExpressibleByFloatLiteral

extension UnitInterval: ExpressibleByFloatLiteral {
    /// Creates a unit interval from a floating-point literal.
    ///
    /// This initializer allows you to create `UnitInterval` instances using
    /// floating-point literals. The literal value must be in the range [0, 1]
    /// or a runtime error will occur.
    ///
    /// - Parameter value: A floating-point literal between 0.0 and 1.0
    ///
    /// - Warning: This initializer will crash if the literal is outside the valid range.
    ///   Use the failable initializer `init(_:)` for runtime validation.
    ///
    /// - Example:
    ///   ```swift
    ///   let quarter: UnitInterval = 0.25
    ///   let half: UnitInterval = 0.5
    ///   ```
    public init(floatLiteral value: Double) {
        self.init(value)!
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension UnitInterval: ExpressibleByIntegerLiteral {
    /// Creates a unit interval from an integer literal.
    ///
    /// This initializer allows you to create `UnitInterval` instances using
    /// integer literals. Only the values 0 and 1 are valid.
    ///
    /// - Parameter value: An integer literal, either 0 or 1
    ///
    /// - Warning: This initializer will crash if the literal is outside the valid range.
    ///   Use the failable initializer `init(_:)` for runtime validation.
    ///
    /// - Example:
    ///   ```swift
    ///   let zero: UnitInterval = 0
    ///   let one: UnitInterval = 1
    ///   ```
    public init(integerLiteral value: Int) {
        self.init(Double(value))!
    }
}
