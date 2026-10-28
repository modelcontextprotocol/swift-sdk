import Foundation
import MCP

// Snippets for docs/client.md: MCP Apps (SEP-1865).

// snippet: client-apps
/// A host that renders HTML views.
func makeAppHost() -> Client {
    var capabilities = Client.Capabilities()
    capabilities.ui = UIExtensionSettings()
    return Client(name: "host", version: "1.0.0", capabilities: capabilities)
}

/// The tools to give the model, and the view of each tool that has one.
func appTools(_ client: Client) async throws -> (model: [Tool], views: [String: AppResourceContents]) {
    let tools = try await client.listTools().tools
    let listing = try await client.listResources().resources
    var views: [String: AppResourceContents] = [:]
    for tool in tools {
        guard let uri = tool.ui?.resourceUri else { continue }
        // The content item's _meta.ui, or the listing entry's.
        views[tool.name] = try await client.readAppResource(uri: uri, listing: listing.first { $0.uri == uri })
    }
    // A tool that only the view calls is not for the model.
    return (tools.filter(\.isVisibleToModel), views)
}
// endsnippet
