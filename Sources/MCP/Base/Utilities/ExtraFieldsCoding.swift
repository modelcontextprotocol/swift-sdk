/// Utilities for encoding and decoding extra fields in Result types.
///
/// These helpers support forward compatibility by preserving unknown fields
/// that aren't defined in the schema.

/// A coding key that can represent any string key.
public struct AnyCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int? { nil }

    public init?(stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(intValue: Int) {
        nil
    }

    public init(_ key: String) {
        self.stringValue = key
    }
}

/// Helpers for decoding extra fields from a decoder.
public enum ExtraFieldsDecoder {
    /// Decodes any fields not in the known keys set as `[String: Value]`.
    ///
    /// - Parameters:
    ///   - decoder: The decoder to read from
    ///   - knownKeys: Set of key names that are already handled by the type
    /// - Returns: A dictionary of extra fields, or nil if empty
    public static func decode(
        from decoder: Decoder,
        knownKeys: Set<String>
    ) throws -> [String: Value]? {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var extra: [String: Value] = [:]

        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(Value.self, forKey: key) {
                extra[key.stringValue] = value
            }
        }

        return extra.isEmpty ? nil : extra
    }
}

/// Helpers for encoding extra fields to an encoder.
public enum ExtraFieldsEncoder {
    /// Encodes extra fields to a keyed container.
    ///
    /// - Parameters:
    ///   - extraFields: The extra fields to encode (can be nil)
    ///   - encoder: The encoder to write to
    public static func encode(
        _ extraFields: [String: Value]?,
        to encoder: Encoder
    ) throws {
        guard let extra = extraFields else { return }
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

// MARK: - Protocol for Types with Extra Fields

// TODO: Consider using a Swift macro to further reduce code duplication.
// A macro like `@ExtraFieldsCodable` could auto-generate the full
// `init(from:)` and `encode(to:)` implementations, eliminating the need
// for conforming types to manually write custom Codable implementations.

/// Protocol for result types that support forward-compatible extra fields.
///
/// Conforming types gain helper methods for encoding/decoding extra fields.
///
/// Usage:
/// ```swift
/// extension ListResources.Result: ResultWithExtraFields {
///     public typealias ResultCodingKeys = CodingKeys
/// }
///
/// // In init(from decoder:):
/// extraFields = try Self.decodeExtraFields(from: decoder)
///
/// // In encode(to encoder:):
/// try encodeExtraFields(to: encoder)
/// ```
public protocol ResultWithExtraFields: Codable, Hashable, Sendable {
    associatedtype ResultCodingKeys: CodingKey & CaseIterable & RawRepresentable
        where ResultCodingKeys.RawValue == String

    /// Additional fields not defined in the schema (for forward compatibility).
    var extraFields: [String: Value]? { get set }
}

extension ResultWithExtraFields {
    /// Decodes extra fields from the decoder (static, callable from init).
    public static func decodeExtraFields(from decoder: Decoder) throws -> [String: Value]? {
        try ExtraFieldsDecoder.decode(
            from: decoder,
            knownKeys: Set(ResultCodingKeys.allCases.map { $0.rawValue })
        )
    }

    /// Encodes extra fields to the encoder.
    public func encodeExtraFields(to encoder: Encoder) throws {
        try ExtraFieldsEncoder.encode(extraFields, to: encoder)
    }
}
