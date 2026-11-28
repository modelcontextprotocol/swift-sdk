import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/
public enum Version {
    /// Protocol revision 2024-11-05.
    public static let v2024_11_05 = "2024-11-05"
    /// Protocol revision 2025-03-26.
    public static let v2025_03_26 = "2025-03-26"
    /// Protocol revision 2025-06-18.
    public static let v2025_06_18 = "2025-06-18"
    /// Protocol revision 2025-11-25.
    public static let v2025_11_25 = "2025-11-25"
    /// Protocol revision 2026-07-28, served without the `initialize` handshake.
    public static let v2026_07_28 = "2026-07-28"

    /// Revisions that open a connection with the `initialize` handshake,
    /// newest first.
    public static let handshake: [String] = [v2025_11_25, v2025_06_18, v2025_03_26, v2024_11_05]

    /// Revisions served without a handshake, where every request carries its
    /// protocol version and client capabilities in `_meta`, newest first.
    public static let stateless: [String] = [v2026_07_28]

    /// All protocol versions supported by this implementation: the handshake
    /// and the stateless revisions.
    public static let supported: Set<String> = Set(handshake + stateless)

    /// The newest handshake revision: the version `initialize` requests and
    /// the default `MCP-Protocol-Version` of session-based HTTP. The newest
    /// revision the SDK implements is `stateless[0]`.
    public static let latestHandshake: String = v2025_11_25

    /// The newest handshake revision.
    @available(*, deprecated, renamed: "latestHandshake", message: "The newest revision is Version.stateless[0]")
    public static var latest: String { latestHandshake }

    /// Negotiates the protocol version of an `initialize` request.
    ///
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The requested version if it is a supported handshake
    ///   revision; otherwise the latest supported handshake revision.
    static func negotiate(clientRequestedVersion: String) -> String {
        if supported.contains(clientRequestedVersion), handshake.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        return handshake.first { supported.contains($0) } ?? latestHandshake
    }

    /// Returns the feature profile of a protocol version.
    ///
    /// Versions are compared as `YYYY-MM-DD` strings, so an unknown future
    /// version gets the profile of the newest known revision before it. A
    /// string that is not a `YYYY-MM-DD` date gets the profile of ``latestHandshake``.
    public static func profile(for version: String) -> ProtocolProfile {
        ProtocolProfile(version: version)
    }

    /// Whether `version` has the `YYYY-MM-DD` form of a revision identifier.
    static func isDateVersion(_ version: String) -> Bool {
        let bytes = Array(version.utf8)
        guard bytes.count == 10 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 7 {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return false }
            }
        }
        return true
    }
}

/// The protocol features that differ between MCP revisions.
///
/// Code that behaves differently per revision reads these flags instead of
/// comparing version strings.
public struct ProtocolProfile: Hashable, Sendable {
    /// The protocol version this profile describes.
    public let version: String

    /// The connection starts with `initialize` and `notifications/initialized`.
    public let usesInitializeHandshake: Bool

    /// Every request carries `io.modelcontextprotocol/protocolVersion`,
    /// `clientCapabilities` and optionally `clientInfo` in `_meta`.
    public let usesRequestMeta: Bool

    /// Results carry `resultType`, and `tools/call`, `prompts/get` and
    /// `resources/read` may return an input-required result (SEP-2322).
    public let usesResultType: Bool

    /// Streamable HTTP uses `Mcp-Session-Id`, the standalone GET stream and
    /// `Last-Event-ID` resumption.
    public let usesSessions: Bool

    /// Servers may send requests (sampling, elicitation, roots) to the client.
    public let allowsServerRequests: Bool

    /// Change notifications are delivered through `subscriptions/listen`
    /// instead of `resources/subscribe` and unsolicited notifications.
    public let usesSubscriptionsListen: Bool

    /// Streamable HTTP requests carry `Mcp-Method`, `Mcp-Name` and
    /// `Mcp-Param-*` headers (SEP-2243).
    public let usesStandardHeaders: Bool

    /// SSE priming events with empty data are safe for the client.
    public let allowsPrimingEvents: Bool

    /// Tasks are part of the protocol (SEP-1686): the client augments a
    /// request with `task` and reads the outcome with `tasks/result`.
    public let usesTaskAugmentation: Bool

    /// Tasks are the `io.modelcontextprotocol/tasks` extension (SEP-2663): the
    /// server decides, and `tasks/get` inlines the outcome.
    public let usesTasksExtension: Bool

    /// The task generation of this revision; `nil` before 2025-11-25.
    var taskGeneration: TaskGeneration? {
        if usesTasksExtension { return .v2 }
        return usesTaskAugmentation ? .v1 : nil
    }

    init(version: String) {
        // Only dates are ordered; anything else would sort above every revision.
        let comparable = Version.isDateVersion(version) ? version : Version.latestHandshake
        let stateless = comparable >= Version.v2026_07_28
        self.version = version
        self.usesInitializeHandshake = !stateless
        self.usesRequestMeta = stateless
        self.usesResultType = stateless
        self.usesSessions = !stateless
        self.allowsServerRequests = !stateless
        self.usesSubscriptionsListen = stateless
        self.usesStandardHeaders = stateless
        self.allowsPrimingEvents = !stateless && comparable >= Version.v2025_03_26
        self.usesTaskAugmentation = !stateless && comparable >= Version.v2025_11_25
        self.usesTasksExtension = stateless
    }
}
