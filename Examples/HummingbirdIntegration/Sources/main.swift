/// Hummingbird MCP Server Example
///
/// This example demonstrates how to integrate an MCP server with the Hummingbird web framework.
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
/// cd Examples/HummingbirdIntegration
/// swift run
/// ```
///
/// The server will listen on http://localhost:3000/mcp

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCP

// MARK: - Server Setup

/// Create the MCP server (ONE instance for all clients)
let mcpServer = MCP.Server(
    name: "hummingbird-mcp-example",
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

/// Logger for the example
let logger = Logger(label: "mcp.example.hummingbird")

// MARK: - Request Context

struct MCPRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        self.coreContext = .init(source: source)
    }
}

// MARK: - HTTP Handlers

/// Handle POST /mcp requests
func handlePost(request: Request, context: MCPRequestContext) async throws -> Response {
    // Get session ID from header (if present)
    let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!]

    // Read request body
    let body = try await request.body.collect(upTo: .max)
    let data = Data(buffer: body)

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
            return Response(
                status: .serviceUnavailable,
                headers: [.retryAfter: "60"],
                body: .init(byteBuffer: .init(string: "Server at capacity"))
            )
        }

        // Generate session ID upfront so we can store the transport
        let newSessionId = UUID().uuidString

        // Create new transport with session callbacks
        let newTransport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: { newSessionId },
                onSessionInitialized: { sessionId in
                    logger.info("Session initialized: \(sessionId)")
                },
                onSessionClosed: { sessionId in
                    await sessionManager.remove(sessionId)
                    logger.info("Session closed: \(sessionId)")
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
        return Response(
            status: .notFound,
            body: .init(byteBuffer: .init(string: "Session expired. Try reconnecting."))
        )
    } else {
        // No session ID and not an initialize request
        return Response(
            status: .badRequest,
            body: .init(byteBuffer: .init(string: "Missing \(HTTPHeader.sessionId) header"))
        )
    }

    // Create the MCP HTTP request for the transport
    let mcpRequest = MCP.HTTPRequest(
        method: "POST",
        headers: extractHeaders(from: request),
        body: data
    )

    // Handle the request
    let mcpResponse = await transport.handleRequest(mcpRequest)

    // Build response
    return buildResponse(from: mcpResponse)
}

/// Handle GET /mcp requests (SSE stream for server-initiated notifications)
func handleGet(request: Request, context: MCPRequestContext) async throws -> Response {
    guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!],
        let transport = await sessionManager.transport(forSessionId: sessionId)
    else {
        return Response(
            status: .badRequest,
            body: .init(byteBuffer: .init(string: "Invalid or missing session ID"))
        )
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "GET",
        headers: extractHeaders(from: request)
    )

    let mcpResponse = await transport.handleRequest(mcpRequest)

    return buildResponse(from: mcpResponse)
}

/// Handle DELETE /mcp requests (session termination)
func handleDelete(request: Request, context: MCPRequestContext) async throws -> Response {
    guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!],
        let transport = await sessionManager.transport(forSessionId: sessionId)
    else {
        return Response(
            status: .notFound,
            body: .init(byteBuffer: .init(string: "Session not found"))
        )
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "DELETE",
        headers: extractHeaders(from: request)
    )

    let mcpResponse = await transport.handleRequest(mcpRequest)

    return Response(status: .init(code: mcpResponse.statusCode))
}

// MARK: - Helper Functions

/// Extract headers from Hummingbird request to dictionary
func extractHeaders(from request: Request) -> [String: String] {
    var headers: [String: String] = [:]
    for field in request.headers {
        headers[field.name.rawName] = field.value
    }
    return headers
}

/// Build a Hummingbird Response from an MCP HTTPResponse
func buildResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
    var responseHeaders = HTTPFields()
    for (key, value) in mcpResponse.headers {
        if let name = HTTPField.Name(key) {
            responseHeaders[name] = value
        }
    }

    let status = HTTPResponse.Status(code: mcpResponse.statusCode)

    if let stream = mcpResponse.stream {
        // SSE response - stream the events
        let responseBody = ResponseBody(asyncSequence: SSEResponseSequence(stream: stream))
        return Response(
            status: status,
            headers: responseHeaders,
            body: responseBody
        )
    } else if let body = mcpResponse.body {
        // JSON response
        return Response(
            status: status,
            headers: responseHeaders,
            body: .init(byteBuffer: .init(data: body))
        )
    } else {
        // No content (e.g., 202 Accepted for notifications)
        return Response(
            status: status,
            headers: responseHeaders
        )
    }
}

/// Async sequence wrapper for SSE stream
struct SSEResponseSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let stream: AsyncThrowingStream<Data, Error>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

        mutating func next() async throws -> ByteBuffer? {
            guard let data = try await iterator.next() else {
                return nil
            }
            return ByteBuffer(data: data)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

// MARK: - Main

@main
struct HummingbirdMCPExample {
    static func main() async throws {
        // Set up tool handlers
        await setUpToolHandlers()

        // Create router
        let router = Router(context: MCPRequestContext.self)

        // MCP endpoints
        router.post("/mcp", use: handlePost)
        router.get("/mcp", use: handleGet)
        router.delete("/mcp", use: handleDelete)

        // Health check
        router.get("/health") { _, _ in
            Response(status: .ok, body: .init(byteBuffer: .init(string: "OK")))
        }

        // Create and run application
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 3000))
        )

        logger.info("Starting MCP server on http://localhost:3000/mcp")
        logger.info("Available tools: echo, add")

        try await app.run()
    }
}
