import Foundation
import MCP

// Snippets for docs/server.md: tools.

// snippet: tools-list
let weatherTool = Tool(
    name: "get_weather",
    title: "Weather",
    description: "Current weather for a city",
    inputSchema: [
        "type": "object",
        "properties": [
            "city": ["type": "string", "description": "City name"],
            "units": ["type": "string", "enum": ["metric", "imperial"]],
        ],
        "required": ["city"],
    ],
    annotations: .init(readOnlyHint: true, openWorldHint: true))

func registerToolList(on server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [weatherTool, forecastTool, queryTool])
    }
}
// endsnippet

// snippet: tools-call
func registerToolCall(on server: Server) async {
    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "get_weather":
            guard let city = params.arguments?["city"]?.stringValue else {
                // A tool failure: the model sees it and can retry.
                return CallTool.Result(
                    content: [.text(text: "Missing argument: city", annotations: nil, _meta: nil)],
                    isError: true)
            }
            let units = params.arguments?["units"]?.stringValue ?? "metric"
            return CallTool.Result(content: [
                .text(text: "18 degrees (\(units)), clear, in \(city)", annotations: nil, _meta: nil)
            ])
        case "get_forecast":
            return try forecastResult(for: params.arguments?["city"]?.stringValue ?? "Paris")
        default:
            // A protocol error: the client gets a JSON-RPC error, not a result.
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
        }
    }
}
// endsnippet

// snippet: tools-content
func chartResult(png: Data) -> CallTool.Result {
    CallTool.Result(content: [
        .text(text: "Temperature over 24 hours", annotations: nil, _meta: nil),
        .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        .resource(
            resource: .text("time,celsius\n00:00,12\n", uri: "weather://paris/today.csv", mimeType: "text/csv")),
        .resourceLink(
            uri: "weather://paris/week", name: "week", title: "Weekly forecast",
            mimeType: "application/json"),
    ])
}
// endsnippet

// snippet: tools-structured
struct Forecast: Codable, Sendable {
    let city: String
    let celsius: Double
    let conditions: String
}

let forecastTool = Tool(
    name: "get_forecast",
    description: "Forecast for a city as structured data",
    inputSchema: [
        "type": "object",
        "properties": ["city": ["type": "string"]],
        "required": ["city"],
    ],
    outputSchema: [
        "type": "object",
        "properties": [
            "city": ["type": "string"],
            "celsius": ["type": "number"],
            "conditions": ["type": "string"],
        ],
        "required": ["city", "celsius", "conditions"],
    ])

func forecastResult(for city: String) throws -> CallTool.Result {
    let forecast = Forecast(city: city, celsius: 18, conditions: "clear")
    // Also send the JSON as text, for clients that ignore structuredContent.
    let json = String(decoding: try JSONEncoder().encode(forecast), as: UTF8.self)
    return try CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        structuredContent: forecast)
}
// endsnippet

// snippet: tools-headers
let queryTool = Tool(
    name: "run_query",
    description: "Runs a read-only query in a region",
    inputSchema: [
        "type": "object",
        "properties": [
            // Mirrored into the Mcp-Param-Region header at 2026-07-28 over HTTP.
            "region": ["type": "string", "x-mcp-header": "Region"],
            "sql": ["type": "string"],
        ],
        "required": ["region", "sql"],
    ])

/// The `Mcp-Param-*` headers of each tool. Call it at startup: a tool with
/// an invalid annotation throws here instead of vanishing from stateless
/// `tools/list` results.
func headerFields(of tools: [Tool]) throws -> [String: [String]] {
    var fields: [String: [String]] = [:]
    for tool in tools {
        fields[tool.name] = try tool.headerParameters().map(\.fieldName)
    }
    return fields
}
// endsnippet
