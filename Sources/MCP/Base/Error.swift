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

/// A model context protocol error.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors (-32700 to -32603)
    case parseError(String?)  // -32700
    case invalidRequest(String?)  // -32600
    case methodNotFound(String?)  // -32601
    case invalidParams(String?)  // -32602
    case internalError(String?)  // -32603

    /// An error with an implementation-defined or unrecognized code.
    case serverError(code: Int, message: String, data: Value? = nil)

    // MCP specific errors

    /// The requested resource does not exist (SEP-2164): -32602 with `data.uri`.
    case resourceNotFound(uri: String, message: String? = nil)
    /// HTTP headers are missing, malformed or do not match the request body: -32020.
    case headerMismatch(String?)
    /// The request needs client capabilities it did not declare: -32021.
    case missingRequiredClientCapabilities(Client.Capabilities, message: String? = nil)
    /// The server does not serve the requested protocol version: -32022.
    case unsupportedProtocolVersion(supported: [String], requested: String? = nil)
    /// The server needs the user to complete URL elicitations first: -32042.
    case urlElicitationRequired(message: String, elicitations: [URLElicitationInfo])

    // Transport specific errors
    case connectionClosed
    case transportError(Swift.Error)

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
        case .parseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .serverError(let code, _, _): return code
        case .resourceNotFound: return -32602
        case .headerMismatch: return -32020
        case .missingRequiredClientCapabilities: return -32021
        case .unsupportedProtocolVersion: return -32022
        case .urlElicitationRequired: return -32042
        case .connectionClosed: return -32000
        case .transportError: return -32001
        }
    }

    /// The `data` member sent with the error, if any.
    public var data: Value? {
        switch self {
        case .parseError(let detail),
            .invalidRequest(let detail),
            .methodNotFound(let detail),
            .invalidParams(let detail),
            .internalError(let detail),
            .headerMismatch(let detail):
            return detail.map { ["detail": .string($0)] }
        case .serverError(_, _, let data):
            return data
        case .resourceNotFound(let uri, _):
            return ["uri": .string(uri)]
        case .missingRequiredClientCapabilities(let capabilities, _):
            return ["requiredCapabilities": (try? Value.preservingStrings(capabilities)) ?? [:]]
        case .unsupportedProtocolVersion(let supported, let requested):
            var data: [String: Value] = ["supported": .array(supported.map { .string($0) })]
            if let requested { data["requested"] = .string(requested) }
            return .object(data)
        case .urlElicitationRequired(_, let elicitations):
            let items = elicitations.map { (try? Value.preservingStrings($0)) ?? .null }
            return ["elicitations": .array(items)]
        case .connectionClosed:
            return nil
        case .transportError(let error):
            return ["error": .string(error.localizedDescription)]
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
        case .serverError(_, let message, _):
            return "Server error: \(message)"
        case .resourceNotFound(let uri, let message):
            return message ?? "Resource not found: \(uri)"
        case .headerMismatch(let detail):
            return "Header mismatch" + (detail.map { ": \($0)" } ?? "")
        case .missingRequiredClientCapabilities(_, let message):
            return message ?? "Missing required client capabilities"
        case .unsupportedProtocolVersion(let supported, let requested):
            let prefix = requested.map { "Unsupported protocol version \($0)" }
                ?? "Unsupported protocol version"
            return prefix + "; supported: " + supported.joined(separator: ", ")
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
        case .resourceNotFound:
            return "The requested resource does not exist"
        case .headerMismatch:
            return "The HTTP headers do not match the request body"
        case .missingRequiredClientCapabilities:
            return "The request needs client capabilities that were not declared"
        case .unsupportedProtocolVersion:
            return "The server does not support the requested protocol version"
        case .urlElicitationRequired:
            return "The server requires user authentication or input via external URL"
        case .connectionClosed:
            return "The connection to the server was closed"
        case .transportError(let error):
            return (error as? LocalizedError)?.failureReason ?? error.localizedDescription
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
        case .unsupportedProtocolVersion(let supported, _):
            return supported.first.map { "Retry with protocol version \($0)" }
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

    /// The `message` member sent on the wire.
    private var wireMessage: String {
        switch self {
        case .serverError(_, let message, _), .urlElicitationRequired(let message, _):
            return message
        default:
            return errorDescription ?? "Unknown error"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(wireMessage, forKey: .message)
        try container.encodeIfPresent(data, forKey: .data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let data = try container.decodeIfPresent(Value.self, forKey: .data)
        let fields = data?.objectValue

        // The detail the standard cases put in `data`, else the message.
        let detail: (String?) -> String? = { fallback in
            fields?["detail"]?.stringValue ?? fallback
        }
        // Without `data.detail`, the message less the text the case adds
        // itself, so a decoded error encodes the message it was sent with.
        let detailOrMessage: (String) -> String? = { text in
            if message == text { return detail(nil) }
            if message.hasPrefix(text + ": ") {
                return detail(String(message.dropFirst(text.count + 2)))
            }
            return detail(message)
        }
        // A message equal to the case's own text for `message: nil` is `nil`.
        let customMessage: (String) -> String? = { text in message == text ? nil : message }
        // An application sees `.data` for a `data:` URL in `data`, as in any
        // other decoded `Value`.
        let serverData = data?.decodingDataURLs

        switch code {
        case -32700:
            self = .parseError(detailOrMessage("Parse error: Invalid JSON"))
        case -32600:
            self = .invalidRequest(detailOrMessage("Invalid Request"))
        case -32601:
            self = .methodNotFound(detailOrMessage("Method not found"))
        case -32602, -32002:
            if fields?["detail"] == nil, let uri = fields?["uri"]?.stringValue {
                self = .resourceNotFound(
                    uri: uri, message: customMessage("Resource not found: \(uri)"))
            } else if code == -32602 {
                self = .invalidParams(detailOrMessage("Invalid params"))
            } else {
                self = .serverError(code: code, message: message, data: serverData)
            }
        case -32603:
            self = .internalError(detailOrMessage("Internal error"))
        case -32020:
            self = .headerMismatch(detailOrMessage("Header mismatch"))
        case -32021:
            // Without a readable `requiredCapabilities`, the error keeps its
            // data: an empty set would read as nothing to declare.
            if let required = fields?["requiredCapabilities"].flatMap({
                try? JSONDecoder().decode(Client.Capabilities.self, from: JSONEncoder().encode($0))
            }) {
                self = .missingRequiredClientCapabilities(
                    required, message: customMessage("Missing required client capabilities"))
            } else {
                self = .serverError(code: code, message: message, data: serverData)
            }
        case -32022:
            let supported = fields?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
            self = .unsupportedProtocolVersion(
                supported: supported, requested: fields?["requested"]?.stringValue)
        case -32042:
            var elicitations: [URLElicitationInfo] = []
            for item in fields?["elicitations"]?.arrayValue ?? [] {
                if let info = try? JSONDecoder().decode(
                    URLElicitationInfo.self, from: JSONEncoder().encode(item))
                {
                    elicitations.append(info)
                }
            }
            self = .urlElicitationRequired(message: message, elicitations: elicitations)
        default:
            // -32000 and -32001 are used by the SDK for local transport errors
            // only; on the wire they are implementation-defined server errors.
            self = .serverError(code: code, message: message, data: serverData)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        switch (lhs, rhs) {
        case (.parseError(let a), .parseError(let b)): return a == b
        case (.invalidRequest(let a), .invalidRequest(let b)): return a == b
        case (.methodNotFound(let a), .methodNotFound(let b)): return a == b
        case (.invalidParams(let a), .invalidParams(let b)): return a == b
        case (.internalError(let a), .internalError(let b)): return a == b
        case (.serverError(let c1, let m1, let d1), .serverError(let c2, let m2, let d2)):
            return c1 == c2 && m1 == m2 && d1 == d2
        case (.resourceNotFound(let u1, let m1), .resourceNotFound(let u2, let m2)):
            return u1 == u2 && m1 == m2
        case (.headerMismatch(let a), .headerMismatch(let b)): return a == b
        case (.missingRequiredClientCapabilities(let c1, let m1),
            .missingRequiredClientCapabilities(let c2, let m2)):
            return c1 == c2 && m1 == m2
        case (.unsupportedProtocolVersion(let s1, let r1), .unsupportedProtocolVersion(let s2, let r2)):
            return s1 == s2 && r1 == r2
        case (.urlElicitationRequired(let m1, let e1), .urlElicitationRequired(let m2, let e2)):
            return m1 == m2 && e1 == e2
        case (.connectionClosed, .connectionClosed): return true
        case (.transportError(let a), .transportError(let b)):
            return a.localizedDescription == b.localizedDescription
        default: return false
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
        case .serverError(_, let message, let data):
            hasher.combine(message)
            hasher.combine(data)
        case .resourceNotFound(let uri, let message):
            hasher.combine(uri)
            hasher.combine(message)
        case .headerMismatch(let detail):
            hasher.combine(detail)
        case .missingRequiredClientCapabilities(let capabilities, let message):
            hasher.combine(capabilities)
            hasher.combine(message)
        case .unsupportedProtocolVersion(let supported, let requested):
            hasher.combine(supported)
            hasher.combine(requested)
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
