import Foundation
import Logging
import SystemPackage
import Testing

@testable import MCP

@Suite("Roundtrip Tests")
struct RoundtripTests {
    @Test(
        "Initialize roundtrip",
        .timeLimit(.minutes(1))
    )
    func testInitializeRoundtrip() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.initialize",
            factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init(), tools: .init())
        )
        let client = Client(name: "TestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let initTask = Task {
            let result = try await client.initialize()

            #expect(result.serverInfo.name == "TestServer")
            #expect(result.serverInfo.version == "1.0.0")
            #expect(result.capabilities.prompts != nil)
            #expect(result.capabilities.tools != nil)
            #expect(result.protocolVersion == Version.latest)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                initTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await initTask.value
            }
            try await group.next()
            group.cancelAll()
        }

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }
}
