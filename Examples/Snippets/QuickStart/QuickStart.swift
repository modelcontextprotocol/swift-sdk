import Foundation
import MCP

// Snippets for docs/quick_start.md. See scripts/weave.swift.

/// The HelloServer example's server, without a transport.
func makeGreetServer() async -> Server {
    let server = Server(name: "hello-server", version: "1.0.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [
            Tool(
                name: "greet", description: "Greets someone by name",
                inputSchema: ["type": "object", "properties": ["name": ["type": "string"]]])
        ])
    }
    await server.withMethodHandler(CallTool.self) { params in
        let name = params.arguments?["name"]?.stringValue ?? "world"
        return CallTool.Result(content: [.text(text: "Hello, \(name)!")])
    }
    return server
}

// snippet: in-process
/// Connects a client to a server in the same process and calls `greet`.
func greetInProcess() async throws -> String {
    let server = await makeGreetServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)

    let client = Client(name: "hello-client", version: "1.0.0")
    try await client.connect(transport: clientTransport)
    let content = try await client.callTool(name: "greet", arguments: ["name": "Swift"]).content

    await client.disconnect()
    await server.stop()
    guard case .text(let text, _, _)? = content.first else { return "" }
    return text
}
// endsnippet

// snippet: http-server
/// Starts the greet server behind a stateless HTTP transport.
func startHTTPGreetServer() async throws -> StatelessHTTPServerTransport {
    let server = await makeGreetServer()
    let transport = StatelessHTTPServerTransport()
    try await server.start(transport: transport)
    return transport
}

/// Your HTTP framework calls this for each request to the MCP endpoint.
func respond(to request: HTTPRequest, using transport: StatelessHTTPServerTransport) async
    -> HTTPResponse
{
    let response = await transport.handleRequest(request)
    // Write response.statusCode and response.headers, then either
    // response.bodyData or, for `.stream`, each chunk of the stream.
    return response
}
// endsnippet

// snippet: http-client
/// Connects to an MCP server over Streamable HTTP.
func connectOverHTTP(to endpoint: URL) async throws -> Client {
    let transport = HTTPClientTransport(endpoint: endpoint)
    let client = Client(name: "hello-client", version: "1.0.0")
    try await client.connect(transport: transport)
    return client
}
// endsnippet
