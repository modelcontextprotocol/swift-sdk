import Foundation
import Logging

public protocol ServerContext: Actor {
    /// - Parameters:
    /// - Throws: MCPError if the request fails
    func elicit<T: Codable & Hashable & Sendable>(
        message: String,
        schema: T.Type
    ) async throws -> ElicitationResult<T>
}

public actor DefaultServerContext: ServerContext {
    private weak var server: Server?
    
    public init(server: Server) {
        self.server = server
    }
    
    public func elicit<T: Codable & Hashable & Sendable>(
        message: String,
        schema: T.Type
    ) async throws -> ElicitationResult<T> {
        guard let server = server else {
            throw MCPError.internalError("Server context is no longer valid")
        }
        
        let schemaValue = Value.object([
            "type": .string("object"),
            "description": .string("Schema for \(String(describing: T.self))")
        ])
        
        let parameters = CreateElicitation.Parameters(
            message: message,
            schema: schemaValue
        )
        
        let result = try await server.requestElicitation(parameters)
        
        return try ElicitationResult<T>(from: result)
    }
}

public protocol ContextProvider {
    associatedtype Context: ServerContext
    var context: Context { get async }
}

extension Server: ContextProvider {
    public var context: DefaultServerContext {
        get async {
            DefaultServerContext(server: self)
        }
    }
}
