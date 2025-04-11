# Basic Stdio Example

This is a basic example demonstrating how to create a simple server that communicates over standard input/output (stdio) using the Model Context Protocol Swift SDK. This setup is compatible with applications like Claude Desktop.

## Getting Started

https://github.com/user-attachments/assets/8e790235-a34c-4358-981d-4d4b5e91488f

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
    *   `command`: This **must** be the absolute path to the compiled `EchoServer` executable you built in the previous step.https://github.com/modelcontextprotocol/swift-sdk/pull/55#issuecomment-2781042026
