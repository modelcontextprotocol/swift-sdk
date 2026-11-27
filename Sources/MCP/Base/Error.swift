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

    /// Creates the information for a required URL elicitation.
    public init(mode: String = "url", elicitationId: String, url: String, message: String) {
        self.mode = mode
        self.elicitationId = elicitationId
        self.url = url
        self.message = message
    }
}

/// A model context protocol error.
///
/// The cases are frozen for 1.x. An error whose code has no case of its own,
/// including a code a later revision adds, is a ``serverError(code:message:data:)``.
/// A received -32042 also uses `serverError` when its data cannot be represented
/// by ``urlElicitationRequired(message:elicitations:)``; ``errorCode`` and the
/// constants of ``Code`` identify it.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors (-32700 to -32603). The string, if any,
    // is sent as `data.detail`.

    /// The message is not valid JSON: -32700.
    case parseError(String?)
    /// The message is not a valid request: -32600.
    case invalidRequest(String?)
    /// The method does not exist or is not available: -32601.
    case methodNotFound(String?)
    /// The parameters of the request are not valid: -32602.
    case invalidParams(String?)
    /// The receiver failed to handle the request: -32603.
    case internalError(String?)

    /// An implementation-defined error, or a received error whose data cannot
    /// be represented by its typed case.
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
    /// A received -32042 with unrepresentable data decodes as `serverError`
    /// with its data available.
    case urlElicitationRequired(message: String, elicitations: [URLElicitationInfo])

    // Transport specific errors

    /// The connection is closed: -32000.
    case connectionClosed
    /// The transport failed with this error: -32001, with its description as `data.error`.
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

// MARK: Codes

extension MCPError {
    /// A JSON-RPC error code. A later revision's codes are added as constants in a minor
    /// release, not as cases of ``MCPError``.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible,
        ExpressibleByIntegerLiteral
    {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: Int) {
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        /// Invalid JSON: -32700.
        public static let parseError: Code = -32700
        /// The JSON is not a valid request: -32600.
        public static let invalidRequest: Code = -32600
        /// The method does not exist or is not available: -32601.
        public static let methodNotFound: Code = -32601
        /// Invalid method parameters, and a missing resource (SEP-2164): -32602.
        public static let invalidParams: Code = -32602
        /// An internal JSON-RPC error: -32603.
        public static let internalError: Code = -32603
        /// The SDK's ``MCPError/connectionClosed``; an implementation-defined server error
        /// on the wire: -32000.
        public static let connectionClosed: Code = -32000
        /// The SDK's ``MCPError/transportError(_:)``; an implementation-defined server error
        /// on the wire: -32001.
        public static let transportError: Code = -32001
        /// Missing or mismatched HTTP headers: -32020.
        public static let headerMismatch: Code = -32020
        /// Undeclared client capabilities: -32021.
        public static let missingRequiredClientCapabilities: Code = -32021
        /// An unsupported protocol version: -32022.
        public static let unsupportedProtocolVersion: Code = -32022
        /// URL elicitations to complete first: -32042.
        public static let urlElicitationRequired: Code = -32042
    }

    /// The error's ``code`` as a ``Code``.
    public var errorCode: Code { Code(rawValue: code) }
}

extension MCPError.Code {
    /// Whether `error` is an ``MCPError`` with code `code`, so that
    /// `catch MCPError.Code.unsupportedProtocolVersion` matches by code.
    public static func ~= (code: Self, error: any Swift.Error) -> Bool {
        (error as? MCPError)?.errorCode == code
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let fields, fields.count == 1,
                let items = fields["elicitations"]?.arrayValue,
                let original = try? encoder.encode(items),
                let elicitations = try? JSONDecoder().decode(
                    [URLElicitationInfo].self, from: original),
                let roundTrip = try? encoder.encode(elicitations),
                roundTrip == original
            {
                self = .urlElicitationRequired(message: message, elicitations: elicitations)
            } else {
                self = .serverError(code: code, message: message, data: serverData)
            }
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
