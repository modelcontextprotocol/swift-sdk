import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

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
            capabilities: .init(
                prompts: .init(),
                resources: .init(),
                tools: .init()
            )
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            return ListTools.Result(tools: [
                Tool(
                    name: "add",
                    description: "Adds two numbers together",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "a": ["type": "integer", "description": "The first number"],
                            "b": ["type": "integer", "description": "The second number"]
                        ],
                        "required": ["a", "b"]
                    ])
            ])
        }
        await server.withRequestHandler(CallTool.self) { request, _ in
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

        // Add resource handlers to server
        await server.withRequestHandler(ListResources.self) { _, _ in
            return ListResources.Result(resources: [
                Resource(
                    name: "Example Text",
                    uri: "test://example.txt",
                    description: "A test resource",
                    mimeType: "text/plain"
                ),
                Resource(
                    name: "Test Data",
                    uri: "test://data.json",
                    description: "JSON test data",
                    mimeType: "application/json"
                ),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            guard request.uri == "test://example.txt" else {
                return ReadResource.Result(contents: [.text("Resource not found", uri: request.uri)]
                )
            }
            return ReadResource.Result(contents: [.text("Hello, World!", uri: request.uri)])
        }

        let client = Client(name: "TestClient", version: "1.0")

        try await server.start(transport: serverTransport)

        let initTask = Task {
            let result = try await client.connect(transport: clientTransport)

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

        // Test ping
        let pingTask = Task {
            try await client.ping()
            // Ping doesn't return anything, so just getting here without throwing is success
            #expect(Bool(true))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                pingTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await pingTask.value
            }
            try await group.next()
            group.cancelAll()
        }

        let listToolsTask = Task {
            let (tools, _) = try await client.listTools()
            #expect(tools.count == 1)
            #expect(tools[0].name == "add")
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
                callToolTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await listToolsTask.value
            }
            group.addTask {
                try await callToolTask.value
            }
            try await group.next()
            group.cancelAll()
        }

        // Test listing resources
        let listResourcesTask = Task {
            let result = try await client.listResources()
            #expect(result.resources.count == 2)
            #expect(result.resources[0].uri == "test://example.txt")
            #expect(result.resources[0].name == "Example Text")
            #expect(result.resources[1].uri == "test://data.json")
            #expect(result.resources[1].name == "Test Data")
        }

        // Test reading a resource
        let readResourceTask = Task {
            let result = try await client.readResource(uri: "test://example.txt")
            #expect(result.count == 1)
            #expect(result[0] == .text("Hello, World!", uri: "test://example.txt"))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                listResourcesTask.cancel()
                readResourceTask.cancel()
                throw CancellationError()
            }
            group.addTask {
                try await listResourcesTask.value
            }
            group.addTask {
                try await readResourceTask.value
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
