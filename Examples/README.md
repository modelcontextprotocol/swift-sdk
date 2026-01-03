# MCP Swift SDK Examples

This directory contains example integrations showing how to build HTTP-based MCP servers with popular Swift web frameworks.

## Available Examples

### [HummingbirdIntegration](./HummingbirdIntegration)

Integration with [Hummingbird](https://github.com/hummingbird-project/hummingbird), a lightweight, flexible Swift web framework.

```bash
cd HummingbirdIntegration
swift run
# Server starts on http://localhost:3000/mcp
```

### [VaporIntegration](./VaporIntegration)

Integration with [Vapor](https://vapor.codes/), a popular full-featured Swift web framework.

```bash
cd VaporIntegration
swift run
# Server starts on http://localhost:8080/mcp
```

## Architecture Pattern

Both examples follow the same architecture pattern from the TypeScript SDK:

1. **One Server instance** is shared across all HTTP clients
2. **Each client session** gets its own `HTTPServerTransport`
3. **SessionManager** tracks active transports by session ID
4. **Request capture** ensures responses route to the correct client

```
                    ┌─────────────────────────────┐
                    │     MCP Server (shared)     │
                    │   - Tool handlers           │
                    │   - Resource handlers       │
                    └─────────────┬───────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│  Transport A  │       │  Transport B  │       │  Transport C  │
│  (session-1)  │       │  (session-2)  │       │  (session-3)  │
└───────┬───────┘       └───────┬───────┘       └───────┬───────┘
        │                       │                       │
        ▼                       ▼                       ▼
    Client A                Client B                Client C
```

## HTTP Endpoints

Both examples implement the standard MCP HTTP endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp` | POST | Handle JSON-RPC requests (initialize, tools/list, tools/call, etc.) |
| `/mcp` | GET | Server-Sent Events stream for server-initiated notifications |
| `/mcp` | DELETE | Terminate a session |
| `/health` | GET | Health check endpoint |

## Testing with curl

### Initialize a session

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "id": "1",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "curl-test", "version": "1.0"}
    }
  }'
```

Save the `Mcp-Session-Id` header from the response for subsequent requests.

### List tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2024-11-05" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": "2"}'
```

### Call a tool

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2024-11-05" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": "3",
    "params": {
      "name": "echo",
      "arguments": {"message": "Hello, MCP!"}
    }
  }'
```

### Terminate session

```bash
curl -X DELETE http://localhost:3000/mcp \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2024-11-05"
```

## Key Components

### SessionManager

The `SessionManager` actor provides thread-safe session storage:

```swift
let sessionManager = SessionManager(maxSessions: 100)

// Store a transport
await sessionManager.store(transport, forSessionId: sessionId)

// Get a transport
if let transport = await sessionManager.transport(forSessionId: sessionId) {
    // Use transport
}

// Remove a transport
await sessionManager.remove(sessionId)

// Cleanup stale sessions
await sessionManager.cleanupStaleSessions(olderThan: .seconds(3600))
```

### HTTPServerTransport

The transport handles HTTP request/response multiplexing:

```swift
let transport = HTTPServerTransport(
    options: .init(
        sessionIdGenerator: { UUID().uuidString },
        onSessionInitialized: { sessionId in
            // Called when session is initialized
            await sessionManager.store(transport, forSessionId: sessionId)
        },
        onSessionClosed: { sessionId in
            // Called when session is terminated (DELETE request)
            await sessionManager.remove(sessionId)
        }
    )
)
```

## Stateless Mode

For simpler deployments that don't need session persistence, you can run in stateless mode by omitting the `sessionIdGenerator`:

```swift
// Stateless mode - no session tracking
let transport = HTTPServerTransport()
```

In stateless mode:
- No `Mcp-Session-Id` header is returned or required
- Each request is independent
- Server-initiated notifications are not supported (no GET endpoint)

## Production Considerations

1. **Session cleanup**: Implement periodic cleanup of stale sessions
2. **Connection limits**: Set `maxSessions` to prevent resource exhaustion
3. **Load balancing**: Use sticky sessions or shared session storage
4. **TLS**: Always use HTTPS in production
5. **Authentication**: Add authentication middleware as needed
