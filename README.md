# MCP Swift SDK

Swift implementation of the [Model Context Protocol][mcp] (MCP).

## Requirements

- Swift 6.0+ (Xcode 16+)

### Supported Platforms

| Platform | Minimum Version |
|----------|----------------|
| macOS | 13.0+ |
| iOS / Mac Catalyst | 16.0+ |
| watchOS | 9.0+ |
| tvOS | 16.0+ |
| visionOS | 1.0+ |
| Linux | ✓ [^1] |

[^1]: Linux support includes glibc-based distributions (Ubuntu, Debian, Fedora, CentOS, RHEL) and musl-based distributions (Alpine Linux).

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1")
]
```

## Usage

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
```

### Basic Server Setup

```swift
import MCP

// Initialize the server with capabilities
let server = Server(
    name: "MyServer", 
    version: "1.0.0",
    capabilities: .init(
        prompts: .init(),
        resources: .init(
            subscribe: true
        ),
        tools: .init()
    )
)

// Create transport and start server
let transport = StdioTransport()
try await server.start(transport: transport)

// Register method handlers
server.withMethodHandler(ReadResource.self) { params in
    // Handle resource read request
    let uri = params.uri
    let content = [Resource.Content.text("Example content")]
    return .init(contents: content)
}

// Register notification handlers
server.onNotification(ResourceUpdatedNotification.self) { message in
    // Handle resource update notification
}

// Stop the server when done
await server.stop()
```

### Working with Tools

```swift
// List available tools
let tools = try await client.listTools()

// Call a tool
let (content, isError) = try await client.callTool(
    name: "example-tool", 
    arguments: ["key": "value"]
)

// Handle tool content
for item in content {
    switch item {
    case .text(let text):
        print(text)
    case .image(let data, let mimeType, let metadata):
        // Handle image data
    }
}
```

### Working with Resources

```swift
// List available resources
let (resources, nextCursor) = try await client.listResources()

// Read a resource
let contents = try await client.readResource(uri: "resource://example")

// Subscribe to resource updates
try await client.subscribeToResource(uri: "resource://example")

// Handle resource updates
await client.onNotification(ResourceUpdatedNotification.self) { message in
    let uri = message.params.uri
    let content = message.params.content
    // Handle the update
}
```

### Working with Prompts

```swift
// List available prompts
let (prompts, nextCursor) = try await client.listPrompts()

// Get a prompt with arguments
let (description, messages) = try await client.getPrompt(
    name: "example-prompt",
    arguments: ["key": "value"]
)
```

## Changelog

This project follows [Semantic Versioning](https://semver.org/). 
For pre-1.0 releases, minor version increments (0.X.0) may contain breaking changes.

For details about changes in each release, 
see the [GitHub Releases page](https://github.com/modelcontextprotocol/swift-sdk/releases).

## License

This project is licensed under the MIT License.

[mcp]: https://modelcontextprotocol.io
