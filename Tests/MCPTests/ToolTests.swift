import Foundation
import Testing

@testable import MCP

@Suite("Tool Tests")
struct ToolTests {
    @Test("Tool initialization with valid parameters")
    func testToolInitialization() throws {
        let tool = Tool(
            name: "test_tool",
            description: "A test tool",
            inputSchema: .object([
                "param1": .string("Test parameter")
            ])
        )

        #expect(tool.name == "test_tool")
        #expect(tool.description == "A test tool")
        #expect(tool.inputSchema != nil)
    }

    @Test("Tool encoding and decoding")
    func testToolEncodingDecoding() throws {
        let tool = Tool(
            name: "test_tool",
            description: "Test tool description",
            inputSchema: .object([
                "param1": .string("String parameter"),
                "param2": .int(42),
            ])
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.name == tool.name)
        #expect(decoded.description == tool.description)
        #expect(decoded.inputSchema == tool.inputSchema)
    }

    @Test("Text content encoding and decoding")
    func testToolContentTextEncoding() throws {
        let content = Tool.Content.text("Hello, world!")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .text(let text) = decoded {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Image content encoding and decoding")
    func testToolContentImageEncoding() throws {
        let content = Tool.Content.image(
            data: "base64data",
            mimeType: "image/png",
            metadata: ["width": "100", "height": "100"]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .image(let data, let mimeType, let metadata) = decoded {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
            #expect(metadata?["width"] == "100")
            #expect(metadata?["height"] == "100")
        } else {
            #expect(Bool(false), "Expected image content")
        }
    }

    @Test("Resource content encoding and decoding")
    func testToolContentResourceEncoding() throws {
        let content = Tool.Content.resource(
            uri: "file://test.txt",
            mimeType: "text/plain",
            text: "Sample text"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .resource(let uri, let mimeType, let text) = decoded {
            #expect(uri == "file://test.txt")
            #expect(mimeType == "text/plain")
            #expect(text == "Sample text")
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test("ListTools parameters validation")
    func testListToolsParameters() throws {
        let params = ListTools.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListTools.Parameters()
        #expect(emptyParams.cursor == nil)
    }

    @Test("ListTools result validation")
    func testListToolsResult() throws {
        let tools = [
            Tool(name: "tool1", description: "First tool", inputSchema: nil),
            Tool(name: "tool2", description: "Second tool", inputSchema: nil),
        ]

        let result = ListTools.Result(tools: tools, nextCursor: "next_page")
        #expect(result.tools.count == 2)
        #expect(result.tools[0].name == "tool1")
        #expect(result.tools[1].name == "tool2")
        #expect(result.nextCursor == "next_page")
    }

    @Test("CallTool parameters validation")
    func testCallToolParameters() throws {
        let arguments: [String: Value] = [
            "param1": .string("value1"),
            "param2": .int(42),
        ]

        let params = CallTool.Parameters(name: "test_tool", arguments: arguments)
        #expect(params.name == "test_tool")
        #expect(params.arguments?["param1"] == .string("value1"))
        #expect(params.arguments?["param2"] == .int(42))
    }

    @Test("CallTool success result validation")
    func testCallToolResult() throws {
        let content = [
            Tool.Content.text("Result 1"),
            Tool.Content.text("Result 2"),
        ]

        let result = CallTool.Result(content: content)
        #expect(result.content.count == 2)
        #expect(result.isError == nil)

        if case .text(let text) = result.content[0] {
            #expect(text == "Result 1")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("CallTool error result validation")
    func testCallToolErrorResult() throws {
        let errorContent = [Tool.Content.text("Error message")]
        let errorResult = CallTool.Result(content: errorContent, isError: true)
        #expect(errorResult.content.count == 1)
        #expect(errorResult.isError == true)

        if case .text(let text) = errorResult.content[0] {
            #expect(text == "Error message")
        } else {
            #expect(Bool(false), "Expected error text content")
        }
    }

    @Test("ToolListChanged notification name validation")
    func testToolListChangedNotification() throws {
        #expect(ToolListChangedNotification.name == "notifications/tools/list_changed")
    }
}
