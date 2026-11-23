import Foundation

// MCP Apps (SEP-1865) on the server: the views that `withAppResources`
// serves. The wire types are in Base/AppTypes.swift.

/// A view that a server serves: an HTML document at a `ui://` URI, with its
/// metadata.
///
/// The server lists it with ``meta`` on the `resources/list` entry, and
/// reads it with ``meta`` on the content item, so that a host can review the
/// metadata before it reads the view.
public struct UIResource: Hashable, Sendable {
    /// The content type of a view: an HTML5 document.
    public static let mimeType = "text/html;profile=mcp-app"

    /// The URI of the view. It starts with `ui://`, in lowercase.
    public let uri: String
    /// The name of the view.
    public var name: String
    /// The human-readable title of the view.
    public var title: String?
    /// What the view does.
    public var description: String?
    /// The HTML document.
    public var body: Body
    /// The security and rendering configuration of the view.
    public var meta: UIResourceMeta?

    /// The HTML document of a view.
    public enum Body: Hashable, Sendable {
        /// The document as text.
        case text(String)
        /// The document as bytes, sent base64-encoded.
        case blob(Data)
    }

    /// A view that is not valid.
    public struct ValidationError: Error, Hashable, CustomStringConvertible {
        /// What is wrong.
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// Creates a view.
    ///
    /// - Throws: ``ValidationError`` when `uri` does not start with `ui://`
    ///   (lowercase) or has nothing after it.
    public init(
        uri: String, name: String, title: String? = nil, description: String? = nil, body: Body,
        meta: UIResourceMeta? = nil
    ) throws {
        let scheme = "ui://"
        // Lowercase, as the extension writes it: views are looked up by the
        // exact URI.
        guard uri.count > scheme.count, uri.hasPrefix(scheme) else {
            throw ValidationError("\(uri) is not a ui:// URI")
        }
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.body = body
        self.meta = meta
    }

    /// Creates a view from an HTML document as text.
    ///
    /// - Throws: ``ValidationError`` when `uri` does not start with `ui://`
    ///   (lowercase) or has nothing after it.
    public init(
        uri: String, name: String, title: String? = nil, description: String? = nil, html: String,
        meta: UIResourceMeta? = nil
    ) throws {
        try self.init(uri: uri, name: name, title: title, description: description, body: .text(html), meta: meta)
    }

    /// The `resources/list` entry of the view.
    public var listing: Resource {
        var resource = Resource(
            name: name, uri: uri, title: title, description: description, mimeType: Self.mimeType)
        resource.ui = meta
        return resource
    }

    /// The `resources/read` content item of the view.
    public var contents: Resource.Content {
        var content: Resource.Content
        switch body {
        case .text(let html): content = .text(html, uri: uri, mimeType: Self.mimeType)
        case .blob(let data): content = .binary(data, uri: uri, mimeType: Self.mimeType)
        }
        content.ui = meta
        return content
    }
}

/// The views of ``Server/withAppResources(_:listInResources:)``, held in
/// memory.
struct AppResourceCatalog: Sendable {
    private let resources: [UIResource]
    private let byURI: [String: UIResource]
    private let pageSize: Int

    /// The views, in order. A later view with the URI of an earlier one
    /// replaces it.
    init(_ resources: [UIResource], pageSize: Int = 100) {
        var seen = Set<String>()
        self.resources = resources.reversed().filter { seen.insert($0.uri).inserted }.reversed()
        byURI = Dictionary(resources.map { ($0.uri, $0) }) { _, later in later }
        self.pageSize = max(1, pageSize)
    }

    func read(uri: String) -> ReadResource.Result? {
        byURI[uri].map { ReadResource.Result(contents: [$0.contents]) }
    }

    func list(cursor: String?) throws -> ListResources.Result {
        var start = 0
        if let cursor {
            guard let offset = Int(cursor), offset >= 0, offset <= resources.count else {
                throw MCPError.invalidParams("Invalid cursor")
            }
            start = offset
        }
        let end = min(resources.count, start + pageSize)
        return ListResources.Result(
            resources: resources[start..<end].map(\.listing), nextCursor: end < resources.count ? String(end) : nil)
    }
}

extension Server {
    /// Serves the views `resources` (SEP-1865).
    ///
    /// The server declares the `io.modelcontextprotocol/ui` extension and the
    /// `resources` capability. A `resources/read` of a view is answered
    /// before the application's handler; other URIs, including other
    /// `ui://` URIs, go to the application's handler. With
    /// `listInResources`, `resources/list` includes the views: the first page
    /// is the application handler's first page and the views' first page,
    /// and the cursors are the server's own. Without it, hosts find the views
    /// only through the tools' ``Tool/ui``. A later view with the URI of an
    /// earlier one replaces it. A second call replaces the views; then send a
    /// `ResourceListChangedNotification`, and declare
    /// `resources: .init(listChanged: true)` when you create the server: this
    /// method declares `resources` without it, and listen streams carry the
    /// notification only when it is declared.
    ///
    /// Give each tool that renders a view a ``Tool/ui`` with the view's URI,
    /// and results with meaningful `content` for hosts without views.
    ///
    /// Call it before the server starts.
    @discardableResult
    public func withAppResources(_ resources: [UIResource], listInResources: Bool = true) -> Self {
        installAppResources(AppResourceCatalog(resources), listInResources: listInResources)
        return self
    }
}

extension Server.HandlerContext {
    /// The MCP Apps settings that the client declares; `nil` when it does not
    /// declare the extension.
    ///
    /// A server can give its views only to clients that render them. At
    /// 2026-07-28 a list that varies with the declared capabilities should not
    /// be shared between clients: give it the ``CacheScope/private`` cache
    /// scope. It is simpler to give tools their ``Tool/ui`` for every client,
    /// with meaningful `content` for clients without views.
    public var clientUISettings: UIExtensionSettings? {
        UIExtensionSettings(clientCapabilities?.extensions)
    }
}
