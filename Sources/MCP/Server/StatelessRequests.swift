/// How the server serves one request.
enum RequestEra: Sendable, Equatable {
    /// Part of an `initialize`-based connection (2025-11-25 and earlier).
    case handshake
    /// Self-contained request at 2026-07-28 or later, described by its `_meta`.
    case stateless(StatelessRequestInfo)
}

/// What a stateless request declares about its client in `_meta`.
struct StatelessRequestInfo: Sendable, Equatable {
    let protocolVersion: String
    let clientCapabilities: Client.Capabilities
    let clientInfo: Client.Info?
    let logLevel: LogLevel?
}

enum StatelessRequests {
    /// Methods that do not exist at 2026-07-28 and later.
    static let removedMethods: Set<String> = [
        Initialize.name, Ping.name, SetLoggingLevel.name,
        ResourceSubscribe.name, ResourceUnsubscribe.name,
    ]

    /// Methods that exist only at 2026-07-28 and later.
    static let statelessOnlyMethods: Set<String> = [ServerDiscover.name, "subscriptions/listen"]

    /// Methods whose results carry SEP-2549 cache hints.
    static let cacheableMethods: Set<String> = [
        ListTools.name, ListPrompts.name, ListResources.name,
        ListResourceTemplates.name, ReadResource.name, ServerDiscover.name,
    ]

    /// Classifies a request by the protocol version in its `_meta`.
    ///
    /// A request without `io.modelcontextprotocol/protocolVersion` belongs to
    /// the handshake era, as does one that names a handshake revision in
    /// `served`. Any other version is served statelessly when it is in
    /// `served`; otherwise the request is rejected with -32022, before its
    /// other `_meta` members are checked.
    ///
    /// - Throws: ``MCPError/invalidParams(_:)`` for malformed `_meta`;
    ///   ``MCPError/unsupportedProtocolVersion(supported:requested:)``.
    static func classify(_ meta: Metadata?, served: [String]) throws -> RequestEra {
        guard let meta, let raw = meta[MetaKey.protocolVersion] else { return .handshake }
        guard let version = raw.stringValue, !version.isEmpty else {
            throw MCPError.invalidParams("Invalid _meta field \"\(MetaKey.protocolVersion)\"")
        }
        if Version.handshake.contains(version) {
            guard served.contains(version) else {
                throw MCPError.unsupportedProtocolVersion(supported: served, requested: version)
            }
            return .handshake
        }
        guard served.contains(version) else {
            throw MCPError.unsupportedProtocolVersion(supported: served, requested: version)
        }

        guard let capabilities = meta.clientCapabilities else {
            throw MCPError.invalidParams(
                "Missing or invalid _meta field \"\(MetaKey.clientCapabilities)\"")
        }
        if meta[MetaKey.clientInfo] != nil, meta.clientInfo == nil {
            throw MCPError.invalidParams("Invalid _meta field \"\(MetaKey.clientInfo)\"")
        }
        return .stateless(
            StatelessRequestInfo(
                protocolVersion: version,
                clientCapabilities: capabilities,
                clientInfo: meta.clientInfo,
                logLevel: meta.logLevel))
    }

    /// Whether `capabilities` declare the feature a method belongs to.
    /// Methods outside the core features are always allowed.
    static func isDeclared(_ method: String, in capabilities: Server.Capabilities) -> Bool {
        switch method {
        case ListTools.name, CallTool.name:
            return capabilities.tools != nil
        case ListPrompts.name, GetPrompt.name:
            return capabilities.prompts != nil
        case ListResources.name, ListResourceTemplates.name, ReadResource.name:
            return capabilities.resources != nil
        case Complete.name:
            return capabilities.completions != nil
        default:
            return true
        }
    }

    /// Adds the members every stateless result carries, unless the handler set them:
    /// `resultType`, `_meta.serverInfo` and, for cacheable methods, cache hints.
    static func annotate(
        _ result: Value, method: String, serverInfo: Server.Info, cacheHint: CacheHint
    ) -> Value {
        guard case .object(var object) = result else { return result }
        if object[ResultKeys.resultType] == nil {
            object[ResultKeys.resultType] = .string(ResultType.complete.rawValue)
        }
        var meta = object["_meta"]?.objectValue ?? [:]
        if meta[MetaKey.serverInfo] == nil, let info = try? Value.preservingStrings(serverInfo) {
            meta[MetaKey.serverInfo] = info
            object["_meta"] = .object(meta)
        }
        if cacheableMethods.contains(method), object[ResultKeys.resultType] == "complete" {
            if object[ResultKeys.ttlMs] == nil {
                object[ResultKeys.ttlMs] = .int(max(0, cacheHint.ttlMs))
            }
            if object[ResultKeys.cacheScope] == nil {
                object[ResultKeys.cacheScope] = .string(cacheHint.scope.rawValue)
            }
        }
        return .object(object)
    }
}

/// Default caching hints for results of cacheable methods (SEP-2549).
public struct CacheHint: Hashable, Codable, Sendable {
    /// How long the result may be reused, in milliseconds.
    public var ttlMs: Int
    /// Who may reuse the result.
    public var scope: CacheScope

    public init(ttlMs: Int, scope: CacheScope) {
        self.ttlMs = ttlMs
        self.scope = scope
    }

    /// Immediately stale and private to the client.
    public static let uncached = CacheHint(ttlMs: 0, scope: .private)
}
