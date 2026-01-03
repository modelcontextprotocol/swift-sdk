import Foundation

// MARK: - Server Task Context

/// Context for task handlers to interact with the task lifecycle.
///
/// This context is passed to task handlers and provides:
/// - Task status updates
/// - Task completion/failure
/// - Cancellation checking
/// - Mid-task elicitation and sampling
/// - Access to the underlying task and store
///
/// - Important: This is an experimental API that may change without notice.
///
/// ## Example
///
/// ```swift
/// async func work(context: ServerTaskContext) async throws -> CallTool.Result {
///     try await context.updateStatus("Starting work...")
///
///     // Check for cancellation periodically
///     guard !context.isCancelled else {
///         throw CancellationError()
///     }
///
///     // Request user input mid-task
///     let result = try await context.elicit(
///         message: "Please confirm the operation",
///         requestedSchema: ElicitationSchema(properties: [
///             "confirm": .boolean(BooleanSchema(title: "Confirm"))
///         ])
///     )
///
///     if result.action != .accept {
///         throw CancellationError()
///     }
///
///     return CallTool.Result(content: [.text("Done!")])
/// }
/// ```
public final class ServerTaskContext: @unchecked Sendable {
    /// The task this context is for.
    public private(set) var task: MCPTask

    /// The task store for persistence.
    private let store: any TaskStore

    /// The message queue for side-channel communication.
    private let queue: any TaskMessageQueue

    /// Client capabilities for checking support.
    private let clientCapabilities: Client.Capabilities?

    /// Server reference for task-augmented requests (elicitAsTask, createMessageAsTask).
    private let server: Server?

    /// Counter for generating request IDs.
    private var requestIdCounter: Int = 0

    /// Whether cancellation has been requested.
    private var _isCancelled = false

    /// Check if cancellation has been requested.
    public var isCancelled: Bool { _isCancelled }

    /// The task ID.
    public var taskId: String { task.taskId }

    /// Create a server task context.
    ///
    /// - Parameters:
    ///   - task: The task to manage
    ///   - store: The task store for persistence
    ///   - queue: The message queue for side-channel communication
    ///   - clientCapabilities: Client capabilities for checking support
    ///   - server: Optional server reference for task-augmented requests
    public init(
        task: MCPTask,
        store: any TaskStore,
        queue: any TaskMessageQueue,
        clientCapabilities: Client.Capabilities? = nil,
        server: Server? = nil
    ) {
        self.task = task
        self.store = store
        self.queue = queue
        self.clientCapabilities = clientCapabilities
        self.server = server
    }

    /// Generate a unique request ID for queued requests.
    private func nextRequestId() -> RequestId {
        requestIdCounter += 1
        return .string("task-\(taskId)-req-\(requestIdCounter)")
    }

    /// Request cancellation of the task.
    ///
    /// This sets the `isCancelled` flag but doesn't immediately stop execution.
    /// Task handlers should check this flag periodically and exit gracefully.
    public func requestCancellation() {
        _isCancelled = true
    }

    /// Update the task status with a message.
    ///
    /// This updates the task to `.working` status with the provided message.
    /// Use this to report progress during long-running operations.
    ///
    /// - Parameters:
    ///   - message: A human-readable status message
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if the task cannot be updated
    public func updateStatus(_ message: String, notify: Bool = true) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .working,
            statusMessage: message
        )
        task = updatedTask
        if notify {
            await sendStatusNotification()
        }
    }

    /// Mark the task as requiring input.
    ///
    /// This updates the task to `.inputRequired` status, signaling that
    /// the task is waiting for user input (e.g., via elicitation).
    ///
    /// - Parameters:
    ///   - message: Optional message describing what input is needed
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if the task cannot be updated
    public func setInputRequired(_ message: String? = nil, notify: Bool = true) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .inputRequired,
            statusMessage: message
        )
        task = updatedTask
        if notify {
            await sendStatusNotification()
        }
    }

    /// Complete the task successfully with a result.
    ///
    /// This stores the result and transitions the task to `.completed` status.
    ///
    /// - Parameters:
    ///   - result: The result value to store
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if the task cannot be completed
    public func complete(result: Value, notify: Bool = true) async throws {
        try await store.storeResult(taskId: taskId, result: result)
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .completed,
            statusMessage: nil
        )
        task = updatedTask
        if notify {
            await sendStatusNotification()
        }
    }

    /// Complete the task successfully with a CallTool.Result.
    ///
    /// This is a convenience method that encodes the result and stores it.
    ///
    /// - Parameters:
    ///   - toolResult: The tool result
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if encoding fails or the task cannot be completed
    public func complete(toolResult: CallTool.Result, notify: Bool = true) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(toolResult)
        let decoder = JSONDecoder()
        let value = try decoder.decode(Value.self, from: data)
        try await complete(result: value, notify: notify)
    }

    /// Fail the task with an error message.
    ///
    /// This transitions the task to `.failed` status with the error message.
    ///
    /// - Parameters:
    ///   - error: A human-readable error message
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if the task cannot be updated
    public func fail(error: String, notify: Bool = true) async throws {
        let updatedTask = try await store.updateTask(
            taskId: taskId,
            status: .failed,
            statusMessage: error
        )
        task = updatedTask
        if notify {
            await sendStatusNotification()
        }
    }

    /// Fail the task with an Error.
    ///
    /// - Parameters:
    ///   - error: The error that caused the failure
    ///   - notify: Whether to send a `TaskStatusNotification` to the client (default: true)
    /// - Throws: Error if the task cannot be updated
    public func fail(error: any Error, notify: Bool = true) async throws {
        try await fail(error: error.localizedDescription, notify: notify)
    }

    /// Send a task status notification to the client.
    ///
    /// This sends a `notifications/tasks/status` notification with the current task state.
    /// Per the MCP spec, this is sent when a task's status changes to keep the client informed.
    private func sendStatusNotification() async {
        guard let server else { return }
        do {
            try await server.notify(TaskStatusNotification.message(.init(task: task)))
        } catch {
            // Notification failures shouldn't break task execution
            // The client will still get status updates via polling
        }
    }

    // MARK: - Mid-Task Interactive Requests

    // MARK: - Mid-Task Interactive Requests: Form Elicitation

    /// Request user input via form elicitation mid-task.
    ///
    /// This queues an elicitation request for delivery via `tasks/result` and waits
    /// for the client's response. The task status is automatically transitioned to
    /// `inputRequired` while waiting and restored to `working` when the response arrives.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await context.elicit(
    ///     message: "Please confirm the deletion",
    ///     requestedSchema: ElicitationSchema(properties: [
    ///         "confirm": .boolean(BooleanSchema(title: "Confirm deletion"))
    ///     ])
    /// )
    ///
    /// if result.action == .accept, let content = result.content {
    ///     let confirmed = content["confirm"]
    ///     // Process the response
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - message: The message to present to the user
    ///   - requestedSchema: The schema defining the form fields
    /// - Returns: The elicitation result from the client
    /// - Throws: MCPError if the client doesn't support elicitation or if the request fails
    public func elicit(
        message: String,
        requestedSchema: ElicitationSchema
    ) async throws -> ElicitResult {
        // Check client supports elicitation
        guard clientCapabilities?.elicitation?.form != nil else {
            throw MCPError.invalidRequest("Client does not support form elicitation")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for user input")

        // Build the elicitation request with related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = ElicitRequestFormParams(
            mode: "form",
            message: message,
            requestedSchema: requestedSchema,
            _meta: RequestMeta(additionalFields: relatedTaskMeta)
        )

        // Build JSON-RPC request
        let request = Elicit.request(id: requestId, .form(params))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for response
        let resolver = Resolver<Value>()

        // Queue the request with resolver
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            // Also signal the store to wake up any waiters
            await store.notifyUpdate(taskId: taskId)

            // Wait for response
            let responseValue = try await resolver.wait()

            // Restore status to working
            try await updateStatus("Continuing after user input")

            // Decode the response
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            return try decoder.decode(ElicitResult.self, from: responseData)
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    // MARK: - Mid-Task Interactive Requests: URL Elicitation

    /// Request user interaction via URL-mode elicitation mid-task.
    ///
    /// This queues a URL elicitation request for delivery via `tasks/result` and waits
    /// for the client's response. URL mode is used for out-of-band flows like OAuth
    /// or credential collection, where the user needs to navigate to an external URL.
    ///
    /// The task status is automatically transitioned to `inputRequired` while waiting
    /// and restored to `working` when the response arrives.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await context.elicitUrl(
    ///     message: "Please authorize access to your account",
    ///     url: "https://example.com/oauth?state=abc123",
    ///     elicitationId: "oauth-flow-123"
    /// )
    ///
    /// switch result.action {
    /// case .accept:
    ///     // User completed the flow
    /// case .decline:
    ///     // User declined
    /// case .cancel:
    ///     // User cancelled
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - message: Human-readable explanation of why the interaction is needed
    ///   - url: The URL the user should navigate to
    ///   - elicitationId: Unique identifier for tracking this elicitation
    /// - Returns: The elicitation result from the client
    /// - Throws: MCPError if the client doesn't support URL elicitation or if the request fails
    public func elicitUrl(
        message: String,
        url: String,
        elicitationId: String
    ) async throws -> ElicitResult {
        // Check client supports URL elicitation
        guard clientCapabilities?.elicitation?.url != nil else {
            throw MCPError.invalidRequest("Client does not support URL elicitation")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for external user interaction")

        // Build the URL elicitation request with related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = ElicitRequestURLParams(
            message: message,
            elicitationId: elicitationId,
            url: url,
            _meta: RequestMeta(additionalFields: relatedTaskMeta)
        )

        // Build JSON-RPC request
        let request = Elicit.request(id: requestId, .url(params))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for response
        let resolver = Resolver<Value>()

        // Queue the request with resolver
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            // Also signal the store to wake up any waiters
            await store.notifyUpdate(taskId: taskId)

            // Wait for response
            let responseValue = try await resolver.wait()

            // Restore status to working
            try await updateStatus("Continuing after external interaction")

            // Decode the response
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            return try decoder.decode(ElicitResult.self, from: responseData)
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    // MARK: - Mid-Task Interactive Requests: Sampling

    /// Request LLM sampling mid-task.
    ///
    /// This queues a sampling request for delivery via `tasks/result` and waits
    /// for the client's response. The task status is automatically transitioned to
    /// `inputRequired` while waiting and restored to `working` when the response arrives.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await context.createMessage(
    ///     messages: [
    ///         .user(.text("What is the capital of France?"))
    ///     ],
    ///     maxTokens: 100
    /// )
    ///
    /// // Process the LLM response
    /// for block in result.content {
    ///     if case .text(let text, _, _) = block {
    ///         print(text)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - maxTokens: Maximum tokens to generate
    ///   - modelPreferences: Optional model selection preferences
    ///   - systemPrompt: Optional system prompt
    ///   - includeContext: What MCP context to include
    ///   - temperature: Controls randomness (0.0 to 1.0)
    ///   - stopSequences: Array of sequences that stop generation
    ///   - metadata: Additional provider-specific parameters
    /// - Returns: The sampling result from the client
    /// - Throws: MCPError if the client doesn't support sampling or if the request fails
    public func createMessage(
        messages: [Sampling.Message],
        maxTokens: Int,
        modelPreferences: ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil
    ) async throws -> CreateSamplingMessage.Result {
        // Check client supports sampling
        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for LLM response")

        // Build the sampling request with related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = CreateSamplingMessage.Parameters(
            messages: messages,
            modelPreferences: modelPreferences,
            systemPrompt: systemPrompt,
            includeContext: includeContext,
            temperature: temperature,
            maxTokens: maxTokens,
            stopSequences: stopSequences,
            metadata: metadata,
            _meta: RequestMeta(additionalFields: relatedTaskMeta)
        )

        // Build JSON-RPC request
        let request = CreateSamplingMessage.request(id: requestId, params)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for response
        let resolver = Resolver<Value>()

        // Queue the request with resolver
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            // Also signal the store to wake up any waiters
            await store.notifyUpdate(taskId: taskId)

            // Wait for response
            let responseValue = try await resolver.wait()

            // Restore status to working
            try await updateStatus("Continuing after LLM response")

            // Decode the response
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            return try decoder.decode(CreateSamplingMessage.Result.self, from: responseData)
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    // MARK: - Task-Augmented Elicitation (Server → Client Task)

    /// Request user input via task-augmented form elicitation.
    ///
    /// Unlike regular `elicit()`, this method creates a task on the CLIENT side,
    /// allowing the client to handle the elicitation asynchronously. This is useful
    /// when the client needs to perform complex operations during elicitation
    /// (e.g., OAuth flows that require external callbacks).
    ///
    /// The method:
    /// 1. Sends an elicitation request with a `task` field to the client
    /// 2. Client returns a `CreateTaskResult` immediately
    /// 3. Polls the client's task until it reaches a terminal state
    /// 4. Retrieves and returns the final `ElicitResult`
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Task-augmented elicitation (client handles as a task)
    /// let result = try await context.elicitAsTask(
    ///     message: "Please authorize access to your account",
    ///     requestedSchema: ElicitationSchema(properties: [
    ///         "authorized": .boolean(BooleanSchema(title: "Authorized"))
    ///     ])
    /// )
    ///
    /// if result.action == .accept {
    ///     // User completed authorization
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - message: The message to present to the user
    ///   - requestedSchema: The schema defining the form fields
    ///   - ttl: Optional time-to-live for the client-side task
    /// - Returns: The elicitation result from the client
    /// - Throws: MCPError if the client doesn't support task-augmented elicitation or if the request fails
    public func elicitAsTask(
        message: String,
        requestedSchema: ElicitationSchema,
        ttl: Int? = nil
    ) async throws -> ElicitResult {
        // Check client supports task-augmented elicitation
        guard hasTaskAugmentedElicitation(clientCapabilities) else {
            throw MCPError.invalidRequest("Client does not support task-augmented elicitation")
        }

        guard clientCapabilities?.elicitation?.form != nil else {
            throw MCPError.invalidRequest("Client does not support form elicitation")
        }

        // Need server reference to poll client tasks after CreateTaskResult
        guard let server else {
            throw MCPError.internalError("Server reference required for task-augmented requests")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for client task completion")

        // Build the elicitation request with task field and related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = ElicitRequestFormParams(
            message: message,
            requestedSchema: requestedSchema,
            _meta: RequestMeta(additionalFields: relatedTaskMeta),
            task: TaskMetadata(ttl: ttl)
        )

        // Build JSON-RPC request
        let request = Elicit.request(id: requestId, .form(params))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for CreateTaskResult response
        let resolver = Resolver<Value>()

        // Queue the request with resolver (like regular elicit)
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            await store.notifyUpdate(taskId: taskId)

            // Wait for CreateTaskResult response (delivered when client polls tasks/result)
            let responseValue = try await resolver.wait()

            // Decode as CreateTaskResult
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            let createResult = try decoder.decode(CreateTaskResult.self, from: responseData)
            let clientTaskId = createResult.task.taskId

            // NOW poll the client's task DIRECTLY (not through queue)
            try await pollClientTaskUntilTerminal(server: server, taskId: clientTaskId)

            // Get the final result from client DIRECTLY
            let result: ElicitResult = try await server.getClientTaskResultAs(
                taskId: clientTaskId,
                type: ElicitResult.self
            )

            // Restore status to working
            try await updateStatus("Continuing after client task completion")

            return result
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    /// Request user input via task-augmented URL elicitation.
    ///
    /// Similar to `elicitAsTask(message:requestedSchema:)` but for URL-mode elicitation.
    /// This creates a task on the CLIENT side for handling out-of-band flows like OAuth.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// - Parameters:
    ///   - message: Human-readable explanation of why the interaction is needed
    ///   - url: The URL the user should navigate to
    ///   - elicitationId: Unique identifier for tracking this elicitation
    ///   - ttl: Optional time-to-live for the client-side task
    /// - Returns: The elicitation result from the client
    /// - Throws: MCPError if the client doesn't support task-augmented URL elicitation
    public func elicitUrlAsTask(
        message: String,
        url: String,
        elicitationId: String,
        ttl: Int? = nil
    ) async throws -> ElicitResult {
        // Check client supports task-augmented elicitation
        guard hasTaskAugmentedElicitation(clientCapabilities) else {
            throw MCPError.invalidRequest("Client does not support task-augmented elicitation")
        }

        guard clientCapabilities?.elicitation?.url != nil else {
            throw MCPError.invalidRequest("Client does not support URL elicitation")
        }

        // Need server reference to poll client tasks after CreateTaskResult
        guard let server else {
            throw MCPError.internalError("Server reference required for task-augmented requests")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for client task completion")

        // Build the URL elicitation request with task field and related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = ElicitRequestURLParams(
            message: message,
            elicitationId: elicitationId,
            url: url,
            _meta: RequestMeta(additionalFields: relatedTaskMeta),
            task: TaskMetadata(ttl: ttl)
        )

        // Build JSON-RPC request
        let request = Elicit.request(id: requestId, .url(params))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for CreateTaskResult response
        let resolver = Resolver<Value>()

        // Queue the request with resolver (like regular elicitUrl)
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            await store.notifyUpdate(taskId: taskId)

            // Wait for CreateTaskResult response (delivered when client polls tasks/result)
            let responseValue = try await resolver.wait()

            // Decode as CreateTaskResult
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            let createResult = try decoder.decode(CreateTaskResult.self, from: responseData)
            let clientTaskId = createResult.task.taskId

            // NOW poll the client's task DIRECTLY (not through queue)
            try await pollClientTaskUntilTerminal(server: server, taskId: clientTaskId)

            // Get the final result from client DIRECTLY
            let result: ElicitResult = try await server.getClientTaskResultAs(
                taskId: clientTaskId,
                type: ElicitResult.self
            )

            // Restore status to working
            try await updateStatus("Continuing after client task completion")

            return result
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    // MARK: - Task-Augmented Sampling (Server → Client Task)

    /// Request LLM sampling via a task-augmented request.
    ///
    /// Unlike regular `createMessage()`, this method creates a task on the CLIENT side,
    /// allowing the client to handle the sampling request asynchronously. This is useful
    /// for long-running LLM operations or when the client needs to perform additional
    /// processing during sampling.
    ///
    /// The method:
    /// 1. Sends a sampling request with a `task` field to the client
    /// 2. Client returns a `CreateTaskResult` immediately
    /// 3. Polls the client's task until it reaches a terminal state
    /// 4. Retrieves and returns the final `CreateSamplingMessage.Result`
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Task-augmented sampling (client handles as a task)
    /// let result = try await context.createMessageAsTask(
    ///     messages: [
    ///         .user(.text("Analyze this large document..."))
    ///     ],
    ///     maxTokens: 4000
    /// )
    ///
    /// for block in result.content {
    ///     if case .text(let text, _, _) = block {
    ///         print(text)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - maxTokens: Maximum tokens to generate
    ///   - modelPreferences: Optional model selection preferences
    ///   - systemPrompt: Optional system prompt
    ///   - includeContext: What MCP context to include
    ///   - temperature: Controls randomness (0.0 to 1.0)
    ///   - stopSequences: Array of sequences that stop generation
    ///   - metadata: Additional provider-specific parameters
    ///   - ttl: Optional time-to-live for the client-side task
    /// - Returns: The sampling result from the client
    /// - Throws: MCPError if the client doesn't support task-augmented sampling
    public func createMessageAsTask(
        messages: [Sampling.Message],
        maxTokens: Int,
        modelPreferences: ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil,
        ttl: Int? = nil
    ) async throws -> CreateSamplingMessage.Result {
        // Check client supports task-augmented sampling
        guard hasTaskAugmentedSampling(clientCapabilities) else {
            throw MCPError.invalidRequest("Client does not support task-augmented sampling")
        }

        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        // Need server reference to poll client tasks after CreateTaskResult
        guard let server else {
            throw MCPError.internalError("Server reference required for task-augmented requests")
        }

        // Update task status to input_required
        try await setInputRequired("Waiting for client LLM task completion")

        // Build the sampling request with task field and related task metadata
        let requestId = nextRequestId()
        let relatedTaskMeta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string(taskId)])
        ]

        let params = CreateSamplingMessage.Parameters(
            messages: messages,
            modelPreferences: modelPreferences,
            systemPrompt: systemPrompt,
            includeContext: includeContext,
            temperature: temperature,
            maxTokens: maxTokens,
            stopSequences: stopSequences,
            metadata: metadata,
            _meta: RequestMeta(additionalFields: relatedTaskMeta),
            task: TaskMetadata(ttl: ttl)
        )

        // Build JSON-RPC request
        let request = CreateSamplingMessage.request(id: requestId, params)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        // Create resolver to wait for CreateTaskResult response
        let resolver = Resolver<Value>()

        // Queue the request with resolver (like regular createMessage)
        let queuedRequest = QueuedRequestWithResolver(
            message: .request(requestData, timestamp: Date()),
            resolver: resolver,
            originalRequestId: requestId
        )

        do {
            try await queue.enqueueWithResolver(taskId: taskId, request: queuedRequest, maxSize: nil)

            // Signal that a message is available
            await queue.notifyMessageAvailable(taskId: taskId)
            await store.notifyUpdate(taskId: taskId)

            // Wait for CreateTaskResult response (delivered when client polls tasks/result)
            let responseValue = try await resolver.wait()

            // Decode as CreateTaskResult
            let decoder = JSONDecoder()
            let responseData = try encoder.encode(responseValue)
            let createResult = try decoder.decode(CreateTaskResult.self, from: responseData)
            let clientTaskId = createResult.task.taskId

            // NOW poll the client's task DIRECTLY (not through queue)
            try await pollClientTaskUntilTerminal(server: server, taskId: clientTaskId)

            // Get the final result from client DIRECTLY
            let result: CreateSamplingMessage.Result = try await server.getClientTaskResultAs(
                taskId: clientTaskId,
                type: CreateSamplingMessage.Result.self
            )

            // Restore status to working
            try await updateStatus("Continuing after client LLM task completion")

            return result
        } catch {
            // Restore status to working even on error
            try? await updateStatus("Continuing after error")
            throw error
        }
    }

    /// Poll a client task until it reaches a terminal state.
    ///
    /// - Parameters:
    ///   - server: The server to use for polling
    ///   - taskId: The client-side task identifier
    private func pollClientTaskUntilTerminal(server: Server, taskId: String) async throws {
        while true {
            let result = try await server.getClientTask(taskId: taskId)

            if result.status.isTerminal {
                return
            }

            // Wait for poll interval (default 500ms)
            let intervalMs = result.pollInterval ?? 500
            try await Task.sleep(for: .milliseconds(intervalMs))
        }
    }
}
