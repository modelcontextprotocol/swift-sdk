import Foundation
import Testing

@testable import MCP

/// Tests for task mode validation functions.
///
/// These tests verify the `validateTaskMode` and `canUseToolWithTaskMode` functions
/// which are the Swift equivalents of Python SDK's `Experimental` class methods:
/// - `is_task` → checked via `isTaskRequest` parameter
/// - `validate_task_mode()` → `validateTaskMode(isTaskRequest:taskSupport:)`
/// - `validate_for_tool()` → `validateTaskMode(isTaskRequest:for:)`
/// - `can_use_tool()` → `canUseToolWithTaskMode(clientSupportsTask:taskSupport:)`
///
/// Based on Python SDK's `tests/experimental/tasks/test_request_context.py`

// MARK: - validateTaskMode Tests

@Suite("validateTaskMode Tests")
struct ValidateTaskModeTests {

    // MARK: - Required Mode Tests

    @Test("REQUIRED mode with task request is valid")
    func testRequiredWithTaskRequestIsValid() throws {
        // Python: test_validate_task_mode_required_with_task_is_valid
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, taskSupport: .required)
        }
    }

    @Test("REQUIRED mode without task request throws error")
    func testRequiredWithoutTaskRequestThrows() throws {
        // Python: test_validate_task_mode_required_without_task_returns_error
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: false, taskSupport: .required)
        }
    }

    @Test("REQUIRED mode error contains descriptive message")
    func testRequiredErrorMessage() throws {
        // Python: test_validate_task_mode_required_without_task_raises_by_default
        do {
            try validateTaskMode(isTaskRequest: false, taskSupport: .required)
            Issue.record("Expected MCPError to be thrown")
        } catch let error as MCPError {
            let description = String(describing: error)
            #expect(description.contains("requires task-augmented"))
        }
    }

    // MARK: - Forbidden Mode Tests

    @Test("FORBIDDEN mode without task request is valid")
    func testForbiddenWithoutTaskRequestIsValid() throws {
        // Python: test_validate_task_mode_forbidden_without_task_is_valid
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, taskSupport: .forbidden)
        }
    }

    @Test("FORBIDDEN mode with task request throws error")
    func testForbiddenWithTaskRequestThrows() throws {
        // Python: test_validate_task_mode_forbidden_with_task_returns_error
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: true, taskSupport: .forbidden)
        }
    }

    @Test("FORBIDDEN mode error contains descriptive message")
    func testForbiddenErrorMessage() throws {
        // Python: test_validate_task_mode_forbidden_with_task_raises_by_default
        do {
            try validateTaskMode(isTaskRequest: true, taskSupport: .forbidden)
            Issue.record("Expected MCPError to be thrown")
        } catch let error as MCPError {
            let description = String(describing: error)
            #expect(description.contains("does not support task-augmented"))
        }
    }

    // MARK: - nil Mode (Treated as Forbidden) Tests

    @Test("nil mode treated as FORBIDDEN - task request throws")
    func testNilModeTreatedAsForbidden() throws {
        // Python: test_validate_task_mode_none_treated_as_forbidden
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: true, taskSupport: nil)
        }
    }

    @Test("nil mode without task request is valid")
    func testNilModeWithoutTaskRequestIsValid() throws {
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, taskSupport: nil)
        }
    }

    // MARK: - Optional Mode Tests

    @Test("OPTIONAL mode with task request is valid")
    func testOptionalWithTaskRequestIsValid() throws {
        // Python: test_validate_task_mode_optional_with_task_is_valid
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, taskSupport: .optional)
        }
    }

    @Test("OPTIONAL mode without task request is valid")
    func testOptionalWithoutTaskRequestIsValid() throws {
        // Python: test_validate_task_mode_optional_without_task_is_valid
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, taskSupport: .optional)
        }
    }
}

// MARK: - validateTaskMode for Tool Tests

@Suite("validateTaskMode for Tool Tests")
struct ValidateTaskModeForToolTests {

    @Test("Tool with execution.taskSupport=required rejects non-task request")
    func testToolWithRequiredRejectsNonTask() throws {
        // Python: test_validate_for_tool_with_execution_required
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .required)
        )

        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }

    @Test("Tool with execution.taskSupport=required accepts task request")
    func testToolWithRequiredAcceptsTask() throws {
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .required)
        )

        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }
    }

    @Test("Tool without execution (nil) rejects task request")
    func testToolWithoutExecutionRejectsTask() throws {
        // Python: test_validate_for_tool_without_execution
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: nil
        )

        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }
    }

    @Test("Tool without execution (nil) accepts non-task request")
    func testToolWithoutExecutionAcceptsNonTask() throws {
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: nil
        )

        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }

    @Test("Tool with execution.taskSupport=optional accepts task request")
    func testToolWithOptionalAcceptsTask() throws {
        // Python: test_validate_for_tool_optional_with_task
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .optional)
        )

        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }
    }

    @Test("Tool with execution.taskSupport=optional accepts non-task request")
    func testToolWithOptionalAcceptsNonTask() throws {
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .optional)
        )

        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }

    @Test("Tool with execution but nil taskSupport treats as forbidden")
    func testToolWithExecutionButNilTaskSupport() throws {
        let tool = Tool(
            name: "test",
            description: "test",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: nil)
        )

        // Task request should be rejected (nil = forbidden)
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }

        // Non-task request should be accepted
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }
}

// MARK: - canUseToolWithTaskMode Tests

@Suite("canUseToolWithTaskMode Tests")
struct CanUseToolWithTaskModeTests {

    @Test("REQUIRED mode with client task support returns true")
    func testRequiredWithTaskSupport() {
        // Python: test_can_use_tool_required_with_task_support
        let result = canUseToolWithTaskMode(clientSupportsTask: true, taskSupport: .required)
        #expect(result == true)
    }

    @Test("REQUIRED mode without client task support returns false")
    func testRequiredWithoutTaskSupport() {
        // Python: test_can_use_tool_required_without_task_support
        let result = canUseToolWithTaskMode(clientSupportsTask: false, taskSupport: .required)
        #expect(result == false)
    }

    @Test("OPTIONAL mode without client task support returns true")
    func testOptionalWithoutTaskSupport() {
        // Python: test_can_use_tool_optional_without_task_support
        let result = canUseToolWithTaskMode(clientSupportsTask: false, taskSupport: .optional)
        #expect(result == true)
    }

    @Test("OPTIONAL mode with client task support returns true")
    func testOptionalWithTaskSupport() {
        let result = canUseToolWithTaskMode(clientSupportsTask: true, taskSupport: .optional)
        #expect(result == true)
    }

    @Test("FORBIDDEN mode without client task support returns true")
    func testForbiddenWithoutTaskSupport() {
        // Python: test_can_use_tool_forbidden_without_task_support
        let result = canUseToolWithTaskMode(clientSupportsTask: false, taskSupport: .forbidden)
        #expect(result == true)
    }

    @Test("FORBIDDEN mode with client task support returns true")
    func testForbiddenWithTaskSupport() {
        let result = canUseToolWithTaskMode(clientSupportsTask: true, taskSupport: .forbidden)
        #expect(result == true)
    }

    @Test("nil mode (treated as FORBIDDEN) without client task support returns true")
    func testNilModeWithoutTaskSupport() {
        // Python: test_can_use_tool_none_without_task_support
        let result = canUseToolWithTaskMode(clientSupportsTask: false, taskSupport: nil)
        #expect(result == true)
    }

    @Test("nil mode (treated as FORBIDDEN) with client task support returns true")
    func testNilModeWithTaskSupport() {
        let result = canUseToolWithTaskMode(clientSupportsTask: true, taskSupport: nil)
        #expect(result == true)
    }
}

// MARK: - TaskMetadata and isTask Pattern Tests

@Suite("Task Request Detection Tests")
struct TaskRequestDetectionTests {

    /// These tests verify the pattern for detecting if a request is task-augmented,
    /// matching Python's `Experimental.is_task` property.

    @Test("Request with TaskMetadata is a task request")
    func testRequestWithTaskMetadataIsTask() {
        // Python: test_is_task_true_when_metadata_present
        let metadata: TaskMetadata? = TaskMetadata(ttl: 60000)
        let isTask = metadata != nil
        #expect(isTask == true)
    }

    @Test("Request without TaskMetadata is not a task request")
    func testRequestWithoutTaskMetadataIsNotTask() {
        // Python: test_is_task_false_when_no_metadata
        let metadata: TaskMetadata? = nil
        let isTask = metadata != nil
        #expect(isTask == false)
    }

    @Test("CallTool.Parameters with task metadata indicates task request")
    func testCallToolWithTaskMetadataIsTask() {
        let params = CallTool.Parameters(
            name: "test_tool",
            arguments: [:],
            task: TaskMetadata(ttl: 60000)
        )

        let isTask = params.task != nil
        #expect(isTask == true)
    }

    @Test("CallTool.Parameters without task metadata indicates non-task request")
    func testCallToolWithoutTaskMetadataIsNonTask() {
        let params = CallTool.Parameters(
            name: "test_tool",
            arguments: [:],
            task: nil
        )

        let isTask = params.task != nil
        #expect(isTask == false)
    }
}

// MARK: - Client Task Capability Detection Tests

@Suite("Client Task Capability Tests")
struct ClientTaskCapabilityTests {

    /// These tests verify the pattern for detecting if a client supports tasks,
    /// matching Python's `Experimental.client_supports_tasks` property.

    @Test("Client with tasks capability supports tasks")
    func testClientWithTasksCapability() {
        // Python: test_client_supports_tasks_true
        let capabilities = Client.Capabilities(tasks: .init())
        let supportsTask = capabilities.tasks != nil
        #expect(supportsTask == true)
    }

    @Test("Client without tasks capability does not support tasks")
    func testClientWithoutTasksCapability() {
        // Python: test_client_supports_tasks_false_no_tasks
        let capabilities = Client.Capabilities()
        let supportsTask = capabilities.tasks != nil
        #expect(supportsTask == false)
    }

    @Test("Nil capabilities means no task support")
    func testNilCapabilities() {
        // Python: test_client_supports_tasks_false_no_capabilities
        let capabilities: Client.Capabilities? = nil
        let supportsTask = capabilities?.tasks != nil
        #expect(supportsTask == false)
    }

    @Test("Server can check client task support")
    func testServerCanCheckClientTaskSupport() {
        // With tasks capability
        let capsWithTasks = Client.Capabilities(tasks: .init())
        #expect(capsWithTasks.tasks != nil)

        // Without tasks capability
        let capsWithoutTasks = Client.Capabilities(sampling: .init())
        #expect(capsWithoutTasks.tasks == nil)
    }
}

// MARK: - Integration Tests for Task Mode Validation

@Suite("Task Mode Validation Integration Tests")
struct TaskModeValidationIntegrationTests {

    @Test("Tool invocation validation flow for required task tool")
    func testToolInvocationValidationFlowRequired() throws {
        // Simulate a tool that requires task-augmented invocation
        let tool = Tool(
            name: "long_running_analysis",
            description: "A long-running analysis that requires task mode",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .required)
        )

        // Client without task support cannot use this tool
        let clientCapsNoTasks = Client.Capabilities()
        let canUse1 = canUseToolWithTaskMode(
            clientSupportsTask: clientCapsNoTasks.tasks != nil,
            taskSupport: tool.execution?.taskSupport
        )
        #expect(canUse1 == false)

        // Client with task support can use this tool
        let clientCapsWithTasks = Client.Capabilities(tasks: .init())
        let canUse2 = canUseToolWithTaskMode(
            clientSupportsTask: clientCapsWithTasks.tasks != nil,
            taskSupport: tool.execution?.taskSupport
        )
        #expect(canUse2 == true)

        // Non-task request should be rejected
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }

        // Task request should be accepted
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }
    }

    @Test("Tool invocation validation flow for forbidden task tool")
    func testToolInvocationValidationFlowForbidden() throws {
        // Simulate a tool that forbids task-augmented invocation
        let tool = Tool(
            name: "quick_lookup",
            description: "A quick lookup that cannot be a task",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .forbidden)
        )

        // Any client can use this tool
        let canUse = canUseToolWithTaskMode(
            clientSupportsTask: false,
            taskSupport: tool.execution?.taskSupport
        )
        #expect(canUse == true)

        // Task request should be rejected
        #expect(throws: MCPError.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }

        // Non-task request should be accepted
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }

    @Test("Tool invocation validation flow for optional task tool")
    func testToolInvocationValidationFlowOptional() throws {
        // Simulate a tool that optionally supports task-augmented invocation
        let tool = Tool(
            name: "flexible_processor",
            description: "Can run as task or not",
            inputSchema: ["type": "object"],
            execution: Tool.Execution(taskSupport: .optional)
        )

        // Any client can use this tool
        let canUseWithTask = canUseToolWithTaskMode(
            clientSupportsTask: true,
            taskSupport: tool.execution?.taskSupport
        )
        #expect(canUseWithTask == true)

        let canUseWithoutTask = canUseToolWithTaskMode(
            clientSupportsTask: false,
            taskSupport: tool.execution?.taskSupport
        )
        #expect(canUseWithoutTask == true)

        // Both task and non-task requests should be accepted
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: true, for: tool)
        }
        #expect(throws: Never.self) {
            try validateTaskMode(isTaskRequest: false, for: tool)
        }
    }

    @Test("Error codes match MCP spec")
    func testErrorCodesMatchSpec() throws {
        // Per MCP spec: METHOD_NOT_FOUND (-32601) for task mode violations
        do {
            try validateTaskMode(isTaskRequest: false, taskSupport: .required)
            Issue.record("Expected error")
        } catch let error as MCPError {
            // MCPError.methodNotFound should be used
            switch error {
            case .methodNotFound:
                // Correct error type
                break
            default:
                Issue.record("Expected methodNotFound error, got \(error)")
            }
        }

        do {
            try validateTaskMode(isTaskRequest: true, taskSupport: .forbidden)
            Issue.record("Expected error")
        } catch let error as MCPError {
            switch error {
            case .methodNotFound:
                // Correct error type
                break
            default:
                Issue.record("Expected methodNotFound error, got \(error)")
            }
        }
    }
}
