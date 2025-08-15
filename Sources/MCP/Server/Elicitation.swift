import Foundation

/// The Model Context Protocol (MCP) allows servers to request user input
/// 
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/draft/client/elicitation
public enum CreateElicitation: Method {
    public static let name = "elicitation/create"
    
    public struct Parameters: Hashable, Codable, Sendable {
        public let message: String
        public let schema: Value
        public let metadata: [String: Value]?
        
        public init(
            message: String,
            schema: Value,
            metadata: [String: Value]? = nil
        ) {
            self.message = message
            self.schema = schema
            self.metadata = metadata
        }
        
        public func validateSecurity() -> [String] {
            var warnings: [String] = []
            
            let lowercaseMessage = message.lowercased()
            let sensitiveTerms = ["password", "ssn", "social security", "credit card", "bank account", "pin", "cvv"]
            
            for term in sensitiveTerms {
                if lowercaseMessage.contains(term) {
                    warnings.append("Elicitation requests sensitive information: \(term)")
                }
            }
            
            if metadata?["server_name"] == nil && metadata?["server_display_name"] == nil {
                warnings.append("Missing server identification in metadata")
            }
            
            return warnings
        }
    }
    
    public struct Result: Hashable, Codable, Sendable {
        public enum Action: String, Hashable, Codable, Sendable {
            case accept
            case decline
            case cancel
        }
        
        public let action: Action
        public let data: Value?
        
        public init(action: Action, data: Value? = nil) {
            self.action = action
            self.data = data
        }
    }
}

public struct ElicitationResult<T: Codable & Hashable & Sendable>: Hashable, Sendable {
    public let action: CreateElicitation.Result.Action
    public let data: T?
    
    public init(action: CreateElicitation.Result.Action, data: T? = nil) {
        self.action = action
        self.data = data
    }
    
    public init(from result: CreateElicitation.Result) throws {
        self.action = result.action
        if let resultData = result.data, result.action == .accept {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(resultData)
            self.data = try decoder.decode(T.self, from: data)
        } else {
            self.data = nil
        }
    }
    
    public var isAccepted: Bool {
        return action == .accept && data != nil
    }
    
    public var isRejected: Bool {
        return action == .decline || action == .cancel
    }
}
