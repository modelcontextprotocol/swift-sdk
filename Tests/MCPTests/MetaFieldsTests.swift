import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import class Foundation.JSONSerialization

@testable import MCP

@Suite("Meta Fields")
struct MetaFieldsTests {
    private struct Payload: Codable, Hashable, Sendable {
        let message: String
    }

    private enum TestMethod: Method {
        static let name = "test.general"
        typealias Parameters = Payload
        typealias Result = Payload
    }

    @Test("Tool encoding and decoding with general fields")
    func testToolGeneralFields() throws {
        let meta = Metadata(additionalFields: [
            "vendor.example/outputTemplate": .string("ui://widget/kanban-board.html")
        ])

        let tool = Tool(
            name: "kanban-board",
            title: "Kanban Board",
            description: "Display kanban widget",
            inputSchema: try Value(["type": "object"]),
            _meta: meta
        )

        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(
            metaObject?["vendor.example/outputTemplate"] as? String
                == "ui://widget/kanban-board.html")

        let decoded = try JSONDecoder().decode(Tool.self, from: data)
        #expect(
            decoded._meta?["vendor.example/outputTemplate"]
                == .string("ui://widget/kanban-board.html")
        )
    }

    @Test("Meta keys allow nested prefixes")
    func testMetaKeyNestedPrefixes() throws {
        let meta = Metadata(additionalFields: [
            "vendor.example/toolInvocation/invoking": .bool(true)
        ])

        let tool = Tool(
            name: "invoke",
            description: "Invoke tool",
            inputSchema: [:],
            _meta: meta
        )

        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/toolInvocation/invoking"] as? Bool == true)

        let decoded = try JSONDecoder().decode(Tool.self, from: data)
        #expect(decoded._meta?["vendor.example/toolInvocation/invoking"] == .bool(true))
    }

    @Test("Resource content encodes meta")
    func testResourceContentGeneralFields() throws {
        let meta = Metadata(additionalFields: [
            "vendor.example/widgetPrefersBorder": .bool(true)
        ])

        let content = Resource.Content.text(
            "<div>Widget</div>",
            uri: "ui://widget/kanban-board.html",
            mimeType: "text/html",
            _meta: meta
        )

        let data = try JSONEncoder().encode(content)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metaObject = json?["_meta"] as? [String: Any]

        #expect(metaObject?["vendor.example/widgetPrefersBorder"] as? Bool == true)

        let decoded = try JSONDecoder().decode(Resource.Content.self, from: data)
        #expect(decoded._meta?["vendor.example/widgetPrefersBorder"] == .bool(true))
    }

    @Test("Initialize.Result encoding with meta")
    func testInitializeResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/build": .string("v1.0.0")])

        let result = Initialize.Result(
            protocolVersion: "2024-11-05",
            capabilities: Server.Capabilities(),
            serverInfo: Server.Info(name: "test", version: "1.0"),
            instructions: "Test server",
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/build"] as? String == "v1.0.0")

        let decoded = try JSONDecoder().decode(Initialize.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/build"] == .string("v1.0.0"))
    }

    @Test("ListTools.Result encoding with meta")
    func testListToolsResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/page": .int(1)])

        let tool = Tool(
            name: "test",
            description: "A test tool",
            inputSchema: try Value(["type": "object"])
        )

        let result = ListTools.Result(
            tools: [tool],
            nextCursor: "page2",
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/page"] as? Int == 1)

        let decoded = try JSONDecoder().decode(ListTools.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/page"] == .int(1))
    }

    @Test("CallTool.Result encoding with meta")
    func testCallToolResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/executionTime": .int(150)])

        let result = CallTool.Result(
            content: [.text(text: "Result data", annotations: nil, _meta: nil)],
            isError: false,
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/executionTime"] as? Int == 150)

        let decoded = try JSONDecoder().decode(CallTool.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/executionTime"] == .int(150))
    }

    @Test("ListResources.Result encoding with meta")
    func testListResourcesResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/cacheControl": .string("max-age=3600")])

        let resource = Resource(
            name: "test.txt",
            uri: "file://test.txt",
            description: "Test resource",
            mimeType: "text/plain"
        )

        let result = ListResources.Result(
            resources: [resource],
            nextCursor: nil,
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let metaObject = json["_meta"] as! [String: Any]
        #expect(metaObject["vendor.example/cacheControl"] as? String == "max-age=3600")

        let decoded = try JSONDecoder().decode(ListResources.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/cacheControl"] == Value.string("max-age=3600"))
    }

    @Test("ReadResource.Result encoding with meta")
    func testReadResourceResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/encoding": .string("utf-8")])

        let result = ReadResource.Result(
            contents: [.text("file contents", uri: "file://test.txt")],
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/encoding"] as? String == "utf-8")

        let decoded = try JSONDecoder().decode(ReadResource.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/encoding"] == .string("utf-8"))
    }

    @Test("ListPrompts.Result encoding with meta")
    func testListPromptsResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/category": .string("system")])

        let prompt = Prompt(
            name: "greeting",
            description: "A greeting prompt"
        )

        let result = ListPrompts.Result(
            prompts: [prompt],
            nextCursor: nil,
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/category"] as? String == "system")

        let decoded = try JSONDecoder().decode(ListPrompts.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/category"] == .string("system"))
    }

    @Test("GetPrompt.Result encoding with meta")
    func testGetPromptResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/version": .int(2)])

        let message = Prompt.Message.user("Hello")

        let result = GetPrompt.Result(
            description: "A test prompt",
            messages: [message],
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let metaObject = json["_meta"] as! [String: Any]
        #expect(metaObject["vendor.example/version"] as? Int == 2)

        let decoded = try JSONDecoder().decode(GetPrompt.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/version"] == Value.int(2))
    }

    @Test("CreateSamplingMessage.Result encoding with meta")
    func testSamplingResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/model-version": .string("gpt-4-0613")])

        let result = CreateSamplingMessage.Result(
            model: "gpt-4",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("Hello!"),
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/model-version"] as? String == "gpt-4-0613")

        let decoded = try JSONDecoder().decode(CreateSamplingMessage.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/model-version"] == .string("gpt-4-0613"))
    }

    @Test("CreateElicitation.Result encoding with meta")
    func testElicitationResultGeneralFields() throws {
        let meta = Metadata(additionalFields: ["vendor.example/timestamp": .int(1_640_000_000)])

        let result = CreateElicitation.Result(
            action: .accept,
            content: ["response": .string("user input")],
            _meta: meta
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/timestamp"] as? Int == 1_640_000_000)

        let decoded = try JSONDecoder().decode(CreateElicitation.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/timestamp"] == .int(1_640_000_000))
    }
}
