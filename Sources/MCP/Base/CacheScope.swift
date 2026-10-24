/// Who may reuse a cached MCP result.
public enum CacheScope: String, Hashable, Codable, Sendable {
    case `public`
    case `private`
}
