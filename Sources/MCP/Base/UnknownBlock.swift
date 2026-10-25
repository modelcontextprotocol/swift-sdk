import Foundation

/// The coding of blocks and requests whose kind the SDK does not know: the
/// whole JSON object, kept as received.
enum UnknownBlock {
    /// The object `decoder` holds.
    static func decode(from decoder: any Decoder) throws -> Value {
        try Value(from: decoder)
    }

    /// Encodes `value` with its kind under `key` (`type` for content blocks).
    static func encode(_ value: Value, kind: String, key: String = "type", to encoder: any Encoder) throws {
        var object = value.objectValue ?? [:]
        object[key] = .string(kind)
        try Value.object(object).encode(to: encoder)
    }
}
