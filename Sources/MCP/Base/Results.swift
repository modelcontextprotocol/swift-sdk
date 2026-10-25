/// The kind of result a request produced.
///
/// Results at protocol 2026-07-28 and later carry a `resultType` member.
/// A missing value means ``complete``.
public struct ResultType: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The request finished; the result holds its outcome.
    public static let complete: ResultType = "complete"

    /// The server needs input from the client before it can finish (SEP-2322).
    public static let inputRequired: ResultType = "input_required"
}

/// Who may reuse a cached result (SEP-2549).
///
/// Open to values this SDK does not know, so a peer's new scope does not
/// fail the result.
public struct CacheScope: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Any client may reuse the result.
    public static let `public`: CacheScope = "public"
    /// Only the client that received the result may reuse it.
    public static let `private`: CacheScope = "private"
}

extension KeyedDecodingContainer {
    /// A caching hint's `ttlMs`, read leniently: a fractional value is
    /// rounded down; a negative, non-numeric or out-of-range value is
    /// ignored instead of failing the result.
    func decodeTTL(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value >= 0 ? value : nil
        }
        guard let value = try? decodeIfPresent(Double.self, forKey: key),
            value.isFinite, value >= 0, value < Double(Int.max)
        else { return nil }
        return Int(value)
    }

    /// A caching hint's `cacheScope`; a non-string value is ignored.
    func decodeCacheScope(forKey key: Key) -> CacheScope? {
        try? decodeIfPresent(CacheScope.self, forKey: key)
    }
}

/// A result that carries caching hints (SEP-2549).
///
/// Implemented by the results of `tools/list`, `prompts/list`,
/// `resources/list`, `resources/templates/list`, `resources/read` and
/// `server/discover`. A `nil` hint is filled in by the server for clients at
/// protocol 2026-07-28 and later, and omitted for earlier clients.
public protocol CacheableResult: Sendable {
    /// How long the result may be reused, in milliseconds. Zero means the
    /// result is stale immediately.
    var ttlMs: Int? { get set }
    /// Who may reuse the result.
    var cacheScope: CacheScope? { get set }
}

/// Wire names shared by results and requests.
enum ResultKeys {
    static let resultType = "resultType"
    static let ttlMs = "ttlMs"
    static let cacheScope = "cacheScope"
}

extension Value {
    /// The `resultType` of a result object; `.complete` when absent.
    var resultType: ResultType {
        objectValue?[ResultKeys.resultType]?.stringValue.map(ResultType.init(rawValue:)) ?? .complete
    }
}
