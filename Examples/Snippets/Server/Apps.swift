import Foundation
import MCP

// Snippets for docs/server.md: MCP Apps (SEP-1865).

// snippet: apps-server
/// A weather tool whose results a view renders, and a tool that only the view
/// calls.
func makeWeatherAppServer() async throws -> Server {
    let server = Server(name: "weather", version: "1.0.0", capabilities: .init(tools: .init()))
    let dashboard = try UIResource(
        uri: "ui://weather/dashboard.html", name: "dashboard", title: "Weather dashboard",
        html: "<!DOCTYPE html><html><body><div id=\"weather\"></div></body></html>",
        meta: UIResourceMeta(csp: .init(connectDomains: ["https://api.weather.example"]), prefersBorder: true))
    await server.withAppResources([dashboard])

    var weather = Tool(
        name: "get_weather", description: "Current weather for a city",
        inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]])
    weather.ui = ToolUIMeta(resourceUri: dashboard.uri)
    var refresh = Tool(
        name: "refresh_dashboard", description: "Reloads the dashboard data", inputSchema: ["type": "object"])
    refresh.ui = ToolUIMeta(resourceUri: dashboard.uri, visibility: [.app])
    let tools = [weather, refresh]

    await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
    await server.withMethodHandler(CallTool.self) { params in
        let city = params.arguments?["city"]?.stringValue ?? "Cupertino"
        // The text is for hosts without views; the view reads the structure.
        return .init(
            content: [.text(text: "\(city): sunny, 21 °C")],
            structuredContent: ["city": .string(city), "condition": "sunny", "celsius": 21])
    }
    return server
}
// endsnippet
