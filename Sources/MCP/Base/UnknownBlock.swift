import Foundation

/// The coding of blocks and requests whose kind the SDK does not know: the
/// whole JSON object, kept as received.
enum UnknownBlock {
    /// The object `decoder` holds, with strings as written: a `data:` URL
    /// stays a string, so the block encodes back to the same JSON value,
    /// though not always the same bytes: key order and number formatting
    /// may change (`1.0` is written `1`).
    static func decode(from decoder: any Decoder) throws -> Value {
        try Value.Preserved(from: decoder).value
    }

    /// Encodes `value` with its kind under `key` (`type` for content blocks).
    static func encode(_ value: Value, kind: String, key: String = "type", to encoder: any Encoder) throws {
        var object = value.objectValue ?? [:]
        object[key] = .string(kind)
        try Value.object(object).encode(to: encoder)
    }
}
