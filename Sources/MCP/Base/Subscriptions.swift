import Foundation

/// The notification types a client opts in to on a `subscriptions/listen`
/// stream (2026-07-28, SEP-2575). Each type is opt-in.
public struct SubscriptionFilter: Hashable, Codable, Sendable {
    /// Receive `notifications/tools/list_changed`.
    public var toolsListChanged: Bool?
    /// Receive `notifications/prompts/list_changed`.
    public var promptsListChanged: Bool?
    /// Receive `notifications/resources/list_changed`.
    public var resourcesListChanged: Bool?
    /// Receive `notifications/resources/updated` for these resource URIs.
    public var resourceSubscriptions: [String]?

    /// Creates a filter. A `nil` type is not requested.
    public init(
        toolsListChanged: Bool? = nil,
        promptsListChanged: Bool? = nil,
        resourcesListChanged: Bool? = nil,
        resourceSubscriptions: [String]? = nil
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
    }
}

/// Opens a stream for notifications that do not belong to a request
/// (2026-07-28, SEP-2575). It replaces the standalone GET stream and
/// `resources/subscribe`.
///
/// The first message on the stream is
/// ``SubscriptionsAcknowledgedNotification``. Every message on the stream
/// carries `_meta["io.modelcontextprotocol/subscriptionId"]`, the JSON-RPC id
/// of the listen request. The result is sent only when the server ends the
/// stream gracefully.
public enum SubscriptionsListen: Method {
    public static let name = "subscriptions/listen"

    /// The parameters of `subscriptions/listen`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The notification types to receive.
        public var notifications: SubscriptionFilter

        /// Creates listen parameters for the given filter.
        public init(notifications: SubscriptionFilter) {
            self.notifications = notifications
        }
    }

    /// The result of `subscriptions/listen`.
    public struct Result: Hashable, Codable, Sendable {
        /// Carries `io.modelcontextprotocol/subscriptionId`.
        public var _meta: Metadata?

        /// Creates a listen result.
        public init(_meta: Metadata? = nil) {
            self._meta = _meta
        }
    }
}

/// The first message on a `subscriptions/listen` stream: the notification
/// types the server will send. Types the server does not support are omitted.
public struct SubscriptionsAcknowledgedNotification: Notification {
    public static let name = "notifications/subscriptions/acknowledged"

    /// The parameters of `notifications/subscriptions/acknowledged`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The honored subset of the requested filter.
        public var notifications: SubscriptionFilter

        /// Creates acknowledgement parameters for the honored filter.
        public init(notifications: SubscriptionFilter) {
            self.notifications = notifications
        }
    }
}

extension Metadata {
    /// `io.modelcontextprotocol/subscriptionId`: the `subscriptions/listen`
    /// request a message belongs to.
    public var subscriptionID: ID? {
        get {
            switch fields[MetaKey.subscriptionID] {
            case .string(let string): return .string(string)
            case .int(let int): return .number(int)
            default: return nil
            }
        }
        set {
            switch newValue {
            case .string(let string): fields[MetaKey.subscriptionID] = .string(string)
            case .number(let int): fields[MetaKey.subscriptionID] = .int(int)
            case nil: fields[MetaKey.subscriptionID] = nil
            }
        }
    }
}

/// A change delivered on `subscriptions/listen` streams.
enum SubscriptionEvent: Hashable, Sendable {
    case toolsListChanged
    case promptsListChanged
    case resourcesListChanged
    case resourceUpdated(uri: String)

    /// The event a notification announces, if it belongs on listen streams.
    /// Only a resource-updated notification's parameters are read.
    init?<N: Notification>(_ notification: Message<N>) {
        switch notification.method {
        case ToolListChangedNotification.name: self = .toolsListChanged
        case PromptListChangedNotification.name: self = .promptsListChanged
        case ResourceListChangedNotification.name: self = .resourcesListChanged
        case ResourceUpdatedNotification.name:
            let uri =
                (notification.params as? ResourceUpdatedNotification.Parameters)?.uri
                ?? (try? Value(notification.params))?.objectValue?["uri"]?.stringValue
            guard let uri else { return nil }
            self = .resourceUpdated(uri: uri)
        default: return nil
        }
    }

    /// The event a notification announces, if it belongs on listen streams.
    init?(method: String, params: Value?) {
        switch method {
        case ToolListChangedNotification.name: self = .toolsListChanged
        case PromptListChangedNotification.name: self = .promptsListChanged
        case ResourceListChangedNotification.name: self = .resourcesListChanged
        case ResourceUpdatedNotification.name:
            guard let uri = params?.objectValue?["uri"]?.stringValue else { return nil }
            self = .resourceUpdated(uri: uri)
        default: return nil
        }
    }

    func matches(_ filter: SubscriptionFilter) -> Bool {
        switch self {
        case .toolsListChanged: return filter.toolsListChanged == true
        case .promptsListChanged: return filter.promptsListChanged == true
        case .resourcesListChanged: return filter.resourcesListChanged == true
        case .resourceUpdated(let uri): return filter.resourceSubscriptions?.contains(uri) == true
        }
    }

    /// Whether a stream with `filter`, whose resource URIs are `resources`,
    /// receives this event.
    func matches(_ filter: SubscriptionFilter, resources: Set<String>) -> Bool {
        if case .resourceUpdated(let uri) = self { return resources.contains(uri) }
        return matches(filter)
    }

    /// The notification for this event on the stream `subscriptionID`.
    func message(subscriptionID: ID) -> Message<AnyNotification> {
        var meta = Metadata()
        meta.subscriptionID = subscriptionID
        switch self {
        case .toolsListChanged:
            return Message(method: ToolListChangedNotification.name, params: [:], _meta: meta)
        case .promptsListChanged:
            return Message(method: PromptListChangedNotification.name, params: [:], _meta: meta)
        case .resourcesListChanged:
            return Message(method: ResourceListChangedNotification.name, params: [:], _meta: meta)
        case .resourceUpdated(let uri):
            return Message(method: ResourceUpdatedNotification.name, params: ["uri": .string(uri)], _meta: meta)
        }
    }
}
