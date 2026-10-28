// Tasks on the client (SEP-1686, SEP-2663): reading, answering and
// cancelling tasks, and driving one to its result.

/// The error thrown for a task that was cancelled before it finished.
public struct TaskCancelledError: Swift.Error, Hashable, Sendable, CustomStringConvertible {
    /// The cancelled task.
    public let taskID: String
    /// The task's status message, if it had one.
    public let statusMessage: String?

    /// Creates the error for a cancelled task.
    public init(taskID: String, statusMessage: String? = nil) {
        self.taskID = taskID
        self.statusMessage = statusMessage
    }

    public var description: String {
        "Task \(taskID) was cancelled" + (statusMessage.map { ": \($0)" } ?? "")
    }
}

/// A task the server runs for this client, to follow it to its result.
///
/// Get one from ``Client/task(_:)`` for the task a result created, or
/// ``Client/task(id:)`` for a task known by its identifier.
public struct TaskHandle: Sendable {
    /// The task's identifier.
    public let id: String
    /// The task as last seen by this handle, if any.
    public let initial: TaskSnapshot?

    private let client: Client

    init(id: String, initial: TaskSnapshot?, client: Client) {
        self.id = id
        self.initial = initial
        self.client = client
    }

    /// Reads the task's state (`tasks/get`).
    public func snapshot() async throws -> TaskSnapshot {
        try await client.getTask(id)
    }

    /// Answers some or all of the task's input requests (`tasks/update`,
    /// 2026-07-28).
    public func update(_ inputResponses: [String: InputResponse]) async throws {
        try await client.updateTask(id, inputResponses: inputResponses)
    }

    /// Asks the server to cancel the task (`tasks/cancel`).
    public func cancel() async throws {
        _ = try await client.cancelTask(id)
    }

    /// Waits for the task to finish and returns the result of its tool call.
    ///
    /// Polls the task at the interval the server suggests, within the
    /// bounds of ``Client/Configuration/Tasks``, and answers its input
    /// requests with the client's registered handlers. When a handler
    /// throws, the task is cancelled and the error rethrown; cancelling the
    /// calling Swift task also cancels the task on the server.
    ///
    /// - Returns: The result of the tool call, which may report a tool error
    ///   (`isError`).
    /// - Throws: The ``MCPError`` the task failed with, or
    ///   ``TaskCancelledError`` when it was cancelled.
    public func result() async throws -> CallTool.Result {
        try await client.drive(self)
    }
}

extension Client {
    /// A handle on the task that `snapshot` describes, for example the
    /// `task` of a `tools/call` result.
    public nonisolated func task(_ snapshot: TaskSnapshot) -> TaskHandle {
        TaskHandle(id: snapshot.taskId, initial: snapshot, client: self)
    }

    /// A handle on the task with identifier `id`, for example one created
    /// before the client restarted.
    public nonisolated func task(id: String) -> TaskHandle {
        TaskHandle(id: id, initial: nil, client: self)
    }

    /// Reads a task's state (`tasks/get`). At 2026-07-28 it carries the
    /// outcome, or the input the task waits for.
    public func getTask(_ id: String) async throws -> TaskSnapshot {
        try validateTasks(GetTask.name)
        return try await send(GetTask.request(.init(taskId: id))).value
    }

    /// Answers some or all of a task's input requests, keyed as the task's
    /// `inputRequests` are (`tasks/update`, 2026-07-28).
    public func updateTask(_ id: String, inputResponses: [String: InputResponse]) async throws {
        try validateTasks(UpdateTask.name)
        _ = try await send(UpdateTask.request(.init(taskId: id, inputResponses: inputResponses))).value
    }

    /// Waits for a task to finish and returns the result of its tool call
    /// (`tasks/result`, 2025-11-25). The server sends the task's input
    /// requests while it waits; the client's handlers answer them.
    ///
    /// - Throws: The error the tool call failed with.
    public func taskResult(_ id: String) async throws -> CallTool.Result {
        try validateTasks(GetTaskPayload.name)
        let payload = try await send(GetTaskPayload.request(.init(taskId: id))).value
        return try CallTool.Result(decoding: payload)
    }

    /// Lists the client's tasks, one page at a time (`tasks/list`,
    /// 2025-11-25). Pass the result's `nextCursor` for the next page.
    public func listTasks(cursor: String? = nil) async throws -> ListTasks.Result {
        try validateTasks(ListTasks.name)
        return try await send(ListTasks.request(cursor.map { .init(cursor: $0) } ?? .init())).value
    }

    /// Asks the server to cancel a task (`tasks/cancel`).
    ///
    /// - Returns: The cancelled task at 2025-11-25; `nil` at 2026-07-28,
    ///   where the server only acknowledges and ``getTask(_:)`` reads the
    ///   new state.
    @discardableResult
    public func cancelTask(_ id: String) async throws -> TaskSnapshot? {
        try validateTasks(CancelTask.name)
        return try await send(CancelTask.request(.init(taskId: id))).value.task
    }

    /// In strict mode, throws -32601 when the server did not declare tasks.
    private func validateTasks(_ method: String) throws {
        guard configuration.strict else { return }
        let declared =
            serverCapabilities?.extensions?[ExtensionID.tasks] != nil || serverCapabilities?.tasks != nil
        guard declared else { throw MCPError.methodNotFound("\(method): the server does not declare tasks") }
    }

    /// Polls a task to its end, answering its input with the registered handlers.
    func drive(_ handle: TaskHandle) async throws -> CallTool.Result {
        defer { endDriving(handle.id) }
        let options = configuration.tasks ?? .init()
        let maxInputRequests = configuration.multiRoundTrip.maxInputRequests
        var snapshot: TaskSnapshot
        if let initial = handle.initial {
            snapshot = initial
        } else {
            snapshot = try await getTask(handle.id)
        }
        var answered: Set<String> = []
        let isV1 = negotiatedProtocolVersion.map { Version.profile(for: $0).usesTaskAugmentation } ?? false
        while true {
            if isV1 {
                // 2025-11-25: tasks/result returns the outcome, and the server
                // sends the task's input requests while it waits.
                switch snapshot.status {
                case .cancelled:
                    throw TaskCancelledError(taskID: handle.id, statusMessage: snapshot.statusMessage)
                case let status where status.isTerminal || status == .inputRequired:
                    do {
                        return try await taskResult(handle.id)
                    } catch let error as MCPError where snapshot.status.isTerminal {
                        throw error
                    } catch let error as MCPError {
                        // The task may have ended meanwhile: cancelled has no result.
                        if let now = try? await getTask(handle.id), now.status.isTerminal {
                            if now.status == .cancelled {
                                throw TaskCancelledError(taskID: handle.id, statusMessage: now.statusMessage)
                            }
                            throw error
                        }
                        let id = handle.id
                        Task { try? await self.cancelTask(id) }
                        throw error
                    } catch {
                        let id = handle.id
                        Task { try? await self.cancelTask(id) }
                        throw error
                    }
                default:
                    break
                }
                do {
                    try await waitForTask(handle.id, timeout: options.pollInterval(suggested: snapshot.pollIntervalMs))
                    snapshot = try await getTask(handle.id)
                } catch {
                    let id = handle.id
                    Task { try? await self.cancelTask(id) }
                    throw error
                }
                continue
            }
            switch snapshot.status {
            case .completed:
                guard let result = snapshot.callToolResult else {
                    throw MCPError.internalError("Task \(handle.id) completed without a tool result")
                }
                return result
            case .failed:
                throw snapshot.error ?? MCPError.internalError("Task \(handle.id) failed")
            case .cancelled:
                throw TaskCancelledError(taskID: handle.id, statusMessage: snapshot.statusMessage)
            default:
                break
            }
            do {
                try Task.checkCancellation()
                let pending =
                    snapshot.status == .inputRequired
                    ? (snapshot.inputRequests ?? [:]).filter { !answered.contains($0.key) } : [:]
                if !pending.isEmpty {
                    guard pending.count <= maxInputRequests else {
                        throw MCPError.internalError(
                            "Task \(handle.id) asked for \(pending.count) inputs at once, more than \(maxInputRequests)")
                    }
                    let responses = try await fulfillInputRequests(pending)
                    try await updateTask(handle.id, inputResponses: responses)
                    answered.formUnion(responses.keys)
                } else {
                    try await waitForTask(handle.id, timeout: options.pollInterval(suggested: snapshot.pollIntervalMs))
                }
                snapshot = try await getTask(handle.id)
            } catch {
                // The client gives up on the task: tell the server, best effort.
                let id = handle.id
                Task { try? await self.cancelTask(id) }
                throw error
            }
        }
    }
}
