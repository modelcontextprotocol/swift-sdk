import Foundation

// MARK: - Storage

/// A task as the server keeps it, independent of the protocol version that
/// reads it.
///
/// A tool that reports an error (`isError`) completes its task here; the
/// SDK reports such a task as failed to 2025-11-25 clients.
public struct TaskRecord: Hashable, Codable, Sendable {
    /// The task's identifier.
    public let id: String
    /// The principal that created the task, from ``TaskManager``'s
    /// `principal`; only that principal can read it.
    public let owner: String?
    /// The protocol version of the request that created the task. The task
    /// is read only at a version of the same generation.
    public let protocolVersion: String
    /// The method of the request the task runs, for example `tools/call`.
    public let method: String
    /// The task's state.
    public var status: TaskStatus
    /// A human-readable description of the state.
    public var statusMessage: String?
    /// When the task was created.
    public let createdAt: Date
    /// When the task last changed.
    public var lastUpdatedAt: Date
    /// How long the task is kept after it was created, in milliseconds;
    /// `nil` for no limit.
    public var ttlMs: Int?
    /// How long clients should wait between polls, in milliseconds.
    public var pollIntervalMs: Int?
    /// The input requests the task waits for, keyed by the names sent to the
    /// client.
    public var inputRequests: [String: InputRequest]
    /// The result of the request once the task completed.
    public var result: Value?
    /// The error the request failed with once the task failed.
    public var error: MCPError?

    /// Creates a task record.
    public init(
        id: String,
        owner: String?,
        protocolVersion: String,
        method: String,
        status: TaskStatus = .working,
        statusMessage: String? = nil,
        createdAt: Date,
        lastUpdatedAt: Date? = nil,
        ttlMs: Int?,
        pollIntervalMs: Int?,
        inputRequests: [String: InputRequest] = [:],
        result: Value? = nil,
        error: MCPError? = nil
    ) {
        self.id = id
        self.owner = owner
        self.protocolVersion = protocolVersion
        self.method = method
        self.status = status
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt ?? createdAt
        self.ttlMs = ttlMs
        self.pollIntervalMs = pollIntervalMs
        self.inputRequests = inputRequests
        self.result = result
        self.error = error
    }

    /// When the task may be deleted; `nil` for no limit.
    public var expiresAt: Date? {
        ttlMs.map { createdAt.addingTimeInterval(Double($0) / 1000) }
    }

    /// Whether the task's lifetime has ended at `date`.
    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    /// The generation the task was created with.
    var generation: TaskGeneration {
        Version.profile(for: protocolVersion).taskGeneration ?? .v2
    }

    /// Whether the outcome is a tool result that reports an error.
    var isToolError: Bool {
        result?.objectValue?["isError"] == .bool(true)
    }

    /// The task as its generation reports it. `detailed` adds the outcome
    /// or the outstanding input (2026-07-28, `tasks/get`).
    func snapshot(detailed: Bool) -> TaskSnapshot {
        var snapshot = TaskSnapshot(
            taskId: id,
            status: status,
            statusMessage: statusMessage,
            createdAt: TaskTimestamp.string(from: createdAt),
            lastUpdatedAt: TaskTimestamp.string(from: lastUpdatedAt),
            ttlMs: ttlMs,
            pollIntervalMs: pollIntervalMs)
        switch generation {
        case .v1:
            if status == .completed, isToolError { snapshot.status = .failed }
            return snapshot.shaped(as: .v1)
        case .v2:
            guard detailed else { return snapshot }
            switch status {
            case .inputRequired where !inputRequests.isEmpty:
                snapshot.inputRequests = inputRequests
            case .completed:
                snapshot.result = result.map(Self.completeResult)
            case .failed:
                snapshot.error = error ?? .internalError("The task failed")
            default:
                break
            }
            return snapshot
        }
    }

    /// An inlined result, with the `resultType` every 2026-07-28 result carries.
    private static func completeResult(_ result: Value) -> Value {
        guard case .object(var object) = result else { return result }
        if object[ResultKeys.resultType] == nil {
            object[ResultKeys.resultType] = .string(ResultType.complete.rawValue)
        }
        return .object(object)
    }
}

/// Where a ``TaskManager`` keeps its tasks.
///
/// The SDK keeps the work and the waiting for input in memory; a store
/// makes the tasks themselves outlive the process or be shared. After a
/// restart, a task the store reports as working has no work behind it: mark
/// such tasks failed when the store loads.
public protocol TaskStore: Sendable {
    /// Adds a new task. Called before the task is reported to the client.
    func insert(_ record: TaskRecord) async throws
    /// The task with `id`, or `nil`.
    func record(id: String) async throws -> TaskRecord?
    /// Replaces the stored task with the same id. A task that is not stored,
    /// such as one removed or expired, must not be added back: the manager
    /// may write a task's last change after it expired.
    func update(_ record: TaskRecord) async throws
    /// Removes the task with `id`.
    func remove(id: String) async throws
    /// The tasks of `owner`, oldest first, for `tasks/list`.
    func records(owner: String?) async throws -> [TaskRecord]
    /// Removes the tasks whose lifetime ended at `date` and returns their ids.
    func removeExpired(asOf date: Date) async throws -> [String]
}

/// A ``TaskStore`` that keeps tasks in memory for the life of the process.
///
/// It keeps finished tasks, with their results, until their lifetime ends.
/// A server open to untrusted clients bounds its memory with a shorter
/// ``TaskManager/Configuration/maximumTTL``, or with a store that limits what
/// it keeps.
public actor InMemoryTaskStore: TaskStore {
    private var tasks: [String: TaskRecord] = [:]

    /// Creates an empty store.
    public init() {}

    /// Adds a new task.
    public func insert(_ record: TaskRecord) {
        tasks[record.id] = record
    }

    /// The task with `id`, or `nil`.
    public func record(id: String) -> TaskRecord? {
        tasks[id]
    }

    /// Replaces the stored task with the same id; does nothing for an unknown task.
    public func update(_ record: TaskRecord) {
        guard tasks[record.id] != nil else { return }
        tasks[record.id] = record
    }

    /// Removes the task with `id`.
    public func remove(id: String) {
        tasks[id] = nil
    }

    /// The tasks of `owner`, oldest first.
    public func records(owner: String?) -> [TaskRecord] {
        tasks.values.filter { $0.owner == owner }.sorted {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }

    /// Removes the tasks whose lifetime ended at `date` and returns their ids.
    public func removeExpired(asOf date: Date) -> [String] {
        let expired = tasks.values.filter { $0.isExpired(at: date) }.map(\.id)
        for id in expired { tasks[id] = nil }
        return expired
    }
}

// MARK: - Manager

/// Runs tasks and keeps their state (SEP-1686, SEP-2663).
///
/// Pass one manager to ``Server/withTasks(_:)`` of every ``Server`` that
/// serves the same clients: a stateful HTTP server creates one `Server` per
/// session, and a 2025-11-25 client may read its task from a new session.
///
/// A task is a durable handle, not durable execution: the work runs in this
/// process and ends with it.
///
/// Without a `principal`, any client that knows a task's identifier can
/// read, answer and cancel it; identifiers carry 128 random bits. With one,
/// a task is visible only to the principal that created it, and
/// 2025-11-25 clients may list their tasks. A caller the `principal`
/// returns `nil` for gets no tasks.
public actor TaskManager {
    /// Limits and defaults of a ``TaskManager``.
    public struct Configuration: Sendable {
        /// The lifetime of a task when the client asks for none; `nil` for
        /// no limit.
        public var defaultTTL: Duration?
        /// The longest lifetime a task may have; a longer one the client asks
        /// for is shortened. `nil` for no limit.
        public var maximumTTL: Duration?
        /// How long clients should wait between polls.
        public var pollInterval: Duration
        /// The most tasks running at once. When it is reached, a request that
        /// must run as a task fails with -32603 and any other runs inline.
        ///
        /// Finished tasks do not count: they stay in the store, with their
        /// results, until their lifetime ends, so ``maximumTTL`` bounds how
        /// long ``InMemoryTaskStore`` keeps them.
        public var maxActiveTasks: Int
        /// The most tasks one principal may run at once; applies only when
        /// tasks are bound to principals.
        public var maxActiveTasksPerPrincipal: Int
        /// Whether the server that created a 2025-11-25 task sends
        /// `notifications/tasks/status` when its status changes.
        public var sendsStatusNotifications: Bool

        /// Creates a configuration.
        public init(
            defaultTTL: Duration? = .seconds(3600),
            maximumTTL: Duration? = .seconds(86_400),
            pollInterval: Duration = .seconds(1),
            maxActiveTasks: Int = 1000,
            maxActiveTasksPerPrincipal: Int = 100,
            sendsStatusNotifications: Bool = true
        ) {
            self.defaultTTL = defaultTTL
            self.maximumTTL = maximumTTL
            self.pollInterval = pollInterval
            self.maxActiveTasks = maxActiveTasks
            self.maxActiveTasksPerPrincipal = maxActiveTasksPerPrincipal
            self.sendsStatusNotifications = sendsStatusNotifications
        }
    }

    /// Identifies the caller of a request, for example from
    /// `context.httpContext`; `nil` when there is none.
    ///
    /// A caller without a principal cannot use tasks: no task is created for
    /// it (a tool that requires a task fails with -32603, any other runs
    /// inline), it sees no task and lists none. Callers without a principal
    /// are not one principal.
    public typealias Principal = @Sendable (Server.HandlerContext) -> String?

    /// Where tasks are kept.
    public nonisolated let store: any TaskStore
    /// Limits and defaults.
    public nonisolated let configuration: Configuration
    private nonisolated let principal: Principal?

    /// Creates a task manager.
    ///
    /// - Parameters:
    ///   - store: Where tasks are kept.
    ///   - configuration: Limits and defaults.
    ///   - principal: Binds each task to the caller that created it.
    public init(
        store: any TaskStore = InMemoryTaskStore(),
        configuration: Configuration = .init(),
        principal: Principal? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.principal = principal
    }

    /// Whether tasks are bound to principals.
    nonisolated var bindsPrincipals: Bool { principal != nil }

    /// The principal of a request.
    nonisolated func owner(of context: Server.HandlerContext) -> String? {
        principal?(context)
    }

    /// The tasks that are not finished, which this process runs or waits on.
    /// The cache is authoritative while a task runs.
    private var active: [String: TaskRecord] = [:]
    /// The work of each running task.
    private var work: [String: Task<Void, Never>] = [:]
    /// Outstanding `requestInput` calls by task, then by token.
    private var exchanges: [String: [Int: Exchange]] = [:]
    /// The input keys each task has sent, so a key is never reused.
    private var usedInputKeys: [String: Set<String>] = [:]
    /// Input requests being sent to the client by a `tasks/result` (2025-11-25).
    private var delivering: [String: Set<String>] = [:]
    private var nextToken = 0
    /// Waiters for the next change of a task, by token.
    private var changeWaiters: [String: [Int: ResponseSlot<Void>]] = [:]
    /// Receives every change, in order, by token.
    private var observers: [Int: AsyncStream<TaskRecord>.Continuation] = [:]
    /// Store writes, in order.
    private var persisting: Task<Void, Never>?
    private var creations = 0

    private struct Exchange {
        /// The key sent to the client, for each key the caller used.
        let wireKeys: [String: String]
        /// Keys still unanswered, as sent.
        var pending: Set<String>
        /// The answers, by the caller's keys.
        var responses: [String: InputResponse] = [:]
        let slot: ResponseSlot<[String: InputResponse]>
    }

    // MARK: Public API

    /// The task with `id`, or `nil` when it does not exist or expired.
    public func record(id: String) async throws -> TaskRecord? {
        try await current(id)
    }

    /// Completes a task with the result of its request, for work the
    /// application runs outside the task, and cancels the task's work. A
    /// task that already finished is unchanged.
    public func complete(_ id: String, with result: CallTool.Result) async throws {
        let value = try Value(result)
        work.removeValue(forKey: id)?.cancel()
        await finish(id, .result(value))
    }

    /// Fails a task with a protocol error and cancels its work. A task that
    /// already finished is unchanged.
    public func fail(_ id: String, with error: MCPError) async throws {
        work.removeValue(forKey: id)?.cancel()
        await finish(id, .error(error))
    }

    /// Cancels a task and its work. Returns the task, or `nil` when it does
    /// not exist; a task that already finished is returned unchanged.
    @discardableResult
    public func cancel(_ id: String) async throws -> TaskRecord? {
        guard var record = try await current(id) else { return nil }
        guard !record.status.isTerminal else { return record }
        record.status = .cancelled
        record.statusMessage = record.statusMessage ?? "The task was cancelled"
        record.inputRequests = [:]
        record.lastUpdatedAt = Date()
        active[id] = record
        let pending = exchanges.removeValue(forKey: id) ?? [:]
        for exchange in pending.values { exchange.slot.resolve(.failure(CancellationError())) }
        work.removeValue(forKey: id)?.cancel()
        await persist(record)
        retire(id)
        changed(record)
        return record
    }

    /// Calls `observer` after every change of a task, one change at a time
    /// and in order, until the returned token is passed to
    /// ``removeObserver(_:)``.
    func addObserver(_ observer: @escaping @Sendable (TaskRecord) async -> Void) -> Int {
        nextToken += 1
        let (changes, continuation) = AsyncStream<TaskRecord>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        observers[nextToken] = continuation
        Task {
            for await record in changes { await observer(record) }
        }
        return nextToken
    }

    func removeObserver(_ token: Int) {
        observers.removeValue(forKey: token)?.finish()
    }

    // MARK: Lifecycle

    /// Creates a task for a request; `nil` when the limits are reached.
    func create(
        context: Server.HandlerContext, method: String, protocolVersion: String,
        requestedTTL: Int?, ttl: Duration?, pollInterval: Duration?
    ) async throws -> TaskRecord? {
        let owner = owner(of: context)
        // A caller without a principal shares tasks with no one.
        if bindsPrincipals, owner == nil { return nil }
        if !hasCapacity(for: owner) {
            // Expired tasks leave `active` only when read: reclaim them first.
            await expireActive()
            guard hasCapacity(for: owner) else { return nil }
        }

        var ttlMs = requestedTTL ?? (ttl ?? configuration.defaultTTL)?.wholeMilliseconds
        if let maximum = configuration.maximumTTL?.wholeMilliseconds {
            ttlMs = min(ttlMs ?? maximum, maximum)
        }
        let record = TaskRecord(
            id: TaskIdentifier.make(), owner: owner, protocolVersion: protocolVersion, method: method,
            createdAt: Date(), ttlMs: ttlMs.map { max(1, $0) },
            pollIntervalMs: max(1, (pollInterval ?? configuration.pollInterval).wholeMilliseconds))
        // Reserved before the first suspension, so the limits hold.
        active[record.id] = record
        do {
            try await store.insert(record)
        } catch {
            active[record.id] = nil
            throw error
        }
        creations += 1
        if creations % 64 == 0 { await sweep() }
        return record
    }

    private func hasCapacity(for owner: String?) -> Bool {
        guard active.count < configuration.maxActiveTasks else { return false }
        // Without a principal hook every task has the same owner: only the overall limit applies.
        return !bindsPrincipals
            || active.values.filter({ $0.owner == owner }).count < configuration.maxActiveTasksPerPrincipal
    }

    /// Runs the work of a created task.
    func start(
        _ id: String,
        _ body: @escaping @Sendable (TaskContext) async throws -> CallTool.Result,
        context: TaskContext
    ) {
        guard active[id] != nil, work[id] == nil else { return }
        work[id] = Task {
            let outcome: Outcome
            do {
                let result = try await Server.$currentHandlerContext.withValue(nil) {
                    try await body(context)
                }
                if result.isInputRequired || result.task != nil {
                    outcome = .error(.internalError("Server bug: a task's work returned input requests or a task"))
                } else {
                    outcome = .result(try Value(result))
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as MCPError {
                outcome = .error(error)
            } catch {
                outcome = .error(.internalError(error.localizedDescription))
            }
            await self.finish(id, outcome)
        }
    }

    enum Outcome {
        case result(Value)
        case error(MCPError)
        case cancelled
    }

    private func finish(_ id: String, _ outcome: Outcome) async {
        work[id] = nil
        guard var record = try? await current(id), !record.status.isTerminal else { return }
        switch outcome {
        case .result(let value):
            record.status = .completed
            record.result = value
        case .error(let error):
            record.status = .failed
            record.error = error
            record.statusMessage = error.errorDescription ?? "The task failed"
        case .cancelled:
            record.status = .cancelled
        }
        record.inputRequests = [:]
        record.lastUpdatedAt = Date()
        active[id] = record
        let pending = exchanges.removeValue(forKey: id) ?? [:]
        for exchange in pending.values { exchange.slot.resolve(.failure(CancellationError())) }
        await persist(record)
        retire(id)
        changed(record)
    }

    /// Forgets the in-memory state of a finished task.
    private func retire(_ id: String) {
        if active[id]?.status.isTerminal == true { active[id] = nil }
        exchanges[id] = nil
        usedInputKeys[id] = nil
        delivering[id] = nil
        wakeWaiters(id)
    }

    // MARK: Reading

    /// The task with `id`; `nil` when unknown or expired.
    private func current(_ id: String) async throws -> TaskRecord? {
        let record: TaskRecord?
        if let cached = active[id] {
            record = cached
        } else {
            record = try await store.record(id: id)
        }
        guard let record else { return nil }
        if record.isExpired(at: Date()) {
            await expire([id])
            try? await store.remove(id: id)
            return nil
        }
        return record
    }

    /// The task with `id` as `context`'s caller may see it: `nil` when it is
    /// unknown, expired, owned by someone else or of another generation.
    func lookup(_ id: String, context: Server.HandlerContext, generation: TaskGeneration) async throws
        -> TaskRecord?
    {
        let owner = owner(of: context)
        if bindsPrincipals, owner == nil { return nil }
        guard let record = try await current(id), record.owner == owner, record.generation == generation
        else { return nil }
        return record
    }

    /// The tasks of `context`'s caller of `generation`.
    func list(context: Server.HandlerContext, generation: TaskGeneration) async throws -> [TaskRecord] {
        let owner = owner(of: context)
        if bindsPrincipals, owner == nil { return [] }
        let now = Date()
        return try await store.records(owner: owner).compactMap { stored in
            let record = active[stored.id] ?? stored
            return record.generation == generation && !record.isExpired(at: now) ? record : nil
        }
    }

    /// Waits until the task is no longer `seen`, `timeout` passes, or the
    /// task expires. Returns at once when it already changed. A task that
    /// does not run here, such as one another process stored, is read from
    /// the store again after its poll interval.
    func waitForChange(_ id: String, from seen: TaskRecord, timeout: Duration) async throws {
        var timeout = timeout
        if let expiresAt = seen.expiresAt {
            timeout = min(timeout, .milliseconds(max(0, Int(expiresAt.timeIntervalSinceNow * 1000))))
        }
        guard let current = active[id] else {
            // It may also have just finished here.
            guard try await store.record(id: id) == seen else { return }
            let interval = Duration.milliseconds(seen.pollIntervalMs ?? configuration.pollInterval.wholeMilliseconds)
            try await Task.sleep(for: min(timeout, interval))
            return
        }
        guard current == seen else { return }
        nextToken += 1
        let token = nextToken
        let slot = ResponseSlot<Void>()
        changeWaiters[id, default: [:]][token] = slot
        let timer = Task {
            try? await Task.sleep(for: timeout)
            slot.resolve(.success(()))
        }
        defer {
            timer.cancel()
            changeWaiters[id]?[token] = nil
            if changeWaiters[id]?.isEmpty == true { changeWaiters[id] = nil }
        }
        try await withTaskCancellationHandler {
            try await slot.value()
        } onCancel: {
            slot.resolve(.failure(CancellationError()))
        }
    }

    /// Waits until the task finished, expired or no longer runs here.
    func waitUntilFinished(_ id: String) async throws {
        while let record = active[id], !record.status.isTerminal {
            if record.isExpired(at: Date()) {
                await expire([id])
                try? await store.remove(id: id)
                return
            }
            try await waitForChange(id, from: record, timeout: .seconds(30))
        }
    }

    /// The number of `waitForChange` calls waiting on the task.
    func changeWaiterCount(_ id: String) -> Int {
        changeWaiters[id]?.count ?? 0
    }

    // MARK: Input

    /// Asks the client for input and waits for every response.
    func requestInput(_ id: String, _ requests: [String: InputRequest]) async throws -> [String: InputResponse] {
        guard !requests.isEmpty else { return [:] }
        guard var record = active[id], !record.status.isTerminal else { throw CancellationError() }
        var used = usedInputKeys[id] ?? []
        var wireKeys: [String: String] = [:]
        for key in requests.keys.sorted() {
            var wire = key
            var suffix = 2
            while used.contains(wire) {
                wire = "\(key)#\(suffix)"
                suffix += 1
            }
            used.insert(wire)
            wireKeys[key] = wire
            record.inputRequests[wire] = requests[key]
        }
        usedInputKeys[id] = used
        nextToken += 1
        let token = nextToken
        let slot = ResponseSlot<[String: InputResponse]>()
        exchanges[id, default: [:]][token] = Exchange(
            wireKeys: wireKeys, pending: Set(wireKeys.values), slot: slot)
        record.status = .inputRequired
        record.lastUpdatedAt = Date()
        active[id] = record
        await persist(record)
        changed(record)

        return try await withTaskCancellationHandler {
            try await slot.value()
        } onCancel: {
            slot.resolve(.failure(CancellationError()))
            Task { await self.withdrawInput(id, token) }
        }
    }

    /// Withdraws the input requests of a `requestInput` call its caller
    /// cancelled while the task goes on.
    private func withdrawInput(_ id: String, _ token: Int) async {
        guard let exchange = exchanges[id]?.removeValue(forKey: token),
            var record = active[id], !record.status.isTerminal
        else { return }
        for key in exchange.pending { record.inputRequests[key] = nil }
        delivering[id]?.subtract(exchange.pending)
        if record.inputRequests.isEmpty { record.status = .working }
        record.lastUpdatedAt = Date()
        active[id] = record
        await persist(record)
        changed(record)
    }

    /// Takes the outstanding input requests no `tasks/result` is sending
    /// yet, by the keys sent; they stay outstanding until answered.
    func claimInput(_ id: String) -> [String: InputRequest] {
        guard let record = active[id], !record.status.isTerminal else { return [:] }
        let taken = delivering[id] ?? []
        let claimed = record.inputRequests.filter { !taken.contains($0.key) }
        delivering[id, default: []].formUnion(claimed.keys)
        return claimed
    }

    /// Gives back claimed input requests that were not delivered, for the
    /// next `tasks/result`.
    func releaseInput(_ id: String, _ keys: some Sequence<String>) {
        delivering[id]?.subtract(keys)
    }

    /// Fails the calls waiting for the input requests `keys`: the client
    /// could not answer them.
    func failInput(_ id: String, _ keys: Set<String>, _ error: MCPError) async {
        delivering[id]?.subtract(keys)
        guard var record = active[id], !record.status.isTerminal else { return }
        for key in keys { record.inputRequests[key] = nil }
        for (token, exchange) in exchanges[id] ?? [:] where !exchange.pending.isDisjoint(with: keys) {
            exchanges[id]?[token] = nil
            for key in exchange.pending { record.inputRequests[key] = nil }
            exchange.slot.resolve(.failure(error))
        }
        if record.inputRequests.isEmpty { record.status = .working }
        record.lastUpdatedAt = Date()
        active[id] = record
        await persist(record)
        changed(record)
    }

    /// Records the client's responses: keys the task does not wait for are
    /// ignored. A call that has all its responses resumes.
    ///
    /// - Throws: -32602 when a response does not fit its request; -32603 for
    ///   an unfinished task that runs in another process.
    func submit(_ id: String, _ responses: [String: InputResponse]) async throws {
        guard var record = active[id] else {
            // Stored by another process: its work, and the calls that wait
            // for input, are not here.
            if let stored = try await store.record(id: id), !stored.status.isTerminal {
                throw MCPError.internalError("The task does not run in this process; its input cannot be delivered")
            }
            return
        }
        guard !record.status.isTerminal else { return }
        var accepted: [String: InputResponse] = [:]
        for (key, response) in responses {
            guard let request = record.inputRequests[key] else { continue }
            accepted[key] = try Self.response(response, fitting: request, key: key)
        }
        guard !accepted.isEmpty else { return }
        for key in accepted.keys { record.inputRequests[key] = nil }
        delivering[id]?.subtract(accepted.keys)

        var resumed: [(ResponseSlot<[String: InputResponse]>, [String: InputResponse])] = []
        for (token, var exchange) in exchanges[id] ?? [:] {
            for (callerKey, wire) in exchange.wireKeys {
                guard let response = accepted[wire], exchange.pending.contains(wire) else { continue }
                exchange.pending.remove(wire)
                exchange.responses[callerKey] = response
            }
            if exchange.pending.isEmpty {
                exchanges[id]?[token] = nil
                resumed.append((exchange.slot, exchange.responses))
            } else {
                exchanges[id]?[token] = exchange
            }
        }
        if record.inputRequests.isEmpty { record.status = .working }
        record.lastUpdatedAt = Date()
        active[id] = record
        await persist(record)
        for (slot, responses) in resumed { slot.resolve(.success(responses)) }
        changed(record)
    }

    /// A response read as the result of its request's method.
    private static func response(_ response: InputResponse, fitting request: InputRequest, key: String) throws
        -> InputResponse
    {
        let fits: Bool
        switch (request, response) {
        case (.elicitation, .elicitation), (.sampling, .sampling), (.listRoots, .roots), (.unknown, _):
            fits = true
        default:
            fits = false
        }
        if fits { return response }
        // Decoding by shape may have picked another kind: read it as a result of the request's method.
        if let value = try? Value(response), let typed = try? InputResponse(method: request.method, result: value) {
            return typed
        }
        throw MCPError.invalidParams("The response \"\(key)\" is not a result of \(request.method)")
    }

    /// Sets the task's status message.
    func setStatusMessage(_ id: String, _ message: String?) async {
        guard var record = active[id], !record.status.isTerminal else { return }
        record.statusMessage = message
        record.lastUpdatedAt = Date()
        active[id] = record
        await persist(record)
        changed(record)
    }

    // MARK: Housekeeping

    private func persist(_ record: TaskRecord) async {
        let previous = persisting
        let store = store
        let write = Task {
            await previous?.value
            try? await store.update(record)
        }
        persisting = write
        await write.value
    }

    private func sweep() async {
        guard let expired = try? await store.removeExpired(asOf: Date()) else { return }
        await expire(expired)
    }

    /// Expires the tasks of `active` whose lifetime ended.
    private func expireActive() async {
        let now = Date()
        let expired = active.values.filter { $0.isExpired(at: now) }.map(\.id)
        guard !expired.isEmpty else { return }
        await expire(expired)
        for id in expired { try? await store.remove(id: id) }
    }

    /// Ends the work of tasks whose lifetime ended.
    private func expire(_ ids: [String]) async {
        for id in ids {
            work.removeValue(forKey: id)?.cancel()
            let pending = exchanges.removeValue(forKey: id) ?? [:]
            for exchange in pending.values { exchange.slot.resolve(.failure(CancellationError())) }
            active[id] = nil
            usedInputKeys[id] = nil
            delivering[id] = nil
            wakeWaiters(id)
        }
    }

    /// Resolves and forgets the waiters for the next change of a task.
    private func wakeWaiters(_ id: String) {
        for slot in (changeWaiters.removeValue(forKey: id) ?? [:]).values {
            slot.resolve(.success(()))
        }
    }

    private func changed(_ record: TaskRecord) {
        wakeWaiters(record.id)
        for observer in observers.values {
            observer.yield(record)
        }
    }
}

// MARK: - Handler API

/// The handle a task's work uses to talk to its client.
///
/// When the request does not run as a task, the work runs inline with the
/// request; ``taskID`` is then `nil`.
public struct TaskContext: Sendable {
    /// The task's identifier; `nil` when the work runs inline.
    public let taskID: String?
    /// The context of the request that started the work.
    public let request: Server.HandlerContext

    let manager: TaskManager?
    /// Sends input requests to the client directly (handshake connections).
    let bridge: InputBridge?
    /// Sends progress for the request's progress token.
    var progress: ProgressReporter?

    init(
        taskID: String?, request: Server.HandlerContext, manager: TaskManager?, bridge: InputBridge?,
        progress: ProgressReporter? = nil
    ) {
        self.taskID = taskID
        self.request = request
        self.manager = manager
        self.bridge = bridge
        self.progress = progress
    }

    /// Whether the work runs as a task.
    public var isTask: Bool { taskID != nil }

    /// Reports progress for the request's progress token, if the client
    /// sent one. At 2025-11-25 the token stays valid for the task's
    /// lifetime; tasks at 2026-07-28 report no progress, so this does
    /// nothing in them.
    public func reportProgress(_ progress: Double, total: Double? = nil, message: String? = nil) async throws {
        try await self.progress?(progress, total, message)
    }

    /// Asks the client for input and waits for the responses, keyed as
    /// `requests` were.
    ///
    /// In a task the requests are reported to the client with the task; the
    /// SDK renames a key the task used before, so each key stays unique. Run
    /// inline at 2026-07-28 the work cannot ask for input: it throws -32021
    /// naming the tasks extension.
    ///
    /// - Throws: -32021 when the client did not declare a capability the
    ///   requests need; `CancellationError` when the task is cancelled.
    public func requestInput(_ requests: [String: InputRequest]) async throws -> [String: InputResponse] {
        try Server.checkCapabilities(requests, method: request.method ?? CallTool.name, declared: request.clientCapabilities)
        if let taskID, let manager {
            return try await manager.requestInput(taskID, requests)
        }
        if let bridge {
            return try await bridge(requests)
        }
        throw MCPError.missingRequiredClientCapabilities(
            .init(extensions: [ExtensionID.tasks: [:]]),
            message: "Asking for input during this request needs the \(ExtensionID.tasks) extension")
    }

    /// Asks the user for input with a form elicitation.
    public func elicit(
        message: String, requestedSchema: Elicitation.RequestSchema = .init()
    ) async throws -> CreateElicitation.Result {
        let key = "elicitation"
        let responses = try await requestInput([key: .elicitation(message: message, requestedSchema: requestedSchema)])
        guard let result = responses[key]?.elicitation else {
            throw MCPError.internalError("The client returned no elicitation result")
        }
        return result
    }

    /// Suspends until the task finishes, for work that hands the task to
    /// another system, which finishes it with ``TaskManager/complete(_:with:)``
    /// or ``TaskManager/fail(_:with:)``. Then throws `CancellationError`; the
    /// task keeps the outcome it was given.
    ///
    /// - Throws: -32603 when the work runs inline, where nothing can finish it.
    public func untilFinished() async throws -> CallTool.Result {
        guard isTask else { throw MCPError.internalError("The work does not run as a task") }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    /// Sets the task's status message; does nothing inline.
    public func setStatusMessage(_ message: String?) async {
        guard let taskID, let manager else { return }
        await manager.setStatusMessage(taskID, message)
    }
}

typealias InputBridge = @Sendable ([String: InputRequest]) async throws -> [String: InputResponse]
typealias ProgressReporter = @Sendable (Double, Double?, String?) async throws -> Void

/// What the server knows about a `tools/call` that may run as a task.
struct TaskRuntime: Sendable {
    let manager: TaskManager
    /// The generation of the request.
    let generation: TaskGeneration
    /// Whether the client can receive a task for this request: it declared
    /// the extension (2026-07-28) or augmented the request (2025-11-25).
    let accepted: Bool
    /// The lifetime the client asked for (2025-11-25).
    let requestedTTL: Int?
    /// The tool's declared support.
    let support: TaskSupport
    /// Called with each task created for the request.
    var created: (@Sendable (TaskRecord) async -> Void)?
}

extension Server.HandlerContext {
    /// Runs `body` as a task when the client can use one, and inline otherwise.
    ///
    /// Call it from a `tools/call` handler of a server set up with
    /// ``Server/withTasks(_:)``, and return its result. A task is created
    /// when the client declared the `io.modelcontextprotocol/tasks` extension
    /// (2026-07-28) or asked for one with `task` (2025-11-25); the result
    /// then describes the task, and `body` runs on after the handler
    /// returned. Otherwise, and when the manager's limits are reached for a
    /// tool that does not require tasks, `body` runs inline and its result is
    /// returned.
    ///
    /// The tool's `execution.taskSupport` in `tools/list` decides which
    /// clients may call it: with ``TaskSupport/required``, a client that
    /// cannot use tasks is refused before the handler runs.
    ///
    /// - Parameters:
    ///   - ttl: The task's lifetime when the client asks for none; defaults
    ///     to the manager's.
    ///   - pollInterval: How long clients should wait between polls;
    ///     defaults to the manager's.
    ///   - body: The work. Its errors fail the task: an ``MCPError`` as is,
    ///     any other as -32603. Cancelling the task cancels it.
    public func runAsTask(
        ttl: Duration? = nil,
        pollInterval: Duration? = nil,
        _ body: @escaping @Sendable (TaskContext) async throws -> CallTool.Result
    ) async throws -> CallTool.Result {
        var plain = self
        plain.taskRuntime = nil
        plain.inputBridge = nil
        plain.progressReporter = nil
        guard let runtime = taskRuntime, runtime.accepted, let protocolVersion else {
            return try await body(
                TaskContext(taskID: nil, request: plain, manager: nil, bridge: inputBridge, progress: progressReporter))
        }
        guard
            let record = try await runtime.manager.create(
                context: self, method: method ?? CallTool.name, protocolVersion: protocolVersion,
                requestedTTL: runtime.requestedTTL, ttl: ttl, pollInterval: pollInterval)
        else {
            if runtime.support == .required || runtime.generation == .v1 {
                throw MCPError.internalError("Too many tasks are running; try again later")
            }
            return try await body(
                TaskContext(taskID: nil, request: plain, manager: nil, bridge: inputBridge, progress: progressReporter))
        }
        await runtime.created?(record)
        let context = TaskContext(
            taskID: record.id, request: plain, manager: runtime.manager, bridge: nil,
            progress: runtime.generation == .v1 ? progressReporter : nil)
        await runtime.manager.start(record.id, body, context: context)
        return CallTool.Result.creating(record.snapshot(detailed: false))
    }
}

extension Server {
    /// Runs `body` as a task when the current request can use one; see
    /// ``HandlerContext/runAsTask(ttl:pollInterval:_:)``. Outside a handler,
    /// `body` runs inline.
    public static func runAsTask(
        ttl: Duration? = nil,
        pollInterval: Duration? = nil,
        _ body: @escaping @Sendable (TaskContext) async throws -> CallTool.Result
    ) async throws -> CallTool.Result {
        guard let context = currentHandlerContext else {
            return try await body(
                TaskContext(taskID: nil, request: .init(id: .string(""), httpContext: nil), manager: nil, bridge: nil))
        }
        return try await context.runAsTask(ttl: ttl, pollInterval: pollInterval, body)
    }
}
