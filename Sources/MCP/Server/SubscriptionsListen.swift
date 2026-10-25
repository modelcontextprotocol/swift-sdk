/// `subscriptions/listen` — modern long-lived notification stream (MCP 2026-07-28).
///
/// Replaces the legacy HTTP GET notification endpoint. The listen request stays
/// open until the client cancels (closes the SSE stream / `notifications/cancelled`)
/// or the server ends it gracefully with this result.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions
public enum SubscriptionsListen: Method {
    public static let name = "subscriptions/listen"

    public struct NotificationFilter: Hashable, Codable, Sendable {
        public var toolsListChanged: Bool?
        public var resourcesListChanged: Bool?
        public var promptsListChanged: Bool?
        public var resourceSubscriptions: [String]?

        public init(
            toolsListChanged: Bool? = nil,
            resourcesListChanged: Bool? = nil,
            promptsListChanged: Bool? = nil,
            resourceSubscriptions: [String]? = nil
        ) {
            self.toolsListChanged = toolsListChanged
            self.resourcesListChanged = resourcesListChanged
            self.promptsListChanged = promptsListChanged
            self.resourceSubscriptions = resourceSubscriptions
        }
    }

    public struct Parameters: Hashable, Codable, Sendable {
        public var _meta: Metadata
        public var notifications: NotificationFilter

        public init(_meta: Metadata, notifications: NotificationFilter) {
            self._meta = _meta
            self.notifications = notifications
        }

        private enum CodingKeys: String, CodingKey {
            case _meta, notifications
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public var resultType: ResultType
        public var _meta: Metadata

        public init(subscriptionId: ID, serverInfo: Metadata? = nil) {
            self.resultType = .complete
            var fields: [String: Value] = [:]
            switch subscriptionId {
            case .string(let s):
                fields[ProtocolMetaKey.subscriptionId] = .string(s)
            case .number(let n):
                fields[ProtocolMetaKey.subscriptionId] = .int(n)
            }
            if let serverInfo,
                let info = serverInfo[ProtocolMetaKey.serverInfo]
            {
                fields[ProtocolMetaKey.serverInfo] = info
            }
            self._meta = Metadata(additionalFields: fields)
        }

        private enum CodingKeys: String, CodingKey {
            case resultType, _meta
        }
    }
}
