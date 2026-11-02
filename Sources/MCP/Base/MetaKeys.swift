import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Reserved `_meta` keys defined by the protocol.
public enum MetaKey {
    /// The protocol version of a request, at 2026-07-28 and later.
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    /// The capabilities the client declares for a request.
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    /// The client implementation that sent a request.
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    /// The lowest log level the client wants for a request.
    public static let logLevel = "io.modelcontextprotocol/logLevel"
    /// The server implementation that produced a result.
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    /// The `subscriptions/listen` request a notification belongs to.
    public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
}

extension Metadata {
    /// `io.modelcontextprotocol/protocolVersion`.
    public var protocolVersion: String? {
        get { fields[MetaKey.protocolVersion]?.stringValue }
        set { fields[MetaKey.protocolVersion] = newValue.map(Value.string) }
    }

    /// `io.modelcontextprotocol/clientCapabilities`; `nil` when absent or invalid.
    public var clientCapabilities: Client.Capabilities? {
        get { decodeField(MetaKey.clientCapabilities) }
        set { encodeField(newValue, MetaKey.clientCapabilities) }
    }

    /// `io.modelcontextprotocol/clientInfo`; `nil` when absent or invalid.
    public var clientInfo: Client.Info? {
        get { decodeField(MetaKey.clientInfo) }
        set { encodeField(newValue, MetaKey.clientInfo) }
    }

    /// `io.modelcontextprotocol/logLevel`; `nil` when absent or unknown.
    public var logLevel: LogLevel? {
        get { fields[MetaKey.logLevel]?.stringValue.flatMap(LogLevel.init(rawValue:)) }
        set { fields[MetaKey.logLevel] = newValue.map { .string($0.rawValue) } }
    }

    /// `io.modelcontextprotocol/serverInfo`; `nil` when absent or invalid.
    public var serverInfo: Server.Info? {
        get { decodeField(MetaKey.serverInfo) }
        set { encodeField(newValue, MetaKey.serverInfo) }
    }

    private func decodeField<T: Decodable>(_ key: String) -> T? {
        guard let value = fields[key], case .object = value,
            let data = try? JSONEncoder().encode(value)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private mutating func encodeField<T: Codable>(_ value: T?, _ key: String) {
        fields[key] = value.flatMap { try? Value.preservingStrings($0) }
    }
}
