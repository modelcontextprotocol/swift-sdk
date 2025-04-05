# MCP Swift SDK

Swift implementation of the [Model Context Protocol][mcp] (MCP).

## Requirements

- Swift 6.0+ / Xcode 16+
- macOS 13.0+
- iOS / Mac Catalyst 16.0+
- watchOS 9.0+
- tvOS 16.0+
- visionOS 1.0+

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0")
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

## Examples

This repository includes an example server demonstrating how to use the Swift MCP SDK.

### Echo Server

Located in the `Example` directory, this simple server demonstrates:
*   Setting up a basic MCP server.
*   Defining and registering a custom tool (`swift_echo`).
*   Handling `ListTools` and `CallTool` requests.
*   Using `StdioTransport` for communication.
*   Detailed logging to stderr.

**Running the Echo Server:**

1.  Navigate to the example directory:
    ```bash
    cd Example 
    ```
2.  Build the server:
    ```bash
    swift build -c release 
    ```
    This will create the executable at `.build/release/EchoServer`. Note the full path to this executable.

3.  **Configure Claude Desktop:**
    To make this server available as a tool provider in Claude Desktop, you need to add it to your Claude Desktop configuration file (`claude_desktop_config.json`). The location of this file varies by operating system.

    Add an entry like the following to the `mcpServers` object in your `claude_desktop_config.json`, replacing `/PATH/TO/YOUR/SERVER/` with the actual absolute path to the `swift-sdk` directory on your system:

    ```json
    {
        "mcpServers": {
            // ... other servers maybe ...
            "swift_echo_example": {
                "command": "/PATH/TO/YOUR/SERVER/Example/.build/release/dummy-mcp-server"
            }
            // ... other servers maybe ...
        }
    }
    ```
    *   `swift_echo_example`: This is the name you'll refer to the server by within Claude Desktop (you can change this).
    *   `command`: This **must** be the absolute path to the compiled `EchoServer` executable you built in the previous step.

4.  **Restart Claude Desktop:** After saving the changes to `claude_desktop_config.json`, restart Claude Desktop for the new server configuration to be loaded. The `swift_echo` tool should then be available.

The server will be started automatically by Claude Desktop when needed and will communicate over standard input/output, printing detailed logs to standard error (which might be captured by Claude Desktop's logs).

## Changelog

This project follows [Semantic Versioning](https://semver.org/). 
For pre-1.0 releases, minor version increments (0.X.0) may contain breaking changes.

For details about changes in each release, 
see the [GitHub Releases page](https://github.com/modelcontextprotocol/swift-sdk/releases).

## License

This project is licensed under the MIT License.

[mcp]: https://modelcontextprotocol.io
