import Foundation
import JSONSchema
import JSONSchemaBuilder
@testable import MCP
@testable import SchemaMCP
import System
import Testing

@Schemable
struct HelloInput {
    @SchemaOptions(description: "The name to say hello to", examples: "World")
    let name: String
}

@Schemable
struct AddInput {
    @SchemaOptions(description: "The first number to add")
    let a: Int

    @SchemaOptions(description: "The second number to add")
    let b: Int
}

@Schemable
struct EchoInput {
    @SchemaOptions(description: "The message to echo")
    let message: String
}

@Suite("Schema Tool Conversion Tests")
struct SchemaToolConversionTests {
    @Test func testSchemaToTool() async throws {
        let schemaTool = SchemaTool(
            name: "test",
            description: "Test tool",
            inputType: HelloInput.self,
            handler: { input in
                .init(content: [.text("Hello, \(input.name)")], isError: false)
            }
        )
        let tool = try schemaTool.toMCPTool()

        #expect(tool.name == "test")
        #expect(tool.description == "Test tool")

        let inputSchema: Value = .object([
            "required": .array([.string("name")]),
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The name to say hello to"),
                    "examples": .string("World"),
                ]),
            ]),
        ])
        #expect(tool.inputSchema == inputSchema)
    }

    @Test func testInputParsing() async throws {
        let tool = SchemaTool(
            name: "add",
            description: "Add two numbers",
            inputType: AddInput.self,
            handler: { input in
                .init(content: [.text("Sum: \(input.a + input.b)")])
            }
        )
        let args: [String: Value] = ["a": .int(2), "b": .int(3)]
        let parsed = try tool.parse(args)
        #expect(parsed.a == 2)
        #expect(parsed.b == 3)
    }

    @Test func testEchoResult() async throws {
        let tool = SchemaTool(
            name: "echo",
            description: "Echo a message",
            inputType: EchoInput.self,
            handler: { input in
                .init(content: [.text(input.message)])
            }
        )
        let args: [String: Value] = ["message": .string("hi!")]
        let result = try await tool.handler(args)
        #expect(result.content == [.text("hi!")])
    }

    @Test func testMultipleToolsConversion() async throws {
        let addTool = SchemaTool(
            name: "add",
            description: "Add two numbers",
            inputType: AddInput.self,
            handler: { _ in .init(content: [.text("")]) }
        )
        let echoTool = SchemaTool(
            name: "echo",
            description: "Echo a message",
            inputType: EchoInput.self,
            handler: { _ in .init(content: [.text("")]) }
        )
        let box = ToolBox(tools: (addTool, echoTool))
        let mcpTools = try box.mcpTools()
        #expect(mcpTools.count == 2)
        #expect(mcpTools[0].name == "add" || mcpTools[1].name == "add")
        #expect(mcpTools[0].name == "echo" || mcpTools[1].name == "echo")
    }
}

@Suite("Schema Tool Error Tests")
struct SchemaToolErrorTests {
    @Test func testInvalidInput() async throws {
        let tool = SchemaTool(
            name: "add",
            description: "Add two numbers",
            inputType: AddInput.self,
            handler: { input in
                .init(content: [.text("Sum: \(input.a + input.b)")])
            }
        )
        let args: [String: Value] = ["a": .string("oops"), "b": .int(3)]
        let result = try await tool.handler(args)
        #expect(result.isError == true)
        #expect(result.content.count == 1)

        guard
            case let .text(text) = result.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text.contains("Type mismatch: the instance of type `string` does not match the expected type `integer`."))
    }
}

@Suite("Schema Tool Server Tests")
class SchemaToolServerTests {
    let serverReadEnd: FileDescriptor
    let clientWriteEnd: FileDescriptor
    let clientReadEnd: FileDescriptor
    let serverWriteEnd: FileDescriptor

    let serverTransport: StdioTransport
    let clientTransport: StdioTransport

    let client: Client
    let server: Server

    init() throws {
        let clientToServer = try FileDescriptor.pipe()
        let serverToClient = try FileDescriptor.pipe()
        serverReadEnd = clientToServer.readEnd
        clientWriteEnd = clientToServer.writeEnd
        clientReadEnd = serverToClient.readEnd
        serverWriteEnd = serverToClient.writeEnd

        let serverTransport = StdioTransport(
            input: serverReadEnd,
            output: serverWriteEnd
        )
        self.serverTransport = serverTransport

        let server = Server(name: "Server", version: "1.0.0")
        self.server = server

        let clientTransport = StdioTransport(
            input: clientReadEnd,
            output: clientWriteEnd
        )
        self.clientTransport = clientTransport

        let client = Client(name: "Client", version: "1.0.0")
        self.client = client
    }

    private func setup() async throws {
        try await serverTransport.connect()
        try await clientTransport.connect()
        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)
    }

    private func registerHelloTool() async {
        let helloTool = SchemaTool(
            name: "hello",
            description: "Say hello",
            inputType: HelloInput.self,
            handler: { input in .init(content: [.text("Hello, \(input.name)")]) }
        )
        let toolBox = ToolBox(tools: helloTool)
        await server.withTools(toolBox)
    }

    private func registerTools() async {
        let helloTool = SchemaTool(
            name: "hello",
            description: "Say hello",
            inputType: HelloInput.self,
            handler: { input in .init(content: [.text("Hello, \(input.name)")]) }
        )
        let addTool = SchemaTool(
            name: "add",
            description: "Add two numbers",
            inputType: AddInput.self,
            handler: { input in .init(content: [.text("Sum: \(input.a + input.b)")]) }
        )
        let toolBox = ToolBox(tools: (helloTool, addTool))
        await server.withTools(toolBox)
    }

    private func registerErrorThrowingTool() async {
        let errorThrowingTool = SchemaTool(
            name: "error",
            description: "Throw an error",
            inputType: HelloInput.self,
            handler: { _ in throw URLError(.unknown) }
        )
        let toolBox = ToolBox(tools: errorThrowingTool)
        await server.withTools(toolBox)
    }

    private func teardown() async {
        await server.stop()
        await client.disconnect()
        await serverTransport.disconnect()
        await clientTransport.disconnect()
    }

    deinit {
        try? serverReadEnd.close()
        try? clientWriteEnd.close()
        try? clientReadEnd.close()
        try? serverWriteEnd.close()
    }

    @Test func testCallToolResult() async throws {
        try await setup()
        await registerHelloTool()

        let callResult = try await client.callTool(
            name: "hello", arguments: ["name": .string("World")]
        )
        #expect(callResult.isError == nil)
        #expect(callResult.content.count == 1)
        guard
            case let .text(text) = callResult.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text == "Hello, World")

        await teardown()
    }

    @Test func testCallToolError() async throws {
        try await setup()
        await registerHelloTool()

        let undefinedTool = try await client.callTool(
            name: "undefined", arguments: ["name": .string("World")]
        )
        #expect(undefinedTool.isError == true)
        #expect(undefinedTool.content.count == 1)
        guard
            case let .text(text) = undefinedTool.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text == "Tool `undefined` not found")

        let invalidParams = try await client.callTool(
            name: "hello", arguments: ["name": .bool(true)]
        )
        #expect(invalidParams.isError == true)
        #expect(invalidParams.content.count == 1)
        guard
            case let .text(text) = invalidParams.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text.contains("Type mismatch: the instance of type `boolean` does not match the expected type `string`."))

        await teardown()
    }

    @Test func testErrorThrowingTool() async throws {
        try await setup()
        await registerErrorThrowingTool()

        do {
            _ = try await client.callTool(name: "error", arguments: ["name": .string("World")])
            Issue.record("Expected a Error")
        } catch let error as MCPError {
            #expect(error == .internalError("The operation couldn’t be completed. (NSURLErrorDomain error -1.)"))
        } catch {
            Issue.record("Expected a MCPError")
        }

        await teardown()
    }

    @Test func testListTools() async throws {
        try await setup()
        await registerHelloTool()

        let toolsResult = try await client.listTools()
        #expect(toolsResult.tools.count == 1)
        #expect(toolsResult.tools[0].name == "hello")
        #expect(toolsResult.tools[0].description == "Say hello")

        let inputSchema: Value = .object([
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The name to say hello to"),
                    "examples": .string("World"),
                ]),
            ]),
            "required": .array([.string("name")]),
            "type": .string("object"),
        ])
        #expect(toolsResult.tools[0].inputSchema == inputSchema)

        await teardown()
    }

    @Test func testMultipleTools() async throws {
        try await setup()
        await registerTools()

        let helloResult = try await client.callTool(
            name: "hello", arguments: ["name": .string("World")]
        )
        guard
            case let .text(text) = helloResult.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text == "Hello, World")

        let addResult = try await client.callTool(
            name: "add", arguments: ["a": .int(2), "b": .int(3)]
        )
        guard
            case let .text(text) = addResult.content.first
        else {
            Issue.record("Expected a text message")
            return
        }
        #expect(text == "Sum: 5")

        await teardown()
    }
}
