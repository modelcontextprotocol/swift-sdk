import MCP
import Foundation

// Async helper function to set up and start the server
// Returns the Server instance
// (Keep detailed logs)
func setupAndStartServer() async throws -> Server { 
    fputs("log: setupAndStartServer: entering function.\n", stderr)

    // Define a JSON schema for the tool's input
    let echoInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("The text to echo back")
            ])
        ]),
        "required": .array([.string("message")])
    ])
    fputs("log: setupAndStartServer: defined input schema for echo tool.\n", stderr)

    // Define the echo tool using the schema
    let echoTool = Tool(
        name: "swift_echo",
        description: "A simple tool that echoes back its input arguments.",
        inputSchema: echoInputSchema
    )
    fputs("log: setupAndStartServer: defined echo tool: \(echoTool.name) with detailed inputSchema.\n", stderr)

    let server = Server(
        name: "SwiftEchoServer",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )
    fputs("log: setupAndStartServer: server instance created (\(server.name)) with capabilities: tools(listChanged: false).\n", stderr)

    // Register handlers
    await server.withMethodHandler(ReadResource.self) { params in
        let uri = params.uri
        fputs("log: handler(ReadResource): received request for uri: \(uri)\n", stderr)
        let content = [Resource.Content.text("dummy content for \(uri)", uri: uri)]
        return .init(contents: content)
    }
    fputs("log: setupAndStartServer: registered ReadResource handler.\n", stderr)

    await server.withMethodHandler(ListResources.self) { _ in
        fputs("log: handler(ListResources): received request (dummy handler - unlikely to be called).\n", stderr)
        return ListResources.Result(resources: [])
    }
    fputs("log: setupAndStartServer: registered ListResources handler (dummy).\n", stderr)

    await server.withMethodHandler(ListPrompts.self) { _ in
        fputs("log: handler(ListPrompts): received request (dummy handler - unlikely to be called).\n", stderr)
        return ListPrompts.Result(prompts: [])
    }
    fputs("log: setupAndStartServer: registered ListPrompts handler (dummy).\n", stderr)

    await server.withMethodHandler(ListTools.self) { _ in
        fputs("log: handler(ListTools): received request.\n", stderr)
        let result = ListTools.Result(tools: [echoTool])
        fputs("log: handler(ListTools): responding with: \(result.tools.map { $0.name }) (detailed schema)\n", stderr)
        return result
    }
    fputs("log: setupAndStartServer: registered ListTools handler.\n", stderr)

    await server.withMethodHandler(CallTool.self) { params in
        fputs("log: handler(CallTool): received request for tool: \(params.name).\n", stderr)
        if params.name == echoTool.name {
            let messageToEcho: String
            if let args = params.arguments, let messageValue = args["message"], let msgStr = messageValue.stringValue {
                messageToEcho = msgStr
            } else {
                fputs("log: handler(CallTool): warning: 'message' argument not found or not a string in args: \(params.arguments?.description ?? "nil")\n", stderr)
                messageToEcho = params.arguments?.description ?? "no arguments provided"
            }

            let content = [Tool.Content.text(messageToEcho)]
            fputs("log: handler(CallTool): executing echo tool with message: \(messageToEcho)\n", stderr)
            fputs("log: handler(CallTool): responding with echoed content.\n", stderr)
            return .init(content: content, isError: false)
        } else {
            fputs("log: handler(CallTool): error: tool not found: \(params.name)\n", stderr)
            throw MCPError.methodNotFound(params.name)
        }
    }
    fputs("log: setupAndStartServer: registered CallTool handler.\n", stderr)

    let transport = StdioTransport()
    fputs("log: setupAndStartServer: created StdioTransport.\n", stderr)

    // Start the server (assuming it runs in background and returns)
    fputs("log: setupAndStartServer: calling server.start()...\n", stderr) 
    try await server.start(transport: transport)
    fputs("log: setupAndStartServer: server.start() completed (background task launched).\n", stderr)

    // Return the server instance
    fputs("log: setupAndStartServer: returning server instance.\n", stderr)
    return server
}

@main
struct MCPServer {
    // Main entry point - Async
    static func main() async {
        fputs("log: main: starting (async).\n", stderr)

        let server: Server
        do {
            fputs("log: main: calling setupAndStartServer()...\n", stderr)
            server = try await setupAndStartServer() 
            fputs("log: main: setupAndStartServer() successful, server instance obtained.\n", stderr) 

            // Explicitly wait for the server's internal task to complete.
            // This will block the main async task until the server stops listening.
            fputs("log: main: server started, calling server.waitUntilCompleted()...\n", stderr)
            await server.waitUntilCompleted() 
            fputs("log: main: server.waitUntilCompleted() returned. Server has stopped.\n", stderr)

        } catch {
            fputs("error: main: server setup/run failed: \(error)\n", stderr) 
            exit(1)
        }

        // Server has stopped either gracefully or due to error handled by waitUntilCompleted.
        fputs("log: main: Server processing finished. Exiting.\n", stderr)
        // No need to call server.stop() here as waitUntilCompleted only returns when the server *is* stopped.
    }
}
