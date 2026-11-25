import Foundation
import MCP

// Snippets for docs/testing.md. See scripts/weave.swift. The tests that
// use them are in Examples/Tests/GuidesSnippetTests.swift.

// snippet: testing-handler-function
/// A tool handler written as a function, so that tests can call it directly.
@Sendable func addNumbers(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard params.name == "add" else {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
    guard let a = params.arguments?["a"]?.intValue, let b = params.arguments?["b"]?.intValue else {
        return CallTool.Result(
            content: [.text(text: "a and b must be integers", annotations: nil, _meta: nil)],
            isError: true)
    }
    return CallTool.Result(
        content: [.text(text: "\(a + b)", annotations: nil, _meta: nil)],
        structuredContent: ["sum": .int(a + b)])
}

func makeCalculatorServer() async -> Server {
    let server = Server(name: "calculator", version: "1.0.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(CallTool.self, handler: addNumbers)
    return server
}
// endsnippet

// snippet: testing-pair
/// Starts `server` on one end of an in-memory pair and connects a client
/// to the other end.
func connectInMemory(
    to server: Server,
    mode: Client.ProtocolMode = .handshake,
    capabilities: Client.Capabilities = .init()
) async throws -> Client {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(
        name: "test-client", version: "1.0.0", capabilities: capabilities,
        configuration: .init(protocolMode: mode))
    try await client.connect(transport: clientTransport)
    return client
}
// endsnippet

// snippet: testing-http-request
/// A 2026-07-28 POST with the headers a client sends, for
/// `StatelessHTTPServerTransport.handleRequest(_:)`.
func statelessPOST(id: Int, method: String, params: [String: Value] = [:]) throws -> HTTPRequest {
    var params = params
    params["_meta"] = [
        MetaKey.protocolVersion: .string(Version.v2026_07_28),
        MetaKey.clientCapabilities: [:],
    ]
    let body: Value = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
    var headers = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": Version.v2026_07_28,
        MCPRequestHeaders.method: method,
    ]
    if let name = MCPRequestHeaders.nameValue(method: method, params: .object(params)) {
        headers[MCPRequestHeaders.name] = MCPRequestHeaders.encode(name)
    }
    return HTTPRequest(method: "POST", headers: headers, body: try JSONEncoder().encode(body), path: "/mcp")
}
// endsnippet
