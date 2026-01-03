/// Vapor MCP Server Example
///
/// This example demonstrates how to integrate an MCP server with the Vapor web framework.
/// It follows the TypeScript SDK's pattern from `examples/server/src/simpleStreamableHttp.ts`.
///
/// ## Architecture
///
/// - ONE `Server` instance is shared across all HTTP clients
/// - Each client session gets its own `HTTPServerTransport`
/// - The `SessionManager` actor manages transport instances by session ID
/// - Request capture in the Server ensures responses route to the correct client
///
/// ## Endpoints
///
/// - `POST /mcp` - Handle JSON-RPC requests (initialize, tools/list, tools/call, etc.)
/// - `GET /mcp` - Server-Sent Events stream for server-initiated notifications
/// - `DELETE /mcp` - Terminate a session
///
/// ## Running
///
/// ```bash
/// cd Examples/VaporIntegration
/// swift run
/// ```
///
/// The server will listen on http://localhost:8080/mcp

import Foundation
import MCP
import Vapor

// MARK: - Server Setup

/// Create the MCP server (ONE instance for all clients)
let mcpServer = MCP.Server(
    name: "vapor-mcp-example",
    version: "1.0.0",
    capabilities: .init(tools: .init())
)

/// Register tool handlers
func setUpToolHandlers() async {
    // Register tool list handler
    await mcpServer.withRequestHandler(ListTools.self) { _, _ in
        ListTools.Result(tools: [
            Tool(
                name: "echo",
                description: "Echoes back the input message",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "message": ["type": "string", "description": "The message to echo"]
                    ],
                    "required": ["message"]
                ]
            ),
            Tool(
                name: "add",
                description: "Adds two numbers",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "a": ["type": "number", "description": "First number"],
                        "b": ["type": "number", "description": "Second number"]
                    ],
                    "required": ["a", "b"]
                ]
            ),
        ])
    }

    // Register tool call handler
    await mcpServer.withRequestHandler(CallTool.self) { request, _ in
        switch request.name {
        case "echo":
            let message = request.arguments?["message"]?.stringValue ?? "No message provided"
            return CallTool.Result(content: [.text(message)])

        case "add":
            let a = request.arguments?["a"]?.doubleValue ?? 0
            let b = request.arguments?["b"]?.doubleValue ?? 0
            return CallTool.Result(content: [.text("Result: \(a + b)")])

        default:
            return CallTool.Result(content: [.text("Unknown tool: \(request.name)")], isError: true)
        }
    }
}

// MARK: - Session Management

/// Session manager for tracking active sessions
let sessionManager = SessionManager(maxSessions: 100)

// MARK: - HTTP Handlers

/// Handle POST /mcp requests
func handlePost(_ req: Vapor.Request) async throws -> Vapor.Response {
    // Get session ID from header (if present)
    let sessionId = req.headers.first(name: HTTPHeader.sessionId)

    // Read request body
    guard let bodyData = req.body.data else {
        throw Abort(.badRequest, reason: "Missing request body")
    }
    let data = Data(buffer: bodyData)

    // Check if this is an initialize request
    let isInitializeRequest = String(data: data, encoding: .utf8)?.contains("\"method\":\"initialize\"") ?? false

    // Get or create transport
    let transport: HTTPServerTransport

    if let sid = sessionId, let existing = await sessionManager.transport(forSessionId: sid) {
        // Reuse existing transport for this session
        transport = existing
    } else if isInitializeRequest {
        // Check capacity
        guard await sessionManager.canAddSession() else {
            throw Abort(.serviceUnavailable, reason: "Server at capacity")
        }

        // Generate session ID upfront so we can store the transport
        let newSessionId = UUID().uuidString

        // Create new transport with session callbacks
        let newTransport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { newSessionId },
                onSessionInitialized: { sessionId in
                    req.logger.info("Session initialized: \(sessionId)")
                },
                onSessionClosed: { sessionId in
                    await sessionManager.remove(sessionId)
                    req.logger.info("Session closed: \(sessionId)")
                }
            )
        )

        // Store the transport immediately (we know the session ID)
        await sessionManager.store(newTransport, forSessionId: newSessionId)
        transport = newTransport

        // Connect transport to server
        try await mcpServer.start(transport: transport)
    } else if sessionId != nil {
        // Client sent a session ID that no longer exists
        throw Abort(.notFound, reason: "Session expired. Try reconnecting.")
    } else {
        // No session ID and not an initialize request
        throw Abort(.badRequest, reason: "Missing \(HTTPHeader.sessionId) header")
    }

    // Create the MCP HTTP request for the transport
    let mcpRequest = MCP.HTTPRequest(
        method: "POST",
        headers: extractHeaders(from: req),
        body: data
    )

    // Handle the request
    let mcpResponse = await transport.handleRequest(mcpRequest)

    // Build response
    return buildVaporResponse(from: mcpResponse, for: req)
}

/// Handle GET /mcp requests (SSE stream for server-initiated notifications)
func handleGet(_ req: Vapor.Request) async throws -> Vapor.Response {
    guard let sessionId = req.headers.first(name: HTTPHeader.sessionId),
        let transport = await sessionManager.transport(forSessionId: sessionId)
    else {
        throw Abort(.badRequest, reason: "Invalid or missing session ID")
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "GET",
        headers: extractHeaders(from: req)
    )

    let mcpResponse = await transport.handleRequest(mcpRequest)

    return buildVaporResponse(from: mcpResponse, for: req)
}

/// Handle DELETE /mcp requests (session termination)
func handleDelete(_ req: Vapor.Request) async throws -> Vapor.Response {
    guard let sessionId = req.headers.first(name: HTTPHeader.sessionId),
        let transport = await sessionManager.transport(forSessionId: sessionId)
    else {
        throw Abort(.notFound, reason: "Session not found")
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "DELETE",
        headers: extractHeaders(from: req)
    )

    let mcpResponse = await transport.handleRequest(mcpRequest)

    return Vapor.Response(status: .init(statusCode: mcpResponse.statusCode))
}

// MARK: - Helper Functions

/// Extract headers from Vapor request to dictionary
func extractHeaders(from req: Vapor.Request) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in req.headers {
        headers[name] = value
    }
    return headers
}

/// Build a Vapor Response from an MCP HTTPResponse
func buildVaporResponse(from mcpResponse: MCP.HTTPResponse, for req: Vapor.Request) -> Vapor.Response {
    var headers = HTTPHeaders()
    for (key, value) in mcpResponse.headers {
        headers.add(name: key, value: value)
    }

    let status = HTTPResponseStatus(statusCode: mcpResponse.statusCode)

    if let stream = mcpResponse.stream {
        // SSE response - create streaming body
        let response = Vapor.Response(status: status, headers: headers)
        response.body = .init(asyncStream: { writer in
            do {
                for try await data in stream {
                    try await writer.write(.buffer(.init(data: data)))
                }
                try await writer.write(.end)
            } catch {
                req.logger.error("SSE stream error: \(error)")
            }
        })
        return response
    } else if let body = mcpResponse.body {
        // JSON response
        return Vapor.Response(
            status: status,
            headers: headers,
            body: .init(data: body)
        )
    } else {
        // No content (e.g., 202 Accepted for notifications)
        return Vapor.Response(status: status, headers: headers)
    }
}

// MARK: - Main

@main
struct VaporMCPExample {
    static func main() async throws {
        // Set up tool handlers
        await setUpToolHandlers()

        // Create Vapor application
        let env = try Environment.detect()
        let app = try await Application.make(env)

        // Configure routes
        app.post("mcp", use: handlePost)
        app.get("mcp", use: handleGet)
        app.delete("mcp", use: handleDelete)

        // Health check
        app.get("health") { _ in
            "OK"
        }

        app.logger.info("Starting MCP server on http://localhost:8080/mcp")
        app.logger.info("Available tools: echo, add")

        try await app.execute()
        try await app.asyncShutdown()
    }
}
