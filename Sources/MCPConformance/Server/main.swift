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

func createConformanceServer(state: ServerState) async -> Server {
    let server = Server(
        name: "mcp-conformance-test-server",
        version: "1.0.0",
        capabilities: Server.Capabilities(
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: true)
        )
    )

    // Tools
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
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
            Tool(name: "test_reconnection", description: "Tests SSE reconnection and resumption with Last-Event-ID", inputSchema: .object(["type": "object", "properties": [:]]))
        ])
    }

    await server.withMethodHandler(CallTool.self) { [weak server] params in
        switch params.name {
        case "test_simple_text":
            return .init(content: [.text("This is a simple text response for testing.")], isError: false)
        case "test_image_content":
            return .init(content: [.image(data: testImageBase64, mimeType: "image/png", metadata: nil)], isError: false)
        case "test_audio_content":
            return .init(content: [.audio(data: testAudioBase64, mimeType: "audio/wav")], isError: false)
        case "test_embedded_resource":
            return .init(content: [.resource(resource: .text("This is an embedded resource content.", uri: "test://embedded-resource", mimeType: "text/plain"))], isError: false)
        case "test_multiple_content_types":
            return .init(content: [
                .text("Multiple content types test:"),
                .image(data: testImageBase64, mimeType: "image/png", metadata: nil),
                .resource(resource: .text("{\"test\":\"data\",\"value\":123}", uri: "test://mixed-content-resource", mimeType: "application/json"))], isError: false)
        case "test_error_handling":
            return .init(content: [.text("An error occurred during tool execution")], isError: true)
        case "test_logging":
            return .init(content: [.text("Logging test completed")], isError: false)
        case "test_progress":
            let duration = params.arguments?["duration_ms"]?.intValue ?? 1000
            try? await Task.sleep(for: .milliseconds(duration))
            return .init(content: [.text("Progress test completed")], isError: false)
        case "add_numbers":
            guard let a = params.arguments?["a"]?.intValue, let b = params.arguments?["b"]?.intValue else {
                return .init(content: [.text("Invalid arguments: expected numbers a and b")], isError: true)
            }
            return .init(content: [.text("\(a + b)")], isError: false)
        case "test_tool_with_progress":
            if let token = params._meta?.progressToken {
                let notification1 = ProgressNotification.message(
                    .init(progressToken: token, progress: 0, total: 100)
                )
                try await server?.notify(notification1)
                try await Task.sleep(for: .microseconds(50))

                let notification2 = ProgressNotification.message(
                    .init(progressToken: token, progress: 50, total: 100)
                )
                try await server?.notify(notification2)
                try await Task.sleep(for: .microseconds(50))

                let notification3 = ProgressNotification.message(
                    .init(progressToken: token, progress: 100, total: 100)
                )
                try await server?.notify(notification3)
            }

            return .init(content: [.text("This is a simple text response for testing.")], isError: false)
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

            return .init(content: [.text("Logging test completed")], isError: false)
        case "test_reconnection":
            // This tool tests SSE reconnection behavior (SEP-1699)
            // In a full implementation, the server would close the SSE stream mid-call
            // and the client would need to reconnect with Last-Event-ID to get the result.
            // For now, we return a simple success response.
            return .init(content: [.text("Reconnection test completed successfully")], isError: false)
        default:
            return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    }

    // Resources
    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: [
            Resource(name: "Static Text Resource", uri: "test://static-text", description: "A simple static text resource", mimeType: "text/plain"),
            Resource(name: "Static Binary Resource", uri: "test://static-binary", description: "A simple static binary resource", mimeType: "application/octet-stream"),
            Resource(name: "Watched Resource", uri: "test://watched", description: "A resource that can be subscribed to for updates", mimeType: "text/plain"),
            Resource(name: "Template Resource", uri: "test://template/{id}", description: "A resource template with URI parameters", mimeType: "text/plain"),
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
            return .init(contents: [.text("Resource not found: \(params.uri)", uri: params.uri)])
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
        .init(prompts: [
            Prompt(name: "test_simple_prompt", description: "A simple prompt without arguments"),
            Prompt(name: "test_prompt_with_arguments", description: "A prompt that accepts arguments", arguments: [Prompt.Argument(name: "arg1", description: "First test argument", required: true), Prompt.Argument(name: "arg2", description: "Second test argument", required: true)]),
            Prompt(name: "test_prompt_with_embedded_resource", description: "A prompt that includes embedded resources", arguments: [Prompt.Argument(name: "resourceUri", description: "URI of the resource to embed", required: true)]),
            Prompt(name: "test_prompt_with_image", description: "A prompt with image content"),
        ])
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        switch params.name {
        case "test_simple_prompt":
            return .init(description: "Simple prompt response", messages: [.user(.text(text: "This is a simple prompt for testing."))])
        case "test_prompt_with_arguments":
            let arg1 = params.arguments?["arg1"]?.stringValue ?? "default1"
            let arg2 = params.arguments?["arg2"]?.stringValue ?? "default2"
            return .init(description: "Prompt with arguments", messages: [.user(.text(text: "Prompt with arguments: arg1='\(arg1)', arg2='\(arg2)'"))])
        case "test_prompt_with_embedded_resource":
            let resourceUri = params.arguments?["resourceUri"]?.stringValue ?? "test://default"
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
                endpoint: "/mcp"
            ),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]),
            serverFactory: { sessionID in
                logger.debug("Creating server for session", metadata: ["sessionID": "\(sessionID)"])
                return await createConformanceServer(state: state)
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
