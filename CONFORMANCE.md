# MCP Conformance Testing

This document describes how to run MCP conformance tests for the Swift SDK.

## Overview

The Swift SDK includes three conformance test executables:

- **`mcp-everything-server`**: A comprehensive MCP server implementing all protocol features (stdio transport)
- **`mcp-http-server`**: HTTP server wrapper for conformance testing (HTTP transport) ✅
- **`mcp-everything-client`**: A scenario-based HTTP client that can test MCP server implementations

### Transport Support

- **Client**: Uses `HTTPClientTransport` - compatible with the official conformance framework ✅
- **Server (stdio)**: Uses `StdioTransport` - works for CLI testing but not HTTP conformance framework ⚠️
- **Server (HTTP)**: Uses HTTP bridge transport - fully compatible with the official conformance framework ✅

These executables are designed to work with the official [MCP Conformance Test Framework](https://github.com/modelcontextprotocol/conformance).

## Building

Build the conformance executables:

```bash
swift build
```

The executables will be located at:
- `.build/debug/mcp-everything-server` (stdio transport)
- `.build/debug/mcp-http-server` (HTTP transport)
- `.build/debug/mcp-everything-client`

## Running Conformance Tests

### Prerequisites

Install the conformance test runner:

```bash
npm install -g @modelcontextprotocol/conformance
```

### Testing the Client

The client is scenario-based, uses HTTP transport, and reads the scenario name from the `MCP_CONFORMANCE_SCENARIO` environment variable.

#### Fully Implemented Scenarios ✅

- `initialize`: Basic connection and initialization
- `tools_call`: Tool listing and invocation

#### Not Implemented (Use Default Handler) ⚠️

The following 21 scenarios will use a default handler that attempts basic connection but will fail scenario-specific checks:

- `elicitation-sep1034-client-defaults`: Elicitation with client defaults
- `sse-retry`: SSE reconnection testing
- **Auth scenarios** (19 total): Require OAuth/client credentials flows
  - `auth/metadata-default`, `auth/metadata-var1`, `auth/metadata-var2`, `auth/metadata-var3`
  - `auth/basic-cimd`, `auth/2025-03-26-oauth-metadata-backcompat`, `auth/2025-03-26-oauth-endpoint-fallback`
  - `auth/scope-from-www-authenticate`, `auth/scope-from-scopes-supported`, `auth/scope-omitted-when-undefined`
  - `auth/scope-step-up`, `auth/scope-retry-limit`
  - `auth/token-endpoint-auth-basic`, `auth/token-endpoint-auth-post`, `auth/token-endpoint-auth-none`
  - `auth/resource-mismatch`, `auth/pre-registration`
  - `auth/client-credentials-jwt`, `auth/client-credentials-basic`

Run conformance tests against the Swift client:

```bash
npx @modelcontextprotocol/conformance client \
  --command ".build/debug/mcp-everything-client" \
  --scenario initialize
```

This will:
1. Start a test HTTP server (by the conformance framework)
2. Run your client with the scenario
3. Pass the server URL as the last argument
4. Save results to `results/initialize-<timestamp>/`

### Testing the Server

#### HTTP Server (Recommended for Conformance Tests) ✅

The HTTP server is fully compatible with the official conformance framework:

```bash
# Start the HTTP server
.build/debug/mcp-http-server --port 3001 &

# Run conformance tests
npx @modelcontextprotocol/conformance server \
  --url http://localhost:3001/mcp \
  --suite active

# Stop the server when done
killall mcp-http-server
```

You can customize the port:

```bash
.build/debug/mcp-http-server --port 8080
```

#### Stdio Server (Manual Testing Only) ⚠️

For manual testing with the stdio server:

```bash
# Start the server
.build/debug/mcp-everything-server

# In another terminal, test with JSON-RPC over stdin
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | .build/debug/mcp-everything-server
```

Note: The stdio server cannot be used with the HTTP-based conformance framework.

## Server Features

The `mcp-everything-server` implements:

### Tools
- `test_simple_text`: Simple text content response
- `test_image_content`: Image content (base64 encoded PNG)
- `test_audio_content`: Audio content (base64 encoded WAV)
- `test_embedded_resource`: Embedded resource in tool response
- `test_multiple_content_types`: Multiple content types in single response
- `test_error_handling`: Error response handling
- `test_logging`: Logging capabilities
- `test_progress`: Progress notifications
- `add_numbers`: Basic arithmetic tool for testing

### Resources
- Static text resource (`test://static-text`)
- Static binary resource (`test://static-binary`)
- Watched resource with subscriptions (`test://watched`)
- Template resource with URI parameters (`test://template/{id}`)

### Prompts
- Simple prompt without arguments (`simple_prompt`)
- Prompt with arguments (`prompt_with_args`)
- Prompt with embedded resources (`prompt_with_resource`)

## Integration with GitHub Actions

You can integrate conformance tests into your GitHub Actions workflow:

```yaml
name: Conformance Tests

on: [push, pull_request]

jobs:
  conformance:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build conformance executables
        run: swift build

      - name: Install conformance tool
        run: npm install -g @modelcontextprotocol/conformance

      - name: Start HTTP server
        run: .build/debug/mcp-http-server --port 3001 &

      - name: Wait for server to start
        run: sleep 2

      - name: Run server conformance tests
        run: |
          npx @modelcontextprotocol/conformance server \
            --url http://localhost:3001/mcp \
            --suite active

      - name: Run client conformance tests
        run: |
          npx @modelcontextprotocol/conformance client \
            --command ".build/debug/mcp-everything-client" \
            --scenario initialize
```

## Development

### Adding New Scenarios

To add a new client scenario:

1. Add a handler function in `Sources/MCPConformance/Client/main.swift`
2. Register it in the `scenarioHandlers` dictionary
3. Update this documentation

### Adding Server Features

To add new server capabilities:

1. Update the server in `Sources/MCPConformance/Server/main.swift`
2. Register tools, resources, or prompts in `createConformanceServer()`
3. Update this documentation

## Troubleshooting

### Server doesn't start

Check that stdio transport is working:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | .build/debug/mcp-everything-server
```

### Client scenarios not working

Verify the scenario name is set:
```bash
echo $MCP_CONFORMANCE_SCENARIO
```

## References

- [MCP Specification](https://modelcontextprotocol.io/specification)
- [Conformance Test Framework](https://github.com/modelcontextprotocol/conformance)
- [SDK Integration Guide](https://github.com/modelcontextprotocol/conformance/blob/main/SDK_INTEGRATION.md)
