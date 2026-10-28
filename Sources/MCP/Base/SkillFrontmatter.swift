import Foundation
import Yams

/// The YAML frontmatter of a `SKILL.md` (SEP-2640), as JSON.
///
/// A skill entry carries its frontmatter as a JSON object that must be
/// identical in content to the file's, and a host compares the two field by
/// field before it loads the skill. Both sides therefore read YAML the way the
/// other SDKs and the conformance harness do: YAML 1.2 with the core schema
/// (`true`, not `yes`; `2024-01-01` is a string). ``Schema/yaml11`` reads it as
/// YAML 1.1 instead, as PyYAML does.
///
/// The input is untrusted: the block is at most ``maximumSize`` bytes,
/// libyaml stops at 1000 levels of nesting, and the converted tree, aliases
/// expanded, is at most ``maximumNodes`` nodes. Yams composes recursively, and
/// 1000 levels overflow the 512 KiB stack of a secondary thread, so parsing
/// runs on a thread of its own with a larger stack; the caller waits for it.
enum SkillFrontmatter {
    /// How plain scalars resolve.
    enum Schema: Sendable {
        /// YAML 1.2, core schema.
        case core
        /// YAML 1.1: `yes`/`no`/`on`/`off` are booleans, `1_000` and `0b1`
        /// are integers, `<<` merges, timestamps stay strings.
        case yaml11
    }

    /// The largest frontmatter block read, in UTF-8 bytes.
    static let maximumSize = 64 * 1024

    /// The most nodes a frontmatter block may expand to, aliases included.
    static let maximumNodes = 10_000

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The document does not start with a `---` delimited block.
        case missing
        case tooLarge(Int)
        case tooManyNodes
        /// The block is not a YAML mapping.
        case notAMapping
        case syntax(String)
        case unsupportedTag(String)
        /// A value that has no JSON form, such as `.inf`, or a scalar that does
        /// not match its explicit tag.
        case invalidValue(String)
        /// A mapping key that is not a string.
        case invalidKey(String)
        case duplicateKey(String)

        var description: String {
            switch self {
            case .missing: "no YAML frontmatter: the file does not start with a --- delimited block"
            case .tooLarge(let size): "the frontmatter is \(size) bytes; at most \(SkillFrontmatter.maximumSize) are read"
            case .tooManyNodes: "the frontmatter expands to more than \(SkillFrontmatter.maximumNodes) nodes"
            case .notAMapping: "the frontmatter is not a YAML mapping"
            case .syntax(let message): "the frontmatter is not valid YAML: \(message)"
            case .unsupportedTag(let tag): "unsupported YAML tag \(tag)"
            case .invalidValue(let value): "\(value) has no JSON value"
            case .invalidKey(let key): "mapping key \(key) is not a string"
            case .duplicateKey(let key): "duplicate mapping key \(key)"
            }
        }
    }

    // MARK: - Extraction

    /// The YAML between the opening and closing `---` of `document`, or `nil`.
    ///
    /// The same match as `^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)`, after
    /// a leading byte order mark is dropped.
    static func block(in document: String) -> Substring? {
        var text = Substring(document)
        if text.unicodeScalars.first == "\u{FEFF}" { text = text.dropFirst() }
        let bytes = text.utf8
        guard let afterOpening = openingDelimiterEnd(bytes) else { return nil }
        var cursor = afterOpening
        // The lazy group: the first position where a closing delimiter matches.
        while cursor <= bytes.endIndex {
            if let _ = closingDelimiter(at: cursor, in: bytes) {
                return Substring(bytes[afterOpening..<cursor])
            }
            guard cursor < bytes.endIndex else { break }
            cursor = bytes.index(after: cursor)
        }
        return nil
    }

    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")
    private static let dash = UInt8(ascii: "-")

    /// The index after `---\r?\n` at the start of `bytes`.
    private static func openingDelimiterEnd(_ bytes: Substring.UTF8View) -> Substring.UTF8View.Index? {
        var index = bytes.startIndex
        for _ in 0..<3 {
            guard index < bytes.endIndex, bytes[index] == dash else { return nil }
            index = bytes.index(after: index)
        }
        if index < bytes.endIndex, bytes[index] == cr { index = bytes.index(after: index) }
        guard index < bytes.endIndex, bytes[index] == lf else { return nil }
        return bytes.index(after: index)
    }

    /// Whether `\r?\n---[ \t]*(?:\r?\n|$)` matches at `start`.
    private static func closingDelimiter(at start: Substring.UTF8View.Index, in bytes: Substring.UTF8View) -> Bool? {
        var index = start
        if index < bytes.endIndex, bytes[index] == cr { index = bytes.index(after: index) }
        guard index < bytes.endIndex, bytes[index] == lf else { return nil }
        index = bytes.index(after: index)
        for _ in 0..<3 {
            guard index < bytes.endIndex, bytes[index] == dash else { return nil }
            index = bytes.index(after: index)
        }
        while index < bytes.endIndex, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "\t") {
            index = bytes.index(after: index)
        }
        if index == bytes.endIndex { return true }
        if bytes[index] == cr { index = bytes.index(after: index) }
        return index < bytes.endIndex && bytes[index] == lf ? true : nil
    }

    // MARK: - Parsing

    /// The frontmatter of `document` as a JSON object.
    static func parse(document: String, schema: Schema = .core) throws -> [String: Value] {
        guard let block = block(in: document) else { throw Failure.missing }
        return try parse(String(block), schema: schema)
    }

    /// `yaml`, a frontmatter block, as a JSON object.
    static func parse(_ yaml: String, schema: Schema = .core) throws -> [String: Value] {
        guard yaml.utf8.count <= maximumSize else { throw Failure.tooLarge(yaml.utf8.count) }
        return try onParsingThread { try compose(yaml, schema: schema) }
    }

    /// The stack of the parsing thread: 1000 levels of Yams and of the
    /// converter, with room to spare.
    static let parsingStackSize = 16 << 20

    /// Runs `body` on a new thread with a ``parsingStackSize`` stack and
    /// returns its result.
    private static func onParsingThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.set(Result { try body() })
            done.signal()
        }
        thread.stackSize = parsingStackSize
        thread.start()
        done.wait()
        return try outcome.get()
    }

    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, any Error>?

        func set(_ result: Result<T, any Error>) {
            lock.withLock { self.result = result }
        }

        func get() throws -> T {
            guard let result = lock.withLock({ self.result }) else {
                throw Failure.syntax("the parser did not finish")
            }
            return try result.get()
        }
    }

    private static func compose(_ yaml: String, schema: Schema) throws -> [String: Value] {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml, schema == .core ? coreResolver : .default)
        } catch let error as YamlError {
            if case .duplicatedKeysInMapping(let duplicates, _) = error {
                throw Failure.duplicateKey(duplicates.joined(separator: ", "))
            }
            throw Failure.syntax("\(error)")
        } catch {
            throw Failure.syntax("\(error)")
        }
        guard let root, case .mapping = root else { throw Failure.notAMapping }
        var converter = Converter(schema: schema)
        guard case .object(let object) = try converter.value(of: root) else { throw Failure.notAMapping }
        return object
    }

    /// Plain scalars without a tag resolve to `implicitTag`, so that the
    /// converter applies the core schema to them and only to them.
    private static let implicitTag = Tag.Name(rawValue: "tag:modelcontextprotocol.io,2026:implicit")
    private static let coreResolver: Resolver = {
        guard let resolver = try? Resolver.basic.appending(implicitTag, "^") else {
            preconditionFailure("the pattern ^ is valid")
        }
        return resolver
    }()

    private struct Converter {
        let schema: Schema
        var nodes = 0

        mutating func value(of node: Node) throws -> Value {
            nodes += 1
            guard nodes <= SkillFrontmatter.maximumNodes else { throw Failure.tooManyNodes }
            let tag = node.tag.rawValue
            switch node {
            case .scalar(let scalar):
                return try value(of: scalar, tag: tag)
            case .sequence(let sequence):
                guard tag == Tag.Name.seq.rawValue else { throw Failure.unsupportedTag(tag) }
                return .array(try sequence.map { try value(of: $0) })
            case .mapping(let mapping):
                guard tag == Tag.Name.map.rawValue else { throw Failure.unsupportedTag(tag) }
                return .object(try object(of: mapping))
            case .alias:
                throw Failure.syntax("unresolved alias")
            }
        }

        private mutating func object(of mapping: Node.Mapping) throws -> [String: Value] {
            var object: [String: Value] = [:]
            var merged: [String: Value] = [:]
            for (keyNode, valueNode) in mapping {
                if schema == .yaml11, keyNode.tag.rawValue == Tag.Name.merge.rawValue {
                    for (key, value) in try mergedEntries(of: valueNode) where merged[key] == nil {
                        merged[key] = value
                    }
                    continue
                }
                let key = try self.key(keyNode)
                guard object[key] == nil else { throw Failure.duplicateKey(key) }
                object[key] = try value(of: valueNode)
            }
            // Explicit keys win over merged ones (YAML 1.1 merge).
            return object.merging(merged) { explicit, _ in explicit }
        }

        /// The entries a `<<` value merges: a mapping, or a sequence of them
        /// (the first wins).
        private mutating func mergedEntries(of node: Node) throws -> [(String, Value)] {
            switch node {
            case .mapping(let mapping):
                return try object(of: mapping).map { ($0.key, $0.value) }
            case .sequence(let sequence):
                var entries: [(String, Value)] = []
                var seen = Set<String>()
                for element in sequence {
                    guard case .mapping(let mapping) = element else {
                        throw Failure.invalidValue("a << value that is not a mapping")
                    }
                    for (key, value) in try object(of: mapping) where seen.insert(key).inserted {
                        entries.append((key, value))
                    }
                }
                return entries
            default:
                throw Failure.invalidValue("a << value that is not a mapping")
            }
        }

        /// A scalar key as a string; integers, booleans and null are written
        /// out as JavaScript does (`007` is `"7"`, `null` is `""`).
        private mutating func key(_ node: Node) throws -> String {
            guard let scalar = node.scalar else { throw Failure.invalidKey("that is a collection") }
            switch try value(of: node) {
            case .string(let key): return key
            case .int(let key): return String(key)
            case .bool(let key): return key ? "true" : "false"
            case .null: return ""
            default: throw Failure.invalidKey(scalar.string)
            }
        }

        private func value(of scalar: Node.Scalar, tag: String) throws -> Value {
            let text = scalar.string
            switch schema {
            case .core:
                if tag == SkillFrontmatter.implicitTag.rawValue { return try Core.resolve(text) }
                return try Core.value(text, tag: tag)
            case .yaml11:
                return try YAML11.value(scalar, tag: tag)
            }
        }
    }

    // MARK: - YAML 1.2 core schema

    /// The YAML 1.2 core schema, with the patterns of the `yaml` npm package.
    private enum Core {
        static func resolve(_ text: String) throws -> Value {
            if isNull(text) { return .null }
            if let bool = bool(text) { return .bool(bool) }
            if let number = try number(text) { return number }
            return .string(text)
        }

        static func value(_ text: String, tag: String) throws -> Value {
            switch tag {
            case Tag.Name.str.rawValue:
                return .string(text)
            case Tag.Name.null.rawValue:
                guard isNull(text) else { throw Failure.invalidValue("!!null \(text)") }
                return .null
            case Tag.Name.bool.rawValue:
                guard let bool = bool(text) else { throw Failure.invalidValue("!!bool \(text)") }
                return .bool(bool)
            case Tag.Name.int.rawValue:
                guard let integer = integer(text) else { throw Failure.invalidValue("!!int \(text)") }
                return integer
            case Tag.Name.float.rawValue:
                // A float written as one: `!!float 1` is refused, as by `yaml`.
                if isNonFinite(text) { throw Failure.invalidValue(text) }
                guard isFloat(text, fractionOrExponent: true), let double = Double(text), double.isFinite else {
                    throw Failure.invalidValue("!!float \(text)")
                }
                return .double(double)
            default:
                throw Failure.unsupportedTag(tag)
            }
        }

        static func isNull(_ text: String) -> Bool {
            ["", "~", "null", "Null", "NULL"].contains(text)
        }

        static func bool(_ text: String) -> Bool? {
            switch text {
            case "true", "True", "TRUE": true
            case "false", "False", "FALSE": false
            default: nil
            }
        }

        /// An integer or a float; `nil` when `text` is neither. Infinity and
        /// NaN have no JSON value.
        static func number(_ text: String) throws -> Value? {
            if let integer = integer(text) { return integer }
            if isNonFinite(text) { throw Failure.invalidValue(text) }
            guard isFloat(text), let double = Double(text), double.isFinite else { return nil }
            return .double(double)
        }

        /// `[-+]?[0-9]+`, `0o[0-7]+` or `0x[0-9a-fA-F]+`. Beyond `Int`, a
        /// double, as JSON numbers are.
        static func integer(_ text: String) -> Value? {
            let utf8 = Array(text.utf8)
            func all(_ bytes: ArraySlice<UInt8>, _ allowed: (UInt8) -> Bool) -> Bool {
                !bytes.isEmpty && bytes.allSatisfy(allowed)
            }
            let isDigit = { (byte: UInt8) in byte >= 0x30 && byte <= 0x39 }
            if utf8.count > 2, utf8[0] == UInt8(ascii: "0") {
                let digits = utf8[2...]
                if utf8[1] == UInt8(ascii: "o"), all(digits, { $0 >= 0x30 && $0 <= 0x37 }) {
                    return radix(String(decoding: digits, as: UTF8.self), 8)
                }
                if utf8[1] == UInt8(ascii: "x"), all(digits, { Character(Unicode.Scalar($0)).isHexDigit }) {
                    return radix(String(decoding: digits, as: UTF8.self), 16)
                }
            }
            let signed = utf8.first == UInt8(ascii: "-") || utf8.first == UInt8(ascii: "+")
            guard all(utf8[(signed ? 1 : 0)...], isDigit) else { return nil }
            if let integer = Int(text) { return .int(integer) }
            return Double(text).map(Value.double)
        }

        static func radix(_ digits: String, _ radix: Int) -> Value? {
            if let integer = Int(digits, radix: radix) { return .int(integer) }
            // Beyond Int: the nearest double, as a JavaScript number.
            var double = 0.0
            for character in digits {
                guard let digit = character.hexDigitValue else { return nil }
                double = double * Double(radix) + Double(digit)
            }
            return .double(double)
        }

        /// `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`; with
        /// `fractionOrExponent`, not an integer.
        static func isFloat(_ text: String, fractionOrExponent: Bool = false) -> Bool {
            var bytes = Substring(text).utf8[...]
            if let first = bytes.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
                bytes = bytes.dropFirst()
            }
            let isDigit = { (byte: UInt8) in byte >= 0x30 && byte <= 0x39 }
            let integerDigits = bytes.prefix(while: isDigit).count
            bytes = bytes.dropFirst(integerDigits)
            var fractionDigits = 0
            var decorated = false
            if bytes.first == UInt8(ascii: ".") {
                decorated = true
                bytes = bytes.dropFirst()
                fractionDigits = bytes.prefix(while: isDigit).count
                bytes = bytes.dropFirst(fractionDigits)
            } else if integerDigits == 0 {
                return false
            }
            guard integerDigits > 0 || fractionDigits > 0 else { return false }
            if let e = bytes.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                decorated = true
                bytes = bytes.dropFirst()
                if let sign = bytes.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
                    bytes = bytes.dropFirst()
                }
                let exponentDigits = bytes.prefix(while: isDigit).count
                guard exponentDigits > 0 else { return false }
                bytes = bytes.dropFirst(exponentDigits)
            }
            return bytes.isEmpty && (decorated || !fractionOrExponent)
        }

        static func isNonFinite(_ text: String) -> Bool {
            var body = Substring(text)
            if body.first == "-" || body.first == "+" { body = body.dropFirst() }
            return [".inf", ".Inf", ".INF"].contains(body) || [".nan", ".NaN", ".NAN"].contains(text)
        }
    }

    // MARK: - YAML 1.1

    /// YAML 1.1 through Yams' default resolver and constructors.
    private enum YAML11 {
        static func value(_ scalar: Node.Scalar, tag: String) throws -> Value {
            let node = Node.scalar(scalar)
            switch tag {
            case Tag.Name.str.rawValue, Tag.Name.timestamp.rawValue, Tag.Name.value.rawValue,
                Tag.Name.merge.rawValue:
                return .string(scalar.string)
            case Tag.Name.null.rawValue:
                guard node.null != nil else { throw Failure.invalidValue("!!null \(scalar.string)") }
                return .null
            case Tag.Name.bool.rawValue:
                guard let bool = node.bool else { throw Failure.invalidValue("!!bool \(scalar.string)") }
                return .bool(bool)
            case Tag.Name.int.rawValue:
                if let integer = node.int { return .int(integer) }
                guard let double = node.float, double.isFinite else {
                    throw Failure.invalidValue("!!int \(scalar.string)")
                }
                return .double(double)
            case Tag.Name.float.rawValue:
                guard let double = node.float else { throw Failure.invalidValue("!!float \(scalar.string)") }
                guard double.isFinite else { throw Failure.invalidValue(scalar.string) }
                return .double(double)
            default:
                throw Failure.unsupportedTag(tag)
            }
        }
    }

    // MARK: - Comparison

    /// Whether two frontmatter objects have the same JSON content: numbers
    /// compare by value (`1` and `1.0` are equal), key order does not matter,
    /// and a `data:` URL string equals the ``Value/data(mimeType:_:)`` it
    /// decodes to.
    static func matches(_ lhs: [String: Value], _ rhs: [String: Value]) -> Bool {
        equivalent(.object(lhs), .object(rhs))
    }

    static func equivalent(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return Double(a) == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let m1, let d1), .data(let m2, let d2)): return m1 == m2 && d1 == d2
        case (.data(let mimeType, let data), .string(let string)), (.string(let string), .data(let mimeType, let data)):
            guard let (parsedType, parsedData) = Data.parseDataURL(string) else { return false }
            return parsedType == mimeType && parsedData == data
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { equivalent($0, $1) }
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && a.allSatisfy { key, value in b[key].map { equivalent(value, $0) } ?? false }
        default: return false
        }
    }
}
