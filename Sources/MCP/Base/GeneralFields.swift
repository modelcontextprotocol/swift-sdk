import Foundation

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum GeneralFieldError: Error, Equatable {
    case invalidMetaKey(String)
}

public struct GeneralFields: Hashable, Sendable {
    public var meta: MetaFields?
    public var additional: [String: Value]

    public init(meta: MetaFields? = nil, additional: [String: Value] = [:]) {
        self.meta = meta
        self.additional = additional.filter { $0.key != "_meta" }
    }

    public var isEmpty: Bool {
        (meta?.isEmpty ?? true) && additional.isEmpty
    }

    public subscript(field name: String) -> Value? {
        get { additional[name] }
        set { additional[name] = newValue }
    }

    mutating public func merge(additional fields: [String: Value]) {
        for (key, value) in fields where key != "_meta" {
            additional[key] = value
        }
    }

    func encode(into encoder: Encoder, reservedKeyNames: Set<String>) throws {
        guard !isEmpty else { return }

        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        if let meta, !meta.isEmpty, let key = DynamicCodingKey(stringValue: "_meta") {
            try container.encode(meta.dictionary, forKey: key)
        }

        for (name, value) in additional where !reservedKeyNames.contains(name) {
            guard let key = DynamicCodingKey(stringValue: name) else { continue }
            try container.encode(value, forKey: key)
        }
    }

    static func decode(
        from container: KeyedDecodingContainer<DynamicCodingKey>,
        reservedKeyNames: Set<String>
    ) throws -> GeneralFields {
        var meta: MetaFields?
        var additional: [String: Value] = [:]

        for key in container.allKeys {
            let name = key.stringValue
            if reservedKeyNames.contains(name) {
                continue
            }

            if name == "_meta" {
                let raw = try container.decodeIfPresent([String: Value].self, forKey: key)
                if let raw {
                    meta = try MetaFields(values: raw)
                }
            } else if let value = try? container.decode(Value.self, forKey: key) {
                additional[name] = value
            }
        }

        return GeneralFields(meta: meta, additional: additional)
    }
}

public struct MetaFields: Hashable, Sendable {
    private var storage: [String: Value]

    public init(values: [String: Value] = [:]) throws {
        for key in values.keys {
            guard MetaFields.isValidKeyName(key) else {
                throw GeneralFieldError.invalidMetaKey(key)
            }
        }
        self.storage = values
    }

    public var dictionary: [String: Value] {
        storage
    }

    public var isEmpty: Bool {
        storage.isEmpty
    }

    public mutating func setValue(_ value: Value?, forKey key: String) throws {
        guard MetaFields.isValidKeyName(key) else {
            throw GeneralFieldError.invalidMetaKey(key)
        }
        storage[key] = value
    }

    public subscript(key: String) -> Value? {
        storage[key]
    }

    public static func isValidKeyName(_ key: String) -> Bool {
        let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)

        let prefix: Substring?
        let name: Substring

        if parts.count == 2 {
            prefix = parts[0]
            name = parts[1]
        } else {
            prefix = nil
            name = parts.first ?? ""
        }

        if let prefix, !prefix.isEmpty {
            let labels = prefix.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty else { return false }
            for label in labels {
                guard MetaFields.isValidPrefixLabel(label) else { return false }
            }
        }

        guard !name.isEmpty else { return false }
        guard MetaFields.isValidName(name) else { return false }

        return true
    }

    private static func isValidPrefixLabel(_ label: Substring) -> Bool {
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

    private static func isValidName(_ name: Substring) -> Bool {
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
}

extension MetaFields: Codable {
    public init(from decoder: Decoder) throws {
        let values = try [String: Value](from: decoder)
        try self.init(values: values)
    }

    public func encode(to encoder: Encoder) throws {
        try storage.encode(to: encoder)
    }
}

extension Character {
    fileprivate var isLetter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    fileprivate var isNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
