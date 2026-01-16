/// Information about the incoming HTTP request.
///
/// This is the Swift equivalent of TypeScript's `RequestInfo` interface, which
/// provides access to HTTP request headers for request handlers.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     if let requestInfo = context.requestInfo {
///         // Access custom headers
///         if let customHeader = requestInfo.headers["X-Custom-Header"] {
///             print("Custom header: \(customHeader)")
///         }
///     }
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct RequestInfo: Hashable, Sendable {
    /// The HTTP headers from the request.
    ///
    /// Header names are preserved as provided by the HTTP framework.
    /// Use case-insensitive comparison when looking up headers.
    public let headers: [String: String]

    public init(headers: [String: String]) {
        self.headers = headers
    }

    /// Get a header value (case-insensitive lookup).
    ///
    /// - Parameter name: The header name to look up
    /// - Returns: The header value, or nil if not found
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lowercased {
                return value
            }
        }
        return nil
    }
}
