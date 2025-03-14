import Foundation
import Logging
import SystemPackage
import Testing

@testable import MCP

@Suite("Roundtrip Tests")
struct RoundtripTests {
    @Test(
        .timeLimit(.minutes(1))
    )
    func testRoundtrip() async throws {
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
        await server.withMethodHandler(ListTools.self) { _ in
            return ListTools.Result(tools: [
                Tool(
                    name: "add",
                    description: "Adds two numbers together",
                    inputSchema: [
                        "a": ["type": "integer", "description": "The first number"],
                        "a": ["type": "integer", "description": "The second number"],
                    ])
            ])
        }
        await server.withMethodHandler(CallTool.self) { request in
            guard request.name == "add" else {
                return CallTool.Result(content: [.text("Invalid tool name")], isError: true)
            }

            guard let a = request.arguments?["a"]?.intValue,
                let b = request.arguments?["b"]?.intValue
            else {
                return CallTool.Result(
                    content: [.text("Did not receive valid arguments")], isError: true)
            }

            return CallTool.Result(content: [.text("\(a + b)")])
        }

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

        let listToolsTask = Task {
            let result = try await client.listTools()
            #expect(result.count == 1)
            #expect(result[0].name == "add")
        }

        let callToolTask = Task {
            let result = try await client.callTool(name: "add", arguments: ["a": 1, "b": 2])
            #expect(result.isError == nil)
            #expect(result.content == [.text("3")])
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                listToolsTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await callToolTask.value
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
