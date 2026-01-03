import Foundation

/// The sender or recipient of messages and data in a conversation.
public enum Role: String, Hashable, Codable, Sendable {
    /// A user message
    case user
    /// An assistant message
    case assistant
}

/// Optional annotations for content, used to inform how objects are used or displayed.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/basic/
public struct Annotations: Hashable, Codable, Sendable {
    // TODO: Deprecate in a future version
    /// Backwards compatibility alias for top-level `Role`.
    public typealias Role = MCP.Role

    /// Describes who the intended audience of this object or data is.
    /// It can include multiple entries to indicate content useful for multiple audiences.
    public var audience: [Role]?

    /// Describes how important this data is for operating the server.
    /// A value of 1 means "most important" (effectively required),
    /// while 0 means "least important" (entirely optional).
    public var priority: Double?

    /// The moment the resource was last modified, as an ISO 8601 formatted string.
    public var lastModified: String?

    public init(
        audience: [Role]? = nil,
        priority: Double? = nil,
        lastModified: String? = nil
    ) {
        self.audience = audience
        self.priority = priority
        self.lastModified = lastModified
    }
}
