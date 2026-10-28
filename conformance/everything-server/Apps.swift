import Foundation
import MCP

// SEP-1865 fixtures: the view and the tools of the interop `apps` profile
// (interop/README.md). The TypeScript server (interop/ts-client/server.mjs)
// serves the same ones with the ext-apps server helpers.

private let viewURI = "ui://interop/weather.html"

let conformanceApps: [UIResource] = [
    try! UIResource(
        uri: viewURI, name: "weather-view", description: "The weather view",
        html: "<!DOCTYPE html><html><body>interop weather view</body></html>",
        meta: UIResourceMeta(csp: .init(connectDomains: ["https://api.example.com"]), prefersBorder: true))
]

let appTools: [Tool] = {
    var show = Tool(
        name: "show_weather", description: "Shows the weather in a view",
        inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])
    show.ui = ToolUIMeta(resourceUri: viewURI)
    var refresh = Tool(
        name: "refresh_weather", description: "Refreshes the weather view; for the view only",
        inputSchema: ["type": "object", "properties": [:]])
    refresh.ui = ToolUIMeta(resourceUri: viewURI, visibility: [.app])
    return [show, refresh]
}()

/// The result of an app tool; `nil` for another tool. The text says whether
/// the client declared that it renders HTML views.
func callAppTool(_ params: CallTool.Parameters) -> CallTool.Result? {
    switch params.name {
    case "show_weather":
        let city = params.arguments?["city"]?.stringValue ?? "Paris"
        let declared = Server.currentHandlerContext?.clientUISettings?.supports() == true
        return .init(content: [.text(text: "Weather in \(city): sunny (view \(declared ? "declared" : "not declared"))")])
    case "refresh_weather":
        return .init(content: [.text(text: "Refreshed")])
    default:
        return nil
    }
}
