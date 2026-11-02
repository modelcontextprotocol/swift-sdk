import Foundation

/// An HTTP reply that carries no JSON-RPC answer for the request.
///
/// ``HTTPClientTransport`` throws it wrapped in ``MCPError/transportError(_:)``:
///
/// ```swift
/// do {
///     _ = try await client.listTools()
/// } catch MCPError.transportError(let error as HTTPStatusError) where error.statusCode == 429 {
///     let retryAfter = error.value(forHeader: "Retry-After")
/// }
/// ```
///
/// A reply whose body is the JSON-RPC error of the request is delivered as that
/// error instead.
public struct HTTPStatusError: LocalizedError, Hashable, Sendable {
    /// The HTTP status code.
    public let statusCode: Int

    /// The response headers, as received.
    public let headers: [String: String]

    /// Whether the server ended the session: a 404 for a request that carried
    /// `Mcp-Session-Id`. The transport has dropped the session; connect again.
    public let isSessionExpired: Bool

    public init(statusCode: Int, headers: [String: String] = [:], isSessionExpired: Bool = false) {
        self.statusCode = statusCode
        self.headers = headers
        self.isSessionExpired = isSessionExpired
    }

    /// The value of the header `name`, compared case-insensitively.
    public func value(forHeader name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var errorDescription: String? {
        switch statusCode {
        case 400: return "Bad request"
        case 401: return "Authentication required"
        case 403: return "Access forbidden"
        case 404: return isSessionExpired ? "Session expired" : "Endpoint not found"
        case 405: return "Method not allowed"
        case 408: return "Request timeout"
        case 429: return "Too many requests"
        case 500..<600: return "Server error: \(statusCode)"
        default: return "Unexpected HTTP response: \(statusCode)"
        }
    }
}

extension HTTPStatusError: CustomDebugStringConvertible {
    /// The status code, ``isSessionExpired`` and the names of the headers.
    /// Header values, such as `Set-Cookie` or `WWW-Authenticate`, are left
    /// out, so the error can be logged; read them from ``headers``.
    public var debugDescription: String {
        let names = headers.keys.sorted { $0.lowercased() < $1.lowercased() }
        return
            "HTTPStatusError(statusCode: \(statusCode), isSessionExpired: \(isSessionExpired), headers: \(names))"
    }
}
