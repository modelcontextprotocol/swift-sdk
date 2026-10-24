import Foundation
import Logging

/// Routes Streamable HTTP requests to a separate server and transport per session.
/// Use one manager for the HTTP endpoint so a client can initialize a new session
/// after its previous session ends.
public actor StatefulHTTPServerSessionManager {
    public typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private let serverFactory: ServerFactory
    private let validationPipeline: any HTTPRequestValidationPipeline
    private let retryInterval: Int?
    private let sessionTimeout: TimeInterval
    private let maxSessions: Int
    private let logger: Logger
    private var sessions: [String: Session] = [:]
    private var creatingSessions = 0
    private var cleanupTask: Task<Void, Never>?
    private var stopped = false

    /// `serverFactory` must return a new `Server` for each session.
    /// `maxSessions` limits active sessions, including sessions still being created.
    public init(
        sessionTimeout: TimeInterval = 3600,
        maxSessions: Int = 100,
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        retryInterval: Int? = nil,
        logger: Logger? = nil,
        serverFactory: @escaping ServerFactory
    ) {
        self.sessionTimeout = sessionTimeout
        self.maxSessions = max(0, maxSessions)
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
        self.retryInterval = retryInterval
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.sessions",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        self.serverFactory = serverFactory
    }

    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard !stopped else {
            return .error(statusCode: 503, .internalError("Server has stopped"))
        }

        if cleanupTask == nil {
            cleanupTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, let self else { return }
                    await self.removeExpiredSessions()
                }
            }
        }

        await removeExpiredSessions()
        guard !stopped else {
            return .error(statusCode: 503, .internalError("Server has stopped"))
        }

        if let sessionID = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[sessionID] else {
                return .error(statusCode: 404, .invalidRequest("Session not found"))
            }

            if request.method.uppercased() == "DELETE" {
                sessions.removeValue(forKey: sessionID)
                let response = await session.transport.handleRequest(request)
                if response.statusCode == 200 {
                    await session.server.stop()
                } else if !stopped {
                    sessions[sessionID] = session
                } else {
                    await session.server.stop()
                }
                return response
            }

            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            return await session.transport.handleRequest(request)
        }

        guard request.method.uppercased() == "POST",
            let body = request.body,
            let kind = JSONRPCMessageKind(data: body),
            kind.isInitializeRequest
        else {
            return .error(statusCode: 400, .invalidRequest("Missing session ID"))
        }

        let context = HTTPValidationContext(
            httpMethod: "POST",
            isInitializationRequest: true,
            supportedProtocolVersions: Version.supported
        )
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        guard sessions.count + creatingSessions < maxSessions else {
            return .error(statusCode: 503, .internalError("Session limit reached"))
        }
        creatingSessions += 1
        defer { creatingSessions -= 1 }

        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: retryInterval,
            logger: logger
        )

        var server: Server?
        do {
            let createdServer = try await serverFactory(sessionID, transport)
            server = createdServer
            try await createdServer.start(transport: transport)
            guard !stopped else {
                await createdServer.stop()
                return .error(statusCode: 503, .internalError("Server has stopped"))
            }

            sessions[sessionID] = Session(
                server: createdServer, transport: transport, lastAccessedAt: Date()
            )
            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await createdServer.stop()
                return response
            }
            return response
        } catch {
            if let server {
                await server.stop()
            } else {
                await transport.disconnect()
            }
            logger.error("Failed to create session: \(error)")
            return .error(statusCode: 500, .internalError("Failed to create session"))
        }
    }

    public func stop() async {
        stopped = true
        cleanupTask?.cancel()
        cleanupTask = nil
        let activeSessions = sessions
        sessions.removeAll()
        for (_, session) in activeSessions {
            await session.server.stop()
        }
    }

    private func removeExpiredSessions() async {
        let now = Date()
        let expiredIDs = sessions.compactMap { sessionID, session in
            now.timeIntervalSince(session.lastAccessedAt) > sessionTimeout ? sessionID : nil
        }
        for sessionID in expiredIDs {
            guard let session = sessions[sessionID],
                now.timeIntervalSince(session.lastAccessedAt) > sessionTimeout
            else { continue }
            sessions.removeValue(forKey: sessionID)
            await session.server.stop()
        }
    }
}
