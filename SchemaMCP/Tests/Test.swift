import Foundation
import JSONSchema
import JSONSchemaBuilder
@testable import MCP
@testable import SchemaMCP
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

@Suite("Schema Tool Tests")
struct SchemaToolTests {
    @Test func schemaToTool() async throws {
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

    @Test func parsesInputCorrectly() async throws {
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

    @Test func handlerReturnsExpectedResult() async throws {
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

    @Test func handlerReturnsErrorOnInvalidInput() async throws {
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
    }

    @Test func toolBoxMcpToolsReturnsAll() async throws {
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
