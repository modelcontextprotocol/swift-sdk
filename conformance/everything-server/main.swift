/**
 * MCP HTTP Server Wrapper
 *
 * HTTP server that wraps the MCP conformance server for testing with the
 * official conformance framework.
 *
 * Usage: mcp-everything-server [--port PORT] | --stdio
 *
 * `--stdio` serves the same server over stdin and stdout, for interop tests
 * with other SDKs' clients (interop/README.md).
 */

import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Test Data

private let testImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
private let testAudioBase64 = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

// MARK: - Server State

actor ServerState {
    var resourceSubscriptions: Set<String> = []
    /// Whether the trigger tools have added their dynamic tool and prompt.
    var dynamicToolListed = false
    var dynamicPromptListed = false

    func listDynamicTool() { dynamicToolListed = true }
    func listDynamicPrompt() { dynamicPromptListed = true }
    var watchedResourceContent = "Watched resource content"

    func subscribe(to uri: String) {
        resourceSubscriptions.insert(uri)
    }

    func unsubscribe(from uri: String) {
        resourceSubscriptions.remove(uri)
    }

    func isSubscribed(to uri: String) -> Bool {
        resourceSubscriptions.contains(uri)
    }

    func updateWatchedResource(_ newContent: String) {
        watchedResourceContent = newContent
    }
}

// MARK: - Server Setup

func createConformanceServer(state: ServerState, transport: any Transport) async -> Server {
    let server = Server(
        name: "mcp-conformance-test-server",
        version: "1.0.0",
        capabilities: Server.Capabilities(
            completions: .init(),
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: true)
        )
    )

    await server.withTasks(conformanceTasks)

    // Tools
    await server.withMethodHandler(ListTools.self) { _ in
        let dynamic = await state.dynamicToolListed
        let listed: [Tool] = [
            Tool(name: "test_simple_text", description: "Tests simple text content response", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_image_content", description: "Tests image content response", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_audio_content", description: "Tests audio content response", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_embedded_resource", description: "Tests embedded resource content response", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_multiple_content_types", description: "Tests response with multiple content types", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_error_handling", description: "Tests error response handling", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_logging", description: "Tests logging capabilities", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_progress", description: "Tests progress notifications", inputSchema: .object(["type": "object", "properties": ["duration_ms": ["type": "number", "description": "Duration in milliseconds to report progress"]]])),
            Tool(name: "add_numbers", description: "Adds two numbers together", inputSchema: .object(["type": "object", "properties": ["a": ["type": "number", "description": "First number"], "b": ["type": "number", "description": "Second number"]]])),
            Tool(name: "test_tool_with_progress", description: "Tool reports progress notifications", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_tool_with_logging", description: "Tool sends log messages during execution", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_reconnection", description: "Tests SSE reconnection and resumption with Last-Event-ID", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_sampling", description: "Tests LLM sampling capabilities", inputSchema: .object(["type": "object", "properties": ["prompt": ["type": "string", "description": "Text to send to the LLM"]], "required": ["prompt"]])),
            Tool(name: "test_elicitation", description: "Tests user input elicitation", inputSchema: .object(["type": "object", "properties": ["message": ["type": "string", "description": "Text displayed to user"]], "required": ["message"]])),
            Tool(name: "test_elicitation_sep1034_defaults", description: "Tests elicitation with default values (SEP-1034)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_elicitation_sep1330_enums", description: "Tests elicitation with enum variants (SEP-1330)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_client_elicitation_defaults", description: "Tests that client applies defaults for omitted elicitation fields", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_missing_capability", description: "Requires the sampling client capability (SEP-2575 -32021)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_logging_tool", description: "Attempts to log; dropped unless the request set a log level (SEP-2575)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_streaming_elicitation", description: "Returns a plain result; the response stream must carry no requests (SEP-2575)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_trigger_tool_change", description: "Adds a tool and sends notifications/tools/list_changed (SEP-2575)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_trigger_prompt_change", description: "Adds a prompt and sends notifications/prompts/list_changed (SEP-2575)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_x_mcp_header", description: "Mirrors region into the Mcp-Param-Region header (SEP-2243)", inputSchema: .object([
                "type": "object",
                "properties": [
                    "region": ["type": "string", "x-mcp-header": "Region"],
                    "level": ["type": "integer"],
                ],
                "required": ["region"],
            ])),
            Tool(name: "json_schema_2020_12_tool", description: "Tool with JSON Schema 2020-12 features", inputSchema: [
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "$defs": [
                    "address": [
                        "$anchor": "addressDef",
                        "type": "object",
                        "properties": ["street": ["type": "string"], "city": ["type": "string"]],
                    ]
                ],
                "properties": [
                    "name": ["type": "string"],
                    "address": ["$ref": "#/$defs/address"],
                    "contactMethod": ["type": "string", "enum": ["phone", "email"]],
                    "phone": ["type": "string"],
                    "email": ["type": "string"],
                ],
                "allOf": [["anyOf": [["required": ["phone"]], ["required": ["email"]]]]],
                "if": ["properties": ["contactMethod": ["const": "phone"]], "required": ["contactMethod"]],
                "then": ["required": ["phone"]],
                "else": ["required": ["email"]],
                "additionalProperties": false,
            ]),
        ]
        return .init(tools: listed + inputRequiredTools + taskTools + (dynamic ? [Tool(name: "test_dynamic_tool", description: "Listed after test_trigger_tool_change", inputSchema: .object(["type": "object", "properties": [:]]))] : []))
    }

    await server.withMethodHandler(CallTool.self) { [weak server, transport] params in
        if let result = try callInputRequiredTool(params) { return result }
        if let result = try await callTaskTool(params) { return result }
        switch params.name {
        case "test_simple_text":
            return .init(content: [.text(text: "This is a simple text response for testing.")], isError: false)
        case "test_trigger_tool_change":
            await state.listDynamicTool()
            try await server?.notify(ToolListChangedNotification.message())
            return .init(content: [.text(text: "Tool list changed")], isError: false)
        case "test_trigger_prompt_change":
            await state.listDynamicPrompt()
            try await server?.notify(PromptListChangedNotification.message())
            return .init(content: [.text(text: "Prompt list changed")], isError: false)
        case "test_dynamic_tool":
            return .init(content: [.text(text: "Dynamic tool")], isError: false)
        case "test_x_mcp_header":
            let region = params.arguments?["region"]?.stringValue ?? ""
            return .init(content: [.text(text: "Region: \(region)")], isError: false)
        case "test_image_content":
            return .init(content: [.image(data: testImageBase64, mimeType: "image/png")], isError: false)
        case "test_audio_content":
            return .init(content: [.audio(data: testAudioBase64, mimeType: "audio/wav")], isError: false)
        case "test_embedded_resource":
            return .init(content: [.resource(resource: .text("This is an embedded resource content.", uri: "test://embedded-resource", mimeType: "text/plain"))], isError: false)
        case "test_multiple_content_types":
            return .init(content: [
                .text(text: "Multiple content types test:"),
                .image(data: testImageBase64, mimeType: "image/png"),
                .resource(resource: .text("{\"test\":\"data\",\"value\":123}", uri: "test://mixed-content-resource", mimeType: "application/json"))], isError: false)
        case "test_error_handling":
            return .init(content: [.text(text: "An error occurred during tool execution")], isError: true)
        case "test_logging":
            return .init(content: [.text(text: "Logging test completed")], isError: false)
        case "test_progress":
            let duration = params.arguments?["duration_ms"]?.intValue ?? 1000
            try? await Task.sleep(for: .milliseconds(duration))
            return .init(content: [.text(text: "Progress test completed")], isError: false)
        case "add_numbers":
            guard let a = params.arguments?["a"]?.intValue, let b = params.arguments?["b"]?.intValue else {
                return .init(content: [.text(text: "Invalid arguments: expected numbers a and b")], isError: true)
            }
            return .init(content: [.text(text: "\(a + b)")], isError: false)
        case "test_tool_with_progress":
            if let token = params._meta?.progressToken {
                let notification1 = ProgressNotification.message(
                    .init(progressToken: token, progress: 0, total: 100)
                )
                try await server?.notify(notification1)
                try await Task.sleep(for: .milliseconds(50))

                let notification2 = ProgressNotification.message(
                    .init(progressToken: token, progress: 50, total: 100)
                )
                try await server?.notify(notification2)
                try await Task.sleep(for: .milliseconds(50))

                let notification3 = ProgressNotification.message(
                    .init(progressToken: token, progress: 100, total: 100)
                )
                try await server?.notify(notification3)
            }

            return .init(content: [.text(text: "This is a simple text response for testing.")], isError: false)
        case "json_schema_2020_12_tool":
            return .init(content: [.text(text: "This is a simple text response for testing.")], isError: false)
        case "test_tool_with_logging":
            try await server?.log(level: .info, data: "Tool execution started")
            try await Task.sleep(for: .milliseconds(50))
            try await server?.log(level: .info, data: "Tool processing data")
            try await Task.sleep(for: .milliseconds(50))
            try await server?.log(level: .info, data: "Tool execution completed")
            return .init(content: [.text(text: "Logging test completed")], isError: false)
        case "test_missing_capability":
            // SEP-2575: a request must not rely on undeclared client capabilities.
            guard Server.currentHandlerContext?.clientCapabilities?.sampling != nil else {
                throw MCPError.missingRequiredClientCapabilities(
                    Client.Capabilities(sampling: .init()),
                    message: "sampling capability required but not declared by client")
            }
            return .init(content: [.text(text: "Client declared the sampling capability; tool executed.")], isError: false)
        case "test_logging_tool":
            // Logged only when the request set _meta io.modelcontextprotocol/logLevel.
            try await server?.log(level: .info, data: "test_logging_tool executed")
            return .init(content: [.text(text: "Log attempted; the server gates on the request log level.")], isError: false)
        case "test_streaming_elicitation":
            // The response stream carries no independent requests at 2026-07-28.
            return .init(content: [.text(text: "stream observed: result frames only, no top-level requests")], isError: false)
        case "test_reconnection":
            // SEP-1699: Close the SSE stream mid-call to trigger client reconnection.
            // The client should reconnect via GET with Last-Event-ID and receive the
            // response on the new stream.
            if let requestID = Server.currentHandlerContext?.id,
                let stateful = transport as? StatefulHTTPServerTransport
            {
                await stateful.closeSSEStream(forRequestID: requestID.description)
            }
            // Wait briefly for the client to reconnect before sending the response.
            try await Task.sleep(for: .milliseconds(100))
            return .init(content: [.text(text: "Reconnection test completed successfully. If you received this, the client properly reconnected after stream closure.")], isError: false)
        case "test_sampling":
            // Test LLM sampling - request sampling/createMessage from client
            guard let prompt = params.arguments?["prompt"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: prompt")], isError: true)
            }

            let samplingResult = try await server?.requestSampling(
                messages: [.user(.text(prompt))],
                maxTokens: 100
            )

            let responseText = samplingResult?.content.asArray
                .compactMap { block -> String? in
                    if case .text(let text) = block {
                        return text
                    }
                    return nil
                }
                .joined(separator: "\n") ?? "No response"

            return .init(content: [.text(text: responseText)], isError: false)
        case "test_elicitation":
            // Test elicitation - request user input for username and email
            guard let message = params.arguments?["message"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: message")], isError: true)
            }

            let elicitationResult = try await server?.requestElicitation(
                message: message,
                requestedSchema: Elicitation.RequestSchema(
                    properties: [
                        "username": .object(["type": .string("string")]),
                        "email": .object(["type": .string("string")])
                    ],
                    required: ["username", "email"]
                )
            )

            return .init(
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])")],
                isError: false
            )
        case "test_elicitation_sep1034_defaults":
            // Test elicitation with default values (SEP-1034)
            let elicitationResult = try await server?.requestElicitation(
                message: "Please provide the following information:",
                requestedSchema: Elicitation.RequestSchema(
                    properties: [
                        "name": .object([
                            "type": .string("string"),
                            "default": .string("John Doe")
                        ]),
                        "age": .object([
                            "type": .string("integer"),
                            "default": .int(30)
                        ]),
                        "score": .object([
                            "type": .string("number"),
                            "default": .double(95.5)
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "enum": .array([.string("active"), .string("inactive"), .string("pending")]),
                            "default": .string("active")
                        ]),
                        "verified": .object([
                            "type": .string("boolean"),
                            "default": .bool(true)
                        ])
                    ]
                )
            )

            return .init(
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])")],
                isError: false
            )
        case "test_elicitation_sep1330_enums":
            // Test elicitation with enum variants (SEP-1330)
            let elicitationResult = try await server?.requestElicitation(
                message: "Select options for enum testing:",
                requestedSchema: Elicitation.RequestSchema(
                    properties: [
                        // 1. Untitled single-select
                        "untitledSingle": .object([
                            "type": .string("string"),
                            "enum": .array([.string("option1"), .string("option2"), .string("option3")])
                        ]),
                        // 2. Titled single-select
                        "titledSingle": .object([
                            "type": .string("string"),
                            "oneOf": .array([
                                .object(["const": .string("opt1"), "title": .string("Option One")]),
                                .object(["const": .string("opt2"), "title": .string("Option Two")]),
                                .object(["const": .string("opt3"), "title": .string("Option Three")])
                            ])
                        ]),
                        // 3. Legacy titled (deprecated enumNames)
                        "legacyEnum": .object([
                            "type": .string("string"),
                            "enum": .array([.string("legacy1"), .string("legacy2"), .string("legacy3")]),
                            "enumNames": .array([.string("Legacy One"), .string("Legacy Two"), .string("Legacy Three")])
                        ]),
                        // 4. Untitled multi-select
                        "untitledMulti": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"),
                                "enum": .array([.string("multi1"), .string("multi2"), .string("multi3")])
                            ])
                        ]),
                        // 5. Titled multi-select
                        "titledMulti": .object([
                            "type": .string("array"),
                            "items": .object([
                                "anyOf": .array([
                                    .object(["const": .string("titled1"), "title": .string("Titled One")]),
                                    .object(["const": .string("titled2"), "title": .string("Titled Two")]),
                                    .object(["const": .string("titled3"), "title": .string("Titled Three")])
                                ])
                            ])
                        ])
                    ]
                )
            )

            return .init(
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])")],
                isError: false
            )
        case "test_client_elicitation_defaults":
            // Tool for client-side elicitation defaults test
            let elicitationResult = try await server?.requestElicitation(
                message: "Please provide your information (defaults available):",
                requestedSchema: Elicitation.RequestSchema(
                    properties: [
                        "name": .object([
                            "type": .string("string"),
                            "default": .string("John Doe")
                        ]),
                        "age": .object([
                            "type": .string("integer"),
                            "default": .int(30)
                        ]),
                        "score": .object([
                            "type": .string("number"),
                            "default": .double(95.5)
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "enum": .array([.string("active"), .string("inactive"), .string("pending")]),
                            "default": .string("active")
                        ]),
                        "verified": .object([
                            "type": .string("boolean"),
                            "default": .bool(true)
                        ])
                    ]
                )
            )

            // Verify the client applied defaults correctly
            guard let content = elicitationResult?.content,
                  let name = content["name"]?.stringValue,
                  let age = content["age"]?.intValue,
                  let score = content["score"]?.doubleValue,
                  let status = content["status"]?.stringValue,
                  let verified = content["verified"]?.boolValue else {
                return .init(content: [.text(text: "Client did not provide all required fields with defaults")], isError: true)
            }

            guard name == "John Doe", age == 30, score == 95.5, status == "active", verified == true else {
                return .init(content: [.text(text: "Client defaults do not match expected values")], isError: true)
            }

            return .init(
                content: [.text(text: "Client correctly applied all default values")],
                isError: false
            )
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)")], isError: true)
        }
    }

    // Resources
    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: [
            Resource(name: "Static Text Resource", uri: "test://static-text", description: "A simple static text resource", mimeType: "text/plain"),
            Resource(name: "Static Binary Resource", uri: "test://static-binary", description: "A simple static binary resource", mimeType: "application/octet-stream"),
            Resource(name: "Watched Resource", uri: "test://watched-resource", description: "A resource that can be subscribed to for updates", mimeType: "text/plain"),
        ])
    }

    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        .init(templates: [
            Resource.Template(uriTemplate: "test://template/{id}/data", name: "Template Resource", description: "A resource template with URI parameters", mimeType: "text/plain"),
        ])
    }

    await server.withMethodHandler(ReadResource.self) { params in
        switch params.uri {
        case "test://static-text":
            return .init(contents: [.text("This is static text content for testing.", uri: params.uri, mimeType: "text/plain")])
        case "test://static-binary":
            guard let imageData = Data(base64Encoded: testImageBase64) else {
                return .init(contents: [.text("Failed to decode binary data", uri: params.uri)])
            }
            return .init(contents: [.binary(imageData, uri: params.uri, mimeType: "application/octet-stream")])
        case "test://watched-resource":
            let content = await state.watchedResourceContent
            return .init(contents: [.text(content, uri: params.uri)])
        default:
            // test://template/{id}/data
            let parts = params.uri.split(separator: "/", omittingEmptySubsequences: false)
            if params.uri.hasPrefix("test://template/"), parts.count == 5, parts[4] == "data", !parts[3].isEmpty {
                return .init(contents: [.text("Template resource with id: \(parts[3])", uri: params.uri)])
            }
            throw MCPError.resourceNotFound(uri: params.uri)
        }
    }

    await server.withMethodHandler(ResourceSubscribe.self) { params in
        await state.subscribe(to: params.uri)
        return Empty()
    }

    await server.withMethodHandler(ResourceUnsubscribe.self) { params in
        await state.unsubscribe(from: params.uri)
        return Empty()
    }

    // Prompts
    await server.withMethodHandler(ListPrompts.self) { _ in
        let dynamic = await state.dynamicPromptListed
        let listed: [Prompt] = [
            Prompt(name: "test_simple_prompt", description: "A simple prompt without arguments"),
            Prompt(name: "test_prompt_with_arguments", description: "A prompt that accepts arguments", arguments: [Prompt.Argument(name: "arg1", description: "First test argument", required: true), Prompt.Argument(name: "arg2", description: "Second test argument", required: true)]),
            Prompt(name: "test_prompt_with_embedded_resource", description: "A prompt that includes embedded resources", arguments: [Prompt.Argument(name: "resourceUri", description: "URI of the resource to embed", required: true)]),
            Prompt(name: "test_prompt_with_image", description: "A prompt with image content"),
        ]
        return .init(prompts: listed + [inputRequiredPrompt] + (dynamic ? [Prompt(name: "test_dynamic_prompt", description: "Listed after test_trigger_prompt_change")] : []))
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        switch params.name {
        case inputRequiredPrompt.name:
            return getInputRequiredPrompt(params)
        case "test_simple_prompt":
            return .init(description: "Simple prompt response", messages: [.user(.text(text: "This is a simple prompt for testing."))])
        case "test_prompt_with_arguments":
            let arg1 = params.arguments?["arg1"] ?? "default1"
            let arg2 = params.arguments?["arg2"] ?? "default2"
            return .init(description: "Prompt with arguments", messages: [.user(.text(text: "Prompt with arguments: arg1='\(arg1)', arg2='\(arg2)'"))])
        case "test_prompt_with_embedded_resource":
            let resourceUri = params.arguments?["resourceUri"] ?? "test://default"
            return .init(description: "Prompt with embedded resource", messages: [
                .user(.resource(resource: .text("Embedded resource content for testing.", uri: resourceUri, mimeType: "text/plain"))),
                .user(.text(text: "Please process the embedded resource above."))
            ])
        case "test_prompt_with_image":
            return .init(description: "Prompt with image", messages: [
                .user(.image(data: testImageBase64, mimeType: "image/png")),
                .user(.text(text: "Please analyze the image above."))
            ])
        default:
            throw MCPError.invalidParams("Unknown prompt: \(params.name)")
        }
    }

    await server.withMethodHandler(SetLoggingLevel.self) { _ in
        // Accept any logging level (debug, info, notice, warning, error, critical, alert, emergency)
        // For conformance testing, we just accept it without doing anything
        return Empty()
    }

    await server.withMethodHandler(Complete.self) { _ in
        return .init(completion: .init(values: []))
    }

    return server
}

// MARK: - HTTP Server

// HTTPApp handles all HTTP server functionality

// MARK: - Main

struct MCPHTTPServer {
    static func run() async throws {
        let args = CommandLine.arguments
        if args.contains("--stdio") {
            let transport = StdioTransport()
            let server = await createConformanceServer(state: ServerState(), transport: transport)
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            return
        }
        var port = 3001

        for (index, arg) in args.enumerated() {
            if arg == "--port" && index + 1 < args.count {
                if let p = Int(args[index + 1]) {
                    port = p
                }
            }
        }

        var loggerConfig = Logger(label: "mcp.http.server", factory: { StreamLogHandler.standardError(label: $0) })
        loggerConfig.logLevel = .trace
        let logger = loggerConfig

        let state = ServerState()

        logger.info("Starting MCP HTTP Server...", metadata: ["port": "\(port)"])

        // Create HTTPApp with server factory
        let app = HTTPApp(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                endpoint: "/mcp",
                retryInterval: 1000
            ),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]),
            statelessValidationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ]),
            serverFactory: { sessionID, transport in
                logger.debug("Creating server", metadata: ["sessionID": "\(sessionID ?? "stateless")"])
                return await createConformanceServer(state: state, transport: transport)
            },
            logger: logger
        )

        try await app.start()
    }
}

do {
    try await MCPHTTPServer.run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
