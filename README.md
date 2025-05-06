# MCP Swift SDK

Official Swift SDK for the [Model Context Protocol][mcp] (MCP).

## Overview

The Model Context Protocol (MCP) defines a standardized way
for applications to communicate with AI and ML models.
This Swift SDK provides a robust implementation of both client and server components.

## Requirements

- Swift 6.0+ (Xcode 16+)

See the [Platform Availability](#platform-availability) section below
for platform-specific requirements.

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MCP", package: "swift-sdk")
    ]
)
```

## Client Usage

The client component allows your application to connect to MCP servers.

### Basic Client Setup

```swift
import MCP

// Initialize the client
let client = Client(name: "MyApp", version: "1.0.0")

// Create a transport and connect
let transport = StdioTransport()
try await client.connect(transport: transport)

// Initialize the connection
let result = try await client.initialize()

// Check server capabilities
if result.capabilities.tools != nil {
    // Server supports tools (implicitly including tool calling if the 'tools' capability object is present)
}
```

### Transport Options for Clients

#### Stdio Transport

For local subprocess communication:

```swift
// Create a stdio transport (simplest option)
let transport = StdioTransport()
try await client.connect(transport: transport)
```

#### HTTP Transport

For remote server communication:

```swift
// Create a streaming HTTP transport
let transport = HTTPClientTransport(
    endpoint: URL(string: "http://localhost:8080")!,
    streaming: true  // Enable Server-Sent Events for real-time updates
)
try await client.connect(transport: transport)
```

### Tools

Tools represent functions that can be called by the client:

```swift
// List available tools
let tools = try await client.listTools()
print("Available tools: \(tools.map { $0.name }.joined(separator: ", "))")

// Call a tool with arguments
let (content, isError) = try await client.callTool(
    name: "image-generator",
    arguments: [
        "prompt": "A serene mountain landscape at sunset",
        "style": "photorealistic",
        "width": 1024,
        "height": 768
    ]
)

// Handle tool content
for item in content {
    switch item {
    case .text(let text):
        print("Generated text: \(text)")
    case .image(let data, let mimeType, let metadata):
        if let width = metadata?["width"] as? Int,
           let height = metadata?["height"] as? Int {
            print("Generated \(width)x\(height) image of type \(mimeType)")
            // Save or display the image data
        }
    case .audio(let data, let mimeType):
        print("Received audio data of type \(mimeType)")
    case .resource(let uri, let mimeType, let text):
        print("Received resource from \(uri) of type \(mimeType)")
        if let text = text {
            print("Resource text: \(text)")
        }
    }
}
```

### Resources

Resources represent data that can be accessed and potentially subscribed to:

```swift
// List available resources
let (resources, nextCursor) = try await client.listResources()
print("Available resources: \(resources.map { $0.uri }.joined(separator: ", "))")

// Read a resource
let contents = try await client.readResource(uri: "resource://example")
print("Resource content: \(contents)")

// Subscribe to resource updates if supported
if result.capabilities.resources.subscribe {
    try await client.subscribeToResource(uri: "resource://example")

    // Register notification handler
    await client.onNotification(ResourceUpdatedNotification.self) { message in
        let uri = message.params.uri
        print("Resource \(uri) updated with new content")

        // Fetch the updated resource content
        let updatedContents = try await client.readResource(uri: uri)
        print("Updated resource content received")
    }
}
```

### Prompts

Prompts represent templated conversation starters:

```swift
// List available prompts
let (prompts, nextCursor) = try await client.listPrompts()
print("Available prompts: \(prompts.map { $0.name }.joined(separator: ", "))")

// Get a prompt with arguments
let (description, messages) = try await client.getPrompt(
    name: "customer-service",
    arguments: [
        "customerName": "Alice",
        "orderNumber": "ORD-12345",
        "issue": "delivery delay"
    ]
)

// Use the prompt messages in your application
print("Prompt description: \(description)")
for message in messages {
    if case .text(text: let text) = message.content {
        print("\(message.role): \(text)")
    }
}
```

### Error Handling

Handle common client errors:

```swift
do {
    let result = try await client.initialize()
    // Success
} catch let error as MCPError {
    print("MCP Error: \(error.localizedDescription)")
} catch {
    print("Unexpected error: \(error)")
}
```

### Advanced Client Features

#### Strict vs Non-Strict Configuration

Configure client behavior for capability checking:

```swift
// Strict configuration - fail fast if a capability is missing
let strictClient = Client(
    name: "StrictClient",
    version: "1.0.0",
    configuration: .strict
)

// With strict configuration, calling a method for an unsupported capability
// will throw an error immediately without sending a request
do {
    // This will throw an error if resources.list capability is not available
    let resources = try await strictClient.listResources()
} catch let error as MCPError {
    print("Capability not available: \(error.localizedDescription)")
}

// Default (non-strict) configuration - attempt the request anyway
let client = Client(
    name: "FlexibleClient",
    version: "1.0.0",
    configuration: .default
)

// With default configuration, the client will attempt the request
// even if the capability wasn't advertised by the server
do {
    let resources = try await client.listResources()
} catch let error as MCPError {
    // Still handle the error if the server rejects the request
    print("Server rejected request: \(error.localizedDescription)")
}
```

#### Request Batching

Improve performance by sending multiple requests in a single batch:

```swift
// Array to hold tool call tasks
var toolTasks: [Task<CallTool.Result, Error>] = []

// Send a batch of requests
try await client.withBatch { batch in
    // Add multiple tool calls to the batch
    for i in 0..<10 {
        toolTasks.append(
            try await batch.addRequest(
                CallTool.request(.init(name: "square", arguments: ["n": i]))
            )
        )
    }
}

// Process results after the batch is sent
print("Processing \(toolTasks.count) tool results...")
for (index, task) in toolTasks.enumerated() {
    do {
        let result = try await task.value
        print("\(index): \(result.content)")
    } catch {
        print("\(index) failed: \(error)")
    }
}
```

You can also batch different types of requests:

```swift
// Declare task variables
var pingTask: Task<Ping.Result, Error>?
var promptTask: Task<GetPrompt.Result, Error>?

// Send a batch with different request types
try await client.withBatch { batch in
    pingTask = try await batch.addRequest(Ping.request())
    promptTask = try await batch.addRequest(
        GetPrompt.request(.init(name: "greeting"))
    )
}

// Process individual results
do {
    if let pingTask = pingTask {
        try await pingTask.value
        print("Ping successful")
    }

    if let promptTask = promptTask {
        let promptResult = try await promptTask.value
        print("Prompt: \(promptResult.description ?? "None")")
    }
} catch {
    print("Error processing batch results: \(error)")
}
```

> [!NOTE]
> `Server` automatically handles batch requests from MCP clients.

## Server Usage

The server component allows your application to host model capabilities and respond to client requests.

### Basic Server Setup

```swift
import MCP

// Initialize the server with capabilities
let server = Server(
    name: "MyModelServer",
    version: "1.0.0",
    capabilities: .init(
        prompts: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true),
        tools: .init(listChanged: true)
    )
)

// Create transport and start server
let transport = StdioTransport()
try await server.start(transport: transport)

// Now register handlers for the capabilities you've enabled
```

### Tools

Register tool handlers to respond to client tool calls:

```swift
// Register a tool list handler
server.withMethodHandler(ListTools.self) { _ in
    let tools = [
        Tool(
            name: "weather",
            description: "Get current weather for a location",
            inputSchema: .object([
                "location": .string("City name or coordinates"),
                "units": .string("Units of measurement, e.g., metric, imperial")
            ])
        ),
        Tool(
            name: "calculator",
            description: "Perform calculations",
            inputSchema: .object([
                "expression": .string("Mathematical expression to evaluate")
            ])
        )
    ]
    return .init(tools: tools)
}

// Register a tool call handler
server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "weather":
        let location = params.arguments?["location"]?.stringValue ?? "Unknown"
        let units = params.arguments?["units"]?.stringValue ?? "metric"
        let weatherData = getWeatherData(location: location, units: units) // Your implementation
        return .init(
            content: [.text("Weather for \(location): \(weatherData.temperature)°, \(weatherData.conditions)")],
            isError: false
        )

    case "calculator":
        if let expression = params.arguments?["expression"]?.stringValue {
            let result = evaluateExpression(expression) // Your implementation
            return .init(content: [.text("\(result)")], isError: false)
        } else {
            return .init(content: [.text("Missing expression parameter")], isError: true)
        }

    default:
        return .init(content: [.text("Unknown tool")], isError: true)
    }
}
```

### Resources

Implement resource handlers for data access:

```swift
// Register a resource list handler
server.withMethodHandler(ListResources.self) { params in
    let resources = [
        Resource(
            uri: "resource://knowledge-base/articles",
            name: "Knowledge Base Articles",
            description: "Collection of support articles and documentation"
        ),
        Resource(
            uri: "resource://system/status",
            name: "System Status",
            description: "Current system operational status"
        )
    ]
    return .init(resources: resources, nextCursor: nil)
}

// Register a resource read handler
server.withMethodHandler(ReadResource.self) { params in
    switch params.uri {
    case "resource://knowledge-base/articles":
        return .init(contents: [Resource.Content.text("# Knowledge Base\n\nThis is the content of the knowledge base...", uri: params.uri)])

    case "resource://system/status":
        let status = getCurrentSystemStatus() // Your implementation
        let statusJson = """
            {
                "status": "\(status.overall)",
                "components": {
                    "database": "\(status.database)",
                    "api": "\(status.api)",
                    "model": "\(status.model)"
                },
                "lastUpdated": "\(status.timestamp)"
            }
            """
        return .init(contents: [Resource.Content.text(statusJson, uri: params.uri, mimeType: "application/json")])

    default:
        throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
    }
}

// Register a resource subscribe handler
server.withMethodHandler(SubscribeToResource.self) { params in
    // Store subscription for later notifications.
    // Client identity for multi-client scenarios needs to be managed by the server application,
    // potentially using information from the initialize handshake if the server handles one client post-init.
    // addSubscription(clientID: /* some_client_identifier */, uri: params.uri)
    print("Client subscribed to \(params.uri). Server needs to implement logic to track this subscription.")
    return .init()
}
```

### Prompts

Implement prompt handlers:

```swift
// Register a prompt list handler
server.withMethodHandler(ListPrompts.self) { params in
    let prompts = [
        Prompt(
            name: "interview",
            description: "Job interview conversation starter",
            arguments: [
                .init(name: "position", description: "Job position", required: true),
                .init(name: "company", description: "Company name", required: true),
                .init(name: "interviewee", description: "Candidate name")
            ]
        ),
        Prompt(
            name: "customer-support",
            description: "Customer support conversation starter",
            arguments: [
                .init(name: "issue", description: "Customer issue", required: true),
                .init(name: "product", description: "Product name", required: true)
            ]
        )
    ]
    return .init(prompts: prompts, nextCursor: nil)
}

// Register a prompt get handler
server.withMethodHandler(GetPrompt.self) { params in
    switch params.name {
    case "interview":
        let position = params.arguments?["position"]?.stringValue ?? "Software Engineer"
        let company = params.arguments?["company"]?.stringValue ?? "Acme Corp"
        let interviewee = params.arguments?["interviewee"]?.stringValue ?? "Candidate"

        let description = "Job interview for \(position) position at \(company)"
        let messages: [Prompt.Message] = [
            .init(role: .user, content: .text(text: "You are an interviewer for the \(position) position at \(company).")),
            .init(role: .user, content: .text(text: "Hello, I'm \(interviewee) and I'm here for the \(position) interview.")),
            .init(role: .assistant, content: .text(text: "Hi \(interviewee), welcome to \(company)! I'd like to start by asking about your background and experience."))
        ]

        return .init(description: description, messages: messages)

    case "customer-support":
        // Similar implementation for customer support prompt

    default:
        throw MCPError.invalidParams("Unknown prompt name: \(params.name)")
    }
}
```

#### Initialize Hook

Control client connections with an initialize hook:

```swift
// Start the server with an initialize hook
try await server.start(transport: transport) { clientInfo, clientCapabilities in
    // Validate client info
    guard clientInfo.name != "BlockedClient" else {
        throw MCPError.invalidRequest("This client is not allowed")
    }

    // You can also inspect client capabilities
    if clientCapabilities.tools == nil {
        print("Client does not support tools")
    }

    // Perform any server-side setup based on client info
    print("Client \(clientInfo.name) v\(clientInfo.version) connected")

    // If the hook completes without throwing, initialization succeeds
}
```

### Graceful Shutdown

We recommend using
[Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle)
for managing startup and shutdown of services.

First, add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
```

Then implement the MCP server as a `Service`:

```swift
import MCP
import ServiceLifecycle
import Logging

struct MCPService: Service {
    let server: Server
    let transport: Transport

    init(server: Server, transport: Transport) {
        self.server = server
        self.transport = transport
    }

    func run() async throws {
        // Start the server
        try await server.start(transport: transport)

        // Keep running until external cancellation
        try await Task.sleep(for: .days(365 * 100))  // Effectively forever
    }

    func shutdown() async throws {
        // Gracefully shutdown the server
        await server.stop()
    }
}
```

Then use it in your application:

```swift
import MCP
import ServiceLifecycle
import Logging

let logger = Logger(label: "com.example.mcp-server")

// Create the MCP server
let server = Server(
    name: "MyModelServer",
    version: "1.0.0",
    capabilities: .init(
        prompts: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true),
        tools: .init(listChanged: true)
    ),
    logger: logger
)

// Add handlers directly to the server
server.withMethodHandler(ListTools.self) { _ in
    // Your implementation
    return .init(tools: [
        Tool(name: "example", description: "An example tool")
    ])
}

server.withMethodHandler(CallTool.self) { params in
    // Your implementation
    return .init(content: [.text("Tool result")], isError: false)
}

// Create MCP service and other services
let transport = StdioTransport(logger: logger)
let mcpService = MCPService(server: server, transport: transport)
let databaseService = DatabaseService() // Your other services

// Create service group with signal handling
let serviceGroup = ServiceGroup(
    services: [mcpService, databaseService],
    configuration: .init(
        gracefulShutdownSignals: [.sigterm, .sigint]
    ),
    logger: logger
)

// Run the service group - this blocks until shutdown
try await serviceGroup.run()
```

This approach has several benefits:

- **Signal handling**:
  Automatically traps SIGINT, SIGTERM and triggers graceful shutdown
- **Graceful shutdown**:
  Properly shuts down your MCP server and other services
- **Timeout-based shutdown**:
  Configurable shutdown timeouts to prevent hanging processes
- **Advanced service management**:
  [`ServiceLifecycle`](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/documentation/servicelifecycle)
  also supports service dependencies, conditional services,
  and other useful features.

## Transports

MCP's transport layer handles communication between clients and servers.
The Swift SDK provides multiple built-in transports:

| Transport | Description | Platforms | Best for |
|-----------|-------------|-----------|----------|
| [`StdioTransport`](/Sources/MCP/Base/Transports/StdioTransport.swift) | Implements [stdio transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#stdio) using standard input/output streams | Apple platforms, Linux with glibc | Local subprocesses, CLI tools |
| [`HTTPClientTransport`](/Sources/MCP/Base/Transports/HTTPClientTransport.swift) | Implements [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) using Foundation's URL Loading System | All platforms with Foundation | Remote servers, web applications |
| [`NetworkTransport`](/Sources/MCP/Base/Transports/NetworkTransport.swift) | Custom transport using Apple's Network framework for TCP/UDP connections | Apple platforms only | Low-level networking, custom protocols |

### Custom Transport Implementation

You can implement a custom transport by conforming to the `Transport` protocol:

```swift
import MCP
import Foundation

public actor MyCustomTransport: Transport {
    public nonisolated let logger: Logger
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "my.custom.transport")

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        // Implement your connection logic
        isConnected = true
    }

    public func disconnect() async {
        // Implement your disconnection logic
        isConnected = false
        messageContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        // Implement your message sending logic
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return messageStream
    }
}
```

## Platform Availability

The Swift SDK has the following platform requirements:

| Platform | Minimum Version |
|----------|----------------|
| macOS | 13.0+ |
| iOS / Mac Catalyst | 16.0+ |
| watchOS | 9.0+ |
| tvOS | 16.0+ |
| visionOS | 1.0+ |
| Linux | Distributions with `glibc` |

While the core library works on any platform supporting Swift 6
(including Linux and Windows),
running a client or server requires a compatible transport.

We're actively working to expand platform support:
- [Alpine Linux support](https://github.com/modelcontextprotocol/swift-sdk/pull/64)
- [Windows support](https://github.com/modelcontextprotocol/swift-sdk/pull/64)

## Debugging and Logging

Enable logging to help troubleshoot issues:

```swift
import Logging
import MCP

// Configure Logger
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    return handler
}

// Create logger
let logger = Logger(label: "com.example.mcp")

// Pass to client/server
let client = Client(name: "MyApp", version: "1.0.0", logger: logger)

// Pass to transport
let transport = StdioTransport(logger: logger)
```

## Additional Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-03-26/)
- [Protocol Documentation](https://modelcontextprotocol.io)
- [GitHub Repository](https://github.com/modelcontextprotocol/swift-sdk)

## Changelog

This project follows [Semantic Versioning](https://semver.org/).
For pre-1.0 releases,
minor version increments (0.X.0) may contain breaking changes.

For details about changes in each release,
see the [GitHub Releases page](https://github.com/modelcontextprotocol/swift-sdk/releases).

## License

This project is licensed under the MIT License.

[mcp]: https://modelcontextprotocol.io