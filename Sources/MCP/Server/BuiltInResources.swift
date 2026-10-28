import Foundation

// Resources that the server answers itself, before the application's
// `resources/read` and `resources/list` handlers: the views of
// `withAppResources(_:listInResources:)` and the skill files of
// `withSkills(_:listInResources:)`.

/// A source of resources that the server answers before the application's
/// handlers.
struct BuiltInResourceSource: Sendable {
    /// The key of the source's position in a listing cursor. It also orders
    /// the sources.
    let key: Key
    /// Whether `resources/list` includes the source's resources.
    let lists: Bool
    /// The contents of the resource at a URI; `nil` when the source does not
    /// have it.
    let read: @Sendable (String) async throws -> ReadResource.Result?
    /// A page of the source's resources, by its own cursor.
    let list: @Sendable (String?) async throws -> ListResources.Result

    /// The sources, in the order that `resources/read` consults them and
    /// `resources/list` lists them.
    enum Key: String, CaseIterable, Comparable, Sendable {
        case apps = "u"
        case skills = "s"

        static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }
}

extension Array where Element == BuiltInResourceSource {
    /// The sources with `source` added, or in place of the source with its
    /// key, in order.
    func installing(_ source: BuiltInResourceSource) -> Self {
        (filter { $0.key != source.key } + [source]).sorted { $0.key < $1.key }
    }
}

extension Server {
    /// The response to a `resources/read` of a built-in resource, or to a
    /// `resources/list` that includes built-in resources; `nil` for the
    /// application's handler.
    ///
    /// A `resources/read` consults the sources in order. The first
    /// `resources/list` page is the application's first page and the first
    /// page of each listed source, so a client that reads one page sees all
    /// of them. Later pages continue the application's listing, then each
    /// source's, in order. The cursor carries every position.
    static func builtInResources(
        _ request: Request<AnyMethod>, sources: [BuiltInResourceSource], applicationList: RequestHandlerBox?
    ) async throws -> Response<AnyMethod>? {
        let params = request.params.objectValue ?? [:]
        if request.method == ReadResource.name {
            guard let uri = params["uri"]?.stringValue else { return nil }
            for source in sources {
                if let result = try await source.read(uri) {
                    return Response(id: request.id, result: try Value.preservingStrings(result))
                }
            }
            return nil
        }
        let listed = sources.filter(\.lists)
        guard request.method == ListResources.name, !listed.isEmpty else { return nil }

        var position = ResourceListingCursor.start(
            listsApplication: applicationList != nil, sources: listed.map(\.key))
        if let value = params["cursor"], value != .null {
            guard let cursor = value.stringValue, var decoded = ResourceListingCursor(cursor) else {
                throw MCPError.invalidParams("Invalid cursor")
            }
            // A position that this server cannot advance would give a next
            // cursor on every page.
            if applicationList == nil { decoded.application = .done }
            decoded.sources = decoded.sources.filter { key, _ in listed.contains { $0.key == key } }
            position = decoded
        }
        var resources: [Value] = []
        var meta: Value?
        var hints: [String: Value] = [:]
        var next = position
        if let application = applicationList, case .page(let cursor) = position.application {
            var forwarded = params
            forwarded["cursor"] = cursor.map(Value.string)
            let response = try await application(
                Request<AnyMethod>(
                    id: request.id, method: request.method, params: .object(forwarded), _meta: request._meta))
            guard case .success(let value) = response.result, let object = value.objectValue else { return response }
            resources += object["resources"]?.arrayValue ?? []
            meta = object["_meta"]
            for key in [ResultKeys.ttlMs, ResultKeys.cacheScope] { hints[key] = object[key] }
            next.application = object["nextCursor"]?.stringValue.map { .page($0) } ?? .done
        }
        // Each source joins the first page, and follows the application's
        // last page and the earlier sources' last pages.
        var earlierDone = position.application == .done
        for source in listed {
            let current = position.sources[source.key] ?? .done
            defer { earlierDone = earlierDone && current == .done }
            guard case .page(let cursor) = current, cursor == nil || earlierDone else { continue }
            let page = try await source.list(cursor)
            let encoded = try Value.preservingStrings(page)
            resources += encoded.objectValue?["resources"]?.arrayValue ?? []
            if meta == nil { meta = encoded.objectValue?["_meta"] }
            for key in [ResultKeys.ttlMs, ResultKeys.cacheScope] where hints[key] == nil {
                hints[key] = encoded.objectValue?[key]
            }
            next.sources[source.key] = page.nextCursor.map { .page($0) } ?? .done
        }
        var result: [String: Value] = ["resources": .array(resources)]
        if let cursor = next.encoded { result["nextCursor"] = .string(cursor) }
        if let meta { result["_meta"] = meta }
        result.merge(hints) { current, _ in current }
        return Response(id: request.id, result: .object(result))
    }
}

// MARK: - Merged resources/list

/// Where a `resources/list` that includes built-in resources stands in the
/// application's listing and in each source's: a page still to read, by its
/// cursor (`nil` for the first), or done.
struct ResourceListingCursor: Equatable {
    enum Position: Equatable {
        case page(String?)
        case done
    }

    var application: Position
    var sources: [BuiltInResourceSource.Key: Position]

    static func start(listsApplication: Bool, sources: [BuiltInResourceSource.Key]) -> Self {
        .init(
            application: listsApplication ? .page(nil) : .done,
            sources: Dictionary(uniqueKeysWithValues: sources.map { ($0, .page(nil)) }))
    }

    private static let prefix = "mcp-resources:"
    private static let applicationKey = "a"

    private var isDone: Bool {
        application == .done && sources.values.allSatisfy { $0 == .done }
    }

    /// The cursor of this position, or `nil` when every listing is done.
    var encoded: String? {
        guard !isDone else { return nil }
        var object: [String: Value] = [:]
        if case .page(let cursor) = application { object[Self.applicationKey] = cursor.map(Value.string) ?? .null }
        for (key, position) in sources {
            if case .page(let cursor) = position { object[key.rawValue] = cursor.map(Value.string) ?? .null }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Value.object(object)) else { return nil }
        return Self.prefix + data.base64EncodedString()
    }

    /// The position a cursor of ``encoded`` names; `nil` for any other string.
    init?(_ cursor: String) {
        guard cursor.hasPrefix(Self.prefix), let data = Data(base64Encoded: String(cursor.dropFirst(Self.prefix.count))),
            let value = try? JSONDecoder().decode([String: Value.Preserved].self, from: data)
        else { return nil }
        let known = Set([Self.applicationKey] + BuiltInResourceSource.Key.allCases.map(\.rawValue))
        guard value.keys.allSatisfy(known.contains) else { return nil }
        func position(_ key: String) -> Position? {
            switch value[key]?.value {
            case nil: return .done
            case .null?: return .page(nil)
            case .string(let cursor)?: return .page(cursor)
            default: return nil
            }
        }
        guard let application = position(Self.applicationKey) else { return nil }
        var sources: [BuiltInResourceSource.Key: Position] = [:]
        for key in BuiltInResourceSource.Key.allCases {
            guard let position = position(key.rawValue) else { return nil }
            if position != .done { sources[key] = position }
        }
        self.init(application: application, sources: sources)
        guard !isDone else { return nil }
    }

    init(application: Position, sources: [BuiltInResourceSource.Key: Position]) {
        self.application = application
        self.sources = sources
    }
}
