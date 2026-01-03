import Foundation
import Logging
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@testable import MCP

@Suite("Resource Subscription Tests")
struct ResourceSubscriptionTests {

    // MARK: - End-to-End Subscribe Tests

    @Test("Client can subscribe to a resource when server supports subscriptions")
    @available(macOS 14.0, *)
    func subscribeToResourceWorks() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.subscribe")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let subscriptionTracker = SubscriptionTracker()

        let server = Server(
            name: "SubscriptionServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: true))
        )

        // Handle resource subscription requests
        await server.withRequestHandler(ResourceSubscribe.self) { request, _ in
            await subscriptionTracker.recordSubscribe(uri: request.uri)
            return Empty()
        }

        // Handle list resources (required for resources capability)
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "test", uri: "file:///test.txt")
            ])
        }

        let client = Client(name: "SubscriptionClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Subscribe to a resource
        try await client.subscribeToResource(uri: "file:///test.txt")

        // Verify subscription was received by server
        let subscriptions = await subscriptionTracker.subscribedURIs
        #expect(subscriptions.count == 1)
        #expect(subscriptions.first == "file:///test.txt")
    }

    @Test("Client can unsubscribe from a resource when server supports subscriptions")
    @available(macOS 14.0, *)
    func unsubscribeFromResourceWorks() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.unsubscribe")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let subscriptionTracker = SubscriptionTracker()

        let server = Server(
            name: "UnsubscriptionServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: true))
        )

        // Handle resource unsubscription requests
        await server.withRequestHandler(ResourceUnsubscribe.self) { request, _ in
            await subscriptionTracker.recordUnsubscribe(uri: request.uri)
            return Empty()
        }

        // Handle list resources (required for resources capability)
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "test", uri: "file:///test.txt")
            ])
        }

        let client = Client(name: "UnsubscriptionClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Unsubscribe from a resource
        try await client.unsubscribeFromResource(uri: "file:///test.txt")

        // Verify unsubscription was received by server
        let unsubscriptions = await subscriptionTracker.unsubscribedURIs
        #expect(unsubscriptions.count == 1)
        #expect(unsubscriptions.first == "file:///test.txt")
    }

    @Test("Subscribe and unsubscribe cycle works correctly")
    @available(macOS 14.0, *)
    func subscribeUnsubscribeCycleWorks() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.subscription.cycle")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let subscriptionTracker = SubscriptionTracker()

        let server = Server(
            name: "SubscriptionCycleServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: true))
        )

        await server.withRequestHandler(ResourceSubscribe.self) { request, _ in
            await subscriptionTracker.recordSubscribe(uri: request.uri)
            return Empty()
        }

        await server.withRequestHandler(ResourceUnsubscribe.self) { request, _ in
            await subscriptionTracker.recordUnsubscribe(uri: request.uri)
            return Empty()
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "doc1", uri: "file:///doc1.txt"),
                Resource(name: "doc2", uri: "file:///doc2.txt"),
            ])
        }

        let client = Client(name: "CycleClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Subscribe to multiple resources
        try await client.subscribeToResource(uri: "file:///doc1.txt")
        try await client.subscribeToResource(uri: "file:///doc2.txt")

        // Unsubscribe from one
        try await client.unsubscribeFromResource(uri: "file:///doc1.txt")

        // Verify state
        let subscriptions = await subscriptionTracker.subscribedURIs
        let unsubscriptions = await subscriptionTracker.unsubscribedURIs

        #expect(subscriptions.count == 2)
        #expect(subscriptions.contains("file:///doc1.txt"))
        #expect(subscriptions.contains("file:///doc2.txt"))
        #expect(unsubscriptions.count == 1)
        #expect(unsubscriptions.first == "file:///doc1.txt")
    }

    // MARK: - Capability Validation Tests

    @Test("Subscribe throws when server does not support subscriptions")
    @available(macOS 14.0, *)
    func subscribeThrowsWithoutCapability() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.subscribe.nocap")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        // Server with resources capability but WITHOUT subscribe
        let server = Server(
            name: "NoSubscribeServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: false))
        )

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "test", uri: "file:///test.txt")
            ])
        }

        // Client configured as strict (default) to enforce capability checks
        let client = Client(
            name: "StrictClient",
            version: "1.0",
            configuration: .init(strict: true)
        )

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Attempt to subscribe should throw
        await #expect(throws: MCPError.self) {
            try await client.subscribeToResource(uri: "file:///test.txt")
        }
    }

    @Test("Unsubscribe throws when server does not support subscriptions")
    @available(macOS 14.0, *)
    func unsubscribeThrowsWithoutCapability() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.unsubscribe.nocap")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        // Server with resources capability but WITHOUT subscribe
        let server = Server(
            name: "NoUnsubscribeServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: false))
        )

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "test", uri: "file:///test.txt")
            ])
        }

        // Client configured as strict to enforce capability checks
        let client = Client(
            name: "StrictClient",
            version: "1.0",
            configuration: .init(strict: true)
        )

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Attempt to unsubscribe should throw
        await #expect(throws: MCPError.self) {
            try await client.unsubscribeFromResource(uri: "file:///test.txt")
        }
    }

    @Test("Subscribe throws when server has no resources capability at all")
    @available(macOS 14.0, *)
    func subscribeThrowsWithNoResourcesCapability() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.subscribe.nores")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        // Server with NO resources capability
        let server = Server(
            name: "NoResourcesServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())  // Only tools, no resources
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        // Client configured as strict to enforce capability checks
        let client = Client(
            name: "StrictClient",
            version: "1.0",
            configuration: .init(strict: true)
        )

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Attempt to subscribe should throw because resources capability is nil
        await #expect(throws: MCPError.self) {
            try await client.subscribeToResource(uri: "file:///test.txt")
        }
    }

    // MARK: - Notification Flow Tests

    @Test("Server can send resource updated notification after subscription")
    @available(macOS 14.0, *)
    func resourceUpdatedNotificationAfterSubscribe() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "mcp.test.subscribe.notify")
        logger.logLevel = .warning

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger
        )

        let notificationTracker = NotificationTracker()

        let server = Server(
            name: "NotifyingServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(subscribe: true), tools: .init())
        )

        await server.withRequestHandler(ResourceSubscribe.self) { _, _ in
            Empty()
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "watched", uri: "file:///watched.txt")
            ])
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "trigger_update", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, context in
            guard request.name == "trigger_update" else {
                return CallTool.Result(content: [.text("Unknown tool")], isError: true)
            }
            // Send resource updated notification
            try await context.sendResourceUpdated(uri: "file:///watched.txt")
            return CallTool.Result(content: [.text("Update sent")])
        }

        let client = Client(name: "WatchingClient", version: "1.0")

        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await notificationTracker.recordResourceUpdated(uri: message.params.uri)
        }

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Subscribe first
        try await client.subscribeToResource(uri: "file:///watched.txt")

        // Trigger an update via tool call
        _ = try await client.callTool(name: "trigger_update", arguments: [:])

        // Wait for notification to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Verify notification was received
        let updatedURIs = await notificationTracker.resourceUpdatedURIs
        #expect(updatedURIs.count == 1)
        #expect(updatedURIs.first == "file:///watched.txt")
    }
}

// MARK: - Test Helpers

/// Thread-safe tracker for subscription requests
private actor SubscriptionTracker {
    private(set) var subscribedURIs: [String] = []
    private(set) var unsubscribedURIs: [String] = []

    func recordSubscribe(uri: String) {
        subscribedURIs.append(uri)
    }

    func recordUnsubscribe(uri: String) {
        unsubscribedURIs.append(uri)
    }
}

/// Thread-safe tracker for notifications
private actor NotificationTracker {
    private(set) var resourceUpdatedURIs: [String] = []

    func recordResourceUpdated(uri: String) {
        resourceUpdatedURIs.append(uri)
    }
}
