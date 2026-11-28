import MCP

// Snippets for docs/protocol_versions.md. See scripts/weave.swift.

// snippet: versions-constants
/// The revision lists in `Version`, with their current values.
func versionLists() -> (handshake: [String], stateless: [String], supported: Set<String>, latest: String) {
    (
        Version.handshake,  // ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
        Version.stateless,  // ["2026-07-28"]
        Version.supported,  // both lists
        Version.latestHandshake  // "2025-11-25": what `initialize` requests
    )
}
// endsnippet

// snippet: versions-profile
/// Whether the request being handled may send sampling, elicitation or
/// roots requests to its client.
func canSendServerRequests() -> Bool {
    guard let profile = Server.currentHandlerContext?.profile else { return false }
    return profile.allowsServerRequests  // false at 2026-07-28
}
// endsnippet

// snippet: versions-server-config
/// Both eras: the default.
let bothEras = Server.Configuration()

/// Only `initialize` clients. Stateless requests get -32022.
let handshakeOnly = Server.Configuration(protocolVersions: Version.handshake)

/// 2026-07-28, and `initialize` at 2025-11-25 or 2025-06-18.
let recentOnly = Server.Configuration(
    protocolVersions: [Version.v2026_07_28, Version.v2025_11_25, Version.v2025_06_18])
// endsnippet

// snippet: versions-handler-era
/// A tool that reports how its request was served.
func registerEraTool(on server: Server) async {
    await server.withMethodHandler(CallTool.self) { _ in
        let context = Server.currentHandlerContext
        let era = context?.isStateless == true ? "stateless" : "handshake"
        let text = "\(context?.protocolVersion ?? "unknown") (\(era))"
        return CallTool.Result(content: [.text(text: text)])
    }
}
// endsnippet

// snippet: versions-stateless-only
/// Only 2026-07-28 clients. `initialize`, and every request without a
/// stateless `_meta`, gets -32022.
let statelessOnly = Server.Configuration(protocolVersions: Version.stateless)
// endsnippet

// snippet: versions-client-modes
/// `server/discover` at 2026-07-28, with a fallback to `initialize`: the default.
let automaticMode = Client.Configuration(protocolMode: .automatic)

/// `initialize` only.
let handshakeMode = Client.Configuration(protocolMode: .handshake)

/// `server/discover` only, starting at 2026-07-28: no fallback.
let pinnedMode = Client.Configuration(protocolMode: .stateless(Version.v2026_07_28))
// endsnippet

// snippet: versions-client-connect
/// Connects in automatic mode and reports the outcome.
func connectAutomatically(over transport: any Transport) async throws -> (Client, String, Bool) {
    let client = Client(
        name: "app", version: "1.0.0", configuration: .init(protocolMode: .automatic))
    let result = try await client.connect(transport: transport)
    // The same value as `client.negotiatedProtocolVersion`.
    let version = result.protocolVersion
    // `true` after `server/discover`: every request then carries `_meta`.
    let stateless = await client.isStateless
    return (client, version, stateless)
}
// endsnippet
