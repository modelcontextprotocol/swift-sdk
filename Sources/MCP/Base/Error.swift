import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// MARK: - Error Codes

/// JSON-RPC and MCP error codes.
///
/// Error codes are organized by source:
/// - Standard JSON-RPC 2.0 error codes (-32700 to -32600)
/// - MCP specification error codes (-32002, -32042)
/// - SDK-specific error codes (-32000, -32001, -32003)
public enum ErrorCode {
    // MARK: Standard JSON-RPC 2.0 Errors

    /// Parse error: Invalid JSON was received by the server.
    public static let parseError: Int = -32700

    /// Invalid request: The JSON sent is not a valid Request object.
    public static let invalidRequest: Int = -32600

    /// Method not found: The method does not exist or is not available.
    public static let methodNotFound: Int = -32601

    /// Invalid params: Invalid method parameter(s).
    public static let invalidParams: Int = -32602

    /// Internal error: Internal JSON-RPC error.
    public static let internalError: Int = -32603

    // MARK: MCP Specification Errors

    /// Resource not found: The requested resource does not exist.
    ///
    /// Defined in MCP specification (resources.mdx).
    public static let resourceNotFound: Int = -32002

    /// URL elicitation required: The request requires URL-mode elicitation(s) to be completed.
    ///
    /// Defined in MCP specification (schema).
    public static let urlElicitationRequired: Int = -32042

    // MARK: SDK-Specific Errors

    /// Connection closed: The connection to the server was closed.
    ///
    /// Not defined in MCP spec. SDK-specific, matches TypeScript SDK.
    public static let connectionClosed: Int = -32000

    /// Request timeout: The server did not respond within the timeout period.
    ///
    /// Not defined in MCP spec. SDK-specific, matches TypeScript SDK.
    public static let requestTimeout: Int = -32001

    /// Transport error: An error occurred in the transport layer.
    ///
    /// Not defined in MCP spec. SDK-specific for Swift.
    public static let transportError: Int = -32003

    /// Request cancelled: The request was cancelled before completion.
    ///
    /// Not defined in MCP spec. SDK-specific for Swift.
    public static let requestCancelled: Int = -32004
}

/// A model context protocol error.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors (-32700 to -32603)
    case parseError(String?)  // -32700
    case invalidRequest(String?)  // -32600
    case methodNotFound(String?)  // -32601
    case invalidParams(String?)  // -32602
    case internalError(String?)  // -32603

    // Server errors (-32000 to -32099)
    case serverError(code: Int, message: String)
    // Request timeout
    /// Request timed out waiting for a response.
    case requestTimeout(timeout: Duration, message: String?)
    // Transport specific errors
    case connectionClosed
    case transportError(Swift.Error)

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
        case .parseError: return ErrorCode.parseError
        case .invalidRequest: return ErrorCode.invalidRequest
        case .methodNotFound: return ErrorCode.methodNotFound
        case .invalidParams: return ErrorCode.invalidParams
        case .internalError: return ErrorCode.internalError
        case .serverError(let code, _): return code
        case .connectionClosed: return ErrorCode.connectionClosed
        case .transportError: return ErrorCode.transportError
        case .requestTimeout: return ErrorCode.requestTimeout
        }
    }
    
    /// The raw error message for wire format serialization.
    ///
    /// This returns the message suitable for JSON-RPC 2.0 error format, without
    /// any additional prefixes or formatting that `errorDescription` might add.
    /// Use this for serialization; use `errorDescription` for human-readable display.
    public var message: String {
        switch self {
        case .parseError(let detail):
            return detail ?? "Invalid JSON"
        case .invalidRequest(let detail):
            return detail ?? "Invalid Request"
        case .methodNotFound(let detail):
            return detail ?? "Method not found"
        case .invalidParams(let detail):
            return detail ?? "Invalid params"
        case .internalError(let detail):
            return detail ?? "Internal error"
        case .serverError(_, let message):
            return message
        case .connectionClosed:
            return "Connection closed"
        case .transportError(let error):
            return error.localizedDescription
        case .requestTimeout(let timeout, let message):
            return message ?? "Request timed out after \(timeout)"
        }
    }
    
    /// The error data payload for wire format serialization.
    ///
    /// This returns the additional data to include in the JSON-RPC 2.0 error,
    /// following MCP specification requirements for specific error types.
    public var data: Value? {
        switch self {
        case .parseError, .invalidRequest, .methodNotFound, .invalidParams, .internalError:
            // Standard JSON-RPC errors don't require data
            return nil
        case .serverError:
            return nil
        case .connectionClosed:
            return nil
        case .transportError(let error):
            return .object(["error": .string(error.localizedDescription)])
        case .requestTimeout(let timeout, _):
            let timeoutMs = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
            return .object(["timeout": .int(timeoutMs)])
        }
    }
    
    /// Check if an error represents a "resource temporarily unavailable" condition
    public static func isResourceTemporarilyUnavailable(_ error: Swift.Error) -> Bool {
        #if canImport(System)
            if let errno = error as? System.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #else
            if let errno = error as? SystemPackage.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #endif
        return false
    }
}

// MARK: LocalizedError

extension MCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .parseError(let detail):
            return "Parse error: Invalid JSON" + (detail.map { ": \($0)" } ?? "")
        case .invalidRequest(let detail):
            return "Invalid Request" + (detail.map { ": \($0)" } ?? "")
        case .methodNotFound(let detail):
            return "Method not found" + (detail.map { ": \($0)" } ?? "")
        case .invalidParams(let detail):
            return "Invalid params" + (detail.map { ": \($0)" } ?? "")
        case .internalError(let detail):
            return "Internal error" + (detail.map { ": \($0)" } ?? "")
        case .serverError(_, let message):
            return "Server error: \(message)"
        case .connectionClosed:
            return "Connection closed"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        case .requestTimeout(let timeout, let message):
            if let message {
                return "Request timeout: \(message)"
            } else {
                return "Request timed out after \(timeout)"
            }
        }
    }

    public var failureReason: String? {
        switch self {
        case .parseError:
            return "The server received invalid JSON that could not be parsed"
        case .invalidRequest:
            return "The JSON sent is not a valid Request object"
        case .methodNotFound:
            return "The method does not exist or is not available"
        case .invalidParams:
            return "Invalid method parameter(s)"
        case .internalError:
            return "Internal JSON-RPC error"
        case .serverError:
            return "Server-defined error occurred"
        case .connectionClosed:
            return "The connection to the server was closed"
        case .transportError(let error):
            return (error as? LocalizedError)?.failureReason ?? error.localizedDescription
        case .requestTimeout:
            return "The server did not respond within the timeout period"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .parseError:
            return "Verify that the JSON being sent is valid and well-formed"
        case .invalidRequest:
            return "Ensure the request follows the JSON-RPC 2.0 specification format"
        case .methodNotFound:
            return "Check the method name and ensure it is supported by the server"
        case .invalidParams:
            return "Verify the parameters match the method's expected parameters"
        case .connectionClosed:
            return "Try reconnecting to the server"
        default:
            return nil
        }
    }
}

// MARK: CustomDebugStringConvertible

extension MCPError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .transportError(let error):
            return
                "[\(code)] \(errorDescription ?? "") (Underlying error: \(String(reflecting: error)))"
        default:
            return "[\(code)] \(errorDescription ?? "")"
        }
    }

}

// MARK: Codable

extension MCPError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        // Encode data if available
        if let data = self.data {
            try container.encode(data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        // Try to decode data as a generic Value first
        let dataValue = try container.decodeIfPresent(Value.self, forKey: .data)
        
        // Helper to check if message is the default for a given error type.
        // If it's the default, we use nil as the detail; otherwise we use the custom message.
        func customDetailOrNil(ifNotDefault defaultMessage: String) -> String? {
            message == defaultMessage ? nil : message
        }
        
        switch code {
        case ErrorCode.parseError:
            self = .parseError(customDetailOrNil(ifNotDefault: "Invalid JSON"))
        case ErrorCode.invalidRequest:
            self = .invalidRequest(customDetailOrNil(ifNotDefault: "Invalid Request"))
        case ErrorCode.methodNotFound:
            self = .methodNotFound(customDetailOrNil(ifNotDefault: "Method not found"))
        case ErrorCode.invalidParams:
            self = .invalidParams(customDetailOrNil(ifNotDefault: "Invalid params"))
        case ErrorCode.internalError:
            self = .internalError(customDetailOrNil(ifNotDefault: "Internal error"))
            
        case ErrorCode.connectionClosed:
            self = .connectionClosed
        case ErrorCode.requestTimeout:
            // Extract timeout from data if present
            var timeoutMs = 60000  // Default 60 seconds
            if case .object(let dict) = dataValue,
               let timeoutValue = dict["timeout"],
               case .int(let t) = timeoutValue {
                timeoutMs = t
            }
            self = .requestTimeout(timeout: .milliseconds(timeoutMs), message: message)
        case ErrorCode.transportError:
            // Extract underlying error string if present
            var underlyingErrorString = message
            if case .object(let dict) = dataValue,
               case .string(let str) = dict["error"] {
                underlyingErrorString = str
            }
            self = .transportError(
                NSError(
                    domain: "org.jsonrpc.error",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                )
            )
        default:
            self = .serverError(code: code, message: message)
        }
    }
    
    /// Reconstructs an MCPError from error code, message, and optional data.
    ///
    /// This is useful for clients receiving error responses and wanting to
    /// work with typed error values.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code
    ///   - message: The error message
    ///   - data: Optional additional error data
    /// - Returns: The appropriate MCPError type
    public static func fromError(code: Int, message: String, data: Value? = nil) -> MCPError {
        // Helper to check if message is the default for a given error type.
        // If it's the default, we use nil as the detail; otherwise we use the custom message.
        func customDetailOrNil(ifNotDefault defaultMessage: String) -> String? {
            message == defaultMessage ? nil : message
        }
        
        switch code {
        case ErrorCode.parseError:
            return .parseError(customDetailOrNil(ifNotDefault: "Invalid JSON"))
        case ErrorCode.invalidRequest:
            return .invalidRequest(customDetailOrNil(ifNotDefault: "Invalid Request"))
        case ErrorCode.methodNotFound:
            return .methodNotFound(customDetailOrNil(ifNotDefault: "Method not found"))
        case ErrorCode.invalidParams:
            return .invalidParams(customDetailOrNil(ifNotDefault: "Invalid params"))
        case ErrorCode.internalError:
            return .internalError(customDetailOrNil(ifNotDefault: "Internal error"))
        case ErrorCode.connectionClosed:
            return .connectionClosed
        case ErrorCode.requestTimeout:
            // Extract timeout from data if present
            var timeoutMs = 60000  // Default 60 seconds
            if case .object(let dict) = data,
               let timeoutValue = dict["timeout"],
               case .int(let t) = timeoutValue {
                timeoutMs = t
            }
            return .requestTimeout(timeout: .milliseconds(timeoutMs), message: message)
        case ErrorCode.transportError:
            // Extract underlying error string if present
            var underlyingErrorString = message
            if case .object(let dict) = data,
               case .string(let str) = dict["error"] {
                underlyingErrorString = str
            }
            return .transportError(
                NSError(
                    domain: "org.jsonrpc.error",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                )
            )
            
        default:
            return .serverError(code: code, message: message)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        switch (lhs, rhs) {
        case (.parseError(let l), .parseError(let r)):
            return l == r
        case (.invalidRequest(let l), .invalidRequest(let r)):
            return l == r
        case (.methodNotFound(let l), .methodNotFound(let r)):
            return l == r
        case (.invalidParams(let l), .invalidParams(let r)):
            return l == r
        case (.internalError(let l), .internalError(let r)):
            return l == r
        case (.serverError(let lCode, let lMsg), .serverError(let rCode, let rMsg)):
            return lCode == rCode && lMsg == rMsg
        case (.connectionClosed, .connectionClosed):
            return true
        case (.transportError(let l), .transportError(let r)):
            return l.localizedDescription == r.localizedDescription
        case (.requestTimeout(let lTimeout, let lMsg), .requestTimeout(let rTimeout, let rMsg)):
            return lTimeout == rTimeout && lMsg == rMsg
        default:
            return false
        }
    }
}

// MARK: Hashable

extension MCPError: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        switch self {
        case .parseError(let detail):
            hasher.combine(detail)
        case .invalidRequest(let detail):
            hasher.combine(detail)
        case .methodNotFound(let detail):
            hasher.combine(detail)
        case .invalidParams(let detail):
            hasher.combine(detail)
        case .internalError(let detail):
            hasher.combine(detail)
        case .serverError(_, let message):
            hasher.combine(message)
        case .connectionClosed:
            break
        case .transportError(let error):
            hasher.combine(error.localizedDescription)
        case .requestTimeout(let timeout, let message):
            hasher.combine(timeout)
            hasher.combine(message)
        }
    }
}
