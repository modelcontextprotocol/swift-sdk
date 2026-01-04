import Foundation
import Logging
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

@testable import MCP

// MARK: - Session Lifecycle Tests

/// Tests for session lifecycle functionality in MCP.
///
/// These tests cover session initialization, client info handling, capability
/// exposure, and race conditions that can occur during the initialization flow.
///
/// Note: This is distinct from SessionManagerTests.swift which tests the
/// SessionManager actor for HTTP server session storage/retrieval.
///
/// Based on Python SDK tests:
/// - tests/client/test_session.py
/// - tests/server/test_session.py
/// - tests/server/test_session_race_condition.py
@Suite("Session Lifecycle Tests")
struct SessionLifecycleTests {

    // MARK: - Request Immediately After Initialize Response Tests

    @Suite("Request immediately after initialize response (race condition)")
    struct InitializeRaceConditionTests {

        /// Test that requests are accepted immediately after initialize response.
        ///
        /// This reproduces the race condition in stateful HTTP mode where:
        /// 1. Client sends InitializeRequest
        /// 2. Server responds with InitializeResult
        /// 3. Client immediately sends tools/list (before server receives InitializedNotification)
        /// 4. Without fix: Server rejects with "Received request before initialization was complete"
        /// 5. With fix: Server accepts and processes the request
        ///
        /// This test simulates the HTTP transport behavior where InitializedNotification
        /// may arrive in a separate POST request after other requests.
        ///
        /// Based on Python SDK: tests/server/test_session_race_condition.py
        @Test(.timeLimit(.minutes(1)))
        func requestImmediatelyAfterInitializeResponse() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (_, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.race-condition")
            logger.logLevel = .warning

            let serverTransport = StdioTransport(
                input: clientToServerRead,
                output: serverToClientWrite,
                logger: logger
            )

            let toolsListSuccess = ToolsListSuccessTracker()

            // Set up server with tools capability
            let server = Server(
                name: "RaceConditionTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                await toolsListSuccess.markSuccess()
                return ListTools.Result(tools: [
                    Tool(
                        name: "example_tool",
                        description: "An example tool",
                        inputSchema: ["type": "object"]
                    )
                ])
            }

            // Start the server
            try await server.start(transport: serverTransport)

            // Wait for server to be ready
            try await Task.sleep(for: .milliseconds(50))

            // Simulate client behavior manually (like HTTP transport race condition)
            let encoder = JSONEncoder()

            // Step 1: Send Initialize request
            let initRequest = Request<Initialize>(
                id: .number(1),
                method: Initialize.name,
                params: Initialize.Parameters(
                    protocolVersion: Version.latest,
                    capabilities: .init(),
                    clientInfo: .init(name: "race-condition-client", version: "1.0")
                )
            )

            let initData = try encoder.encode(initRequest)
            _ = try clientToServerWrite.writeAll(initData)
            _ = try clientToServerWrite.writeAll("\n".data(using: .utf8)!)

            // Wait for and read the initialize response
            try await Task.sleep(for: .milliseconds(100))

            // Step 2: Immediately send tools/list BEFORE InitializedNotification
            // This is the race condition scenario
            let toolsListRequest = Request<ListTools>(
                id: .number(2),
                method: ListTools.name,
                params: ListTools.Parameters()
            )

            let toolsData = try encoder.encode(toolsListRequest)
            _ = try clientToServerWrite.writeAll(toolsData)
            _ = try clientToServerWrite.writeAll("\n".data(using: .utf8)!)

            // Wait for tools/list to be processed
            try await Task.sleep(for: .milliseconds(200))

            // Step 3: Now send InitializedNotification
            let initializedNotification = InitializedNotification.message(.init())
            let notifData = try encoder.encode(initializedNotification)
            _ = try clientToServerWrite.writeAll(notifData)
            _ = try clientToServerWrite.writeAll("\n".data(using: .utf8)!)

            // Give time for all messages to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify tools/list succeeded (race condition was handled correctly)
            let success = await toolsListSuccess.wasSuccessful
            #expect(success, "tools/list should succeed immediately after initialize response, before InitializedNotification")

            // Clean up
            await server.stop()
        }

        /// Test that server in lenient mode accepts requests before initialized notification.
        ///
        /// In lenient mode, the server should accept any request after receiving
        /// the initialize request, without waiting for InitializedNotification.
        @Test(.timeLimit(.minutes(1)))
        func lenientModeAcceptsEarlyRequests() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.lenient-mode")
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

            // Set up server in lenient mode (default)
            let server = Server(
                name: "LenientModeServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                return ListTools.Result(tools: [
                    Tool(name: "test_tool", inputSchema: ["type": "object"])
                ])
            }

            let client = Client(name: "LenientModeClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Make a request - should succeed in lenient mode
            let tools = try await client.send(ListTools.request(.init()))
            #expect(tools.tools.count == 1)
            #expect(tools.tools.first?.name == "test_tool")

            await client.disconnect()
            await server.stop()
        }
    }

    // MARK: - Client Info Tests

    @Suite("Client info handling")
    struct ClientInfoTests {

        /// Test that custom client info is properly sent during initialization.
        ///
        /// Based on Python SDK: test_client_session_custom_client_info
        @Test(.timeLimit(.minutes(1)))
        func customClientInfoSentDuringInitialization() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.custom-client-info")
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

            let receivedClientInfo = ReceivedClientInfoTracker()

            let server = Server(
                name: "ClientInfoTestServer",
                version: "1.0.0",
                capabilities: .init()
            )

            // Use custom client info
            let customName = "custom-test-client"
            let customVersion = "2.3.4"
            let client = Client(name: customName, version: customVersion)

            // Track received client info via initialize hook (trailing closure on start)
            try await server.start(transport: serverTransport) { clientInfo, _ in
                await receivedClientInfo.set(clientInfo)
            }
            _ = try await client.connect(transport: clientTransport)

            // Give time for hook to be called
            try await Task.sleep(for: .milliseconds(100))

            // Verify the custom client info was received
            let info = await receivedClientInfo.info
            #expect(info != nil, "Server should have received client info")
            #expect(info?.name == customName, "Server should receive custom client name")
            #expect(info?.version == customVersion, "Server should receive custom client version")

            await client.disconnect()
            await server.stop()
        }

        /// Test that default client info is properly sent during initialization.
        ///
        /// Based on Python SDK: test_client_session_default_client_info
        @Test(.timeLimit(.minutes(1)))
        func defaultClientInfoSentDuringInitialization() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.default-client-info")
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

            let receivedClientInfo = ReceivedClientInfoTracker()

            let server = Server(
                name: "DefaultClientInfoServer",
                version: "1.0.0",
                capabilities: .init()
            )

            // Use minimal client (name and version are required in Swift)
            let client = Client(name: "test-app", version: "1.0")

            // Track received client info via initialize hook (trailing closure on start)
            try await server.start(transport: serverTransport) { clientInfo, _ in
                await receivedClientInfo.set(clientInfo)
            }
            _ = try await client.connect(transport: clientTransport)

            // Give time for hook to be called
            try await Task.sleep(for: .milliseconds(100))

            // Verify client info was received and has expected values
            let info = await receivedClientInfo.info
            #expect(info != nil, "Server should have received client info")
            #expect(info?.name == "test-app")
            #expect(info?.version == "1.0")

            await client.disconnect()
            await server.stop()
        }
    }

    // MARK: - Server Capabilities Tests

    @Suite("Server capabilities")
    struct ServerCapabilitiesTests {

        /// Test that getServerCapabilities returns nil before init and capabilities after.
        ///
        /// Based on Python SDK: test_get_server_capabilities
        @Test(.timeLimit(.minutes(1)))
        func getServerCapabilitiesBeforeAndAfterInit() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.server-capabilities")
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

            // Server with various capabilities enabled
            let server = Server(
                name: "CapabilitiesTestServer",
                version: "1.0.0",
                capabilities: .init(
                    logging: .init(),
                    prompts: .init(listChanged: true),
                    resources: .init(subscribe: true, listChanged: true),
                    tools: .init(listChanged: false)
                )
            )

            // Register minimal handlers so capabilities are advertised
            await server.withRequestHandler(ListPrompts.self) { _, _ in
                return ListPrompts.Result(prompts: [])
            }
            await server.withRequestHandler(ListResources.self) { _, _ in
                return ListResources.Result(resources: [])
            }
            await server.withRequestHandler(ListTools.self) { _, _ in
                return ListTools.Result(tools: [])
            }

            let client = Client(name: "CapabilitiesTestClient", version: "1.0")

            // Check capabilities before connection - should be nil
            let capabilitiesBeforeConnect = await client.serverCapabilities
            #expect(capabilitiesBeforeConnect == nil, "Capabilities should be nil before connect")

            try await server.start(transport: serverTransport)

            // Connect and verify capabilities
            let initResult = try await client.connect(transport: clientTransport)

            // Check capabilities after connection - should be populated
            let capabilitiesAfterConnect = await client.serverCapabilities
            #expect(capabilitiesAfterConnect != nil, "Capabilities should be set after connect")

            // Verify specific capabilities
            #expect(capabilitiesAfterConnect?.logging != nil, "Logging capability should be present")
            #expect(capabilitiesAfterConnect?.prompts != nil, "Prompts capability should be present")
            #expect(capabilitiesAfterConnect?.prompts?.listChanged == true, "Prompts listChanged should be true")
            #expect(capabilitiesAfterConnect?.resources != nil, "Resources capability should be present")
            #expect(capabilitiesAfterConnect?.resources?.subscribe == true, "Resources subscribe should be true")
            #expect(capabilitiesAfterConnect?.tools != nil, "Tools capability should be present")
            #expect(capabilitiesAfterConnect?.tools?.listChanged == false, "Tools listChanged should be false")

            // Verify init result matches
            #expect(initResult.capabilities.logging != nil)
            #expect(initResult.capabilities.prompts != nil)
            #expect(initResult.capabilities.resources != nil)
            #expect(initResult.capabilities.tools != nil)

            await client.disconnect()
            await server.stop()

            // After disconnect, capabilities should still be available (cached)
            // This matches the Swift SDK behavior where we cache the last known capabilities
            let capabilitiesAfterDisconnect = await client.serverCapabilities
            #expect(capabilitiesAfterDisconnect != nil, "Capabilities remain cached after disconnect")
        }
    }

    // MARK: - In-Flight Request Tracking Tests

    @Suite("In-flight request tracking")
    struct InFlightRequestTrackingTests {

        /// Test that in-flight request tracking is cleared after request completes.
        ///
        /// This verifies that the internal tracking of pending requests is properly
        /// cleaned up after responses are received, preventing memory leaks.
        ///
        /// Based on Python SDK: test_in_flight_requests_cleared_after_completion
        @Test(.timeLimit(.minutes(1)))
        func inFlightRequestsClearedAfterCompletion() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.in-flight-cleanup")
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

            let server = Server(
                name: "InFlightTestServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            await server.withRequestHandler(ListTools.self) { _, _ in
                return ListTools.Result(tools: [
                    Tool(name: "test_tool", inputSchema: ["type": "object"])
                ])
            }

            let client = Client(name: "InFlightTestClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send multiple requests and verify they complete
            for i in 1...5 {
                let tools = try await client.send(ListTools.request(.init()))
                #expect(tools.tools.count == 1, "Request \(i) should succeed")
            }

            // The client should still be functional after all requests complete
            // This indirectly verifies that in-flight tracking was cleaned up
            let finalTools = try await client.send(ListTools.request(.init()))
            #expect(finalTools.tools.first?.name == "test_tool")

            await client.disconnect()
            await server.stop()
        }

        /// Test that multiple concurrent requests are properly tracked and cleaned up.
        @Test(.timeLimit(.minutes(1)))
        func concurrentRequestsTrackedAndCleanedUp() async throws {
            let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
            let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

            var logger = Logger(label: "mcp.test.concurrent-in-flight")
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

            let server = Server(
                name: "ConcurrentInFlightServer",
                version: "1.0.0",
                capabilities: .init(tools: .init())
            )

            let callCount = CallCountTracker()

            await server.withRequestHandler(ListTools.self) { _, _ in
                return ListTools.Result(tools: [])
            }

            await server.withRequestHandler(CallTool.self) { request, _ in
                // Small delay to ensure requests overlap
                let delay = request.arguments?["delay"]?.doubleValue ?? 0.05
                try? await Task.sleep(for: .seconds(delay))
                await callCount.increment()
                return CallTool.Result(content: [.text("Done")])
            }

            let client = Client(name: "ConcurrentInFlightClient", version: "1.0")

            try await server.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)

            // Send multiple concurrent requests
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<10 {
                    group.addTask {
                        let delay = Double(i % 3) * 0.01 + 0.01
                        _ = try? await client.send(
                            CallTool.request(.init(
                                name: "test",
                                arguments: ["delay": .double(delay)]
                            ))
                        )
                    }
                }
            }

            // All 10 requests should have been processed
            let count = await callCount.count
            #expect(count == 10, "All concurrent requests should complete")

            // Client should still be functional
            let tools = try await client.send(ListTools.request(.init()))
            #expect(tools.tools.isEmpty)

            await client.disconnect()
            await server.stop()
        }
    }
}

// MARK: - Helper Actors

private actor ToolsListSuccessTracker {
    private var _success = false

    func markSuccess() {
        _success = true
    }

    var wasSuccessful: Bool { _success }
}

private actor ReceivedClientInfoTracker {
    private var _info: Client.Info?

    func set(_ info: Client.Info) {
        _info = info
    }

    var info: Client.Info? { _info }
}

private actor CallCountTracker {
    private var _count = 0

    func increment() {
        _count += 1
    }

    var count: Int { _count }
}
