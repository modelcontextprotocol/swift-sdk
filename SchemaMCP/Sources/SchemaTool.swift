import Foundation
import JSONSchema
import JSONSchemaBuilder
import MCP

public extension Server {
    /// Registers a toolbox of tools with the server.
    /// - Parameter toolBox: The toolbox to register.
    /// - Returns: The server instance for chaining.
    @discardableResult
    func withTools<each S>(
        _ toolBox: ToolBox< repeat each S>
    ) -> Self {
        withMethodHandler(ListTools.self) { parameters in
            try .init(tools: toolBox.mcpTools(), nextCursor: parameters.cursor)
        }

        return withMethodHandler(CallTool.self) { call in
            for tool in repeat each toolBox.tools {
                if call.name == tool.name {
                    let result = try await tool.handler(call.arguments)
                    return result
                }
            }

            return .init(content: [.text("Tool \(call.name) not found")], isError: true)
        }
    }
}

/// A toolbox holding a variadic list of schema tools.
public struct ToolBox<each T: Schemable>: Sendable {
    /// The tuple of tools.
    public let tools: (repeat SchemaTool<each T>)

    /// Initializes a toolbox with the given tools.
    /// - Parameter tools: The tuple of tools.
    public init(tools: (repeat SchemaTool<each T>)) {
        self.tools = tools
    }

    /// Converts all tools to MCP tool definitions.
    /// - Throws: `MCPError` if any conversion fails.
    public func mcpTools() throws(MCPError) -> [Tool] {
        var mcpTools: [Tool] = []
        for tool in repeat (each tools) {
            try mcpTools.append(tool.toMCPTool())
        }
        return mcpTools
    }
}

/// Represents a tool with a schema-based input and async handler.
public struct SchemaTool<Schema: Schemable>: Identifiable, Sendable {
    /// The tool name.
    public let name: String
    /// The tool description.
    public let description: String
    /// The tool input schema type.
    public let inputType: Schema.Type
    /// The tool handler.
    private let handlerClosure: @Sendable (Schema) async throws -> CallTool.Result
    /// Schema used to parse or validate input.
    private let inputSchema: Schema.Schema

    /// The tool's unique identifier (same as name).
    public var id: String { name }

    /// Parses arguments into the schema type.
    /// - Parameter arguments: The arguments to parse.
    /// - Throws: `MCPError.parseError` if parsing fails or type mismatch.
    public func parse(_ arguments: [String: Value]?) throws(MCPError) -> Schema {
        let output = try inputSchema.parse(arguments)
        guard let schema = output as? Schema else {
            throw MCPError.parseError("Schema.Schema.Output != Schema")
        }
        return schema
    }

    /// Handles a tool call with arguments.
    /// - Parameter arguments: The arguments to handle.
    /// - Returns: The result of the tool call.
    public func handler(
        _ arguments: [String: Value]?
    ) async throws -> CallTool.Result {
        do {
            let output = try inputSchema.parse(arguments)
            guard let schema = output as? Schema else {
                throw MCPError.parseError("Schema.Schema.Output != Schema")
            }
            return try await handlerClosure(schema)
        } catch {
            return .init(content: [.text("Failed to parse arguments: \(error)")], isError: true)
        }
    }

    /// Initializes a new `SchemaTool`.
    /// - Parameters:
    ///   - name: The tool name.
    ///   - description: The tool description.
    ///   - inputType: The schema type for input.
    ///   - handler: The async handler closure.
    public init(
        name: String,
        description: String,
        inputType: Schema.Type,
        handler: @escaping @Sendable (Schema) async throws -> CallTool.Result
    ) {
        self.name = name
        self.description = description
        self.inputType = inputType
        handlerClosure = handler
        inputSchema = inputType.schema
    }

    /// Converts the tool to an MCP tool definition.
    /// - Throws: `MCPError` if conversion fails.
    public func toMCPTool() throws(MCPError) -> Tool {
        try .init(
            name: name,
            description: description,
            inputSchema: .init(schema: inputSchema)
        )
    }
}

/// Extension to initialize `Value` from a JSONSchemaComponent.
public extension Value {
    /// Initializes a `Value` from a schema component.
    /// - Parameter schema: The schema component to encode.
    /// - Throws: `MCPError.parseError` if encoding or decoding fails.
    init(schema: some JSONSchemaComponent) throws(MCPError) {
        do {
            let data = try JSONEncoder().encode(schema.definition())
            self = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw MCPError.parseError("Invalid schema: \(error)")
        }
    }
}

/// Extension to parse arguments using a JSONSchemaComponent.
public extension JSONSchemaComponent {
    /// Parses and validates arguments using the schema.
    /// - Parameter arguments: The arguments to parse.
    /// - Throws: `MCPError.invalidParams` if parsing fails.
    func parse(_ arguments: [String: Value]?) throws(MCPError) -> Output {
        do {
            let data = try JSONEncoder().encode(arguments)
            let string = String(data: data, encoding: .utf8) ?? ""
            return try parseAndValidate(instance: string)
        } catch {
            throw MCPError.invalidParams("Failed to parse arguments: \(error)")
        }
    }
}
