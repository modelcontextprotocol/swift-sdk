import Foundation

/// Information about a validated access token.
///
/// This struct contains authentication context that can be provided to request handlers
/// when using HTTP transports with OAuth or other token-based authentication.
///
/// Matches the TypeScript SDK's `AuthInfo` interface.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     if let authInfo = context.authInfo {
///         print("Authenticated as: \(authInfo.clientId)")
///         print("Scopes: \(authInfo.scopes)")
///     }
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct AuthInfo: Hashable, Codable, Sendable {
    /// The access token string.
    public let token: String

    /// The client ID associated with this token.
    public let clientId: String

    /// Scopes associated with this token.
    public let scopes: [String]

    /// When the token expires (in seconds since epoch).
    ///
    /// If `nil`, the token does not expire or expiration is unknown.
    public let expiresAt: Int?

    /// The RFC 8707 resource server identifier for which this token is valid.
    ///
    /// If set, this should match the MCP server's resource identifier (minus hash fragment).
    public let resource: String?

    /// Additional data associated with the token.
    ///
    /// Use this for any additional data that needs to be attached to the auth info.
    public let extra: [String: Value]?

    public init(
        token: String,
        clientId: String,
        scopes: [String],
        expiresAt: Int? = nil,
        resource: String? = nil,
        extra: [String: Value]? = nil
    ) {
        self.token = token
        self.clientId = clientId
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.resource = resource
        self.extra = extra
    }
}

extension AuthInfo: CustomStringConvertible {
    /// Redacts the token to prevent accidental exposure in logs.
    ///
    /// The token is still accessible via the `token` property for legitimate use,
    /// but this prevents it from appearing in string interpolation or print statements.
    public var description: String {
        "AuthInfo(clientId: \(clientId), scopes: \(scopes), token: [REDACTED])"
    }
}
