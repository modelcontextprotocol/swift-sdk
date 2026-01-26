// Internal helpers for encoding and decoding _meta fields per MCP spec

import Foundation

/// The reserved key name for metadata fields
let metaKey = "_meta"

/// A dynamic coding key for encoding/decoding arbitrary string keys
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Error thrown when meta field validation fails
enum MetaFieldError: Error, LocalizedError, Equatable {
    case invalidMetaKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidMetaKey(let key):
            return
                "Invalid _meta key: '\(key)'. Keys must follow the format: [prefix/]name where prefix is dot-separated labels and name is alphanumeric with hyphens, underscores, or dots."
        }
    }
}

/// Validates that a key name follows the spec-defined format for _meta fields
/// Keys must follow the format: [prefix/]name where:
/// - prefix (optional): dot-separated labels, each starting with a letter, ending with letter or digit, containing letters, digits, or hyphens
/// - name: starts and ends with alphanumeric, may contain hyphens, underscores, dots, and alphanumerics
func validateMetaKey(_ key: String) throws {
    guard isValidMetaKey(key) else {
        throw MetaFieldError.invalidMetaKey(key)
    }
}

/// Checks if a key is valid for _meta without throwing
func isValidMetaKey(_ key: String) -> Bool {
    // Empty keys are invalid
    guard !key.isEmpty else { return false }

    let parts = key.split(separator: "/", omittingEmptySubsequences: false)

    // At minimum we must have a name segment
    guard let name = parts.last, !name.isEmpty else { return false }

    // Validate each prefix segment if present
    let prefixSegments = parts.dropLast()
    if !prefixSegments.isEmpty {
        for segment in prefixSegments {
            // Empty segments (e.g. "vendor//name") are invalid
            guard !segment.isEmpty else { return false }

            let labels = segment.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty else { return false }
            for label in labels {
                guard isValidPrefixLabel(label) else { return false }
            }
        }
    }

    // Validate name
    guard isValidName(name) else { return false }

    return true
}

/// Validates that a prefix label follows the format:
/// - Starts with a letter
/// - Ends with a letter or digit
/// - Contains only letters, digits, or hyphens
private func isValidPrefixLabel(_ label: Substring) -> Bool {
    guard let first = label.first, first.isLetter else { return false }
    guard let last = label.last, last.isLetter || last.isNumber else { return false }
    for character in label {
        if character.isLetter || character.isNumber || character == "-" {
            continue
        }
        return false
    }
    return true
}

/// Validates that a name follows the format:
/// - Starts with a letter or digit
/// - Ends with a letter or digit
/// - Contains only letters, digits, hyphens, underscores, or dots
private func isValidName(_ name: Substring) -> Bool {
    guard let first = name.first, first.isLetter || first.isNumber else { return false }
    guard let last = name.last, last.isLetter || last.isNumber else { return false }

    for character in name {
        if character.isLetter || character.isNumber || character == "-" || character == "_"
            || character == "."
        {
            continue
        }
        return false
    }

    return true
}

// Character extensions for validation
extension Character {
    fileprivate var isLetter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    fileprivate var isNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}

/// Encodes a _meta dictionary into a container, validating keys
func encodeMeta(
    _ meta: [String: Value]?, to container: inout KeyedEncodingContainer<DynamicCodingKey>
) throws {
    guard let meta = meta, !meta.isEmpty else { return }

    // Validate all keys before encoding
    for key in meta.keys {
        try validateMetaKey(key)
    }

    // Encode the _meta object
    let metaCodingKey = DynamicCodingKey(stringValue: metaKey)!
    var metaContainer = container.nestedContainer(
        keyedBy: DynamicCodingKey.self, forKey: metaCodingKey)

    for (key, value) in meta {
        let dynamicKey = DynamicCodingKey(stringValue: key)!
        try metaContainer.encode(value, forKey: dynamicKey)
    }
}

/// Encodes extra fields (index signature) into a container
func encodeExtraFields(
    _ extraFields: [String: Value]?, to container: inout KeyedEncodingContainer<DynamicCodingKey>,
    excluding excludedKeys: Set<String> = []
) throws {
    guard let extraFields = extraFields, !extraFields.isEmpty else { return }

    for (key, value) in extraFields where key != metaKey && !excludedKeys.contains(key) {
        let dynamicKey = DynamicCodingKey(stringValue: key)!
        try container.encode(value, forKey: dynamicKey)
    }
}

/// Decodes a _meta dictionary from a container
func decodeMeta(from container: KeyedDecodingContainer<DynamicCodingKey>) throws -> [String: Value]?
{
    let metaCodingKey = DynamicCodingKey(stringValue: metaKey)!

    guard container.contains(metaCodingKey) else {
        return nil
    }

    let metaContainer = try container.nestedContainer(
        keyedBy: DynamicCodingKey.self, forKey: metaCodingKey)
    var meta: [String: Value] = [:]

    for key in metaContainer.allKeys {
        // Validate each key as we decode
        try validateMetaKey(key.stringValue)
        let value = try metaContainer.decode(Value.self, forKey: key)
        meta[key.stringValue] = value
    }

    return meta.isEmpty ? nil : meta
}

/// Decodes extra fields (index signature) from a container
func decodeExtraFields(
    from container: KeyedDecodingContainer<DynamicCodingKey>,
    excluding excludedKeys: Set<String> = []
) throws -> [String: Value]? {
    var extraFields: [String: Value] = [:]

    for key in container.allKeys
    where key.stringValue != metaKey && !excludedKeys.contains(key.stringValue) {
        let value = try container.decode(Value.self, forKey: key)
        extraFields[key.stringValue] = value
    }

    return extraFields.isEmpty ? nil : extraFields
}
