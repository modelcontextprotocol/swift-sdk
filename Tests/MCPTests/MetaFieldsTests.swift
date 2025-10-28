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

    @Test("Encoding includes meta and custom fields")
    func testEncodingGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/request-id": .string("abc123")]
        let extra: [String: Value] = ["custom": .int(5)]

        let request = Request<TestMethod>(
            id: 42,
            method: TestMethod.name,
            params: Payload(message: "hello"),
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/request-id"] as? String == "abc123")
        #expect(json?["custom"] as? Int == 5)
    }

    @Test("Decoding restores general fields")
    func testDecodingGeneralFields() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": TestMethod.name,
            "params": ["message": "hi"],
            "_meta": ["vendor.example/session": "s42"],
            "custom-data": ["value": 1],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(Request<TestMethod>.self, from: data)

        let metaValue = decoded._meta?["vendor.example/session"]
        #expect(metaValue == .string("s42"))
        #expect(decoded.extraFields?["custom-data"] == .object(["value": .int(1)]))
    }

    @Test("Reserved fields are ignored when encoding extras")
    func testReservedFieldsIgnored() throws {
        let extra: [String: Value] = ["method": .string("override"), "custom": .bool(true)]

        let request = Request<TestMethod>(
            id: 1,
            method: TestMethod.name,
            params: Payload(message: "ping"),
            _meta: nil,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["method"] as? String == TestMethod.name)
        #expect(json?["custom"] as? Bool == true)

        let decoded = try JSONDecoder().decode(Request<TestMethod>.self, from: data)
        #expect(decoded.extraFields?["method"] == nil)
        #expect(decoded.extraFields?["custom"] == .bool(true))
    }

    @Test("Invalid meta key is rejected")
    func testInvalidMetaKey() {
        #expect(throws: MetaFieldError.invalidMetaKey("invalid key")) {
            let meta: [String: Value] = ["invalid key": .int(1)]
            let request = Request<TestMethod>(
                id: 1,
                method: TestMethod.name,
                params: Payload(message: "test"),
                _meta: meta,
                extraFields: nil
            )
            _ = try JSONEncoder().encode(request)
        }
    }

    @Test("Response encoding includes general fields")
    func testResponseGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/status": .string("partial")]
        let extra: [String: Value] = ["progress": .int(50)]
        let response = Response<TestMethod>(
            id: 99,
            result: .success(Payload(message: "ok")),
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/status"] as? String == "partial")
        #expect(json?["progress"] as? Int == 50)

        let decoded = try JSONDecoder().decode(Response<TestMethod>.self, from: data)
        #expect(decoded.extraFields?["progress"] == .int(50))
        #expect(decoded._meta?["vendor.example/status"] == .string("partial"))
    }

    @Test("Tool encoding and decoding with general fields")
    func testToolGeneralFields() throws {
        let meta: [String: Value] = [
            "vendor.example/outputTemplate": .string("ui://widget/kanban-board.html")
        ]

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
        let meta: [String: Value] = [
            "vendor.example/toolInvocation/invoking": .bool(true)
        ]

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
        let meta: [String: Value] = [
            "vendor.example/widgetPrefersBorder": .bool(true)
        ]

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

    @Test("Initialize.Result encoding with meta and extra fields")
    func testInitializeResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/build": .string("v1.0.0")]
        let extra: [String: Value] = ["serverTime": .int(1_234_567_890)]

        let result = Initialize.Result(
            protocolVersion: "2024-11-05",
            capabilities: Server.Capabilities(),
            serverInfo: Server.Info(name: "test", version: "1.0"),
            instructions: "Test server",
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/build"] as? String == "v1.0.0")
        #expect(json?["serverTime"] as? Int == 1_234_567_890)

        let decoded = try JSONDecoder().decode(Initialize.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/build"] == .string("v1.0.0"))
        #expect(decoded.extraFields?["serverTime"] == .int(1_234_567_890))
    }

    @Test("ListTools.Result encoding with meta and extra fields")
    func testListToolsResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/page": .int(1)]
        let extra: [String: Value] = ["totalCount": .int(42)]

        let tool = Tool(
            name: "test",
            description: "A test tool",
            inputSchema: try Value(["type": "object"])
        )

        let result = ListTools.Result(
            tools: [tool],
            nextCursor: "page2",
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/page"] as? Int == 1)
        #expect(json?["totalCount"] as? Int == 42)

        let decoded = try JSONDecoder().decode(ListTools.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/page"] == .int(1))
        #expect(decoded.extraFields?["totalCount"] == .int(42))
    }

    @Test("CallTool.Result encoding with meta and extra fields")
    func testCallToolResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/executionTime": .int(150)]
        let extra: [String: Value] = ["cacheHit": .bool(true)]

        let result = CallTool.Result(
            content: [.text("Result data")],
            isError: false,
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/executionTime"] as? Int == 150)
        #expect(json?["cacheHit"] as? Bool == true)

        let decoded = try JSONDecoder().decode(CallTool.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/executionTime"] == .int(150))
        #expect(decoded.extraFields?["cacheHit"] == .bool(true))
    }

    @Test("ListResources.Result encoding with meta and extra fields")
    func testListResourcesResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/cacheControl": .string("max-age=3600")]
        let extra: [String: Value] = ["refreshRate": .int(60)]

        let resource = Resource(
            name: "test.txt",
            uri: "file://test.txt",
            description: "Test resource",
            mimeType: "text/plain"
        )

        let result = ListResources.Result(
            resources: [resource],
            nextCursor: nil,
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let metaObject = json["_meta"] as! [String: Any]
        #expect(metaObject["vendor.example/cacheControl"] as? String == "max-age=3600")
        #expect(json["refreshRate"] as? Int == 60)

        let decoded = try JSONDecoder().decode(ListResources.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/cacheControl"] == Value.string("max-age=3600"))
        #expect(decoded.extraFields?["refreshRate"] == Value.int(60))
    }

    @Test("ReadResource.Result encoding with meta and extra fields")
    func testReadResourceResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/encoding": .string("utf-8")]
        let extra: [String: Value] = ["fileSize": .int(1024)]

        let result = ReadResource.Result(
            contents: [.text("file contents", uri: "file://test.txt")],
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/encoding"] as? String == "utf-8")
        #expect(json?["fileSize"] as? Int == 1024)

        let decoded = try JSONDecoder().decode(ReadResource.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/encoding"] == .string("utf-8"))
        #expect(decoded.extraFields?["fileSize"] == .int(1024))
    }

    @Test("ListPrompts.Result encoding with meta and extra fields")
    func testListPromptsResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/category": .string("system")]
        let extra: [String: Value] = ["featured": .bool(true)]

        let prompt = Prompt(
            name: "greeting",
            description: "A greeting prompt"
        )

        let result = ListPrompts.Result(
            prompts: [prompt],
            nextCursor: nil,
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/category"] as? String == "system")
        #expect(json?["featured"] as? Bool == true)

        let decoded = try JSONDecoder().decode(ListPrompts.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/category"] == .string("system"))
        #expect(decoded.extraFields?["featured"] == .bool(true))
    }

    @Test("GetPrompt.Result encoding with meta and extra fields")
    func testGetPromptResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/version": .int(2)]
        let extra: [String: Value] = ["lastModified": .string("2024-01-01")]

        let message = Prompt.Message.user("Hello")

        let result = GetPrompt.Result(
            description: "A test prompt",
            messages: [message],
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let metaObject = json["_meta"] as! [String: Any]
        #expect(metaObject["vendor.example/version"] as? Int == 2)
        #expect(json["lastModified"] as? String == "2024-01-01")

        let decoded = try JSONDecoder().decode(GetPrompt.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/version"] == Value.int(2))
        #expect(decoded.extraFields?["lastModified"] == Value.string("2024-01-01"))
    }

    @Test("CreateSamplingMessage.Result encoding with meta and extra fields")
    func testSamplingResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/model-version": .string("gpt-4-0613")]
        let extra: [String: Value] = ["tokensUsed": .int(250)]

        let result = CreateSamplingMessage.Result(
            model: "gpt-4",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("Hello!"),
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/model-version"] as? String == "gpt-4-0613")
        #expect(json?["tokensUsed"] as? Int == 250)

        let decoded = try JSONDecoder().decode(CreateSamplingMessage.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/model-version"] == .string("gpt-4-0613"))
        #expect(decoded.extraFields?["tokensUsed"] == .int(250))
    }

    @Test("CreateElicitation.Result encoding with meta and extra fields")
    func testElicitationResultGeneralFields() throws {
        let meta: [String: Value] = ["vendor.example/timestamp": .int(1_640_000_000)]
        let extra: [String: Value] = ["userAgent": .string("TestApp/1.0")]

        let result = CreateElicitation.Result(
            action: .accept,
            content: ["response": .string("user input")],
            _meta: meta,
            extraFields: extra
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let metaObject = json?["_meta"] as? [String: Any]
        #expect(metaObject?["vendor.example/timestamp"] as? Int == 1_640_000_000)
        #expect(json?["userAgent"] as? String == "TestApp/1.0")

        let decoded = try JSONDecoder().decode(CreateElicitation.Result.self, from: data)
        #expect(decoded._meta?["vendor.example/timestamp"] == .int(1_640_000_000))
        #expect(decoded.extraFields?["userAgent"] == .string("TestApp/1.0"))
    }
}
