# MCP Swift SDK

Official Swift SDK for the [Model Context Protocol][mcp] (MCP).

## Overview

The Model Context Protocol (MCP) defines a standardized way
for applications to communicate with AI and ML models.
This Swift SDK implements both client and server components
according to the [2025-11-25][mcp-spec-2025-11-25] (latest) version
of the MCP specification.

## Table of contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Client Usage](#client-usage)
  - [Basic Client Setup](#basic-client-setup)
  - [Transport Options for Clients](#transport-options-for-clients)
  - [Tools](#tools)
  - [Resources](#resources)
  - [Prompts](#prompts)
  - [Completions](#completions)
  - [Sampling](#sampling)
  - [Elicitation](#elicitation)
  - [Roots](#roots)
  - [Logging](#logging)
  - [Error Handling](#error-handling)
  - [Cancellation](#cancellation)
  - [Progress Tracking](#progress-tracking)
  - [Advanced Client Features](#advanced-client-features)
- [Server Usage](#server-usage)
  - [Basic Server Setup](#basic-server-setup)
  - [Tools](#tools-1)
  - [Resources](#resources-1)
  - [Prompts](#prompts-1)
  - [Completions](#completions-1)
  - [Sampling](#sampling-1)
  - [Elicitations](#elicitations)
  - [Roots](#roots-1)
  - [Logging](#logging-1)
  - [Progress Tracking](#progress-tracking-1)
  - [Initialize Hook](#initialize-hook)
  - [Graceful Shutdown](#graceful-shutdown)
- [Transports](#transports)
- [Authentication](#authentication)
  - [Client: Client Credentials Flow](#client-client-credentials-flow)
  - [Client: Authorization Code Flow](#client-authorization-code-flow)
  - [Client: Custom Token Provider](#client-custom-token-provider)
  - [Client: Custom Token Storage](#client-custom-token-storage)
  - [Client: private\_key\_jwt Authentication](#client-private_key_jwt-authentication)
  - [Client: Endpoint Overrides](#client-endpoint-overrides)
  - [Server: Serving Protected Resource Metadata](#server-serving-protected-resource-metadata)
  - [Server: Validating Bearer Tokens](#server-validating-bearer-tokens)
- [Platform Availability](#platform-availability)
- [Debugging and Logging](#debugging-and-logging)
- [Additional Resources](#additional-resources)
- [Changelog](#changelog)
- [License](#license)

## Requirements

- Swift 6.0+ (Xcode 16+)

See the [Platform Availability](#platform-availability) section below
for platform-specific requirements.

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
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
let result = try await client.connect(transport: transport)

// Check server capabilities
if result.capabilities.tools != nil {
    // Server supports tools (implicitly including tool calling if the 'tools' capability object is present)
}
```

> [!NOTE]
> The `Client.connect(transport:)` method returns the initialization result.
> This return value is discardable, 
> so you can ignore it if you don't need to check server capabilities.

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
let (tools, cursor) = try await client.listTools()
print("Available tools: \(tools.map { $0.name }.joined(separator: ", "))")

// Call a tool with arguments and get the result
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
    case .resource(let resource, _, _):
        print("Received embedded resource: \(resource)")
    case .resourceLink(let uri, let name, _, _, let mimeType, _):
        print("Resource link: \(name) at \(uri), type: \(mimeType ?? "unknown")")
    }
}

// React when the server's tool list changes
await client.onNotification(ToolListChangedNotification.self) { _ in
    let (tools, _) = try await client.listTools()
    print("Tool list updated: \(tools.map { $0.name })")
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
if result.capabilities.resources?.subscribe == true {
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

// Unsubscribe from resource updates
_ = try await client.send(ResourceUnsubscribe.request(.init(uri: "resource://example"))).value

// Read a binary resource (the blob field contains base64-encoded data)
let binaryContents = try await client.readResource(uri: "resource://image/logo")
for content in binaryContents {
    if let blob = content.blob {
        let imageData = Data(base64Encoded: blob)!
        // Use imageData as needed...
    }
}

// List resource templates and read a resolved URI
let (templates, _) = try await client.listResourceTemplates()
print("Available templates: \(templates.map { $0.uriTemplate })")

// Resolve a template by substituting variables, then read it
let resolvedURI = "file:///Users/user/projects/readme.md"
let templateContents = try await client.readResource(uri: resolvedURI)

// React when the server's resource list changes
await client.onNotification(ResourceListChangedNotification.self) { _ in
    let (resources, _) = try await client.listResources()
    print("Resource list updated: \(resources.map { $0.uri })")
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
    switch message.content {
    case .text(let text):
        print("\(message.role): \(text)")
    case .image(let data, let mimeType):
        let imageData = Data(base64Encoded: data)!
        print("Image (\(mimeType)): \(imageData.count) bytes")
    case .audio(let data, let mimeType):
        print("Audio (\(mimeType))")
    case .resource(let resource, _, _):
        // Inline resource content embedded in the prompt
        if let text = resource.text {
            print("Embedded resource \(resource.uri): \(text)")
        } else if resource.blob != nil {
            print("Embedded binary resource: \(resource.uri)")
        }
    case .resourceLink(let uri, let name, _, _, _, _):
        print("Resource link: \(name) at \(uri)")
    }
}

// React when the server's prompt list changes
await client.onNotification(PromptListChangedNotification.self) { _ in
    let (prompts, _) = try await client.listPrompts()
    print("Prompt list updated: \(prompts.map { $0.name })")
}
```

### Completions

Completions allow servers to provide autocompletion suggestions for prompt and resource template arguments as users type:

```swift
// Request completions for a prompt argument
let completion = try await client.complete(
    promptName: "code_review",
    argumentName: "language",
    argumentValue: "py"
)

// Display suggestions to the user
for value in completion.values {
    print("Suggestion: \(value)")
}

if completion.hasMore == true {
    print("More suggestions available (total: \(completion.total ?? 0))")
}
```

You can also provide context with already-resolved arguments:

```swift
// First, user selects a language
let languageCompletion = try await client.complete(
    promptName: "code_review",
    argumentName: "language",
    argumentValue: "py"
)
// User selects "python"

// Then get framework suggestions based on the selected language
let frameworkCompletion = try await client.complete(
    promptName: "code_review",
    argumentName: "framework",
    argumentValue: "fla",
    context: ["language": .string("python")]
)
// Returns: ["flask"]
```

Completions work for resource templates as well:

```swift
// Get path completions for a resource URI template
let pathCompletion = try await client.complete(
    resourceURI: "file:///{path}",
    argumentName: "path",
    argumentValue: "/usr/"
)
// Returns: ["/usr/bin", "/usr/lib", "/usr/local"]
```

### Sampling

Sampling allows servers to request LLM completions through the client, 
enabling agentic behaviors while maintaining human-in-the-loop control. 
Clients register a handler to process incoming sampling requests from servers.

> [!TIP]
> Sampling requests flow from **server to client**, 
> not client to server. 
> This enables servers to request AI assistance 
> while clients maintain control over model access and user approval.

```swift
// Register a sampling handler in the client
await client.withSamplingHandler { parameters in
    // Review the sampling request (human-in-the-loop step 1)
    print("Server requests completion for: \(parameters.messages)")
    
    // Optionally modify the request based on user input
    var messages = parameters.messages
    if let systemPrompt = parameters.systemPrompt {
        print("System prompt: \(systemPrompt)")
    }
    
    // Sample from your LLM (this is where you'd call your AI service)
    let completion = try await callYourLLMService(
        messages: messages,
        maxTokens: parameters.maxTokens,
        temperature: parameters.temperature
    )
    
    // Review the completion (human-in-the-loop step 2)
    print("LLM generated: \(completion)")
    // User can approve, modify, or reject the completion here
    
    // Return the result to the server
    return CreateSamplingMessage.Result(
        model: "your-model-name",
        stopReason: .endTurn,
        role: .assistant,
        content: .text(completion)
    )
}
```

### Elicitation

Elicitation allows servers to request structured information directly from users through the client. 
This is useful when servers need user input that wasn't provided in the original request, 
such as credentials, configuration choices, or approval for sensitive operations.

> [!TIP]
> Elicitation requests flow from **server to client**, 
> similar to sampling. 
> Clients must register a handler to respond to elicitation requests from servers.

#### Client-Side: Handling Elicitation Requests

Register an elicitation handler to respond to server requests:

```swift
// Register an elicitation handler in the client
await client.withElicitationHandler { parameters in
    switch parameters {
    case .form(let form):
        // Display the request to the user
        print("Server requests: \(form.message)")

        // If a schema was provided, inspect it
        if let schema = form.requestedSchema {
            print("Required fields: \(schema.required ?? [])")
            print("Schema: \(schema.properties)")
        }

        // Present UI to collect user input
        let userResponse = presentElicitationUI(form)

        // Return the user's response
        if userResponse.accepted {
            return CreateElicitation.Result(
                action: .accept,
                content: userResponse.data
            )
        } else if userResponse.canceled {
            return CreateElicitation.Result(action: .cancel)
        } else {
            return CreateElicitation.Result(action: .decline)
        }

    case .url(let url):
        // Direct the user to an external URL (e.g., for OAuth)
        openURL(url.url)
        return CreateElicitation.Result(action: .accept)
    }
}
```

Common use cases for elicitation:

- **Authentication**: Request credentials when needed rather than upfront
- **Confirmation**: Ask for user approval before sensitive operations
- **Configuration**: Collect preferences or settings during operation
- **Missing information**: Request additional details not provided initially

### Roots

Roots define the filesystem boundaries that a client exposes to servers. Servers discover roots by sending a `roots/list` request to the client; clients notify servers when the list changes.

> [!TIP]
> To use roots, declare the `roots` capability when creating the client.

```swift
let client = Client(
    name: "MyApp",
    version: "1.0.0",
    capabilities: .init(
        roots: .init(listChanged: true)
    )
)

// Register a handler for roots/list requests from servers
await client.withRootsHandler {
    return [
        Root(uri: "file:///Users/user/projects", name: "Projects"),
        Root(uri: "file:///Users/user/documents", name: "Documents")
    ]
}

// Notify connected servers whenever roots change
try await client.notifyRootsChanged()
```

### Logging

Clients can control server logging levels and receive structured log messages:

```swift
// Set the minimum logging level
try await client.setLoggingLevel(.warning)

// Register a handler for log messages from the server
await client.onNotification(LogMessageNotification.self) { message in
    let level = message.params.level        // LogLevel (debug, info, warning, etc.)
    let logger = message.params.logger      // Optional logger name
    let data = message.params.data          // Arbitrary JSON data

    // Display log message based on level
    switch level {
    case .error, .critical, .alert, .emergency:
        print("❌ [\(logger ?? "server")] \(data)")
    case .warning:
        print("⚠️ [\(logger ?? "server")] \(data)")
    default:
        print("ℹ️ [\(logger ?? "server")] \(data)")
    }
}
```

Log levels follow the standard syslog severity levels (RFC 5424):

- **debug**: Detailed debugging information
- **info**: General informational messages
- **notice**: Normal but significant events
- **warning**: Warning conditions
- **error**: Error conditions
- **critical**: Critical conditions
- **alert**: Action must be taken immediately
- **emergency**: System is unusable

### Error Handling

Handle common client errors:

```swift
do {
    try await client.connect(transport: transport)
    // Success
} catch let error as MCPError {
    print("MCP Error: \(error.localizedDescription)")
} catch {
    print("Unexpected error: \(error)")
}
```

### Cancellation

Either side can cancel an in-progress request and handle incoming cancellations gracefully:

#### Option 1: Convenience Methods with RequestContext Overload

For common operations like tool calls, use the overloaded method that returns `RequestContext`:

```swift
// Call a tool and get a context for cancellation
let context = try client.callTool(
    name: "long-running-analysis",
    arguments: ["data": largeDataset]
)

// You can cancel the request at any time
try await client.cancelRequest(context.requestID, reason: "User cancelled")

// Await the result (will throw CancellationError if cancelled)
do {
    let result = try await context.value
    print("Result: \(result.content)")
} catch is CancellationError {
    print("Request was cancelled")
}
```

#### Option 2: Direct send() for Maximum Flexibility

For full control or custom requests, use `send()` directly:

```swift
// Create any request type
let request = CallTool.request(.init(
    name: "long-running-analysis",
    arguments: ["data": largeDataset]
))

// Send and get a context for cancellation tracking
let context: RequestContext<CallTool.Result> = try client.send(request)

// Cancel when needed
try await client.cancelRequest(context.requestID, reason: "Timeout")

// Get the result
let result = try await context.value
let content = result.content
let isError = result.isError
```

### Progress tracking

Clients can attach a progress token to a request and receive incremental progress updates for long-running operations:

```swift
// Call a tool with progress tracking
let progressToken = ProgressToken.unique()

// Register a notification handler to receive progress updates
await client.onNotification(ProgressNotification.self) { message in
    let params = message.params
    // Filter by your progress token
    if params.progressToken == progressToken {
        print("Progress: \(params.progress)/\(params.total ?? 0)")
        if let message = params.message {
            print("Status: \(message)")
        }
    }
}

// Make the request with the progress token
let (content, isError) = try await client.callTool(
    name: "long-running-tool",
    arguments: ["input": "value"],
    meta: Metadata(progressToken: progressToken)
)
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
var toolTasks: [Task<CallTool.Result, Swift.Error>] = []

// Send a batch of requests
try await client.withBatch { batch in
    // Add multiple tool calls to the batch
    for i in 0..<10 {
        toolTasks.append(
            try await batch.addRequest(
                CallTool.request(.init(name: "square", arguments: ["n": Value(i)]))
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

// Create a server with given capabilities
let server = Server(
    name: "MyModelServer",
    version: "1.0.0",
    capabilities: .init(
        completions: .init(),
        logging: .init(),
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
await server.withMethodHandler(ListTools.self) { _ in
    let tools = [
        Tool(
            name: "weather",
            description: "Get current weather for a location",
            inputSchema: .object([
                "properties": .object([
                    "location": .string("City name or coordinates"),
                    "units": .string("Units of measurement, e.g., metric, imperial")
                ])
            ])
        ),
        Tool(
            name: "calculator",
            description: "Perform calculations",
            inputSchema: .object([
                "properties": .object([
                    "expression": .string("Mathematical expression to evaluate")
                ])
            ])
        )
    ]
    return .init(tools: tools)
}

// Register a tool call handler
await server.withMethodHandler(CallTool.self) { params in
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

// Notify clients that the tool list has changed
// (Requires tools.listChanged: true in server capabilities)
try await server.notify(ToolListChangedNotification.message())
```

### Resources

Implement resource handlers for data access:

```swift
// Register a resource list handler
await server.withMethodHandler(ListResources.self) { params in
    let resources = [
        Resource(
            name: "Knowledge Base Articles",
            uri: "resource://knowledge-base/articles",
            description: "Collection of support articles and documentation"
        ),
        Resource(
            name: "System Status",
            uri: "resource://system/status",
            description: "Current system operational status"
        )
    ]
    return .init(resources: resources, nextCursor: nil)
}

// Register a resource read handler
await server.withMethodHandler(ReadResource.self) { params in
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

    case "resource://image/logo":
        let imageData = loadLogoImage() // Your implementation — returns Data
        return .init(contents: [
            Resource.Content.binary(imageData, uri: params.uri, mimeType: "image/png")
        ])

    default:
        throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
    }
}

// Register a resource subscribe handler
await server.withMethodHandler(ResourceSubscribe.self) { params in
    // Store subscription for later notifications.
    // Client identity for multi-client scenarios needs to be managed by the server application,
    // potentially using information from the initialize handshake if the server handles one client post-init.
    // addSubscription(clientID: /* some_client_identifier */, uri: params.uri)
    print("Client subscribed to \(params.uri). Server needs to implement logic to track this subscription.")
    return .init()
}

// Register an unsubscribe handler
await server.withMethodHandler(ResourceUnsubscribe.self) { params in
    print("Client unsubscribed from \(params.uri)")
    return .init()
}

// List resource templates so clients can discover parameterized resource URIs
await server.withMethodHandler(ListResourceTemplates.self) { _ in
    let templates = [
        Resource.Template(
            uriTemplate: "file:///{path}",
            name: "Project Files",
            description: "Access files in the project directory",
            mimeType: "text/plain"
        )
    ]
    return .init(templates: templates)
}

// Notify clients that the resource list has changed
// (Requires resources.listChanged: true in server capabilities)
try await server.notify(ResourceListChangedNotification.message())

// Notify subscribed clients that a specific resource was updated
// (Requires resources.subscribe: true in server capabilities)
try await server.notify(ResourceUpdatedNotification.message(.init(uri: "resource://system/status")))
```

### Prompts

Implement prompt handlers:

```swift
// Register a prompt list handler
await server.withMethodHandler(ListPrompts.self) { params in
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
await server.withMethodHandler(GetPrompt.self) { params in
    switch params.name {
    case "interview":
        let position = params.arguments?["position"]?.stringValue ?? "Software Engineer"
        let company = params.arguments?["company"]?.stringValue ?? "Acme Corp"
        let interviewee = params.arguments?["interviewee"]?.stringValue ?? "Candidate"

        let description = "Job interview for \(position) position at \(company)"
        let messages: [Prompt.Message] = [
            .user(.text(text: "You are an interviewer for the \(position) position at \(company).")),
            .user(.text(text: "Hello, I'm \(interviewee) and I'm here for the \(position) interview.")),
            .assistant(.text(text: "Hi \(interviewee), welcome to \(company)! I'd like to start by asking about your background and experience."))
        ]

        return .init(description: description, messages: messages)

    case "customer-support":
        // Similar implementation for customer support prompt

    case "image-analysis":
        // Prompt messages can include image content and embedded resources
        let imageBase64 = loadChartImage() // Your implementation — returns base64 string
        let messages: [Prompt.Message] = [
            .user(.text(text: "Please analyze the following chart:")),
            .user(.image(data: imageBase64, mimeType: "image/png")),
            .user(.resource(
                resource: Resource.Content.text(
                    "Chart data source: Q4 2025 sales figures",
                    uri: "resource://charts/q4-metadata"
                )
            ))
        ]
        return .init(description: "Image analysis prompt", messages: messages)

    default:
        throw MCPError.invalidParams("Unknown prompt name: \(params.name)")
    }
}

// Notify clients that the prompt list has changed
// (Requires prompts.listChanged: true in server capabilities)
try await server.notify(PromptListChangedNotification.message())
```

### Completions

Servers can provide autocompletion suggestions for prompt and resource template arguments:

```swift
// Enable completions capability
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        completions: .init(),
        prompts: .init(listChanged: true)
    )
)

// Register a completion handler
await server.withMethodHandler(Complete.self) { params in
    // Get the argument being completed
    let argumentName = params.argument.name
    let currentValue = params.argument.value

    // Check which prompt or resource is being completed
    switch params.ref {
    case .prompt(let promptRef):
        // Provide completions for a prompt argument
        if promptRef.name == "code_review" && argumentName == "language" {
            // Simple prefix matching
            let allLanguages = ["python", "perl", "php", "javascript", "java", "swift"]
            let matches = allLanguages.filter { $0.hasPrefix(currentValue.lowercased()) }

            return .init(
                completion: .init(
                    values: Array(matches.prefix(100)),  // Max 100 items
                    total: matches.count,
                    hasMore: matches.count > 100
                )
            )
        }

    case .resource(let resourceRef):
        // Provide completions for a resource template argument
        if resourceRef.uri == "file:///{path}" && argumentName == "path" {
            // Return directory suggestions
            let suggestions = try getDirectoryCompletions(for: currentValue)
            return .init(
                completion: .init(
                    values: suggestions,
                    total: suggestions.count,
                    hasMore: false
                )
            )
        }
    }

    // No completions available
    return .init(completion: .init(values: [], total: 0, hasMore: false))
}
```

You can also use context from already-resolved arguments:

```swift
await server.withMethodHandler(Complete.self) { params in
    // Access context from previous argument completions
    if let context = params.context,
       let language = context.arguments["language"]?.stringValue {

        // Provide framework suggestions based on selected language
        if language == "python" {
            let frameworks = ["flask", "django", "fastapi", "tornado"]
            let matches = frameworks.filter {
                $0.hasPrefix(params.argument.value.lowercased())
            }
            return .init(
                completion: .init(values: matches, total: matches.count, hasMore: false)
            )
        }
    }

    return .init(completion: .init(values: [], total: 0, hasMore: false))
}
```

### Sampling

Servers can request LLM completions from clients through sampling. This enables agentic behaviors where servers can ask for AI assistance while maintaining human oversight.

```swift
// Enable sampling capability in server
let server = Server(
    name: "MyModelServer",
    version: "1.0.0",
    capabilities: .init(
        sampling: .init(),  // Enable sampling capability
        tools: .init(listChanged: true)
    )
)

// Request sampling from the connected client
do {
    let result = try await server.requestSampling(
        messages: [
            .user("Analyze this data and suggest next steps")
        ],
        systemPrompt: "You are a helpful data analyst",
        temperature: 0.7,
        maxTokens: 150
    )
    
    // Use the LLM completion in your server logic
    print("LLM suggested: \(result.content)")
    
} catch {
    print("Sampling request failed: \(error)")
}
```

Sampling enables powerful agentic workflows:

- **Decision-making**: Ask the LLM to choose between options
- **Content generation**: Request drafts for user approval
- **Data analysis**: Get AI insights on complex data
- **Multi-step reasoning**: Chain AI completions with tool calls

### Elicitations

Servers can request information from users through elicitation:

```swift
// Ask the user to provide some additional information
let schema = Elicitation.RequestSchema(
    title: "Additional Information Required",
    description: "Please provide the following details to continue",
    properties: [
        "name": .object([
            "type": .string("string"),
            "description": .string("Your full name")
        ]),
        "confirmed": .object([
            "type": .string("boolean"),
            "description": .string("Do you confirm the provided information?")
        ])
    ],
    required: ["name", "confirmed"]
)

let result = try await server.requestElicitation(
    message: "Some details are needed before proceeding",
    requestedSchema: schema
)

switch result.action {
case .accept:
    if let content = result.content {
        let name = content["name"]?.stringValue
        let confirmed = content["confirmed"]?.boolValue
        // Use the collected data...
    }
case .decline:
    throw MCPError.invalidRequest("User declined to provide information")
case .cancel:
    throw MCPError.invalidRequest("Operation canceled by user")
}
```

For URL-based elicitation (e.g., OAuth flows), use the URL overload:

```swift
let result = try await server.requestElicitation(
    message: "Please sign in to continue",
    url: "https://example.com/oauth/authorize?client_id=...",
    elicitationId: UUID().uuidString
)
```

Elicitation schemas support default values and enum constraints:

```swift
let configSchema = Elicitation.RequestSchema(
    title: "Deployment Configuration",
    properties: [
        "environment": .object([
            "type": .string("string"),
            "title": .string("Target Environment"),
            "enum": .array([.string("staging"), .string("production")]),
            "default": .string("staging")
        ]),
        "replicas": .object([
            "type": .string("integer"),
            "title": .string("Number of Replicas"),
            "minimum": .int(1),
            "maximum": .int(10),
            "default": .int(2)
        ])
    ],
    required: ["environment"]
)

let deployResult = try await server.requestElicitation(
    message: "Configure your deployment",
    requestedSchema: configSchema
)
```

For URL-based elicitation, send `ElicitationCompleteNotification` after the out-of-band flow finishes so the client knows the flow is done:

```swift
let elicitationId = UUID().uuidString
_ = try await server.requestElicitation(
    message: "Please authorize access",
    url: "https://example.com/oauth/authorize?...",
    elicitationId: elicitationId
)

// After the user completes the external flow, notify the client
try await server.notify(ElicitationCompleteNotification.message(.init(elicitationId: elicitationId)))
```

### Roots

Servers can request the list of filesystem roots that the client has exposed:

```swift
// Request roots from the connected client
// (requires the client to declare the roots capability)
let roots = try await server.listRoots()
for root in roots {
    print("Root: \(root.name ?? root.uri) at \(root.uri)")
}

// React to root list changes
await server.onNotification(RootsListChangedNotification.self) { _ in
    let updatedRoots = try await server.listRoots()
    print("Roots updated: \(updatedRoots.map { $0.uri })")
}
```

### Logging

Servers can send structured log messages to clients:

```swift
// Enable logging capability
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        logging: .init(),
        tools: .init(listChanged: true)
    )
)

// Send log messages at different severity levels
try await server.log(
    level: .info,
    logger: "database",
    data: Value.object([
        "message": .string("Database connected successfully"),
        "host": .string("localhost"),
        "port": .int(5432)
    ])
)

try await server.log(
    level: .error,
    logger: "api",
    data: Value.object([
        "message": .string("Request failed"),
        "statusCode": .int(500),
        "error": .string("Internal server error")
    ])
)

// You can also use codable types directly
struct ErrorLog: Codable {
    let message: String
    let code: Int
    let timestamp: String
}

let errorLog = ErrorLog(
    message: "Operation failed",
    code: 500,
    timestamp: ISO8601DateFormatter().string(from: Date())
)

try await server.log(level: .error, logger: "operations", data: errorLog)
```

Clients can control which log levels they receive:

```swift
// Register a handler for client's logging level preferences
await server.withMethodHandler(SetLoggingLevel.self) { params in
    let minimumLevel = params.level

    // Store the client's preference and filter log messages accordingly
    // (Implementation depends on your server architecture)
    storeLogLevel(minimumLevel)

    return Empty()
}
```

### Progress Tracking

Servers can send incremental progress notifications during long-running tool calls by reading the `progressToken` from the request metadata and sending `ProgressNotification` messages:

```swift
await server.withMethodHandler(CallTool.self) { params in
    // Read the progress token from request metadata
    guard let token = params._meta?.progressToken else {
        // No progress token provided — run without reporting progress
        return .init(content: [.text("Done")], isError: false)
    }

    // Report initial progress
    let started = ProgressNotification.message(
        .init(progressToken: token, progress: 0, total: 100)
    )
    try await server.notify(started)

    // ... do work ...

    // Report intermediate progress
    let halfway = ProgressNotification.message(
        .init(progressToken: token, progress: 50, total: 100, message: "Halfway there")
    )
    try await server.notify(halfway)

    // ... do more work ...

    // Report completion
    let done = ProgressNotification.message(
        .init(progressToken: token, progress: 100, total: 100, message: "Complete")
    )
    try await server.notify(done)

    return .init(content: [.text("Done")], isError: false)
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
    if clientCapabilities.sampling == nil {
        print("Client does not support sampling")
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
    )
)

// Add handlers directly to the server
await server.withMethodHandler(ListTools.self) { _ in
    // Your implementation
    return .init(tools: [
        Tool(name: "example", description: "An example tool")
    ])
}

await server.withMethodHandler(CallTool.self) { params in
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
`[ServiceLifecycle](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/documentation/servicelifecycle)`
also supports service dependencies, conditional services,
and other useful features.

## Transports

MCP's transport layer handles communication between clients and servers.
The Swift SDK provides multiple built-in transports:


| Transport | Description | Platforms | Best for |
| --------- | ----------- | --------- | -------- |
| [`StdioTransport`](/Sources/MCP/Base/Transports/StdioTransport.swift) | Implements [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio) using standard input/output streams | Apple platforms, Linux with glibc | Local subprocesses, CLI tools |
| [`HTTPClientTransport`](/Sources/MCP/Base/Transports/HTTPClientTransport.swift) | Implements [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http) using Foundation's URL Loading System | All platforms with Foundation | Remote servers, web applications |
| [`StatelessHTTPServerTransport`](/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift) | HTTP server transport with simple request-response semantics; no session management or SSE streaming | All platforms with Foundation | Simple HTTP servers, serverless/edge functions |
| [`StatefulHTTPServerTransport`](/Sources/MCP/Base/Transports/HTTPServer/StatefulHTTPServerTransport.swift) | HTTP server transport with full session management and SSE streaming for server-initiated messages | All platforms with Foundation | Full-featured HTTP servers, streaming notifications |
| [`InMemoryTransport`](/Sources/MCP/Base/Transports/InMemoryTransport.swift) | Custom in-memory transport for direct communication within the same process | All platforms | Testing, debugging, same-process client-server communication |
| [`NetworkTransport`](/Sources/MCP/Base/Transports/NetworkTransport.swift) | Custom transport using Apple's Network framework for TCP/UDP connections | Apple platforms only | Low-level networking, custom protocols |


### HTTP Server Transports

Both server transports are framework-agnostic: you pass incoming `HTTPRequest` values and receive `HTTPResponse` values to convert to your HTTP framework's native types.

#### Stateful (with SSE streaming)

`StatefulHTTPServerTransport` supports full session management and Server-Sent Events for server-initiated messages such as resource update and tool list change notifications:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        resources: .init(subscribe: true, listChanged: true),
        tools: .init(listChanged: true)
    )
)

let transport = StatefulHTTPServerTransport()
try await server.start(transport: transport)

// In your HTTP framework handler:
// let httpResponse = await transport.handleRequest(httpRequest)
// Convert httpResponse to your framework's response type and return it
```

#### Stateless (request-response only)

`StatelessHTTPServerTransport` provides simple request-response semantics with no session management or SSE streaming. Use this for serverless environments and edge functions:

```swift
let transport = StatelessHTTPServerTransport()
try await server.start(transport: transport)

// In your HTTP framework handler:
// let httpResponse = await transport.handleRequest(httpRequest)
```

> [!NOTE]
> The legacy SSE transport from the 2024-11-05 MCP specification (dedicated `GET /sse` and `POST /messages` endpoints) is not available as a separate transport type. Use `HTTPClientTransport` with `streaming: true` (the default) and `StatefulHTTPServerTransport` for SSE-capable Streamable HTTP connections.

### Stdio Server Transport

For local process communication, use `StdioTransport` on the server. The server reads MCP requests from standard input and writes responses to standard output:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

let transport = StdioTransport()
try await server.start(transport: transport)
// The process now handles MCP messages via stdin/stdout
```

### Protocol Version Negotiation

The SDK supports multiple protocol versions and negotiates automatically during the connection handshake. The client sends `Version.latest` in the `initialize` request; if the server responds with an older version, both sides use that version for the session:

```swift
// Versions supported by this SDK (newest to oldest):
// "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"
// Version.latest == "2025-11-25"

// The negotiated version is available from the initialization result:
let result = try await client.connect(transport: transport)
print("Negotiated protocol version: \(result.protocolVersion)")
// e.g. "2025-06-18" when connecting to an older server
```

### Custom Transport Implementation

You can implement a custom transport by conforming to the `Transport` protocol:

```swift
import MCP
import Foundation

public actor MyCustomTransport: Transport {
    public nonisolated let logger: Logger
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, any Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "my.custom.transport")

        var continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation!
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

    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> {
        return messageStream
    }
}
```

## Authentication

`HTTPClientTransport` supports OAuth 2.1 Bearer token authorization per the
[MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).
When a server returns `401 Unauthorized` or `403 Forbidden`, the transport automatically:

1. Discovers Protected Resource Metadata (RFC 9728) at `/.well-known/oauth-protected-resource`
2. Discovers Authorization Server Metadata (RFC 8414 / OIDC Discovery 1.0)
3. Registers the client dynamically (RFC 7591) if needed
4. Acquires a Bearer token using the configured grant flow (PKCE enforced)
5. Retries the original request with the token attached

Authorization is opt-in and disabled by default.
Pass an `OAuthAuthorizer` to `HTTPClientTransport(authorizer:)` to enable it.

### Client: Client Credentials Flow

Machine-to-machine authentication using a pre-shared client secret:

```swift
let config = OAuthConfiguration(
    grantType: .clientCredentials,
    authentication: .clientSecretBasic(clientID: "my-app", clientSecret: "s3cr3t")
)
let authorizer = OAuthAuthorizer(configuration: config)
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    authorizer: authorizer
)
let client = Client(name: "MyClient", version: "1.0.0")
try await client.connect(transport: transport)
```

### Client: Authorization Code Flow

Interactive, browser-based authentication with PKCE.
Implement `OAuthAuthorizationDelegate` to open the authorization URL and capture the redirect:

```swift
struct MyAuthDelegate: OAuthAuthorizationDelegate {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        // Open the URL in a browser/webview and wait for the callback redirect URI.
        // The returned URL must include the authorization code and state parameters.
        return try await openBrowserAndWaitForCallback(url)
    }
}

let config = OAuthConfiguration(
    grantType: .authorizationCode,
    authentication: .none(clientID: "my-app"),
    authorizationDelegate: MyAuthDelegate()
)
let authorizer = OAuthAuthorizer(configuration: config)
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    authorizer: authorizer
)
```

### Client: Custom Token Provider

Supply an externally acquired token (e.g., from a system credential store) via `accessTokenProvider`.
The SDK calls this closure after discovery completes. Return `nil` to fall back to the configured grant flow:

```swift
let config = OAuthConfiguration(
    grantType: .clientCredentials,
    authentication: .none(clientID: "my-app"),
    accessTokenProvider: { context, session in
        // context contains the discovered resource URI, token endpoint, scopes, etc.
        return try await KeychainTokenStore.shared.loadToken(for: context.resource)
    }
)
```

### Client: Custom Token Storage

By default, tokens are stored in memory and lost when the process exits.
To persist tokens across sessions, implement `TokenStorage` and pass it to `OAuthAuthorizer`:

```swift
final class KeychainTokenStorage: TokenStorage {
    func save(_ token: OAuthAccessToken) {
        // Encode and store token.value in the system Keychain
    }

    func load() -> OAuthAccessToken? {
        // Load and decode token from the Keychain
        return nil
    }

    func clear() {
        // Delete from the Keychain
    }
}

let authorizer = OAuthAuthorizer(
    configuration: config,
    tokenStorage: KeychainTokenStorage()
)
```

### Client: `private_key_jwt` Authentication

Authenticate to the token endpoint using an asymmetric key (RFC 7523).
The SDK provides a built-in ES256 helper for P-256 keys:

```swift
let config = OAuthConfiguration(
    grantType: .clientCredentials,
    authentication: .privateKeyJWT(
        clientID: "my-app",
        assertionFactory: { tokenEndpoint, clientID in
            try OAuthConfiguration.makePrivateKeyJWTAssertion(
                clientID: clientID,
                tokenEndpoint: tokenEndpoint,
                privateKeyPEM: myEC256PrivateKeyPEM  // PEM-encoded P-256 private key
            )
        }
    )
)
```

### Client: Endpoint Overrides

Skip automatic discovery by providing explicit endpoint URLs.
Useful when the server does not publish well-known metadata documents:

```swift
let config = OAuthConfiguration(
    grantType: .clientCredentials,
    authentication: .clientSecretBasic(clientID: "app", clientSecret: "secret"),
    endpointOverrides: OAuthConfiguration.EndpointOverrides(
        tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!
    )
)
```

### Server: Serving Protected Resource Metadata

Per the MCP authorization specification, servers **MUST** serve Protected Resource Metadata
at `/.well-known/oauth-protected-resource` so clients can discover authorization server endpoints.

Use `ProtectedResourceMetadataValidator` as the first validator in your pipeline so that
unauthenticated discovery requests are handled before the bearer token check:

```swift
let metadata = OAuthProtectedResourceServerMetadata(
    resource: "https://api.example.com",
    authorizationServers: [URL(string: "https://auth.example.com")!],
    scopesSupported: ["read", "write"]
)
let metadataValidator = ProtectedResourceMetadataValidator(metadata: metadata)
```

### Server: Validating Bearer Tokens

Use `BearerTokenValidator` to authenticate incoming requests.
Your `tokenValidator` closure **MUST** verify the token's `aud` claim to prevent
token substitution attacks where a token intended for another resource is replayed against your server:

```swift
let resourceIdentifier = URL(string: "https://api.example.com")!

let bearerValidator = BearerTokenValidator(
    resourceMetadataURL: URL(string: "https://api.example.com/.well-known/oauth-protected-resource")!,
    resourceIdentifier: resourceIdentifier,
    tokenValidator: { token, request, context in
        guard let claims = try? verifyAndDecodeJWT(token) else {
            return .invalidToken(errorDescription: "Token verification failed")
        }
        // Pass audience and expiry to BearerTokenInfo; the SDK validates the
        // audience claim against resourceIdentifier automatically.
        return .valid(BearerTokenInfo(
            audience: claims.audience,
            expiresAt: claims.expiresAt
        ))
    }
)

let pipeline = StandardValidationPipeline(validators: [
    metadataValidator,            // serves /.well-known/oauth-protected-resource unauthenticated
    bearerValidator,              // validates Bearer tokens on all other requests
    AcceptHeaderValidator(mode: .sseRequired),
    ContentTypeValidator(),
    SessionValidator(),
])
```

## Platform Availability

The Swift SDK has the following platform requirements:


| Platform           | Minimum Version                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------- |
| macOS              | 13.0+                                                                                    |
| iOS / Mac Catalyst | 16.0+                                                                                    |
| watchOS            | 9.0+                                                                                     |
| tvOS               | 16.0+                                                                                    |
| visionOS           | 1.0+                                                                                     |
| Linux              | Distributions with `glibc` or `musl`, including Ubuntu, Debian, Fedora, and Alpine Linux |


While the core library works on any platform supporting Swift 6
(including Linux), running a client or server requires a compatible transport.

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
let client = Client(name: "MyApp", version: "1.0.0")

// Pass to transport
let transport = StdioTransport(logger: logger)
```

## Additional Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [Protocol Documentation](https://modelcontextprotocol.io)
- [GitHub Repository](https://github.com/modelcontextprotocol/swift-sdk)

## Changelog

This project follows [Semantic Versioning](https://semver.org/).
For pre-1.0 releases,
minor version increments (0.X.0) may contain breaking changes.

For details about changes in each release,
see the [GitHub Releases page](https://github.com/modelcontextprotocol/swift-sdk/releases).

## License

This project is licensed under Apache 2.0 for new contributions, with existing code under MIT. See the [LICENSE](LICENSE) file for details.

[mcp]: https://modelcontextprotocol.io
[mcp-spec-2025-11-25]: https://modelcontextprotocol.io/specification/2025-11-25
