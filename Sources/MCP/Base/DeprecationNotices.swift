import Foundation

/// The deprecated features of the specification that a peer declared,
/// each logged once for each process.
///
/// SEP-2577 deprecates roots, sampling and logging. Implementations SHOULD
/// warn when such a capability is negotiated. A notice for each server
/// instance would repeat for every session of a stateful HTTP server, which
/// creates a server for each session, so the SDK logs each notice once.
final class DeprecationNotices: @unchecked Sendable {
    /// The notices of the process. Tests run with their own instance.
    @TaskLocal static var current = DeprecationNotices()

    private let lock = NSLock()
    private var logged: Set<String> = []

    /// The notices for the deprecated capabilities a client declared, the
    /// first time only.
    func notices(forClient capabilities: Client.Capabilities) -> [String] {
        var result: [String] = []
        if capabilities.roots != nil, first("client.roots") {
            result.append(
                Self.notice(
                    "The client declared the roots capability", feature: "Roots",
                    migration: "pass directories or files in tool arguments, resource URIs or server configuration"))
        }
        if capabilities.sampling != nil, first("client.sampling") {
            result.append(
                Self.notice(
                    "The client declared the sampling capability", feature: "Sampling",
                    migration: "call the API of an LLM provider from the server"))
        }
        return result
    }

    /// The notices for the deprecated capabilities a server declared, the
    /// first time only.
    func notices(forServer capabilities: Server.Capabilities) -> [String] {
        guard capabilities.logging != nil, first("server.logging") else { return [] }
        return [
            Self.notice(
                "The server declared the logging capability", feature: "Logging",
                migration: "log to stderr (stdio) or use OpenTelemetry")
        ]
    }

    private func first(_ key: String) -> Bool {
        lock.withLock { logged.insert(key).inserted }
    }

    private static func notice(_ cause: String, feature: String, migration: String) -> String {
        "\(cause). \(feature) is deprecated by the specification (SEP-2577) and can be removed in the "
            + "first revision released on or after 2027-07-28. It still works on every revision that "
            + "has it. To migrate, \(migration). This notice is logged once."
    }
}
