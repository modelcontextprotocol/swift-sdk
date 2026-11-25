import MCP

// Snippets for docs/protocol.md, section "Notification streams".

/// Opens a listen stream, triggers one tool list change, and waits for it.
/// Returns the filter the server honored.
func listenForToolChanges() async throws -> SubscriptionFilter {
    // snippet: listen-server
    let server = Server(
        name: "example", version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: true)))
    // endsnippet
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
    let client = Client(name: "example-client", version: "1.0.0")
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)

    let (changes, change) = AsyncStream<Void>.makeStream()
    // snippet: listen-client
    await client.onNotification(ToolListChangedNotification.self) { _ in
        change.yield()  // refetch with listTools()
    }
    let subscription = try await client.listen(
        .init(toolsListChanged: true, promptsListChanged: true))
    // The server does not declare prompts.listChanged, so only tools is honored.
    print(subscription.notifications)
    // endsnippet

    // snippet: listen-notify
    try await server.notify(ToolListChangedNotification.message())
    // endsnippet

    for await _ in changes { break }
    // snippet: listen-cancel
    await subscription.cancel()
    // endsnippet
    await client.disconnect()
    await server.stop()
    return subscription.notifications
}

/// Lets callers listen only to `public://` resources. Returns the URIs a
/// stream for `public://a` and `private://b` serves.
func listenToPublicResources() async throws -> [String] {
    let server = Server(
        name: "example", version: "1.0.0",
        capabilities: .init(resources: .init(subscribe: true)))
    // snippet: listen-authorizer
    await server.withSubscriptionAuthorizer { filter, context in
        var allowed = filter
        allowed.resourceSubscriptions = filter.resourceSubscriptions?.filter { $0.hasPrefix("public://") }
        return allowed
    }
    // endsnippet
    let client = Client(
        name: "example-client", version: "1.0.0",
        configuration: .init(protocolMode: .automatic))
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)
    let subscription = try await client.listen(.init(resourceSubscriptions: ["public://a", "private://b"]))
    await subscription.cancel()
    await client.disconnect()
    await server.stop()
    return subscription.notifications.resourceSubscriptions ?? []
}
