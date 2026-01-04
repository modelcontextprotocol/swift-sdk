import Testing

@testable import MCP

/// Tests that verify server handlers execute concurrently.
///
/// These tests are based on Python SDK's `test_188_concurrency.py`:
/// - `test_messages_are_executed_concurrently_tools`
/// - `test_messages_are_executed_concurrently_tools_and_resources`
///
/// The pattern uses coordination primitives (events) to prove concurrent execution:
/// 1. First handler starts and waits on an event
/// 2. Second handler starts (only possible if handlers run concurrently)
/// 3. Second handler signals the event
/// 4. First handler completes
///
/// If handlers ran sequentially, the first handler would block forever
/// waiting for an event that the second handler (which never starts) should signal.
@Suite("Concurrent Execution Tests")
struct ConcurrentExecutionTests {

    // MARK: - Helper Types

    /// An actor that allows async coordination between concurrent tasks.
    /// Similar to Python's anyio.Event().
    private actor AsyncEvent {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            signaled = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }

        func wait() async {
            if signaled { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        var isSignaled: Bool { signaled }
    }

    /// An actor that tracks the order of events for verification.
    private actor CallOrderTracker {
        private var order: [String] = []

        func append(_ event: String) {
            order.append(event)
        }

        var events: [String] { order }
    }

    // MARK: - Concurrent Tool Execution Tests

    /// Tests that tool calls execute concurrently on the server.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - "trigger" tool starts (proves concurrency), waits for sleep to start, then signals
    /// - Both tools complete
    ///
    /// If execution were sequential, the sleep tool would block forever.
    @Test("Tool calls execute concurrently on server")
    func toolCallsExecuteConcurrently() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"]),
                Tool(name: "trigger", description: "Triggers the event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            } else if request.name == "trigger" {
                // Wait for sleep tool to start before signaling
                await toolStarted.wait()
                await callOrder.append("trigger_started")
                await event.signal()
                await callOrder.append("trigger_end")
                return CallTool.Result(content: [.text("triggered")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the trigger tool (will signal the event)
        let triggerTask = Task {
            try await client.send(CallTool.request(.init(name: "trigger", arguments: nil)))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await triggerTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "trigger_started", "trigger_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)"
        )
    }

    /// Tests that tool and resource handlers execute concurrently.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools_and_resources`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - resource read starts (proves concurrency), signals the event
    /// - Both complete
    @Test("Tool and resource calls execute concurrently on server")
    func toolAndResourceCallsExecuteConcurrently() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentMixedServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(), tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "Slow Resource", uri: "test://slow_resource")
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            if request.uri == "test://slow_resource" {
                // Wait for tool to start before signaling
                await toolStarted.wait()
                await event.signal()
                await callOrder.append("resource_end")
                return ReadResource.Result(contents: [
                    .text("slow", uri: "test://slow_resource")
                ])
            }
            return ReadResource.Result(contents: [])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentMixedClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the resource read (will signal the event)
        let resourceTask = Task {
            try await client.send(ReadResource.request(.init(uri: "test://slow_resource")))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await resourceTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "resource_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)"
        )
    }

    /// Tests that multiple concurrent tool calls all execute in parallel.
    ///
    /// Pattern: Start N tools that all wait on a shared event, then signal it once.
    /// If sequential, only the first would run and block forever.
    @Test("Multiple concurrent tool calls all execute in parallel")
    func multipleConcurrentToolCallsExecuteInParallel() async throws {
        let event = AsyncEvent()
        let startedCount = StartedCounter()
        let expectedConcurrency = 5

        let server = Server(
            name: "ParallelToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "wait_tool", description: "Waits for event", inputSchema: ["type": "object"])
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            // Track that this handler started
            await startedCount.increment()

            // Wait for the event
            await event.wait()
            return CallTool.Result(content: [.text("done")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ParallelTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        // Start multiple tool calls concurrently
        let tasks = (0..<expectedConcurrency).map { _ in
            Task {
                try await client.send(CallTool.request(.init(name: "wait_tool", arguments: nil)))
            }
        }

        // Wait for all handlers to start (proves they're running concurrently)
        var attempts = 0
        while await startedCount.value < expectedConcurrency && attempts < 100 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }

        let started = await startedCount.value
        #expect(
            started == expectedConcurrency,
            "All \(expectedConcurrency) handlers should have started concurrently, but only \(started) started"
        )

        // Signal the event to let all handlers complete
        await event.signal()

        // Wait for all tasks to complete
        for task in tasks {
            _ = try await task.value
        }
    }

    /// Counter actor for tracking how many handlers have started.
    private actor StartedCounter {
        private var count = 0

        func increment() {
            count += 1
        }

        var value: Int { count }
    }
}
