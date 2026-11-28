import MCP

// Snippets for docs/server.md: cacheable results (SEP-2549).

// snippet: cache-configuration
func makeCachingServer() -> Server {
    Server(
        name: "catalog", version: "1.0.0",
        capabilities: .init(resources: .init(), tools: .init()),
        configuration: .init(
            cacheHints: [
                ListTools.name: CacheHint(ttlMs: 60_000, scope: .public),
                ServerDiscover.name: CacheHint(ttlMs: 300_000, scope: .public),
            ],
            defaultCacheHint: CacheHint(ttlMs: 5_000, scope: .private)))
}
// endsnippet

// snippet: cache-result
func registerCachedRead(on server: Server) async {
    await server.withMethodHandler(ReadResource.self) { params in
        // Hints on the result win over the configuration.
        ReadResource.Result(
            contents: [.text("v1", uri: params.uri)],
            ttlMs: 1_000,
            cacheScope: .private)
    }
}
// endsnippet
