import Foundation

extension Client {
    // MARK: - Request Options

    /// Options that can be given per request.
    ///
    /// Similar to TypeScript SDK's `RequestOptions`, this allows configuring
    /// timeout behavior for individual requests, including progress-aware timeouts.
    public struct RequestOptions: Sendable {
        /// The default request timeout (60 seconds), matching TypeScript SDK.
        public static let defaultTimeout: Duration = .seconds(60)

        /// A timeout for this request.
        ///
        /// If exceeded, the request will be cancelled and an `MCPError.requestTimeout`
        /// will be thrown. A `CancelledNotification` will also be sent to the server.
        ///
        /// If `nil`, no timeout is applied (the request can wait indefinitely).
        /// Default is `nil` to match existing behavior.
        public var timeout: Duration?

        /// If `true`, receiving a progress notification resets the timeout clock.
        ///
        /// This is useful for long-running operations that send periodic progress updates.
        /// As long as the server keeps sending progress, the request won't time out.
        ///
        /// When combined with `maxTotalTimeout`, this allows both:
        /// - Per-interval timeout that resets on progress
        /// - Overall hard limit that prevents infinite waiting
        ///
        /// Default is `false`.
        ///
        /// - Note: Only effective when `timeout` is set and the request uses `onProgress`.
        public var resetTimeoutOnProgress: Bool

        /// Maximum total time to wait for the request, regardless of progress.
        ///
        /// When `resetTimeoutOnProgress` is `true`, this provides a hard upper limit
        /// on the total wait time. Even if progress notifications keep arriving,
        /// the request will be cancelled if this limit is exceeded.
        ///
        /// If `nil`, there's no maximum total timeout (only the regular `timeout`
        /// applies, potentially reset by progress).
        ///
        /// - Note: Only effective when both `timeout` and `resetTimeoutOnProgress` are set.
        public var maxTotalTimeout: Duration?

        /// Creates request options with the specified configuration.
        ///
        /// - Parameters:
        ///   - timeout: The timeout duration, or `nil` for no timeout.
        ///   - resetTimeoutOnProgress: Whether to reset the timeout when progress is received.
        ///   - maxTotalTimeout: Maximum total time to wait regardless of progress.
        public init(
            timeout: Duration? = nil,
            resetTimeoutOnProgress: Bool = false,
            maxTotalTimeout: Duration? = nil
        ) {
            self.timeout = timeout
            self.resetTimeoutOnProgress = resetTimeoutOnProgress
            self.maxTotalTimeout = maxTotalTimeout
        }

        /// Request options with the default timeout (60 seconds).
        public static let withDefaultTimeout = RequestOptions(timeout: defaultTimeout)

        /// Request options with no timeout.
        public static let noTimeout = RequestOptions(timeout: nil)
    }

    // MARK: - Requests

    /// Send a request and receive its response.
    ///
    /// This method sends a request without a timeout. For timeout support,
    /// use `send(_:options:)` instead.
    public func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        try await send(request, options: nil)
    }

    /// Send a request and receive its response with options.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    public func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?
    ) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let requestData = try encoder.encode(request)

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

        // Track whether we've timed out (for the onTermination handler)
        let requestId = request.id
        let timeout = options?.timeout

        // Clean up pending request if caller cancels (e.g., task cancelled or timeout)
        // and send CancelledNotification to server per MCP spec
        continuation.onTermination = { @Sendable [weak self] termination in
            Task {
                guard let self else { return }
                await self.cleanUpPendingRequest(id: requestId)

                // Per MCP spec: send notifications/cancelled when cancelling a request
                // Only send if the stream was cancelled (not finished normally)
                if case .cancelled = termination {
                    let reason = if let timeout {
                        "Request timed out after \(timeout)"
                    } else {
                        "Client cancelled the request"
                    }
                    await self.sendCancellationNotification(
                        requestId: requestId,
                        reason: reason
                    )
                }
            }
        }

        // Add the pending request before attempting to send
        addPendingRequest(id: request.id, continuation: continuation)

        // Send the request data
        do {
            try await connection.send(requestData)
        } catch {
            // If send fails, remove the pending request and rethrow
            if removePendingRequest(id: request.id) != nil {
                continuation.finish(throwing: error)
            }
            throw error
        }

        // Wait for response with optional timeout
        if let timeout {
            // Use withTimeout pattern for cancellation-aware timeout
            return try await withThrowingTaskGroup(of: M.Result.self) { group in
                // Add the main task that waits for the response
                group.addTask {
                    for try await result in stream {
                        return result
                    }
                    throw MCPError.internalError("No response received")
                }

                // Add the timeout task
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MCPError.requestTimeout(timeout: timeout, message: "Request timed out")
                }

                // Return whichever completes first
                guard let result = try await group.next() else {
                    throw MCPError.internalError("No response received")
                }

                // Cancel the other task
                group.cancelAll()

                return result
            }
        } else {
            // No timeout - wait indefinitely for response
            for try await result in stream {
                return result
            }

            // Stream closed without yielding a response
            throw MCPError.internalError("No response received")
        }
    }

    /// Send a request with a progress callback.
    ///
    /// This method automatically sets up progress tracking by:
    /// 1. Generating a unique progress token based on the request ID
    /// 2. Injecting the token into the request's `_meta.progressToken`
    /// 3. Invoking the callback when progress notifications are received
    ///
    /// The callback is automatically cleaned up when the request completes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await client.send(
    ///     CallTool.request(.init(name: "slow_operation", arguments: ["steps": 5])),
    ///     onProgress: { progress in
    ///         print("Progress: \(progress.value)/\(progress.total ?? 0) - \(progress.message ?? "")")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The request to send
    ///   - onProgress: A callback invoked when progress notifications are received
    /// - Returns: The response result
    public func send<M: Method>(
        _ request: Request<M>,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        try await send(request, options: nil, onProgress: onProgress)
    }

    /// Send a request with options and a progress callback.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    public func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?,
        onProgress: @escaping ProgressCallback
    ) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Generate a progress token from the request ID
        let progressToken: ProgressToken = switch request.id {
            case .number(let n): .integer(n)
            case .string(let s): .string(s)
        }

        // Encode the request, inject progressToken into _meta, then re-encode
        let requestData = try encoder.encode(request)
        var requestDict = try decoder.decode([String: Value].self, from: requestData)

        // Ensure params exists and inject _meta.progressToken
        var params = requestDict["params"]?.objectValue ?? [:]
        var meta = params["_meta"]?.objectValue ?? [:]
        meta["progressToken"] = switch progressToken {
            case .string(let s): .string(s)
            case .integer(let n): .int(n)
        }
        params["_meta"] = .object(meta)
        requestDict["params"] = .object(params)

        let modifiedRequestData = try encoder.encode(requestDict)

        // Register the progress callback and track the request → token mapping
        // (used to detect task-augmented responses and keep progress handlers alive)
        progressCallbacks[progressToken] = onProgress
        requestProgressTokens[request.id] = progressToken

        // Create timeout controller if resetTimeoutOnProgress is enabled
        let timeoutController: TimeoutController?
        if let timeout = options?.timeout, options?.resetTimeoutOnProgress == true {
            let controller = TimeoutController(
                timeout: timeout,
                resetOnProgress: true,
                maxTotalTimeout: options?.maxTotalTimeout
            )
            timeoutControllers[progressToken] = controller
            timeoutController = controller
        } else {
            timeoutController = nil
        }

        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<M.Result, Swift.Error>.makeStream()

        let requestId = request.id
        let timeout = options?.timeout
        continuation.onTermination = { @Sendable [weak self] termination in
            Task {
                guard let self else { return }
                await self.cleanUpPendingRequest(id: requestId)
                await self.removeRequestProgressToken(id: requestId)
                await self.removeProgressCallback(token: progressToken)
                await self.removeTimeoutController(token: progressToken)

                if case .cancelled = termination {
                    let reason = if let timeout {
                        "Request timed out after \(timeout)"
                    } else {
                        "Client cancelled the request"
                    }
                    await self.sendCancellationNotification(
                        requestId: requestId,
                        reason: reason
                    )
                }
            }
        }

        // Add the pending request before attempting to send
        addPendingRequest(id: request.id, continuation: continuation)

        // Send the modified request data
        do {
            try await connection.send(modifiedRequestData)
        } catch {
            if removePendingRequest(id: request.id) != nil {
                continuation.finish(throwing: error)
            }
            removeRequestProgressToken(id: request.id)
            removeProgressCallback(token: progressToken)
            removeTimeoutController(token: progressToken)
            throw error
        }

        // Wait for response with optional timeout
        if let timeout {
            // Use TimeoutController if resetTimeoutOnProgress is enabled
            if let controller = timeoutController {
                return try await withThrowingTaskGroup(of: M.Result.self) { group in
                    group.addTask {
                        for try await result in stream {
                            return result
                        }
                        throw MCPError.internalError("No response received")
                    }

                    group.addTask {
                        try await controller.waitForTimeout()
                        throw MCPError.internalError("Unreachable - timeout should throw")
                    }

                    guard let result = try await group.next() else {
                        throw MCPError.internalError("No response received")
                    }

                    group.cancelAll()
                    await controller.cancel()
                    removeProgressCallback(token: progressToken)
                    removeTimeoutController(token: progressToken)
                    return result
                }
            } else {
                // Simple timeout without progress-aware reset
                return try await withThrowingTaskGroup(of: M.Result.self) { group in
                    group.addTask {
                        for try await result in stream {
                            return result
                        }
                        throw MCPError.internalError("No response received")
                    }

                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw MCPError.requestTimeout(timeout: timeout, message: "Request timed out")
                    }

                    guard let result = try await group.next() else {
                        throw MCPError.internalError("No response received")
                    }

                    group.cancelAll()
                    removeProgressCallback(token: progressToken)
                    return result
                }
            }
        } else {
            for try await result in stream {
                removeProgressCallback(token: progressToken)
                removeTimeoutController(token: progressToken)
                return result
            }

            removeProgressCallback(token: progressToken)
            removeTimeoutController(token: progressToken)
            throw MCPError.internalError("No response received")
        }
    }

    /// Remove a progress callback for the given token.
    ///
    /// If the token is being tracked for a task (task-augmented response), the callback
    /// is NOT removed. This keeps progress handlers alive until the task completes.
    private func removeProgressCallback(token: ProgressToken) {
        // Check if this token is being tracked for a task
        // If so, don't remove the callback - it needs to stay alive until task completes
        let isTaskProgressToken = taskProgressTokens.values.contains(token)
        if isTaskProgressToken {
            return
        }
        progressCallbacks.removeValue(forKey: token)
    }

    /// Remove a timeout controller for the given token.
    ///
    /// If the token is being tracked for a task (task-augmented response), the controller
    /// is NOT removed. This keeps timeout tracking alive until the task completes.
    private func removeTimeoutController(token: ProgressToken) {
        // Check if this token is being tracked for a task
        // If so, don't remove the controller - it needs to stay alive until task completes
        let isTaskProgressToken = taskProgressTokens.values.contains(token)
        if isTaskProgressToken {
            return
        }
        timeoutControllers.removeValue(forKey: token)
    }

    /// Remove the request → progress token mapping for the given request ID.
    private func removeRequestProgressToken(id: RequestId) {
        requestProgressTokens.removeValue(forKey: id)
    }

    func addPendingRequest<T: Sendable & Decodable>(
        id: RequestId,
        continuation: AsyncThrowingStream<T, Swift.Error>.Continuation
    ) {
        pendingRequests[id] = AnyPendingRequest(continuation: continuation)
    }

    func removePendingRequest(id: RequestId) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    /// Removes a pending request without returning it.
    /// Used by onTermination handlers when the request has been cancelled.
    func cleanUpPendingRequest(id: RequestId) {
        pendingRequests.removeValue(forKey: id)
    }

    /// Send a CancelledNotification to the server for a cancelled request.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends
    /// a `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// This is called when a client Task waiting for a response is cancelled.
    /// The notification is sent on a best-effort basis - failures are logged but not thrown.
    func sendCancellationNotification(requestId: RequestId, reason: String?) async {
        guard let connection = connection else {
            await logger?.debug(
                "Cannot send cancellation notification - connection is nil",
                metadata: ["requestId": "\(requestId)"]
            )
            return
        }

        let notification = CancelledNotification.message(.init(
            requestId: requestId,
            reason: reason
        ))

        do {
            let notificationData = try encoder.encode(notification)
            try await connection.send(notificationData)
            await logger?.debug(
                "Sent cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        } catch {
            // Log but don't throw - cancellation notification is best-effort
            // per MCP spec's fire-and-forget nature of notifications
            await logger?.debug(
                "Failed to send cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "error": "\(error)",
                ]
            )
        }
    }
}
