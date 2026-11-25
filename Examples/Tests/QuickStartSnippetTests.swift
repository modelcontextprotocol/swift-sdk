import Foundation
import Testing

@testable import MCP
@testable import QuickStartSnippets

// Runs the snippets of docs/quick_start.md.
@Suite("Quick start snippets")
struct QuickStartSnippetTests {
    @Test("The in-process client greets")
    func inProcess() async throws {
        #expect(try await greetInProcess() == "Hello, Swift!")
    }

    @Test("The HTTP server answers a 2026-07-28 tools/call")
    func httpServer() async throws {
        let transport = try await startHTTPGreetServer()
        let body = #"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"greet","arguments":{"name":"HTTP"},
            "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
            """#
        let request = HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": "2026-07-28",
                "Mcp-Method": "tools/call",
                "Mcp-Name": "greet",
            ],
            body: Data(body.utf8))
        let response = await respond(to: request, using: transport)
        #expect(response.statusCode == 200)
        let reply = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        #expect(reply.objectValue?["id"] == 7)
        let content = reply.objectValue?["result"]?.objectValue?["content"]?.arrayValue
        #expect(content?.first?.objectValue?["text"] == "Hello, HTTP!")
        await transport.disconnect()
    }

    @Test("The HTTP client fails cleanly without a server")
    func httpClient() async throws {
        // Port 9 (discard) has no MCP server: connect throws instead of hanging.
        await #expect(throws: (any Error).self) {
            _ = try await connectOverHTTP(to: URL(string: "http://127.0.0.1:9/mcp")!)
        }
    }
}
