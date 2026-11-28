// HelloServer: an MCP server with one tool, `greet`, served over stdio.
//
// The server reads JSON-RPC messages from standard input and writes them to
// standard output, one per line. It exits when standard input closes.
// Run it through the HelloClient example, which starts it as a subprocess:
//
//   swift build --product HelloServer
//   swift build --product HelloClient
//   $(swift build --show-bin-path)/HelloClient $(swift build --show-bin-path)/HelloServer

// snippet: hello-server
import MCP

let server = Server(
    name: "hello-server",
    version: "1.0.0",
    capabilities: .init(tools: .init()))

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [
        Tool(
            name: "greet",
            description: "Greets someone by name",
            inputSchema: [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "Who to greet"]],
                "required": ["name"],
            ])
    ])
}

await server.withMethodHandler(CallTool.self) { params in
    guard params.name == "greet" else {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
    let name = params.arguments?["name"]?.stringValue ?? "world"
    return CallTool.Result(content: [.text(text: "Hello, \(name)!")])
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
// endsnippet
