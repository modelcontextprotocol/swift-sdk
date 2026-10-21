import Foundation

/// Resource limits applied while decoding or encoding exact JSON values.
///
/// The exact JSON parser uses these limits before constructing strings or
/// decoding programmatic data values, so callers can safely expose raw request
/// parameters to handlers without first passing unbounded input through
/// `JSONDecoder`.
public struct RawJSONLimits: Hashable, Sendable {
    /// The maximum size of one JSON document, in bytes.
    public var maximumDocumentBytes: Int

    /// The maximum UTF-8 byte length of one decoded JSON string.
    public var maximumStringBytes: Int

    /// The maximum nesting depth of arrays and objects.
    public var maximumDepth: Int

    /// The maximum total number of array elements and object members.
    public var maximumContainerEntries: Int

    /// Conservative defaults suitable for MCP messages that may contain
    /// image or audio payloads.
    public static let `default` = RawJSONLimits(
        maximumDocumentBytes: 64 * 1024 * 1024,
        maximumStringBytes: 48 * 1024 * 1024,
        maximumDepth: 128,
        maximumContainerEntries: 250_000
    )

    public init(
        maximumDocumentBytes: Int,
        maximumStringBytes: Int,
        maximumDepth: Int,
        maximumContainerEntries: Int
    ) {
        self.maximumDocumentBytes = maximumDocumentBytes
        self.maximumStringBytes = maximumStringBytes
        self.maximumDepth = maximumDepth
        self.maximumContainerEntries = maximumContainerEntries
    }
}

/// An error produced while parsing or encoding an exact JSON value.
public struct RawJSONError: Error, Hashable, LocalizedError, Sendable {
    /// The byte offset at which the error was detected, when parsing input.
    public let byteOffset: Int?

    /// A human-readable description of the violated JSON or resource-limit rule.
    public let message: String

    public var errorDescription: String? {
        if let byteOffset {
            return "Raw JSON error at byte \(byteOffset): \(message)"
        }
        return "Raw JSON error: \(message)"
    }

    init(byteOffset: Int? = nil, message: String) {
        self.byteOffset = byteOffset
        self.message = message
    }
}

/// A JSON object that retains source member order and compares keys by their
/// exact Unicode scalar sequence.
///
/// Swift `String` equality is canonically equivalent, which makes composed and
/// decomposed spellings compare equal. JSON object names do not have that
/// normalization rule. This representation therefore keeps members in an
/// array and performs scalar-exact lookup and equality.
public struct ExactJSONObject: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public let key: String
        public let value: RawJSONValue

        public init(key: String, value: RawJSONValue) {
            self.key = key
            self.value = value
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            scalarExactEqual(lhs.key, rhs.key) && lhs.value == rhs.value
        }

        public func hash(into hasher: inout Hasher) {
            scalarExactHash(key, into: &hasher)
            hasher.combine(value)
        }
    }

    /// Members in their original source order, including duplicate keys.
    public let members: [Member]

    public init(members: [Member]) {
        self.members = members
    }

    /// Returns every value whose key has the same Unicode scalar sequence.
    public func values(forExactKey key: String) -> [RawJSONValue] {
        members.compactMap { member in
            scalarExactEqual(member.key, key) ? member.value : nil
        }
    }

    /// Returns the value only when the exact key occurs once.
    public func uniqueValue(forExactKey key: String) -> RawJSONValue? {
        let matches = values(forExactKey: key)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// A lossless semantic JSON value for inspecting inbound MCP requests.
///
/// Unlike ``Value``, this type preserves object member order and duplicate
/// keys, compares strings by their exact Unicode scalar sequence, and never
/// interprets JSON strings as data URLs. The `data` case exists only for
/// programmatically constructed values; parsing JSON always produces `string`.
public indirect enum RawJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The exact valid JSON number spelling from the source document.
    case number(String)
    case string(String)
    case data(mimeType: String? = nil, Data)
    case array([RawJSONValue])
    case object(ExactJSONObject)

    /// Parses one complete UTF-8 JSON document without dictionary conversion,
    /// string normalization, or data-URL coercion.
    public static func decode(
        _ data: Data,
        limits: RawJSONLimits = .default
    ) throws -> RawJSONValue {
        try Task<Never, Never>.checkCancellation()
        try validateRawJSONLimits(limits)
        guard data.count <= limits.maximumDocumentBytes else {
            throw RawJSONError(
                message:
                    "document exceeds maximumDocumentBytes (\(limits.maximumDocumentBytes))"
            )
        }

        return try data.withUnsafeBytes { rawBuffer in
            var parser = RawJSONParser(
                bytes: rawBuffer.bindMemory(to: UInt8.self),
                limits: limits
            )
            return try parser.parse()
        }
    }

    /// Encodes the value as JSON after preflighting all configured limits.
    ///
    /// Programmatic `data` values are measured using the base64 length formula
    /// before base64 bytes are allocated.
    public func encodedData(limits: RawJSONLimits = .default) throws -> Data {
        try validateRawJSONLimits(limits)
        var measurement = RawJSONEncoder.Measurement(limits: limits)
        let byteCount = try measurement.measure(self, depth: 0)

        var output = Data()
        output.reserveCapacity(byteCount)
        try RawJSONEncoder.append(self, to: &output, limits: limits, depth: 0)
        return output
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: ExactJSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case (.bool(let lhs), .bool(let rhs)):
            lhs == rhs
        case (.number(let lhs), .number(let rhs)), (.string(let lhs), .string(let rhs)):
            scalarExactEqual(lhs, rhs)
        case (.data(let lhsType, let lhsData), .data(let rhsType, let rhsData)):
            optionalScalarExactEqual(lhsType, rhsType) && lhsData == rhsData
        case (.array(let lhs), .array(let rhs)):
            lhs == rhs
        case (.object(let lhs), .object(let rhs)):
            lhs == rhs
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .number(let value):
            hasher.combine(2)
            scalarExactHash(value, into: &hasher)
        case .string(let value):
            hasher.combine(3)
            scalarExactHash(value, into: &hasher)
        case .data(let mimeType, let data):
            hasher.combine(4)
            if let mimeType {
                hasher.combine(true)
                scalarExactHash(mimeType, into: &hasher)
            } else {
                hasher.combine(false)
            }
            hasher.combine(data)
        case .array(let values):
            hasher.combine(5)
            hasher.combine(values)
        case .object(let object):
            hasher.combine(6)
            hasher.combine(object)
        }
    }

    static func batchElementRanges(in data: Data) throws -> [Range<Data.Index>] {
        try Task<Never, Never>.checkCancellation()
        let offsets = try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var scanner = JSONContainerElementScanner(
                bytes: bytes,
                openingByte: 0x5B,
                closingByte: 0x5D,
                containerName: "batch"
            )
            let ranges = try scanner.scan()
            for range in ranges {
                var parser = RawJSONParser(
                    bytes: UnsafeBufferPointer(rebasing: bytes[range]),
                    limits: .permittingDocument(range.count)
                )
                try parser.validateSyntax()
            }
            return ranges
        }
        return offsets.map { range in
            let lowerBound = data.index(data.startIndex, offsetBy: range.lowerBound)
            let upperBound = data.index(data.startIndex, offsetBy: range.upperBound)
            return lowerBound..<upperBound
        }
    }

    static func requestRoute(
        in data: Data,
        rawAwareMethods: [String],
        maximumIDBytes: Int
    ) throws -> RawJSONRequestRoute? {
        try Task<Never, Never>.checkCancellation()
        let maximumMethodBytes = rawAwareMethods.reduce(into: 0) { maximum, method in
            maximum = max(maximum, max(
                method.precomposedStringWithCanonicalMapping.utf8.count,
                method.decomposedStringWithCanonicalMapping.utf8.count
            ))
        }
        return try data.withUnsafeBytes { rawBuffer in
            var parser = RawJSONParser(
                bytes: rawBuffer.bindMemory(to: UInt8.self),
                limits: .permittingDocument(data.count)
            )
            return try parser.parseRequestRoute(
                maximumMethodBytes: maximumMethodBytes,
                rawAwareMethods: rawAwareMethods,
                maximumIDBytes: maximumIDBytes
            )
        }
    }
}

struct RawJSONRequestRoute {
    let rawAwareMethod: String?
    let methodMemberCount: Int
    let hasID: Bool
    let id: ID?
}

extension RawJSONLimits {
    static func permittingDocument(_ byteCount: Int) -> RawJSONLimits {
        RawJSONLimits(
            maximumDocumentBytes: byteCount,
            maximumStringBytes: byteCount,
            maximumDepth: min(max(byteCount, 1), 512),
            maximumContainerEntries: byteCount
        )
    }

}

private func scalarExactEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars) { $0.value == $1.value }
}

private struct UTF8ValidationState {
    private var remainingContinuationBytes = 0
    private var nextLowerBound: UInt8 = 0x80
    private var nextUpperBound: UInt8 = 0xBF

    var isComplete: Bool {
        remainingContinuationBytes == 0
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        if remainingContinuationBytes > 0 {
            guard byte >= nextLowerBound, byte <= nextUpperBound else { return false }
            remainingContinuationBytes -= 1
            nextLowerBound = 0x80
            nextUpperBound = 0xBF
            return true
        }

        switch byte {
        case 0x00...0x7F:
            return true
        case 0xC2...0xDF:
            remainingContinuationBytes = 1
        case 0xE0:
            remainingContinuationBytes = 2
            nextLowerBound = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF:
            remainingContinuationBytes = 2
        case 0xED:
            remainingContinuationBytes = 2
            nextUpperBound = 0x9F
        case 0xF0:
            remainingContinuationBytes = 3
            nextLowerBound = 0x90
        case 0xF1...0xF3:
            remainingContinuationBytes = 3
        case 0xF4:
            remainingContinuationBytes = 3
            nextUpperBound = 0x8F
        default:
            return false
        }
        return true
    }
}

private struct JSONContainerElementScanner {
    let bytes: UnsafeBufferPointer<UInt8>
    let openingByte: UInt8
    let closingByte: UInt8
    let containerName: String
    var index = 0
    var nextCancellationCheck = 4_096

    mutating func scan() throws -> [Range<Int>] {
        try skipWhitespace()
        guard currentByte == openingByte else {
            throw error("expected \(containerName)")
        }
        try advance()
        try skipWhitespace()
        if currentByte == closingByte {
            try advance()
            try finishDocument()
            return []
        }

        var ranges: [Range<Int>] = []
        while true {
            let start = index
            let untrimmedEnd = try scanElementEnd()
            var end = untrimmedEnd
            while end > start, Self.isWhitespace(bytes[end - 1]) {
                end -= 1
            }
            guard end > start else {
                throw error("batch item must not be empty")
            }
            ranges.append(start..<end)

            switch currentByte {
            case 0x2C:
                try advance()
                try skipWhitespace()
                guard currentByte != closingByte else {
                    throw error("\(containerName) must not contain a trailing comma")
                }
            case closingByte:
                try advance()
                try finishDocument()
                return ranges
            case nil:
                throw error("unterminated \(containerName)")
            default:
                throw error("expected ',' or closing delimiter in \(containerName)")
            }
        }
    }

    private mutating func scanElementEnd() throws -> Int {
        var nestedContainers = 0
        var inString = false
        var escaped = false

        while let byte = currentByte {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                try advance()
                continue
            }

            switch byte {
            case 0x22:
                inString = true
            case 0x5B, 0x7B:
                nestedContainers += 1
            case 0x5D, 0x7D:
                if byte == closingByte, nestedContainers == 0 {
                    return index
                }
                if nestedContainers > 0 {
                    nestedContainers -= 1
                }
            case 0x2C where nestedContainers == 0:
                return index
            default:
                break
            }
            try advance()
        }

        if inString {
            throw error("unterminated string in batch")
        }
        throw error("unterminated \(containerName)")
    }

    private mutating func finishDocument() throws {
        try skipWhitespace()
        guard index == bytes.count else {
            throw error("unexpected trailing bytes after batch")
        }
    }

    private mutating func skipWhitespace() throws {
        while let byte = currentByte, Self.isWhitespace(byte) {
            try advance()
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private mutating func advance() throws {
        index += 1
        if index >= nextCancellationCheck {
            try Task<Never, Never>.checkCancellation()
            nextCancellationCheck = index + 4_096
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func error(_ message: String) -> RawJSONError {
        RawJSONError(byteOffset: index, message: message)
    }

}

private func optionalScalarExactEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let lhs), .some(let rhs)): scalarExactEqual(lhs, rhs)
    default: false
    }
}

private func scalarExactHash(_ value: String, into hasher: inout Hasher) {
    hasher.combine(value.unicodeScalars.count)
    for scalar in value.unicodeScalars {
        hasher.combine(scalar.value)
    }
}

private func validateRawJSONLimits(_ limits: RawJSONLimits) throws {
    guard limits.maximumDocumentBytes >= 0,
        limits.maximumStringBytes >= 0,
        limits.maximumDepth >= 0,
        limits.maximumContainerEntries >= 0
    else {
        throw RawJSONError(message: "JSON limits must not be negative")
    }
}

private struct RawJSONParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private let limits: RawJSONLimits
    private var index = 0
    private var containerEntries = 0
    private var nextCancellationCheck = 4_096

    init(bytes: UnsafeBufferPointer<UInt8>, limits: RawJSONLimits) {
        self.bytes = bytes
        self.limits = limits
    }

    mutating func parse() throws -> RawJSONValue {
        try checkCancellation()
        try skipWhitespace()
        let value = try parseValue(depth: 0)
        try skipWhitespace()
        guard index == bytes.count else {
            throw error("unexpected trailing bytes")
        }
        return value
    }

    mutating func validateSyntax() throws {
        try checkCancellation()
        try skipWhitespace()
        try skipRoutingValue(depth: 0)
        try skipWhitespace()
        guard index == bytes.count else {
            throw error("unexpected trailing bytes")
        }
    }

    mutating func parseRequestRoute(
        maximumMethodBytes: Int,
        rawAwareMethods: [String],
        maximumIDBytes: Int
    ) throws -> RawJSONRequestRoute? {
        try checkCancellation()
        try skipWhitespace()
        guard currentByte == 0x7B else { return nil }
        try consume(0x7B)
        try skipWhitespace()

        var rawAwareMethod: String?
        var methodMemberCount = 0
        var hasID = false
        var id: ID?

        if currentByte != 0x7D {
            while true {
                guard currentByte == 0x22 else {
                    throw error("expected string object key")
                }
                let key = try parseRoutingString(maximumCapturedBytes: 6)
                try skipWhitespace()
                try consume(0x3A)
                try skipWhitespace()

                if key.map({ scalarExactEqual($0, "method") }) == true {
                    methodMemberCount += 1
                    if currentByte == 0x22 {
                        if let method = try parseRoutingString(
                            maximumCapturedBytes: maximumMethodBytes
                        ), rawAwareMethods.contains(method) {
                            rawAwareMethod = rawAwareMethod ?? method
                        }
                    } else {
                        try skipRoutingValue(depth: 1)
                    }
                } else if key.map({ scalarExactEqual($0, "id") }) == true {
                    hasID = true
                    id = try parseRoutingID(maximumStringBytes: maximumIDBytes)
                } else {
                    try skipRoutingValue(depth: 1)
                }

                try skipWhitespace()
                switch currentByte {
                case 0x2C:
                    try advance()
                    try skipWhitespace()
                case 0x7D:
                    break
                case nil:
                    throw error("unterminated request object")
                default:
                    throw error("expected ',' or '}' in request object")
                }
                if currentByte == 0x7D { break }
            }
        }

        try consume(0x7D)
        try skipWhitespace()
        guard index == bytes.count else {
            throw error("unexpected trailing bytes")
        }
        return RawJSONRequestRoute(
            rawAwareMethod: rawAwareMethod,
            methodMemberCount: methodMemberCount,
            hasID: hasID,
            id: id
        )
    }

    private mutating func parseRoutingID(maximumStringBytes: Int) throws -> ID? {
        guard let byte = currentByte else { return nil }
        switch byte {
        case 0x22:
            return try parseRoutingString(maximumCapturedBytes: maximumStringBytes).map(ID.string)
        case 0x2D, 0x30...0x39:
            guard let spelling = try parseRoutingNumber(maximumCapturedBytes: 32),
                let value = Int(spelling)
            else {
                return nil
            }
            return .number(value)
        default:
            try skipRoutingValue(depth: 1)
            return nil
        }
    }

    private mutating func parseRoutingString(maximumCapturedBytes: Int) throws -> String? {
        try consume(0x22)
        var captured: [UInt8] = []
        captured.reserveCapacity(min(maximumCapturedBytes, 64))
        var exceededLimit = false
        var utf8Validation = UTF8ValidationState()

        while let byte = currentByte {
            switch byte {
            case 0x22:
                guard utf8Validation.isComplete else {
                    throw error("invalid UTF-8 in string")
                }
                try advance()
                guard !exceededLimit else { return nil }
                guard let string = String(bytes: captured, encoding: .utf8) else {
                    throw error("invalid UTF-8 in string")
                }
                return string
            case 0x5C:
                guard utf8Validation.isComplete else {
                    throw error("invalid UTF-8 in string")
                }
                try advance()
                let escapedBytes = try parseRoutingEscape()
                appendRoutingBytes(
                    escapedBytes,
                    maximumCapturedBytes: maximumCapturedBytes,
                    captured: &captured,
                    exceededLimit: &exceededLimit
                )
            case 0x00...0x1F:
                throw error("unescaped control character in string")
            default:
                guard utf8Validation.consume(byte) else {
                    throw error("invalid UTF-8 in string")
                }
                appendRoutingBytes(
                    CollectionOfOne(byte),
                    maximumCapturedBytes: maximumCapturedBytes,
                    captured: &captured,
                    exceededLimit: &exceededLimit
                )
                try advance()
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseRoutingEscape() throws -> [UInt8] {
        guard let byte = currentByte else {
            throw error("unterminated string escape")
        }
        try advance()
        switch byte {
        case 0x22, 0x5C, 0x2F:
            return [byte]
        case 0x62:
            return [0x08]
        case 0x66:
            return [0x0C]
        case 0x6E:
            return [0x0A]
        case 0x72:
            return [0x0D]
        case 0x74:
            return [0x09]
        case 0x75:
            let first = try parseHexQuad()
            let scalarValue: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard currentByte == 0x5C else {
                    throw error("high surrogate must be followed by a low surrogate")
                }
                try advance()
                guard currentByte == 0x75 else {
                    throw error("high surrogate must be followed by a Unicode escape")
                }
                try advance()
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw error("invalid low surrogate")
                }
                scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw error("unpaired low surrogate")
                }
                scalarValue = first
            }
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw error("invalid Unicode scalar")
            }
            return Array(String(scalar).utf8)
        default:
            throw error("invalid string escape")
        }
    }

    private func appendRoutingBytes<S: Sequence>(
        _ bytes: S,
        maximumCapturedBytes: Int,
        captured: inout [UInt8],
        exceededLimit: inout Bool
    ) where S.Element == UInt8 {
        guard !exceededLimit else { return }
        for byte in bytes {
            if captured.count == maximumCapturedBytes {
                exceededLimit = true
                captured.removeAll(keepingCapacity: false)
                return
            }
            captured.append(byte)
        }
    }

    private mutating func skipRoutingValue(depth: Int) throws {
        guard depth <= 512 else {
            throw error("routing depth exceeds 512")
        }
        guard let byte = currentByte else {
            throw error("unexpected end of input")
        }
        switch byte {
        case 0x6E:
            try consumeKeyword("null")
        case 0x74:
            try consumeKeyword("true")
        case 0x66:
            try consumeKeyword("false")
        case 0x22:
            _ = try parseRoutingString(maximumCapturedBytes: 0)
        case 0x5B:
            try skipRoutingArray(depth: depth + 1)
        case 0x7B:
            try skipRoutingObject(depth: depth + 1)
        case 0x2D, 0x30...0x39:
            _ = try parseRoutingNumber(maximumCapturedBytes: 0)
        default:
            throw error("unexpected byte")
        }
    }

    private mutating func skipRoutingArray(depth: Int) throws {
        try consume(0x5B)
        try skipWhitespace()
        if currentByte == 0x5D {
            try advance()
            return
        }
        while true {
            try skipRoutingValue(depth: depth)
            try skipWhitespace()
            switch currentByte {
            case 0x2C:
                try advance()
                try skipWhitespace()
            case 0x5D:
                try advance()
                return
            default:
                throw error("expected ',' or ']' in array")
            }
        }
    }

    private mutating func skipRoutingObject(depth: Int) throws {
        try consume(0x7B)
        try skipWhitespace()
        if currentByte == 0x7D {
            try advance()
            return
        }
        while true {
            guard currentByte == 0x22 else {
                throw error("expected string object key")
            }
            _ = try parseRoutingString(maximumCapturedBytes: 0)
            try skipWhitespace()
            try consume(0x3A)
            try skipWhitespace()
            try skipRoutingValue(depth: depth)
            try skipWhitespace()
            switch currentByte {
            case 0x2C:
                try advance()
                try skipWhitespace()
            case 0x7D:
                try advance()
                return
            default:
                throw error("expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseRoutingNumber(maximumCapturedBytes: Int) throws -> String? {
        let range = try scanNumber()
        guard range.count <= maximumCapturedBytes else { return nil }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    private mutating func parseValue(depth: Int) throws -> RawJSONValue {
        guard let byte = currentByte else {
            throw error("unexpected end of input")
        }

        switch byte {
        case 0x6E:
            try consumeKeyword("null")
            return .null
        case 0x74:
            try consumeKeyword("true")
            return .bool(true)
        case 0x66:
            try consumeKeyword("false")
            return .bool(false)
        case 0x22:
            return .string(try parseString())
        case 0x5B:
            try checkContainerDepth(depth + 1)
            return .array(try parseArray(depth: depth + 1))
        case 0x7B:
            try checkContainerDepth(depth + 1)
            return .object(try parseObject(depth: depth + 1))
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw error("unexpected byte")
        }
    }

    private mutating func parseArray(depth: Int) throws -> [RawJSONValue] {
        try consume(0x5B)
        try skipWhitespace()
        if currentByte == 0x5D {
            try advance()
            return []
        }

        var values: [RawJSONValue] = []
        while true {
            try countContainerEntry()
            values.append(try parseValue(depth: depth))
            try skipWhitespace()
            switch currentByte {
            case 0x2C:
                try advance()
                try skipWhitespace()
            case 0x5D:
                try advance()
                return values
            case nil:
                throw error("unterminated array")
            default:
                throw error("expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseObject(depth: Int) throws -> ExactJSONObject {
        try consume(0x7B)
        try skipWhitespace()
        if currentByte == 0x7D {
            try advance()
            return ExactJSONObject(members: [])
        }

        var members: [ExactJSONObject.Member] = []
        while true {
            guard currentByte == 0x22 else {
                throw error("expected string object key")
            }
            let key = try parseString()
            try skipWhitespace()
            try consume(0x3A)
            try skipWhitespace()
            try countContainerEntry()
            let value = try parseValue(depth: depth)
            members.append(.init(key: key, value: value))
            try skipWhitespace()

            switch currentByte {
            case 0x2C:
                try advance()
                try skipWhitespace()
            case 0x7D:
                try advance()
                return ExactJSONObject(members: members)
            case nil:
                throw error("unterminated object")
            default:
                throw error("expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseString() throws -> String {
        try consume(0x22)
        var segmentStart = index
        var result = ""
        var decodedByteCount = 0

        while let byte = currentByte {
            switch byte {
            case 0x22:
                try appendUTF8(
                    from: segmentStart,
                    to: index,
                    into: &result,
                    decodedByteCount: &decodedByteCount
                )
                try advance()
                return result
            case 0x5C:
                try appendUTF8(
                    from: segmentStart,
                    to: index,
                    into: &result,
                    decodedByteCount: &decodedByteCount
                )
                try advance()
                try appendEscape(into: &result, decodedByteCount: &decodedByteCount)
                segmentStart = index
            case 0x00...0x1F:
                throw error("unescaped control character in string")
            default:
                try advance()
            }
        }

        throw error("unterminated string")
    }

    private mutating func appendEscape(
        into result: inout String,
        decodedByteCount: inout Int
    ) throws {
        guard let byte = currentByte else {
            throw error("unterminated string escape")
        }
        try advance()

        switch byte {
        case 0x22:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\"")
        case 0x5C:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\\")
        case 0x2F:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("/")
        case 0x62:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\u{08}")
        case 0x66:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\u{0C}")
        case 0x6E:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\n")
        case 0x72:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\r")
        case 0x74:
            try addDecodedBytes(1, to: &decodedByteCount)
            result.append("\t")
        case 0x75:
            let first = try parseHexQuad()
            let scalarValue: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard currentByte == 0x5C else {
                    throw error("high surrogate must be followed by a low surrogate")
                }
                try advance()
                guard currentByte == 0x75 else {
                    throw error("high surrogate must be followed by a Unicode escape")
                }
                try advance()
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw error("invalid low surrogate")
                }
                scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw error("unpaired low surrogate")
                }
                scalarValue = first
            }

            guard let scalar = UnicodeScalar(scalarValue) else {
                throw error("invalid Unicode scalar")
            }
            try addDecodedBytes(scalar.utf8ByteCount, to: &decodedByteCount)
            result.unicodeScalars.append(scalar)
        default:
            throw error("invalid string escape")
        }

    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = currentByte, let digit = hexDigit(byte) else {
                throw error("invalid Unicode escape")
            }
            value = (value << 4) | digit
            try advance()
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let range = try scanNumber()
        return String(decoding: bytes[range], as: UTF8.self)
    }

    private mutating func scanNumber() throws -> Range<Int> {
        let start = index
        if currentByte == 0x2D {
            try advance()
        }

        guard let first = currentByte else {
            throw error("incomplete number")
        }
        if first == 0x30 {
            try advance()
            if let byte = currentByte, (0x30...0x39).contains(byte) {
                throw error("leading zero in number")
            }
        } else if (0x31...0x39).contains(first) {
            try consumeDigits()
        } else {
            throw error("invalid number")
        }

        if currentByte == 0x2E {
            try advance()
            guard let byte = currentByte, (0x30...0x39).contains(byte) else {
                throw error("fraction requires a digit")
            }
            try consumeDigits()
        }

        if currentByte == 0x65 || currentByte == 0x45 {
            try advance()
            if currentByte == 0x2B || currentByte == 0x2D {
                try advance()
            }
            guard let byte = currentByte, (0x30...0x39).contains(byte) else {
                throw error("exponent requires a digit")
            }
            try consumeDigits()
        }

        return start..<index
    }

    private mutating func consumeDigits() throws {
        while let byte = currentByte, (0x30...0x39).contains(byte) {
            try advance()
        }
    }

    private mutating func consumeKeyword(_ keyword: StaticString) throws {
        for expected in keyword.withUTF8Buffer({ Array($0) }) {
            guard currentByte == expected else {
                throw error("invalid literal")
            }
            try advance()
        }
    }

    private mutating func appendUTF8(
        from start: Int,
        to end: Int,
        into result: inout String,
        decodedByteCount: inout Int
    ) throws {
        guard start < end else { return }
        try addDecodedBytes(end - start, to: &decodedByteCount)
        guard let segment = String(bytes: bytes[start..<end], encoding: .utf8) else {
            throw error("invalid UTF-8 in string")
        }
        result.append(segment)
    }

    private mutating func skipWhitespace() throws {
        while let byte = currentByte,
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        {
            try advance()
        }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard currentByte == expected else {
            throw error("unexpected byte")
        }
        try advance()
    }

    private mutating func countContainerEntry() throws {
        let (next, overflow) = containerEntries.addingReportingOverflow(1)
        guard !overflow, next <= limits.maximumContainerEntries else {
            throw error(
                "container entries exceed maximumContainerEntries (\(limits.maximumContainerEntries))"
            )
        }
        containerEntries = next
    }

    private func addDecodedBytes(_ count: Int, to total: inout Int) throws {
        let (next, overflow) = total.addingReportingOverflow(count)
        guard !overflow, next <= limits.maximumStringBytes else {
            throw error(
                "decoded string exceeds maximumStringBytes (\(limits.maximumStringBytes))"
            )
        }
        total = next
    }

    private func checkContainerDepth(_ depth: Int) throws {
        guard depth <= limits.maximumDepth else {
            throw error("nesting exceeds maximumDepth (\(limits.maximumDepth))")
        }
    }

    private mutating func advance() throws {
        index += 1
        if index >= nextCancellationCheck {
            try checkCancellation()
            nextCancellationCheck = index + 4_096
        }
    }

    private func checkCancellation() throws {
        try Task<Never, Never>.checkCancellation()
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func error(_ message: String) -> RawJSONError {
        RawJSONError(byteOffset: index, message: message)
    }
}

private func hexDigit(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x30...0x39: UInt32(byte - 0x30)
    case 0x41...0x46: UInt32(byte - 0x41 + 10)
    case 0x61...0x66: UInt32(byte - 0x61 + 10)
    default: nil
    }
}

extension UnicodeScalar {
    fileprivate var utf8ByteCount: Int {
        switch value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }
}

private enum RawJSONEncoder {
    struct Measurement {
        let limits: RawJSONLimits
        var containerEntries = 0

        mutating func measure(_ value: RawJSONValue, depth: Int) throws -> Int {
            try Task<Never, Never>.checkCancellation()

            let count: Int
            switch value {
            case .null:
                count = 4
            case .bool(let value):
                count = value ? 4 : 5
            case .number(let value):
                guard value.utf8.count <= limits.maximumDocumentBytes,
                    isValidJSONNumber(value)
                else {
                    throw RawJSONError(message: "invalid programmatic JSON number")
                }
                count = value.utf8.count
            case .string(let value):
                try checkString(value)
                count = try jsonStringByteCount(value)
            case .data(let mimeType, let data):
                let prefix = "data:\(mimeType ?? "text/plain");base64,"
                let base64Count = try base64EncodedLength(data.count)
                let stringCount = try checkedAdd(prefix.utf8.count, base64Count)
                guard stringCount <= limits.maximumStringBytes else {
                    throw RawJSONError(
                        message:
                            "encoded data string exceeds maximumStringBytes (\(limits.maximumStringBytes))"
                    )
                }
                count = try checkedAdd(try jsonStringByteCount(prefix), base64Count)
            case .array(let values):
                try checkContainerDepth(depth + 1)
                try countEntries(values.count)
                var total = 2
                for (offset, child) in values.enumerated() {
                    if offset > 0 { total = try checkedAdd(total, 1) }
                    total = try checkedAdd(total, try measure(child, depth: depth + 1))
                }
                count = total
            case .object(let object):
                try checkContainerDepth(depth + 1)
                try countEntries(object.members.count)
                var total = 2
                for (offset, member) in object.members.enumerated() {
                    try checkString(member.key)
                    if offset > 0 { total = try checkedAdd(total, 1) }
                    total = try checkedAdd(total, try jsonStringByteCount(member.key))
                    total = try checkedAdd(total, 1)
                    total = try checkedAdd(total, try measure(member.value, depth: depth + 1))
                }
                count = total
            }

            guard count <= limits.maximumDocumentBytes else {
                throw RawJSONError(
                    message:
                        "encoded value exceeds maximumDocumentBytes (\(limits.maximumDocumentBytes))"
                )
            }
            return count
        }

        private func checkString(_ value: String) throws {
            guard value.utf8.count <= limits.maximumStringBytes else {
                throw RawJSONError(
                    message: "string exceeds maximumStringBytes (\(limits.maximumStringBytes))")
            }
        }

        private mutating func countEntries(_ count: Int) throws {
            let (next, overflow) = containerEntries.addingReportingOverflow(count)
            guard !overflow, next <= limits.maximumContainerEntries else {
                throw RawJSONError(
                    message:
                        "container entries exceed maximumContainerEntries (\(limits.maximumContainerEntries))"
                )
            }
            containerEntries = next
        }

        private func checkContainerDepth(_ depth: Int) throws {
            guard depth <= limits.maximumDepth else {
                throw RawJSONError(
                    message: "nesting exceeds maximumDepth (\(limits.maximumDepth))")
            }
        }
    }

    static func append(
        _ value: RawJSONValue,
        to output: inout Data,
        limits: RawJSONLimits,
        depth: Int
    ) throws {
        try Task<Never, Never>.checkCancellation()
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let value):
            output.append(contentsOf: value.utf8)
        case .string(let value):
            try appendJSONString(value, to: &output)
        case .data(let mimeType, let data):
            let prefix = "data:\(mimeType ?? "text/plain");base64,"
            output.append(0x22)
            try appendJSONStringContents(prefix, to: &output)
            try Task<Never, Never>.checkCancellation()
            output.append(data.base64EncodedData())
            try Task<Never, Never>.checkCancellation()
            output.append(0x22)
        case .array(let values):
            output.append(0x5B)
            for (offset, child) in values.enumerated() {
                if offset > 0 { output.append(0x2C) }
                try append(child, to: &output, limits: limits, depth: depth + 1)
            }
            output.append(0x5D)
        case .object(let object):
            output.append(0x7B)
            for (offset, member) in object.members.enumerated() {
                if offset > 0 { output.append(0x2C) }
                try appendJSONString(member.key, to: &output)
                output.append(0x3A)
                try append(member.value, to: &output, limits: limits, depth: depth + 1)
            }
            output.append(0x7D)
        }
    }

    private static func appendJSONString(_ value: String, to output: inout Data) throws {
        output.append(0x22)
        try appendJSONStringContents(value, to: &output)
        output.append(0x22)
    }

    private static func appendJSONStringContents(_ value: String, to output: inout Data) throws {
        var byteCount = 0
        for byte in value.utf8 {
            switch byte {
            case 0x08: output.append(contentsOf: "\\b".utf8)
            case 0x09: output.append(contentsOf: "\\t".utf8)
            case 0x0A: output.append(contentsOf: "\\n".utf8)
            case 0x0C: output.append(contentsOf: "\\f".utf8)
            case 0x0D: output.append(contentsOf: "\\r".utf8)
            case 0x22: output.append(contentsOf: "\\\"".utf8)
            case 0x5C: output.append(contentsOf: "\\\\".utf8)
            case 0x00...0x1F:
                output.append(contentsOf: [
                    0x5C, 0x75, 0x30, 0x30,
                    lowercaseHexDigits[Int((byte >> 4) & 0xF)],
                    lowercaseHexDigits[Int(byte & 0xF)],
                ])
            default:
                output.append(byte)
            }
            byteCount += 1
            if byteCount == 4_096 {
                try Task<Never, Never>.checkCancellation()
                byteCount = 0
            }
        }
    }
}

private func jsonStringByteCount(_ value: String) throws -> Int {
    var count = 2
    var byteCount = 0
    for byte in value.utf8 {
        let addition: Int
        switch byte {
        case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
            addition = 2
        case 0x00...0x1F:
            addition = 6
        default:
            addition = 1
        }
        count = try checkedAdd(count, addition)
        byteCount += 1
        if byteCount == 4_096 {
            try Task<Never, Never>.checkCancellation()
            byteCount = 0
        }
    }
    return count
}

private let lowercaseHexDigits = Array("0123456789abcdef".utf8)

private func base64EncodedLength(_ byteCount: Int) throws -> Int {
    guard byteCount >= 0 else {
        throw RawJSONError(message: "negative data length")
    }
    let completeGroups = byteCount / 3
    let (completeLength, multiplyOverflow) = completeGroups.multipliedReportingOverflow(by: 4)
    guard !multiplyOverflow else {
        throw RawJSONError(message: "encoded data length overflows Int")
    }
    guard byteCount % 3 != 0 else { return completeLength }
    return try checkedAdd(completeLength, 4)
}

private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw RawJSONError(message: "encoded JSON length overflows Int")
    }
    return result
}

private func isValidJSONNumber(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty else { return false }
    var index = 0

    if bytes[index] == 0x2D {
        index += 1
        guard index < bytes.count else { return false }
    }

    if bytes[index] == 0x30 {
        index += 1
        if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            return false
        }
    } else if (0x31...0x39).contains(bytes[index]) {
        index += 1
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
        }
    } else {
        return false
    }

    if index < bytes.count, bytes[index] == 0x2E {
        index += 1
        guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
            return false
        }
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
        }
    }

    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
        index += 1
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            index += 1
        }
        guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
            return false
        }
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
        }
    }

    return index == bytes.count
}
