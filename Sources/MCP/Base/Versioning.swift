import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-03-26/
public enum Version {
    /// All protocol versions supported by this implementation, ordered from newest to oldest.
    static let supported: Set<String> = [
        "2025-03-26",
        "2024-11-05",
    ]

    /// The latest protocol version supported by this implementation.
    public static let latest = supported.max()!

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
