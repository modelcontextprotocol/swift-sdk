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
                "type": .string("object"),
                "properties": .object([
                    "param1": .string("Test parameter")
                ])
            ])
        )

        #expect(tool.name == "test_tool")
        #expect(tool.description == "A test tool")
        #expect(tool.inputSchema != nil)
    }

    @Test("Tool Annotations initialization and properties")
    func testToolAnnotationsInitialization() throws {
        // Empty annotations
        let emptyAnnotations = Tool.Annotations()
        #expect(emptyAnnotations.isEmpty)
        #expect(emptyAnnotations.title == nil)
        #expect(emptyAnnotations.readOnlyHint == nil)
        #expect(emptyAnnotations.destructiveHint == nil)
        #expect(emptyAnnotations.idempotentHint == nil)
        #expect(emptyAnnotations.openWorldHint == nil)

        // Full annotations
        let fullAnnotations = Tool.Annotations(
            title: "Test Tool",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )

        #expect(!fullAnnotations.isEmpty)
        #expect(fullAnnotations.title == "Test Tool")
        #expect(fullAnnotations.readOnlyHint == true)
        #expect(fullAnnotations.destructiveHint == false)
        #expect(fullAnnotations.idempotentHint == true)
        #expect(fullAnnotations.openWorldHint == false)

        // Partial annotations - should not be empty
        let partialAnnotations = Tool.Annotations(title: "Partial Test")
        #expect(!partialAnnotations.isEmpty)
        #expect(partialAnnotations.title == "Partial Test")

        // Initialize with nil literal
        let nilAnnotations: Tool.Annotations = nil
        #expect(nilAnnotations.isEmpty)
    }

    @Test("Tool Annotations encoding and decoding")
    func testToolAnnotationsEncodingDecoding() throws {
        let annotations = Tool.Annotations(
            title: "Test Tool",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )

        #expect(!annotations.isEmpty)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(annotations)
        let decoded = try decoder.decode(Tool.Annotations.self, from: data)

        #expect(decoded.title == annotations.title)
        #expect(decoded.readOnlyHint == annotations.readOnlyHint)
        #expect(decoded.destructiveHint == annotations.destructiveHint)
        #expect(decoded.idempotentHint == annotations.idempotentHint)
        #expect(decoded.openWorldHint == annotations.openWorldHint)

        // Test that empty annotations are encoded as expected
        let emptyAnnotations = Tool.Annotations()
        let emptyData = try encoder.encode(emptyAnnotations)
        let decodedEmpty = try decoder.decode(Tool.Annotations.self, from: emptyData)

        #expect(decodedEmpty.isEmpty)
    }

    @Test("Tool with annotations encoding and decoding")
    func testToolWithAnnotationsEncodingDecoding() throws {
        let annotations = Tool.Annotations(
            title: "Calculator",
            destructiveHint: false
        )

        let tool = Tool(
            name: "calculate",
            description: "Performs calculations",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "expression": .string("Mathematical expression to evaluate")
                ])
            ]),
            annotations: annotations
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.name == tool.name)
        #expect(decoded.description == tool.description)
        #expect(decoded.annotations.title == annotations.title)
        #expect(decoded.annotations.destructiveHint == annotations.destructiveHint)

        // Verify that the annotations field is properly included in the JSON
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"annotations\""))
        #expect(jsonString.contains("\"title\":\"Calculator\""))
    }

    @Test("Tool with empty annotations")
    func testToolWithEmptyAnnotations() throws {
        var tool = Tool(
            name: "test_tool",
            description: "Test tool description",
            inputSchema: ["type": "object"]
        )

        do {
            #expect(tool.annotations.isEmpty)

            let encoder = JSONEncoder()
            let data = try encoder.encode(tool)

            // Verify that empty annotations are not included in the JSON
            let jsonString = String(data: data, encoding: .utf8)!
            #expect(!jsonString.contains("\"annotations\""))
        }

        do {
            tool.annotations.title = "Test"

            #expect(!tool.annotations.isEmpty)

            let encoder = JSONEncoder()
            let data = try encoder.encode(tool)

            // Verify that empty annotations are not included in the JSON
            let jsonString = String(data: data, encoding: .utf8)!
            #expect(jsonString.contains("\"annotations\""))
        }
    }

    @Test("Tool with nil literal annotations")
    func testToolWithNilLiteralAnnotations() throws {
        let tool = Tool(
            name: "test_tool",
            description: "Test tool description",
            inputSchema: ["type": "object"],
            annotations: nil
        )

        #expect(tool.annotations.isEmpty)

        let encoder = JSONEncoder()
        let data = try encoder.encode(tool)

        // Verify that nil literal annotations are not included in the JSON
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(!jsonString.contains("\"annotations\""))
    }

    @Test("Tool encoding and decoding")
    func testToolEncodingDecoding() throws {
        let tool = Tool(
            name: "test_tool",
            description: "Test tool description",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "param1": .string("String parameter"),
                    "param2": .int(42)
                ])
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

        if case .text(let text, _, _) = decoded {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Image content encoding and decoding")
    func testToolContentImageEncoding() throws {
        let content = Tool.Content.image(data: "base64data", mimeType: "image/png")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .image(let data, let mimeType, _, _) = decoded {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
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

        if case .resource(let resourceContent, _, _) = decoded {
            #expect(resourceContent.uri == "file://test.txt")
            #expect(resourceContent.mimeType == "text/plain")
            #expect(resourceContent.text == "Sample text")
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test("Audio content encoding and decoding")
    func testToolContentAudioEncoding() throws {
        let content = Tool.Content.audio(
            data: "base64audiodata",
            mimeType: "audio/wav"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .audio(let data, let mimeType, _, _) = decoded {
            #expect(data == "base64audiodata")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }
    }

    @Test("ListTools parameters validation")
    func testListToolsParameters() throws {
        let params = ListTools.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListTools.Parameters()
        #expect(emptyParams.cursor == nil)
    }

    @Test("ListTools request decoding with omitted params")
    func testListToolsRequestDecodingWithOmittedParams() throws {
        // Test decoding when params field is omitted
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"tools/list"}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListTools>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListTools.name)
    }

    @Test("ListTools request decoding with null params")
    func testListToolsRequestDecodingWithNullParams() throws {
        // Test decoding when params field is null
        let jsonString = """
            {"jsonrpc":"2.0","id":"test-id","method":"tools/list","params":null}
            """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListTools>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListTools.name)
    }

    @Test("ListTools result validation")
    func testListToolsResult() throws {
        let tools = [
            Tool(name: "tool1", description: "First tool", inputSchema: ["type": "object"]),
            Tool(name: "tool2", description: "Second tool", inputSchema: ["type": "object"]),
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

        if case .text(let text, _, _) = result.content[0] {
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

        if case .text(let text, _, _) = errorResult.content[0] {
            #expect(text == "Error message")
        } else {
            #expect(Bool(false), "Expected error text content")
        }
    }

    @Test("ToolListChanged notification name validation")
    func testToolListChangedNotification() throws {
        #expect(ToolListChangedNotification.name == "notifications/tools/list_changed")
    }

    @Test("ListTools handler invocation without params")
    func testListToolsHandlerWithoutParams() async throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":1,"method":"tools/list"}
            """
        let jsonData = jsonString.data(using: .utf8)!

        let anyRequest = try JSONDecoder().decode(AnyRequest.self, from: jsonData)

        let handler = TypedRequestHandler<ListTools> { request, _ in
            #expect(request.method == ListTools.name)
            #expect(request.id == 1)
            #expect(request.params.cursor == nil)

            let testTool = Tool(
                name: "test_tool",
                description: "Test tool for verification",
                inputSchema: ["type": "object"]
            )
            return ListTools.response(id: request.id, result: ListTools.Result(tools: [testTool]))
        }

        // Create a dummy context for testing
        let dummyContext = Server.RequestHandlerContext(
            sendNotification: { _ in },
            sendMessage: { _ in },
            sendData: { _ in },
            sessionId: nil,
            shouldSendLogMessage: { _ in true }
        )
        let response = try await handler(anyRequest, context: dummyContext)

        if case .success(let value) = response.result {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(value)
            let result = try decoder.decode(ListTools.Result.self, from: data)

            #expect(result.tools.count == 1)
            #expect(result.tools[0].name == "test_tool")
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }

    @Test("Tool with missing description")
    func testToolWithMissingDescription() throws {
        let jsonString = """
            {
                "name": "test_tool",
                "inputSchema": {"type": "object"}
            }
            """
        let jsonData = jsonString.data(using: .utf8)!

        let tool = try JSONDecoder().decode(Tool.self, from: jsonData)

        #expect(tool.name == "test_tool")
        #expect(tool.description == nil)
        #expect(tool.inputSchema == ["type": "object"])
    }

    // MARK: - Tool with outputSchema

    @Test("Tool with outputSchema encoding and decoding")
    func testToolWithOutputSchema() throws {
        let outputSchema: Value = [
            "type": "object",
            "properties": [
                "result": ["type": "integer"]
            ],
            "required": ["result"]
        ]

        let tool = Tool(
            name: "calculate",
            description: "Performs calculations",
            inputSchema: ["type": "object"],
            outputSchema: outputSchema
        )

        #expect(tool.outputSchema != nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.outputSchema == outputSchema)

        // Verify JSON contains outputSchema
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"outputSchema\""))
    }

    @Test("CallTool result with structuredContent")
    func testCallToolResultWithStructuredContent() throws {
        let structuredContent: Value = [
            "name": "John",
            "age": 30
        ]

        let result = CallTool.Result(
            content: [.text("User data")],
            structuredContent: structuredContent
        )

        #expect(result.structuredContent == structuredContent)
        #expect(result.isError == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CallTool.Result.self, from: data)

        #expect(decoded.structuredContent == structuredContent)
    }

    // MARK: - Tool.Execution Tests

    @Test("Tool.Execution with taskSupport encoding and decoding")
    func testToolExecutionWithTaskSupport() throws {
        let execution = Tool.Execution(taskSupport: .required)
        #expect(execution.taskSupport == .required)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(execution)
        let decoded = try decoder.decode(Tool.Execution.self, from: data)

        #expect(decoded.taskSupport == .required)

        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"taskSupport\":\"required\""))
    }

    @Test("Tool with execution property encoding and decoding")
    func testToolWithExecution() throws {
        let tool = Tool(
            name: "long_running_task",
            description: "A task that takes a long time",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .optional)
        )

        #expect(tool.execution?.taskSupport == .optional)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.execution?.taskSupport == .optional)

        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"execution\""))
        #expect(jsonString.contains("\"taskSupport\":\"optional\""))
    }

    @Test(
        "Tool.Execution.TaskSupport enum values",
        arguments: [
            (Tool.Execution.TaskSupport.forbidden, "forbidden"),
            (Tool.Execution.TaskSupport.optional, "optional"),
            (Tool.Execution.TaskSupport.required, "required")
        ]
    )
    func testTaskSupportEnumValues(testCase: (value: Tool.Execution.TaskSupport, rawValue: String)) throws {
        #expect(testCase.value.rawValue == testCase.rawValue)

        let execution = Tool.Execution(taskSupport: testCase.value)
        let encoder = JSONEncoder()
        let data = try encoder.encode(execution)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"\(testCase.rawValue)\""))
    }

    @Test("Tool.Execution with nil taskSupport")
    func testToolExecutionWithNilTaskSupport() throws {
        let execution = Tool.Execution(taskSupport: nil)
        #expect(execution.taskSupport == nil)

        let encoder = JSONEncoder()
        let data = try encoder.encode(execution)

        // Empty execution should encode as empty object
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString == "{}")
    }

    // MARK: - Tool with Title, Icons, _meta Tests

    @Test("Tool with top-level title property")
    func testToolWithTitle() throws {
        let tool = Tool(
            name: "calculate",
            title: "Calculator Tool",
            description: "Performs calculations",
            inputSchema: ["type": "object"]
        )

        #expect(tool.title == "Calculator Tool")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.title == "Calculator Tool")

        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"title\":\"Calculator Tool\""))
    }

    @Test("Tool with icons")
    func testToolWithIcons() throws {
        let icons = [
            Icon(src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48"], theme: .light),
            Icon(src: "https://example.com/icon-dark.png", mimeType: "image/png", sizes: ["48x48"], theme: .dark)
        ]

        let tool = Tool(
            name: "visual_tool",
            description: "A tool with icons",
            inputSchema: ["type": "object"],
            icons: icons
        )

        #expect(tool.icons?.count == 2)
        #expect(tool.icons?[0].theme == .light)
        #expect(tool.icons?[1].theme == .dark)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.icons?.count == 2)
        #expect(decoded.icons?[0].src == "https://example.com/icon.png")
        #expect(decoded.icons?[1].src == "https://example.com/icon-dark.png")
    }

    @Test("Tool with _meta")
    func testToolWithMeta() throws {
        let meta: [String: Value] = [
            "vendor": .string("example"),
            "version": .int(1),
            "experimental": .bool(true)
        ]

        let tool = Tool(
            name: "meta_tool",
            description: "A tool with metadata",
            inputSchema: ["type": "object"],
            _meta: meta
        )

        #expect(tool._meta?["vendor"]?.stringValue == "example")
        #expect(tool._meta?["version"]?.intValue == 1)
        #expect(tool._meta?["experimental"]?.boolValue == true)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded._meta?["vendor"]?.stringValue == "example")
        #expect(decoded._meta?["version"]?.intValue == 1)
    }

    @Test("Tool with all properties")
    func testToolWithAllProperties() throws {
        let tool = Tool(
            name: "full_tool",
            title: "Full Featured Tool",
            description: "A tool with all properties",
            inputSchema: [
                "type": "object",
                "properties": [
                    "input": ["type": "string"]
                ]
            ],
            outputSchema: [
                "type": "object",
                "properties": [
                    "result": ["type": "integer"]
                ]
            ],
            _meta: ["custom": .string("value")],
            icons: [Icon(src: "https://example.com/icon.svg", mimeType: "image/svg+xml")],
            execution: Tool.Execution(taskSupport: .optional),
            annotations: Tool.Annotations(
                title: "Annotated Title",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.name == "full_tool")
        #expect(decoded.title == "Full Featured Tool")
        #expect(decoded.description == "A tool with all properties")
        #expect(decoded.outputSchema != nil)
        #expect(decoded._meta?["custom"]?.stringValue == "value")
        #expect(decoded.icons?.count == 1)
        #expect(decoded.execution?.taskSupport == .optional)
        #expect(decoded.annotations.title == "Annotated Title")
        #expect(decoded.annotations.readOnlyHint == true)
    }

    // MARK: - ResourceLink Content Tests

    @Test("ResourceLink content encoding and decoding")
    func testResourceLinkContent() throws {
        let resourceLink = ResourceLink(
            name: "data.json",
            title: "Data File",
            uri: "file:///data/output.json",
            description: "Output data file",
            mimeType: "application/json",
            size: 1024
        )

        let content = Tool.Content.resourceLink(resourceLink)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .resourceLink(let link) = decoded {
            #expect(link.name == "data.json")
            #expect(link.title == "Data File")
            #expect(link.uri == "file:///data/output.json")
            #expect(link.description == "Output data file")
            #expect(link.mimeType == "application/json")
            #expect(link.size == 1024)
        } else {
            #expect(Bool(false), "Expected resourceLink content")
        }

        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"type\":\"resource_link\""))
    }

    @Test("ResourceLink with icons and annotations")
    func testResourceLinkWithIconsAndAnnotations() throws {
        let resourceLink = ResourceLink(
            name: "report.pdf",
            uri: "file:///reports/report.pdf",
            mimeType: "application/pdf",
            annotations: Annotations(audience: [.assistant], priority: 0.8),
            icons: [Icon(src: "https://example.com/pdf.png", mimeType: "image/png")]
        )

        let content = Tool.Content.resourceLink(resourceLink)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .resourceLink(let link) = decoded {
            #expect(link.annotations?.audience == [.assistant])
            #expect(link.annotations?.priority == 0.8)
            #expect(link.icons?.count == 1)
        } else {
            #expect(Bool(false), "Expected resourceLink content")
        }
    }

    // MARK: - Content with Annotations and _meta Tests

    @Test("Text content with annotations and _meta")
    func testTextContentWithAnnotationsAndMeta() throws {
        let annotations = Annotations(audience: [.user, .assistant], priority: 0.9)
        let meta: [String: Value] = ["source": .string("calculation")]

        let content = Tool.Content.text("Result: 42", annotations: annotations, _meta: meta)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .text(let text, let decodedAnnotations, let decodedMeta) = decoded {
            #expect(text == "Result: 42")
            #expect(decodedAnnotations?.audience == [.user, .assistant])
            #expect(decodedAnnotations?.priority == 0.9)
            #expect(decodedMeta?["source"]?.stringValue == "calculation")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test("Image content with annotations")
    func testImageContentWithAnnotations() throws {
        let annotations = Annotations(audience: [.user])

        let content = Tool.Content.image(
            data: "base64imagedata",
            mimeType: "image/png",
            annotations: annotations,
            _meta: nil
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .image(_, _, let decodedAnnotations, _) = decoded {
            #expect(decodedAnnotations?.audience == [.user])
        } else {
            #expect(Bool(false), "Expected image content")
        }
    }

    @Test("Resource content with annotations")
    func testResourceContentWithAnnotations() throws {
        let annotations = Annotations(priority: 0.5)
        let resourceContent = Resource.Content.text("File contents", uri: "file:///test.txt", mimeType: "text/plain")

        let content = Tool.Content.resource(resource: resourceContent, annotations: annotations, _meta: nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(Tool.Content.self, from: data)

        if case .resource(_, let decodedAnnotations, _) = decoded {
            #expect(decodedAnnotations?.priority == 0.5)
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }
}

// MARK: - Tool Name Validation Tests

@Suite("Tool Name Validation Tests")
struct ToolNameValidationTests {

    // MARK: - Valid Names

    @Test(
        "Accepts valid tool names",
        arguments: [
            "getUser",
            "get_user_profile",
            "user-profile-update",
            "admin.tools.list",
            "DATA_EXPORT_v2.1",
            "a",
            String(repeating: "a", count: 128)
        ]
    )
    func acceptsValidNames(toolName: String) throws {
        let result = validateToolName(toolName)
        #expect(result.isValid == true)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Invalid Names

    @Test("Rejects empty name")
    func rejectsEmptyName() throws {
        let result = validateToolName("")
        #expect(result.isValid == false)
        #expect(result.warnings.contains { $0.contains("cannot be empty") })
    }

    @Test("Rejects name exceeding max length")
    func rejectsNameExceedingMaxLength() throws {
        let longName = String(repeating: "a", count: 129)
        let result = validateToolName(longName)
        #expect(result.isValid == false)
        #expect(result.warnings.contains { $0.contains("exceeds maximum length of 128 characters") })
        #expect(result.warnings.contains { $0.contains("current: 129") })
    }

    @Test(
        "Rejects names with invalid characters",
        arguments: [
            ("get user profile", " "),
            ("get,user,profile", ","),
            ("user/profile/update", "/"),
            ("user@domain.com", "@")
        ]
    )
    func rejectsInvalidCharacters(testCase: (toolName: String, invalidChar: String)) throws {
        let result = validateToolName(testCase.toolName)
        #expect(result.isValid == false)
        #expect(result.warnings.contains { $0.contains("invalid characters") })
    }

    @Test("Rejects multiple invalid characters")
    func rejectsMultipleInvalidChars() throws {
        let result = validateToolName("user name@domain,com")
        #expect(result.isValid == false)
        let warningWithChars = result.warnings.first { $0.contains("invalid characters") }
        #expect(warningWithChars != nil)
    }

    @Test("Rejects unicode characters")
    func rejectsUnicodeCharacters() throws {
        let result = validateToolName("user-ñame")  // n with tilde
        #expect(result.isValid == false)
    }

    // MARK: - Warnings for Problematic Patterns

    @Test("Warns on leading dash")
    func warnsOnLeadingDash() throws {
        let result = validateToolName("-get-user")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dash") })
    }

    @Test("Warns on trailing dash")
    func warnsOnTrailingDash() throws {
        let result = validateToolName("get-user-")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dash") })
    }

    @Test("Warns on leading dot")
    func warnsOnLeadingDot() throws {
        let result = validateToolName(".get.user")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dot") })
    }

    @Test("Warns on trailing dot")
    func warnsOnTrailingDot() throws {
        let result = validateToolName("get.user.")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dot") })
    }

    // MARK: - Edge Cases

    @Test("Handles only dots")
    func handlesOnlyDots() throws {
        let result = validateToolName("...")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dot") })
    }

    @Test("Handles only dashes")
    func handlesOnlyDashes() throws {
        let result = validateToolName("---")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("starts or ends with a dash") })
    }

    @Test("Rejects only slashes")
    func rejectsOnlySlashes() throws {
        let result = validateToolName("///")
        #expect(result.isValid == false)
        #expect(result.warnings.contains { $0.contains("invalid characters") })
    }

    @Test("Rejects mixed valid and invalid characters")
    func rejectsMixedValidInvalid() throws {
        let result = validateToolName("user@name123")
        #expect(result.isValid == false)
        #expect(result.warnings.contains { $0.contains("invalid characters") })
    }

    // MARK: - validateAndWarnToolName

    @Test("validateAndWarnToolName returns true for valid name")
    func validateAndWarnReturnsTrue() throws {
        let isValid = validateAndWarnToolName("valid-tool-name")
        #expect(isValid == true)
    }

    @Test("validateAndWarnToolName returns false for invalid name")
    func validateAndWarnReturnsFalse() throws {
        #expect(validateAndWarnToolName("") == false)
        #expect(validateAndWarnToolName(String(repeating: "a", count: 129)) == false)
        #expect(validateAndWarnToolName("invalid name") == false)
    }
}

// MARK: - Unicode Tool Tests

@Suite("Unicode Tool Tests")
struct UnicodeToolTests {

    /// Test strings with various Unicode characters (matching Python SDK)
    static let unicodeTestStrings: [String: String] = [
        "cyrillic": "Слой хранилища, где располагаются",
        "cyrillic_short": "Привет мир",
        "chinese": "你好世界 - 这是一个测试",
        "japanese": "こんにちは世界 - これはテストです",
        "korean": "안녕하세요 세계 - 이것은 테스트입니다",
        "arabic": "مرحبا بالعالم - هذا اختبار",
        "hebrew": "שלום עולם - זה מבחן",
        "greek": "Γεια σου κόσμε - αυτό είναι δοκιμή",
        "emoji": "Hello 👋 World 🌍 - Testing 🧪 Unicode ✨",
        "math": "∑ ∫ √ ∞ ≠ ≤ ≥ ∈ ∉ ⊆ ⊇",
        "accented": "Café, naïve, résumé, piñata, Zürich",
        "mixed": "Hello世界🌍Привет안녕مرحباשלום",
        "special": "Line\nbreak\ttab\r\nCRLF",
        "quotes": #"«French» „German" "English" 「Japanese」"#,
        "currency": "€100 £50 ¥1000 ₹500 ₽200 ¢99"
    ]

    @Test("Tool with Unicode description encodes and decodes correctly")
    func unicodeDescriptionEncodingDecoding() throws {
        let tool = Tool(
            name: "echo_unicode",
            description: "🔤 Echo Unicode text - Hello 👋 World 🌍 - Testing 🧪 Unicode ✨",
            inputSchema: ["type": "object"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(tool)
        let decoded = try decoder.decode(Tool.self, from: data)

        #expect(decoded.description == tool.description)
        #expect(decoded.description?.contains("🔤") == true)
        #expect(decoded.description?.contains("👋") == true)
    }

    @Test(
        "Unicode text in tool call arguments roundtrips correctly",
        arguments: Array(unicodeTestStrings.keys)
    )
    func unicodeArgumentsRoundtrip(testKey: String) throws {
        let testString = Self.unicodeTestStrings[testKey]!

        let params = CallTool.Parameters(
            name: "echo_unicode",
            arguments: ["text": .string(testString)]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        let decoded = try decoder.decode(CallTool.Parameters.self, from: data)

        #expect(decoded.arguments?["text"]?.stringValue == testString)
    }

    @Test("Unicode text in tool result content roundtrips correctly")
    func unicodeResultContentRoundtrip() throws {
        for (testName, testString) in Self.unicodeTestStrings {
            let result = CallTool.Result(
                content: [.text("Echo: \(testString)")]
            )

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            let data = try encoder.encode(result)
            let decoded = try decoder.decode(CallTool.Result.self, from: data)

            if case .text(let text, _, _) = decoded.content[0] {
                #expect(text == "Echo: \(testString)", "Failed for \(testName)")
            } else {
                Issue.record("Expected text content for \(testName)")
            }
        }
    }

    @Test("Mixed Unicode content types roundtrip correctly")
    func mixedUnicodeContentRoundtrip() throws {
        let cyrillic = Self.unicodeTestStrings["cyrillic"]!
        let mixed = Self.unicodeTestStrings["mixed"]!

        let result = CallTool.Result(
            content: [
                .text(cyrillic),
                .text(mixed)
            ],
            structuredContent: [
                "message": .string(mixed),
                "data": .object([
                    "text": .string(cyrillic)
                ])
            ]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CallTool.Result.self, from: data)

        #expect(decoded.content.count == 2)

        if case .text(let text1, _, _) = decoded.content[0] {
            #expect(text1 == cyrillic)
        }

        if case .text(let text2, _, _) = decoded.content[1] {
            #expect(text2 == mixed)
        }

        #expect(decoded.structuredContent?.objectValue?["message"]?.stringValue == mixed)
    }
}

// MARK: - Tool Pagination Tests

@Suite("Tool Pagination Tests")
struct ToolPaginationTests {

    @Test("ListTools cursor parameter encodes correctly")
    func cursorParameterEncoding() throws {
        let testCursor = "test-cursor-123"
        let params = ListTools.Parameters(cursor: testCursor)

        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"cursor\":\"test-cursor-123\""))
    }

    @Test("ListTools result with nextCursor encodes correctly")
    func resultWithNextCursor() throws {
        let tools = [
            Tool(name: "tool1", inputSchema: ["type": "object"]),
            Tool(name: "tool2", inputSchema: ["type": "object"])
        ]
        let result = ListTools.Result(tools: tools, nextCursor: "next-page-token")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListTools.Result.self, from: data)

        #expect(decoded.tools.count == 2)
        #expect(decoded.nextCursor == "next-page-token")
    }

    @Test("ListTools result without nextCursor indicates end of pagination")
    func resultWithoutNextCursor() throws {
        let tools = [
            Tool(name: "final_tool", inputSchema: ["type": "object"])
        ]
        let result = ListTools.Result(tools: tools, nextCursor: nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListTools.Result.self, from: data)

        #expect(decoded.nextCursor == nil)

        // Verify null cursor is not included in JSON
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(!jsonString.contains("nextCursor"))
    }

    @Test("ListTools request with cursor decodes correctly")
    func requestWithCursorDecoding() throws {
        let jsonString = """
            {"jsonrpc":"2.0","id":"page-2","method":"tools/list","params":{"cursor":"page-1-token"}}
            """
        let jsonData = jsonString.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Request<ListTools>.self, from: jsonData)

        #expect(decoded.id == "page-2")
        #expect(decoded.params.cursor == "page-1-token")
    }

    @Test("Simulated multi-page tool listing")
    func simulatedMultiPageToolListing() throws {
        // Simulate a server that returns 100 tools across multiple pages
        let allTools = (0..<100).map { i in
            Tool(name: "tool_\(i)", inputSchema: ["type": "object"])
        }

        let pageSize = 10
        var collectedTools: [Tool] = []
        var currentCursor: String? = nil

        // Simulate pagination
        for pageIndex in 0..<10 {
            let startIndex = pageIndex * pageSize
            let endIndex = min(startIndex + pageSize, allTools.count)
            let pageTools = Array(allTools[startIndex..<endIndex])

            let nextCursor = endIndex < allTools.count ? "page-\(pageIndex + 1)" : nil
            let result = ListTools.Result(tools: pageTools, nextCursor: nextCursor)

            // Encode and decode to verify serialization
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(result)
            let decoded = try decoder.decode(ListTools.Result.self, from: data)

            collectedTools.append(contentsOf: decoded.tools)
            currentCursor = decoded.nextCursor

            if currentCursor == nil {
                break
            }
        }

        #expect(collectedTools.count == 100)
        #expect(currentCursor == nil)

        // Verify all tools are unique and have correct names
        let toolNames = Set(collectedTools.map { $0.name })
        #expect(toolNames.count == 100)

        let expectedNames = Set((0..<100).map { "tool_\($0)" })
        #expect(toolNames == expectedNames)
    }
}