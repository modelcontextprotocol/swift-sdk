import Foundation
import MCP

// Snippets for docs/server.md: resources.

// snippet: resources-register
func registerResources(on server: Server) async {
    await server.withMethodHandler(ListResources.self) { _ in
        ListResources.Result(resources: [
            Resource(name: "readme", uri: "file:///project/README.md", title: "README", mimeType: "text/markdown"),
            Resource(name: "logo", uri: "file:///project/logo.png", mimeType: "image/png", size: 4),
        ])
    }
    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        ListResourceTemplates.Result(templates: [
            Resource.Template(uriTemplate: "file:///project/{path}", name: "project-file", mimeType: "text/plain")
        ])
    }
    await server.withMethodHandler(ReadResource.self) { params in
        switch params.uri {
        case "file:///project/README.md":
            return ReadResource.Result(contents: [
                .text("# Project\n", uri: params.uri, mimeType: "text/markdown")
            ])
        case "file:///project/logo.png":
            // Binary contents travel base64-encoded in `blob`.
            return ReadResource.Result(contents: [
                .binary(Data([0x89, 0x50, 0x4E, 0x47]), uri: params.uri, mimeType: "image/png")
            ])
        case let uri where uri.hasPrefix("file:///project/"):
            // URIs that match the template: the handler does the matching.
            let path = uri.dropFirst("file:///project/".count)
            return ReadResource.Result(contents: [.text("Contents of \(path)", uri: uri)])
        default:
            // -32602 with data.uri (SEP-2164).
            throw MCPError.resourceNotFound(uri: params.uri)
        }
    }
}
// endsnippet

// snippet: resources-subscribe
/// The resources a handshake client asked to watch.
actor WatchedResources {
    private(set) var uris: Set<String> = []
    func add(_ uri: String) { uris.insert(uri) }
    func remove(_ uri: String) { uris.remove(uri) }
}

func registerSubscriptions(on server: Server, watched: WatchedResources) async {
    // 2025-11-25 and earlier. At 2026-07-28 these methods answer -32601 and
    // clients use subscriptions/listen, which the SDK serves.
    await server.withMethodHandler(ResourceSubscribe.self) { params in
        await watched.add(params.uri)
        return Empty()
    }
    await server.withMethodHandler(ResourceUnsubscribe.self) { params in
        await watched.remove(params.uri)
        return Empty()
    }
}
// endsnippet

// snippet: resources-updated
/// Announces a change to every client that may care, in both eras.
func resourceDidChange(_ uri: String, on server: Server) async throws {
    try await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
}
// endsnippet
