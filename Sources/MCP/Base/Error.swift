import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// Information about a required URL elicitation
public struct URLElicitationInfo: Codable, Hashable, Sendable {
    /// Elicitation mode (must be "url")
    public var mode: String
    /// Unique identifier for this elicitation
    public var elicitationId: String
    /// URL for the user to visit
    public var url: String
    /// Message describing the elicitation
    public var message: String

    public init(mode: String = "url", elicitationId: String, url: String, message: String) {
        self.mode = mode
        self.elicitationId = elicitationId
        self.url = url
        self.message = message
    }
}

/// A wrapper to make any Error Sendable.
public struct SendableError: @unchecked Sendable, Swift.Error {
    public let error: Swift.Error
    public init(_ error: Swift.Error) {
        self.error = error
    }
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

    // MCP specific errors
    case urlElicitationRequired(message: String, elicitations: [URLElicitationInfo])  // -32042

    // Transport specific errors
    case connectionClosed
    case transportError(SendableError)

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
        case .parseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .serverError(let code, _): return code
        case .urlElicitationRequired: return -32042
        case .connectionClosed: return -32000
        case .transportError: return -32001
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
        case .urlElicitationRequired(let message, _):
            return "URL elicitation required: \(message)"
        case .connectionClosed:
            return "Connection closed"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
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
        case .urlElicitationRequired:
            return "The server requires user authentication or input via external URL"
        case .connectionClosed:
            return "The connection to the server was closed"
        case .transportError(let error):
            return (error.error as? LocalizedError)?.failureReason ?? error.localizedDescription
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
        case .urlElicitationRequired(_, let elicitations):
            if let first = elicitations.first {
                return "Visit \(first.url) to complete the required authentication or input"
            }
            return "Complete the required URL-based elicitation"
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
                "[\(code)] \(errorDescription ?? "") (Underlying error: \(String(reflecting: error.error)))"
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
        try container.encode(errorDescription ?? "Unknown error", forKey: .message)

        // Encode additional data if available
        switch self {
        case .parseError(let detail),
            .invalidRequest(let detail),
            .methodNotFound(let detail),
            .invalidParams(let detail),
            .internalError(let detail):
            if let detail = detail {
                try container.encode(["detail": detail], forKey: .data)
            }
        case .serverError(_, _):
            // No additional data for server errors
            break
        case .urlElicitationRequired(_, let elicitations):
            // Encode elicitations array as structured data
            let elicitationsData = elicitations.map { info -> [String: Value] in
                return [
                    "mode": .string(info.mode),
                    "elicitationId": .string(info.elicitationId),
                    "url": .string(info.url),
                    "message": .string(info.message)
                ]
            }
            try container.encode(
                ["elicitations": Value.array(elicitationsData.map { .object($0) })],
                forKey: .data
            )
        case .connectionClosed:
            break
        case .transportError(let error):
            try container.encode(
                ["error": error.localizedDescription],
                forKey: .data
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let data = try container.decodeIfPresent([String: Value].self, forKey: .data)

        // Helper to extract detail from data, falling back to message if needed
        let unwrapDetail: (String?) -> String? = { fallback in
            guard let detailValue = data?["detail"] else { return fallback }
            if case .string(let str) = detailValue { return str }
            return fallback
        }

        switch code {
        case -32700:
            self = .parseError(unwrapDetail(message))
        case -32600:
            self = .invalidRequest(unwrapDetail(message))
        case -32601:
            self = .methodNotFound(unwrapDetail(message))
        case -32602:
            self = .invalidParams(unwrapDetail(message))
        case -32603:
            self = .internalError(unwrapDetail(nil))
        case -32042:
            // Extract elicitations array from data
            var elicitations: [URLElicitationInfo] = []
            if case .array(let items) = data?["elicitations"] {
                for item in items {
                    if case .object(let dict) = item,
                       case .string(let mode) = dict["mode"],
                       case .string(let elicitationId) = dict["elicitationId"],
                       case .string(let url) = dict["url"],
                       case .string(let msg) = dict["message"] {
                        elicitations.append(URLElicitationInfo(
                            mode: mode,
                            elicitationId: elicitationId,
                            url: url,
                            message: msg))
                    }
                }
            }
            self = .urlElicitationRequired(message: message, elicitations: elicitations)
        case -32000:
            self = .connectionClosed
        case -32001:
            // Extract underlying error string if present
            let underlyingErrorString =
                data?["error"].flatMap { val -> String? in
                    if case .string(let str) = val { return str }
                    return nil
                } ?? message
            self = .transportError(
                SendableError(NSError(
                    domain: "org.jsonrpc.error",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                ))
            )
        default:
            self = .serverError(code: code, message: message)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        lhs.code == rhs.code
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
        case .urlElicitationRequired(let message, let elicitations):
            hasher.combine(message)
            hasher.combine(elicitations)
        case .connectionClosed:
            break
        case .transportError(let error):
            hasher.combine(error.localizedDescription)
        }
    }
}
