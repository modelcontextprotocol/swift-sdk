/**
 * Everything client - a single conformance test client that handles all scenarios.
 *
 * Usage: mcp-everything-client <server-url>
 *
 * The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
 * which is set by the conformance test runner.
 *
 * This client routes to the appropriate behavior based on the scenario name,
 * consolidating all the individual test clients into one.
 */

import Foundation
import Logging
import MCP

// MARK: - Scenario Handlers

typealias ScenarioHandler = ([String]) async throws -> Void

// MARK: - Basic Scenarios

/// Basic client that connects, initializes, and lists tools
func runInitializeScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.initialize",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting initialize scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Disconnect
    await client.disconnect()

    logger.debug("Initialize scenario completed successfully")
}

/// Client that calls the add_numbers tool
func runToolsCallScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.tools_call",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting tools_call scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the add_numbers tool
    if tools.contains(where: { $0.name == "add_numbers" }) {
        let result = try await client.callTool(
            name: "add_numbers",
            arguments: ["a": 5, "b": 3]
        )
        logger.debug("Tool call result", metadata: [
            "isError": "\(result.isError ?? false)",
            "contentCount": "\(result.content.count)"
        ])
    } else {
        logger.warning("add_numbers tool not found")
    }

    // Disconnect
    await client.disconnect()

    logger.debug("Tools call scenario completed successfully")
}

// MARK: - SSE Scenarios

/// Handler for SSE-related scenarios (retry, reconnection, etc.)
func runSSEScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.sse",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting SSE scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport with streaming enabled
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        streaming: true,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect - this will start the SSE stream in the background
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // Give the GET SSE stream time to establish
    try await Task.sleep(for: .milliseconds(500))

    // Call the test_reconnection tool to trigger SSE stream closure and retry test.
    // The server will close the POST SSE stream without the response,
    // then deliver it on the GET SSE stream after we reconnect.
    logger.debug("Calling test_reconnection tool...")
    let result = try await client.callTool(name: "test_reconnection", arguments: [:])
    logger.debug("Tool call result received", metadata: [
        "isError": "\(result.isError ?? false)",
        "contentCount": "\(result.content.count)"
    ])

    // Keep the connection open briefly for the test to collect timing data
    try await Task.sleep(for: .seconds(2))

    // Disconnect
    await client.disconnect()

    logger.debug("SSE scenario completed")
}

/// Client that handles elicitation-sep1034-client-defaults scenario
/// Tests that client properly applies default values for omitted fields
func runElicitationSEP1034ClientDefaults(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.elicitation_client_defaults",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting elicitation-sep1034-client-defaults scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport with streaming enabled for bidirectional communication
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        streaming: true,
        logger: logger
    )

    // Create client with elicitation capabilities
    let client = Client(
        name: "test-client",
        version: "1.0.0",
        capabilities: Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: .init(), url: .init())
        )
    )

    // Set up elicitation handler that accepts defaults BEFORE connecting
    await client.withElicitationHandler { [logger] params in
        let message: String
        switch params {
        case .form(let formParams):
            message = formParams.message
        case .url(let urlParams):
            message = urlParams.message
        }

        logger.debug("Elicitation handler invoked", metadata: [
            "message": "\(message)"
        ])

        // Accept with default values applied
        // The schema has optional fields with defaults:
        // name: "John Doe", age: 30, score: 95.5, status: "active", verified: true
        return CreateElicitation.Result(
            action: .accept,
            content: [
                "name": "John Doe",
                "age": 30,
                "score": 95.5,
                "status": "active",
                "verified": true
            ]
        )
    }

    // Connect
    try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the test_client_elicitation_defaults tool
    if tools.contains(where: { $0.name == "test_client_elicitation_defaults" }) {
        let result = try await client.callTool(
            name: "test_client_elicitation_defaults",
            arguments: [:]
        )
        logger.debug("Tool call result", metadata: [
            "isError": "\(result.isError ?? false)",
            "contentCount": "\(result.content.count)"
        ])
    } else {
        logger.warning("test_client_elicitation_defaults tool not found")
    }

    // Disconnect
    await client.disconnect()

    logger.debug("Elicitation client defaults scenario completed successfully")
}

// MARK: - Default Handler for Unimplemented Scenarios

/// Default handler that performs basic connection test for unimplemented scenarios
func runDefaultScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.default",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Running default scenario handler")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // Disconnect
    await client.disconnect()

    logger.debug("Default scenario completed successfully")
}

// MARK: - Scenario Registry

nonisolated(unsafe) let scenarioHandlers: [String: ScenarioHandler] = [
    "initialize": runInitializeScenario,
    "tools_call": runToolsCallScenario,
    "sse-retry": runSSEScenario,
    "elicitation-sep1034-client-defaults": runElicitationSEP1034ClientDefaults,
    // Note: Other scenarios (auth/*) will use the default handler
]

// MARK: - Error Types

enum ConformanceError: Error, CustomStringConvertible {
    case missingScenario
    case invalidArguments(String)

    var description: String {
        switch self {
        case .missingScenario:
            return "MCP_CONFORMANCE_SCENARIO environment variable not set"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        }
    }
}

struct ConformanceClient {
    static func run() async {
        do {
            // Get scenario from environment
            guard let scenario = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SCENARIO"] else {
                var stderr = StandardError()
                print("Error: MCP_CONFORMANCE_SCENARIO environment variable not set", to: &stderr)
                Foundation.exit(1)
            }

            // Get server URL from arguments (last argument)
            let args = Array(CommandLine.arguments.dropFirst())
            guard !args.isEmpty else {
                var stderr = StandardError()
                print("Usage: mcp-everything-client <server-url>", to: &stderr)
                print("Error: Server URL is required", to: &stderr)
                Foundation.exit(1)
            }

            // Get handler for scenario, or use default if not implemented
            let handler = scenarioHandlers[scenario] ?? runDefaultScenario

            // Log if using default handler
            if scenarioHandlers[scenario] == nil {
                var stderr = StandardError()
                print("⚠️  Scenario '\(scenario)' not fully implemented - using default handler", to: &stderr)
            }

            // Run the scenario
            try await handler(args)
            Foundation.exit(0)
        } catch {
            var stderr = StandardError()
            print("Error: \(error)", to: &stderr)
            Foundation.exit(1)
        }
    }
}

// MARK: - Helpers

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

await ConformanceClient.run()
