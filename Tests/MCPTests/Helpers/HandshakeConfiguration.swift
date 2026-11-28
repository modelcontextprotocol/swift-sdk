@testable import MCP

extension Client.Configuration {
    /// The `initialize` handshake. Tests written for 2025-11-25 and earlier
    /// connections use it; the default mode is `.automatic`.
    static let handshake = Client.Configuration(protocolMode: .handshake)

    /// Strict mode over the `initialize` handshake.
    static let strictHandshake = Client.Configuration(strict: true, protocolMode: .handshake)
}
