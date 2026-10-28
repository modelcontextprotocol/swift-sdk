import Foundation
import MCP

// Snippets for docs/server.md: Server Cards (SEP-2127).

// snippet: server-card
/// The card of a server whose endpoint is https://mcp.example.com/mcp. The
/// name is in reverse-DNS format, and the server uses the same name.
func makeServerCard() throws -> ServerCardValidator {
    let card = ServerCard(
        info: Server.Info(name: "com.example/weather", version: "1.2.0", title: "Weather"),
        endpoint: URL(string: "https://mcp.example.com/mcp")!,
        protocolVersions: Server.Configuration.default.protocolVersions,
        description: "Current weather for a city.")
    return try ServerCardValidator(card: card, endpointPath: "/mcp")
}

/// Answers card requests before the MCP endpoint.
func route(_ request: HTTPRequest, card: ServerCardValidator, mcp: StatelessHTTPServerTransport) async
    -> HTTPResponse
{
    if let response = card.response(to: request) { return response }
    return await mcp.handleRequest(request)
}
// endsnippet
