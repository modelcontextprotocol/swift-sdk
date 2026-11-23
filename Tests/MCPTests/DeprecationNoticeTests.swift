import Foundation
import Logging
import Testing

@testable import MCP

// SEP-2577: implementations SHOULD warn when a deprecated capability is
// negotiated. The SDK logs a notice once for each process; each test runs
// with its own set of notices.

@Suite("Deprecation notices (SEP-2577)", .timeLimit(.minutes(1)))
struct DeprecationNoticeTests {
    private func notices(_ log: CapturingLogHandler) -> [String] {
        log.messages.filter { $0.contains("deprecated by the specification (SEP-2577)") }
    }

    /// Connects `count` client and server pairs and, with `call`, calls a
    /// tool on each. With `quietFirst`, the first pair has the transports'
    /// default no-op logger.
    private func run(
        count: Int = 1, mode: Client.ProtocolMode, call: Bool = true, quietFirst: Bool = false,
        client capabilities: Client.Capabilities, server serverCapabilities: Server.Capabilities,
        log: CapturingLogHandler
    ) async throws {
        try await DeprecationNotices.$current.withValue(DeprecationNotices()) {
            for index in 0..<count {
                let logger = quietFirst && index == 0 ? nil : Logger(label: "test") { _ in log }
                let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair(logger: logger)
                let server = Server(name: "s", version: "1", capabilities: serverCapabilities)
                await server.withMethodHandler(CallTool.self) { _ in .init(content: []) }
                try await server.start(transport: serverEnd)
                let client = Client(
                    name: "c", version: "1", capabilities: capabilities, configuration: .init(protocolMode: mode))
                try await client.connect(transport: clientEnd)
                if call { _ = try await client.callTool(name: "t") }
                await client.disconnect()
                await server.stop()
            }
        }
    }

    @Test("The server logs one notice for each deprecated client capability", arguments: [
        Client.ProtocolMode.handshake, .automatic,
    ])
    func clientCapabilities(mode: Client.ProtocolMode) async throws {
        let log = CapturingLogHandler(minimumLevel: .notice)
        try await run(
            count: 2, mode: mode, client: .init(sampling: .init(), roots: .init()),
            server: .init(tools: .init()), log: log)
        let logged = notices(log)
        #expect(logged.count == 2)
        #expect(logged.contains { $0.hasPrefix("The client declared the roots capability. Roots is deprecated") })
        #expect(logged.contains { $0.hasPrefix("The client declared the sampling capability. Sampling is deprecated") })
        #expect(logged.allSatisfy { $0.contains("first revision released on or after 2027-07-28") })
    }

    @Test("The client logs one notice when the server declares logging", arguments: [
        Client.ProtocolMode.handshake, .automatic,
    ])
    func serverCapabilities(mode: Client.ProtocolMode) async throws {
        let log = CapturingLogHandler(minimumLevel: .notice)
        try await run(count: 2, mode: mode, client: .init(), server: .init(logging: .init(), tools: .init()), log: log)
        #expect(notices(log).count == 1)
        #expect(notices(log).first?.hasPrefix("The server declared the logging capability") == true)
    }

    @Test("No notice without deprecated capabilities, and none at warning level")
    func none() async throws {
        let log = CapturingLogHandler(minimumLevel: .notice)
        try await run(mode: .automatic, client: .init(elicitation: .init()), server: .init(tools: .init()), log: log)
        #expect(notices(log).isEmpty)

        let warnings = CapturingLogHandler()
        try await run(mode: .automatic, client: .init(sampling: .init()), server: .init(logging: .init(), tools: .init()), log: warnings)
        #expect(notices(warnings).isEmpty)
    }

    @Test("A handshake client's capabilities are noticed during initialize, without another request")
    func duringInitialize() async throws {
        let log = CapturingLogHandler(minimumLevel: .notice)
        try await run(
            mode: .handshake, call: false, client: .init(sampling: .init(), roots: .init()),
            server: .init(tools: .init()), log: log)
        #expect(notices(log).count == 2)
    }

    @Test("An instance whose logger drops notices does not use them up")
    func quietInstanceFirst() async throws {
        let log = CapturingLogHandler(minimumLevel: .notice)
        try await run(
            count: 2, mode: .automatic, quietFirst: true, client: .init(sampling: .init(), roots: .init()),
            server: .init(logging: .init(), tools: .init()), log: log)
        // Roots and sampling from the server, logging from the client.
        #expect(notices(log).count == 3)
    }
}
