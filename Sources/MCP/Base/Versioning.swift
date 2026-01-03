import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/
public enum Version {
    // MARK: - Version Constants

    /// Protocol version 2025-11-25: Tasks, icons, URL elicitation, sampling tools, tool execution
    public static let v2025_11_25 = "2025-11-25"

    /// Protocol version 2025-06-18: Elicitation, structured output, title fields, resource links
    public static let v2025_06_18 = "2025-06-18"

    /// Protocol version 2025-03-26: JSON-RPC batching
    public static let v2025_03_26 = "2025-03-26"

    /// Protocol version 2024-11-05: Initial stable release
    public static let v2024_11_05 = "2024-11-05"

    // MARK: - Computed Properties

    /// All protocol versions supported by this implementation.
    public static let supported: Set<String> = [
        v2025_11_25,
        v2025_06_18,
        v2025_03_26,
        v2024_11_05,
    ]

    /// The latest protocol version supported by this implementation.
    public static let latest = v2025_11_25

    /// The default protocol version assumed when no `MCP-Protocol-Version` header is received.
    ///
    /// Per the spec: "For backwards compatibility, if the server does _not_ receive an
    /// `MCP-Protocol-Version` header, and has no other way to identify the version - for example,
    /// by relying on the protocol version negotiated during initialization - the server **SHOULD**
    /// assume protocol version `2025-03-26`."
    public static let defaultNegotiated = v2025_03_26

    /// Negotiates the protocol version based on the client's request and server's capabilities.
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The negotiated protocol version. If the client's requested version is supported,
    ///            that version is returned. Otherwise, the server's latest supported version is returned.
    static func negotiate(clientRequestedVersion: String) -> String {
        if supported.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        return latest
    }
}
