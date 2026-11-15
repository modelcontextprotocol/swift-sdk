/**
 * MCP HTTP Server Wrapper
 *
 * HTTP server that wraps the MCP conformance server for testing with the
 * official conformance framework.
 *
 * Usage: mcp-http-server [--port PORT]
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
    var watchedResourceContent = "Watched resource content"
    var promptListHasChanged = false
    var toolListHasChanged = false

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

    func markPromptListChanged() {
        promptListHasChanged = true
    }

    func markToolListChanged() {
        toolListHasChanged = true
    }
}

private func inputRequest(_ method: String, params: [String: Value]) -> Value {
    .object(["method": .string(method), "params": .object(params)])
}

private func inputRequiredFixture(_ params: CallTool.Parameters) throws -> CallTool.Result? {
    let name = params.name
    guard name.hasPrefix("test_input_required_result_") else { return nil }
    if name == "test_input_required_result_tampered_state",
       params.inputResponses != nil,
       params.requestState != "signed-state" {
        throw MCPError.invalidParams("requestState integrity check failed")
    }
    if name == "test_input_required_result_elicitation",
       let responses = params.inputResponses,
       !(responses["user_name"].map { if case .object = $0 { true } else { false } } ?? false) {
        return CallTool.Result(
            resultType: .inputRequired,
            inputRequests: ["user_name": inputRequest("elicitation/create", params: [
                "message": .string("What is your name?"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")]),
                ]),
            ])]
        )
    }
    if params.inputResponses != nil {
        if name == "test_input_required_result_multi_round", params.requestState == "round-1" {
            return CallTool.Result(
                resultType: .inputRequired,
                inputRequests: ["step2": inputRequest("elicitation/create", params: [
                    "message": .string("Step 2: What is your favorite color?"),
                    "requestedSchema": .object(["type": .string("object"), "properties": .object(["color": .object(["type": .string("string")])]), "required": .array([.string("color")])]),
                ])],
                requestState: "round-2"
            )
        }
        return CallTool.Result(content: [.text(text: "Input received", annotations: nil, _meta: nil)])
    }

    let elicitation = inputRequest("elicitation/create", params: [
        "message": .string("What is your name?"),
        "requestedSchema": .object(["type": .string("object"), "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")])]),
    ])
    let sampling = inputRequest("sampling/createMessage", params: [
        "messages": .array([.object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string("What is the capital of France?")])])]),
        "maxTokens": .int(100),
    ])
    let roots = inputRequest("roots/list", params: [:])
    var requests: [String: Value]
    var state: String? = nil
    switch name {
    case "test_input_required_result_sampling": requests = ["capital_question": sampling]
    case "test_input_required_result_list_roots": requests = ["client_roots": roots]
    case "test_input_required_result_request_state": requests = ["confirm": elicitation]; state = "request-state-v1"
    case "test_input_required_result_multiple_inputs": requests = ["user_name": elicitation, "greeting": sampling, "client_roots": roots]; state = "multiple-inputs-v1"
    case "test_input_required_result_multi_round": requests = ["step1": elicitation]; state = "round-1"
    case "test_input_required_result_tampered_state": requests = ["confirm": elicitation]; state = "signed-state"
    case "test_input_required_result_capabilities":
        let caps = params._meta?[ProtocolMetaKey.clientCapabilities]
        requests = [:]
        if case .object(let values) = caps, values["sampling"] != nil { requests["capital_question"] = sampling }
    default: requests = ["user_name": elicitation]
    }
    return CallTool.Result(resultType: .inputRequired, inputRequests: requests, requestState: state)
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

    // Tools
    await server.withMethodHandler(ListTools.self) { _ in
        var tools = [
            Tool(name: "test_simple_text", description: "Tests simple text content response", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_custom_header", description: "Tests SEP-2243 custom parameter headers", inputSchema: .object(["type": "object", "properties": ["tenant": ["type": "string", "x-mcp-header": "Tenant"]], "required": ["tenant"]])),
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
            Tool(name: "test_missing_capability", description: "Diagnostic tool requiring sampling capability", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_elicitation", description: "Input-required elicitation fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_sampling", description: "Input-required sampling fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_list_roots", description: "Input-required roots fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_request_state", description: "Input-required state fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_multiple_inputs", description: "Multiple input-required fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_multi_round", description: "Multi-round input-required fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_tampered_state", description: "Tampered state fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_input_required_result_capabilities", description: "Capability-filtered input-required fixture", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_elicitation", description: "Tests user input elicitation", inputSchema: .object(["type": "object", "properties": ["message": ["type": "string", "description": "Text displayed to user"]], "required": ["message"]])),
            Tool(name: "test_elicitation_sep1034_defaults", description: "Tests elicitation with default values (SEP-1034)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_elicitation_sep1330_enums", description: "Tests elicitation with enum variants (SEP-1330)", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "test_client_elicitation_defaults", description: "Tests that client applies defaults for omitted elicitation fields", inputSchema: .object(["type": "object", "properties": [:]])),
            Tool(name: "json_schema_2020_12_tool", description: "Tool with JSON Schema 2020-12 features", inputSchema: .object([
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "type": .string("object"),
                "$defs": .object([
                    "address": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "street": .object(["type": .string("string")]),
                            "city": .object(["type": .string("string")])
                        ])
                    ])
                ]),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "address": .object(["$ref": .string("#/$defs/address")])
                ]),
                "additionalProperties": .bool(false)
            ])),
            Tool(name: "test_trigger_prompt_change", description: "Conformance hook that changes the prompt list", inputSchema: .object(["type": .string("object")])),
            Tool(name: "test_trigger_tool_change", description: "Conformance hook that changes the tool list", inputSchema: .object(["type": .string("object")])),
        ]
        if await state.toolListHasChanged {
            tools.append(Tool(name: "test_dynamic_tool", description: "Added by the conformance list-change hook", inputSchema: .object(["type": .string("object")])))
        }
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { [weak server, transport] params in
        if let fixture = try inputRequiredFixture(params) { return fixture }
        switch params.name {
        case "test_missing_capability":
            guard Server.currentHandlerContext?.clientCapabilities?.sampling != nil else {
                throw MCPError.missingRequiredClientCapability(["sampling": .object([:])])
            }
            return .init(content: [.text(text: "Sampling capability declared", annotations: nil, _meta: nil)], isError: false)
        case "test_simple_text":
            return .init(content: [.text(text: "This is a simple text response for testing.", annotations: nil, _meta: nil)], isError: false)
        case "test_custom_header":
            return .init(content: [.text(text: params.arguments?["tenant"]?.stringValue ?? "missing", annotations: nil, _meta: nil)], isError: false)
        case "test_image_content":
            return .init(content: [.image(data: testImageBase64, mimeType: "image/png", annotations: nil, _meta: nil)], isError: false)
        case "test_audio_content":
            return .init(content: [.audio(data: testAudioBase64, mimeType: "audio/wav", annotations: nil, _meta: nil)], isError: false)
        case "test_embedded_resource":
            return .init(content: [.resource(resource: .text("This is an embedded resource content.", uri: "test://embedded-resource", mimeType: "text/plain"))], isError: false)
        case "test_multiple_content_types":
            return .init(content: [
                .text(text: "Multiple content types test:", annotations: nil, _meta: nil),
                .image(data: testImageBase64, mimeType: "image/png", annotations: nil, _meta: nil),
                .resource(resource: .text("{\"test\":\"data\",\"value\":123}", uri: "test://mixed-content-resource", mimeType: "application/json"))], isError: false)
        case "test_error_handling":
            return .init(content: [.text(text: "An error occurred during tool execution", annotations: nil, _meta: nil)], isError: true)
        case "test_logging":
            return .init(content: [.text(text: "Logging test completed", annotations: nil, _meta: nil)], isError: false)
        case "test_progress":
            let duration = params.arguments?["duration_ms"]?.intValue ?? 1000
            if let token = params._meta?.progressToken {
                try await server?.notify(ProgressNotification.message(.init(progressToken: token, progress: 0, total: 100)))
                try await Task.sleep(for: .milliseconds(max(1, duration / 2)))
                try await server?.notify(ProgressNotification.message(.init(progressToken: token, progress: 50, total: 100)))
            } else {
                try? await Task.sleep(for: .milliseconds(duration))
            }
            return .init(content: [.text(text: "Progress test completed", annotations: nil, _meta: nil)], isError: false)
        case "add_numbers":
            guard let a = params.arguments?["a"]?.intValue, let b = params.arguments?["b"]?.intValue else {
                return .init(content: [.text(text: "Invalid arguments: expected numbers a and b", annotations: nil, _meta: nil)], isError: true)
            }
            return .init(content: [.text(text: "\(a + b)", annotations: nil, _meta: nil)], isError: false)
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

            return .init(content: [.text(text: "This is a simple text response for testing.", annotations: nil, _meta: nil)], isError: false)
        case "json_schema_2020_12_tool":
            return .init(content: [.text(text: "This is a simple text response for testing.", annotations: nil, _meta: nil)], isError: false)
        case "test_tool_with_logging":
            // Send first log message
            let log1 = LogMessageNotification.message(
                .init(level: .info, data: .string("Tool execution started"))
            )
            try await server?.notify(log1)

            // Wait 50ms
            try await Task.sleep(for: .milliseconds(50))

            // Send second log message
            let log2 = LogMessageNotification.message(
                .init(level: .info, data: .string("Tool processing data"))
            )
            try await server?.notify(log2)

            // Wait another 50ms
            try await Task.sleep(for: .milliseconds(50))

            // Send third log message
            let log3 = LogMessageNotification.message(
                .init(level: .info, data: .string("Tool execution completed"))
            )
            try await server?.notify(log3)

            return .init(content: [.text(text: "Logging test completed", annotations: nil, _meta: nil)], isError: false)
        case "test_trigger_tool_change":
            await state.markToolListChanged()
            try await server?.notify(ToolListChangedNotification.message())
            return .init(content: [.text(text: "Tool list changed", annotations: nil, _meta: nil)], isError: false)
        case "test_trigger_prompt_change":
            await state.markPromptListChanged()
            try await server?.notify(PromptListChangedNotification.message())
            return .init(content: [.text(text: "Prompt list changed", annotations: nil, _meta: nil)], isError: false)
        case "test_reconnection":
            // SEP-1699: Close the SSE stream mid-call to trigger client reconnection.
            // The client should reconnect via GET with Last-Event-ID and receive the
            // response on the new stream.
            if let requestID = Server.currentHandlerContext?.id {
                await (transport as? StatefulHTTPServerTransport)?.closeSSEStream(forRequestID: requestID)
            }
            // Wait briefly for the client to reconnect before sending the response.
            try await Task.sleep(for: .milliseconds(100))
            return .init(content: [.text(text: "Reconnection test completed successfully. If you received this, the client properly reconnected after stream closure.", annotations: nil, _meta: nil)], isError: false)
        case "test_sampling":
            // Test LLM sampling - request sampling/createMessage from client
            guard let prompt = params.arguments?["prompt"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: prompt", annotations: nil, _meta: nil)], isError: true)
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

            return .init(content: [.text(text: responseText, annotations: nil, _meta: nil)], isError: false)
        case "test_elicitation":
            // Test elicitation - request user input for username and email
            guard let message = params.arguments?["message"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: message", annotations: nil, _meta: nil)], isError: true)
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
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])", annotations: nil, _meta: nil)],
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
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])", annotations: nil, _meta: nil)],
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
                content: [.text(text: "Elicitation completed: action=\(elicitationResult?.action.rawValue ?? "unknown"), content=\(elicitationResult?.content ?? [:])", annotations: nil, _meta: nil)],
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
                return .init(content: [.text(text: "Client did not provide all required fields with defaults", annotations: nil, _meta: nil)], isError: true)
            }

            guard name == "John Doe", age == 30, score == 95.5, status == "active", verified == true else {
                return .init(content: [.text(text: "Client defaults do not match expected values", annotations: nil, _meta: nil)], isError: true)
            }

            return .init(
                content: [.text(text: "Client correctly applied all default values", annotations: nil, _meta: nil)],
                isError: false
            )
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // Resources
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        .init(templates: [Resource.Template(
            uriTemplate: "test://template/{id}",
            name: "Template Resource",
            description: "A resource template with URI parameters",
            mimeType: "text/plain"
        )])
    }
    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: [
            Resource(name: "Static Text Resource", uri: "test://static-text", description: "A simple static text resource", mimeType: "text/plain"),
            Resource(name: "Static Binary Resource", uri: "test://static-binary", description: "A simple static binary resource", mimeType: "application/octet-stream"),
            Resource(name: "Watched Resource", uri: "test://watched", description: "A resource that can be subscribed to for updates", mimeType: "text/plain"),
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
        case "test://watched":
            let content = await state.watchedResourceContent
            return .init(contents: [.text(content, uri: params.uri)])
        default:
            if params.uri.hasPrefix("test://template/") {
                let id = String(params.uri.dropFirst("test://template/".count))
                return .init(contents: [.text("Template resource with id: \(id)", uri: params.uri)])
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
        var prompts = [
            Prompt(name: "test_input_required_result_prompt", description: "Prompt requiring context"),
            Prompt(name: "test_simple_prompt", description: "A simple prompt without arguments"),
            Prompt(name: "test_prompt_with_arguments", description: "A prompt that accepts arguments", arguments: [Prompt.Argument(name: "arg1", description: "First test argument", required: true), Prompt.Argument(name: "arg2", description: "Second test argument", required: true)]),
            Prompt(name: "test_prompt_with_embedded_resource", description: "A prompt that includes embedded resources", arguments: [Prompt.Argument(name: "resourceUri", description: "URI of the resource to embed", required: true)]),
            Prompt(name: "test_prompt_with_image", description: "A prompt with image content"),
        ]
        if await state.promptListHasChanged {
            prompts.append(Prompt(name: "test_dynamic_prompt", description: "Added by the conformance list-change hook"))
        }
        return .init(prompts: prompts)
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        if params.name == "test_input_required_result_prompt" {
            if params.inputResponses == nil {
                return .init(
                    messages: [],
                    resultType: .inputRequired,
                    inputRequests: ["user_context": inputRequest("elicitation/create", params: [
                        "message": .string("What context should the prompt use?"),
                        "requestedSchema": .object(["type": .string("object"), "properties": .object(["context": .object(["type": .string("string")])]), "required": .array([.string("context")])]),
                    ])]
                )
            }
            return GetPrompt.Result(description: "Prompt with supplied context", messages: [Prompt.Message.user(.text(text: "Context received"))])
        }
        switch params.name {
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
            throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
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
                MCPRoutingHeaderValidator(),
                SessionValidator(),
            ]),
            serverFactory: { sessionID, transport in
                logger.debug("Creating server for session", metadata: ["sessionID": "\(sessionID)"])
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
    print(error)
    exit(1)
}
