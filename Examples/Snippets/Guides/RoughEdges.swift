import MCP

// Snippets for docs/rough_edges.md. See scripts/weave.swift.

// snippet: rough-call-tool-overloads
/// `callTool(name:arguments:meta:)` has two overloads that differ only in
/// their return type. Bind the result with a type to pick one.
func callBothWays(_ client: Client, tool: String) async throws -> (Bool?, CallTool.Result) {
    // The async overload: a tuple of content and isError.
    let (_, isError) = try await client.callTool(name: tool)
    // The other overload: a RequestContext, which also gives the request id.
    let request: RequestContext<CallTool.Result> = try await client.callTool(name: tool)
    return (isError, try await request.value)
}
// endsnippet

// snippet: rough-full-result
/// The list methods return tuples, which drop `_meta`, `ttlMs` and
/// `cacheScope`. `send(_:)` returns the whole result.
func listToolsWithCacheHints(_ client: Client) async throws -> ListTools.Result {
    try await client.send(ListTools.request(.init())).value
}
// endsnippet

// snippet: rough-text-content
/// `Tool.Content.text(text:)` without annotations resolves to a deprecated
/// helper. A small function keeps call sites short.
func textContent(_ string: String) -> Tool.Content {
    .text(text: string, annotations: nil, _meta: nil)
}
// endsnippet
