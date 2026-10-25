import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
public enum Version {
    /// Modern protocol revisions convey version, identity, and capabilities as
    /// per-request metadata (`2026-07-28` and later). They do not use `initialize`.
    public static let modern: Set<String> = [
        "2026-07-28",
    ]

    /// Legacy protocol revisions establish a session with an `initialize` handshake
    /// (`2025-11-25` and earlier).
    public static let legacy: Set<String> = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    /// All protocol versions supported by this implementation.
    public static let supported: Set<String> = modern.union(legacy)

    /// The latest protocol version supported by this implementation.
    public static let latest = modern.max()!

    /// The latest legacy (initialize-based) protocol version.
    public static let latestLegacy = legacy.max()!

    /// Whether `version` is a modern (per-request metadata) revision.
    public static func isModern(_ version: String) -> Bool {
        modern.contains(version)
    }

    /// Whether `version` is a legacy (initialize handshake) revision.
    public static func isLegacy(_ version: String) -> Bool {
        legacy.contains(version)
    }

    /// Negotiates a legacy protocol version for the `initialize` handshake.
    ///
    /// If the client's requested version is supported (including modern), that
    /// version is returned when it is legacy; otherwise the latest *legacy*
    /// version is returned. Modern clients should use per-request `_meta` and
    /// `server/discover` instead of this path.
    ///
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The negotiated protocol version for a legacy session.
    static func negotiate(clientRequestedVersion: String) -> String {
        if legacy.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        // A modern-only request on the initialize path is not a negotiated
        // modern session — fall back to the latest legacy version so dual-era
        // clients that probe initialize still get a usable legacy answer.
        return latestLegacy
    }

    /// Validates a per-request modern protocol version.
    ///
    /// Legacy revisions in `_meta` are rejected: modern-shaped requests must use
    /// a modern revision (or omit `_meta` and use the legacy initialize path).
    ///
    /// - Throws: ``MCPError/unsupportedProtocolVersion(requested:supported:)`` when
    ///   the version is not a modern revision implemented by this SDK.
    public static func requireSupported(_ version: String) throws {
        guard modern.contains(version) else {
            throw MCPError.unsupportedProtocolVersion(
                requested: version,
                supported: Array(modern).sorted(by: >)
            )
        }
    }
}
