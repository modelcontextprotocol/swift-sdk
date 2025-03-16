/// The Model Context Protocol includes an optional ping mechanism that allows either party to verify that their counterpart is still responsive and the connection is alive.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/utilities/ping
public enum Ping: Method {
    public typealias Parameters = Empty
    public typealias Result = Value
    public static let name: String = "ping"
}
