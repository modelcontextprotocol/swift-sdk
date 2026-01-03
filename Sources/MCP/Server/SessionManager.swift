import Foundation

/// Optional helper actor for managing HTTP sessions.
///
/// `SessionManager` provides a thread-safe storage layer for managing multiple concurrent
/// HTTP sessions. It's a Swift equivalent of the TypeScript SDK's session dictionary pattern:
///
/// ```typescript
/// // TypeScript SDK pattern:
/// const transports: { [sessionId: string]: HTTPServerTransport } = {};
/// ```
///
/// In Swift, we use an actor for thread-safe access:
/// ```swift
/// let sessionManager = SessionManager()
/// await sessionManager.store(transport, forSessionId: sessionId)
/// ```
///
/// This actor is **optional** - applications can implement their own session management
/// logic directly using dictionaries or other data structures if preferred.
///
/// ## Usage Pattern
///
/// - One `Server` instance can be shared across all sessions
/// - Each session has its own `HTTPServerTransport`
/// - The application routes requests to the correct transport by session ID
///
/// ```swift
/// // Create session manager
/// let sessionManager = SessionManager()
///
/// // In your HTTP handler:
/// func handleMCPRequest(_ request: HTTPRequest) async -> HTTPResponse {
///     let sessionId = request.headers[HTTPHeader.sessionId]
///     let isInitializeRequest = request.body.contains("\"method\":\"initialize\"")
///
///     // Get or create transport
///     let transport: HTTPServerTransport
///     if let sessionId, let existing = await sessionManager.transport(forSessionId: sessionId) {
///         transport = existing
///     } else if isInitializeRequest {
///         // Create new transport with session callbacks
///         transport = HTTPServerTransport(
///             options: .init(
///                 sessionIdGenerator: { UUID().uuidString },
///                 onSessionInitialized: { id in
///                     await sessionManager.store(transport, forSessionId: id)
///                 },
///                 onSessionClosed: { id in
///                     await sessionManager.remove(id)
///                 }
///             )
///         )
///         try await server.start(transport: transport)
///     } else {
///         // No session, no initialization - reject
///         return HTTPResponse(statusCode: 400, ...)
///     }
///
///     return await transport.handleRequest(request)
/// }
/// ```
public actor SessionManager {
    /// Storage for transports by session ID
    private var transports: [String: HTTPServerTransport] = [:]

    /// Last activity time for each session (for cleanup)
    private var lastActivity: [String: Date] = [:]

    /// Maximum number of concurrent sessions (nil = unlimited)
    public var maxSessions: Int?

    /// Creates a new SessionManager.
    ///
    /// - Parameter maxSessions: Maximum concurrent sessions allowed (nil for unlimited)
    public init(maxSessions: Int? = nil) {
        self.maxSessions = maxSessions
    }

    /// Gets an existing transport for the given session ID.
    ///
    /// - Parameter sessionId: The session ID to look up
    /// - Returns: The transport for this session, or nil if not found
    public func transport(forSessionId sessionId: String) -> HTTPServerTransport? {
        if let transport = transports[sessionId] {
            lastActivity[sessionId] = Date()
            return transport
        }
        return nil
    }

    /// Stores a transport for a session ID.
    ///
    /// - Parameters:
    ///   - transport: The transport to store
    ///   - sessionId: The session ID
    public func store(_ transport: HTTPServerTransport, forSessionId sessionId: String) {
        transports[sessionId] = transport
        lastActivity[sessionId] = Date()
    }

    /// Removes a transport from the session manager.
    ///
    /// - Parameter sessionId: The session ID to remove
    public func remove(_ sessionId: String) {
        transports.removeValue(forKey: sessionId)
        lastActivity.removeValue(forKey: sessionId)
    }

    /// Checks if capacity allows adding a new session.
    ///
    /// - Returns: true if a new session can be added, false if at capacity
    public func canAddSession() -> Bool {
        guard let max = maxSessions else { return true }
        return transports.count < max
    }

    /// Removes all sessions that have been inactive for longer than the specified duration.
    ///
    /// Call this periodically to clean up stale sessions.
    ///
    /// - Parameter timeout: Sessions inactive for longer than this duration will be removed
    /// - Returns: The number of sessions removed
    @discardableResult
    public func cleanUpStaleSessions(olderThan timeout: Duration) async -> Int {
        let cutoff = Date().addingTimeInterval(-timeout.timeInterval)
        var removed = 0

        for (sessionId, activity) in lastActivity where activity < cutoff {
            if let transport = transports[sessionId] {
                await transport.close()
            }
            transports.removeValue(forKey: sessionId)
            lastActivity.removeValue(forKey: sessionId)
            removed += 1
        }

        return removed
    }

    /// The number of active sessions.
    public var activeSessionCount: Int {
        transports.count
    }

    /// All active session IDs.
    public var activeSessionIds: [String] {
        Array(transports.keys)
    }

    /// Closes all sessions and clears the session manager.
    public func closeAll() async {
        for (_, transport) in transports {
            await transport.close()
        }
        transports.removeAll()
        lastActivity.removeAll()
    }
}

/// Errors that can occur during HTTP session management.
///
/// These errors are used with ``SessionManager`` to handle common session-related
/// failure scenarios when routing HTTP requests to the appropriate transport.
///
/// ## Example Usage
///
/// ```swift
/// func handleMCPRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
///     let sessionId = request.headers[HTTPHeader.sessionId]
///     let isInitialize = request.body?.contains("initialize") ?? false
///
///     guard let sessionId else {
///         if isInitialize {
///             // Create new session
///         } else {
///             throw SessionError.missingSessionId
///         }
///     }
///
///     guard let transport = await sessionManager.transport(forSessionId: sessionId) else {
///         throw SessionError.sessionNotFound(sessionId)
///     }
///
///     return await transport.handleRequest(request)
/// }
/// ```
public enum SessionError: Error, CustomStringConvertible {
    /// The requested session was not found.
    /// This typically means the session expired or was never created.
    case sessionNotFound(String)

    /// A session ID was required but not provided.
    /// This occurs when a non-initialization request lacks the `Mcp-Session-Id` header.
    case missingSessionId

    /// The maximum number of concurrent sessions has been reached.
    /// The server should reject new connections until existing sessions are closed.
    case capacityReached(Int)

    public var description: String {
        switch self {
        case .sessionNotFound(let sessionId):
            return "Session not found: \(sessionId)"
        case .missingSessionId:
            return "Session ID required for non-initialization requests"
        case .capacityReached(let max):
            return "Maximum session capacity reached (\(max))"
        }
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Converts the duration to a TimeInterval (seconds).
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
