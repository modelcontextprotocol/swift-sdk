import Logging
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol client
public actor Client {
    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The client name
        public var name: String
        /// The client version
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// The client capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// The roots capabilities
        public struct Roots: Hashable, Codable, Sendable {
            /// Whether the list of roots has changed
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// The sampling capabilities
        public struct Sampling: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Experimental features supported by the client
        public var experimental: [String: String]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?

        public init(
            sampling: Sampling? = nil,
            experimental: [String: String]? = nil,
            roots: Capabilities.Roots? = nil
        ) {
            self.sampling = sampling
            self.experimental = experimental
            self.roots = roots
        }
    }

    /// The connection to the server
    private var connection: (any Transport)?
    /// The logger for the client
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The client information
    private let clientInfo: Client.Info
    /// The client name
    public nonisolated var name: String { clientInfo.name }
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities

    /// The server capabilities
    private var serverCapabilities: Server.Capabilities?
    /// The server version
    private var serverVersion: String?
    /// The server instructions
    private var instructions: String?

    /// A dictionary of type-erased notification handlers, keyed by method name
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    /// An error indicating a type mismatch when decoding a pending request
    private struct TypeMismatchError: Swift.Error {}

    /// A pending request with a continuation for the result
    private struct PendingRequest<T> {
        let continuation: CheckedContinuation<T, Swift.Error>
    }

    /// A type-erased pending request
    private struct AnyPendingRequest {
        private let _resume: (Result<Any, Swift.Error>) -> Void

        init<T: Sendable & Decodable>(_ request: PendingRequest<T>) {
            _resume = { result in
                switch result {
                case .success(let value):
                    if let typedValue = value as? T {
                        request.continuation.resume(returning: typedValue)
                    } else if let value = value as? Value,
                        let data = try? JSONEncoder().encode(value),
                        let decoded = try? JSONDecoder().decode(T.self, from: data)
                    {
                        request.continuation.resume(returning: decoded)
                    } else {
                        request.continuation.resume(throwing: TypeMismatchError())
                    }
                case .failure(let error):
                    request.continuation.resume(throwing: error)
                }
            }
        }
        func resume(returning value: Any) {
            _resume(.success(value))
        }

        func resume(throwing error: Swift.Error) {
            _resume(.failure(error))
        }
    }

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [ID: AnyPendingRequest] = [:]

    public init(
        name: String,
        version: String
    ) {
        self.clientInfo = Client.Info(name: name, version: version)
        self.capabilities = Capabilities()
    }

    /// Connect to the server using the given transport
    public func connect(transport: any Transport) async throws {
        self.connection = transport
        try await self.connection?.connect()

        await logger?.info(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            guard let connection = self.connection else { return }
            repeat {
                // Check for cancellation before starting the iteration
                if Task.isCancelled { break }

                do {
                    let stream = await connection.receive()
                    for try await string in stream {
                        if Task.isCancelled { break }  // Check inside loop too

                        // Decode and handle incoming message
                        guard let data = string.data(using: .utf8) else {
                            throw Error.parseError("Invalid UTF-8 data")
                        }

                        // Attempt to decode string data as AnyResponse or AnyMessage
                        let decoder = JSONDecoder()
                        if let response = try? decoder.decode(AnyResponse.self, from: data),
                            let request = pendingRequests[response.id]
                        {
                            await handleResponse(response, for: request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            await handleMessage(message)
                        } else {
                            var metadata: Logger.Metadata = [:]
                            if let string = String(data: data, encoding: .utf8) {
                                metadata["message"] = .string(string)
                            }
                            await logger?.warning(
                                "Unexpected message received by client", metadata: metadata)
                        }
                    }
                } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                    continue
                } catch {
                    await logger?.error(
                        "Error in message handling loop", metadata: ["error": "\(error)"])
                    break
                }
            } while true
        }
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        // Cancel all pending requests
        for (id, request) in pendingRequests {
            request.resume(throwing: Error.internalError("Client disconnected"))
            pendingRequests.removeValue(forKey: id)
        }

        task?.cancel()
        task = nil
        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    // MARK: - Registration

    /// Register a handler for a notification
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Requests

    /// Send a request and receive its response
    public func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        guard let connection = connection else {
            throw Error.internalError("Client connection not initialized")
        }

        let requestData = try JSONEncoder().encode(request)
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw Error.internalError("Failed to encode request")
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Store the pending request first
            Task {
                self.addPendingRequest(
                    id: request.id,
                    continuation: continuation,
                    type: M.Result.self
                )

                // Send the request
                do {
                    try await connection.send(requestString)
                } catch {
                    continuation.resume(throwing: error)
                    self.removePendingRequest(id: request.id)
                }
            }
        }
    }

    private func addPendingRequest<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type
    ) {
        pendingRequests[id] = AnyPendingRequest(PendingRequest(continuation: continuation))
    }

    private func removePendingRequest(id: ID) {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Lifecycle

    public func initialize() async throws -> Initialize.Result {
        let request = Initialize.request(
            .init(
                protocolVersion: Version.latest,
                capabilities: capabilities,
                clientInfo: clientInfo
            ))

        let result = try await send(request)

        self.serverCapabilities = result.capabilities
        self.serverVersion = result.protocolVersion
        self.instructions = result.instructions

        return result
    }

    public func ping() async throws {
        let request = Ping.request()
        _ = try await send(request)
    }

    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: Value]? = nil) async throws
        -> (description: String?, messages: [Prompt.Message])
    {
        _ = try checkCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        return (description: result.description, messages: result.messages)
    }

    public func listPrompts(cursor: String? = nil) async throws
        -> (prompts: [Prompt], nextCursor: String?)
    {
        _ = try checkCapability(\.prompts, "Prompts")
        let request = ListPrompts.request(.init(cursor: cursor))
        let result = try await send(request)
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        _ = try checkCapability(\.resources?.read, "Resource reading")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await send(request)
        return result.contents
    }

    public func listResources(cursor: String? = nil) async throws -> (
        resources: [Resource], nextCursor: String?
    ) {
        _ = try checkCapability(\.resources?.list, "Resource listing")
        let request = ListResources.request(.init(cursor: cursor))
        let result = try await send(request)
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        _ = try checkCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    // MARK: - Tools

    public func listTools(cursor: String? = nil) async throws -> [Tool] {
        _ = try checkCapability(\.tools, "Tools")
        let request = ListTools.request(.init(cursor: cursor))
        let result = try await send(request)
        return result.tools
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async throws -> (
        content: [Tool.Content], isError: Bool?
    ) {
        _ = try checkCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        return (content: result.content, isError: result.isError)
    }

    // MARK: -

    private func handleResponse(_ response: Response<AnyMethod>, for request: AnyPendingRequest)
        async
    {
        await logger?.debug(
            "Processing response",
            metadata: ["id": "\(response.id)"])

        switch response.result {
        case .success(let value):
            request.resume(returning: value)
        case .failure(let error):
            request.resume(throwing: error)
        }

        removePendingRequest(id: response.id)
    }

    private func handleMessage(_ message: Message<AnyNotification>) async {
        await logger?.debug(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    // MARK: -

    private func checkCapability<T>(_ keyPath: KeyPath<Server.Capabilities, T?>, _ name: String)
        throws -> T
    {
        guard let capabilities = serverCapabilities else {
            throw Error.methodNotFound("Server capabilities not initialized")
        }
        guard let value = capabilities[keyPath: keyPath] else {
            throw Error.methodNotFound("\(name) is not supported by the server")
        }
        return value
    }
}
