import Foundation

// MCP Apps (SEP-1865) on the client (a host): reading a view and its
// effective metadata. The wire types are in Base/AppTypes.swift.

/// A failure to read a view with ``Client/readAppResource(uri:listing:)``.
public struct AppResourceError: Swift.Error, Hashable, Sendable, CustomStringConvertible {
    /// Why the read failed.
    public struct Reason: Hashable, Sendable, CustomStringConvertible {
        /// The reason's identifier.
        public let rawValue: String

        init(_ rawValue: String) { self.rawValue = rawValue }

        public var description: String { rawValue }

        /// The URI does not start with `ui://` in lowercase.
        public static let notUIResource = Reason("notUIResource")
        /// The read returned no content item for the URI.
        public static let missingContent = Reason("missingContent")
        /// The content item's MIME type is not ``UIResource/mimeType``.
        public static let unsupportedMimeType = Reason("unsupportedMimeType")
        /// The content item has neither `text` nor a `blob` of base64-encoded
        /// UTF-8.
        public static let invalidContent = Reason("invalidContent")
    }

    /// Why the read failed.
    public let reason: Reason
    /// The URI of the view.
    public let uri: String
    /// A description of the failure.
    public let message: String

    init(_ reason: Reason, uri: String, message: String) {
        self.reason = reason
        self.uri = uri
        self.message = message
    }

    public var description: String { "\(reason): \(message)" }
}

/// A view that ``Client/readAppResource(uri:listing:)`` read.
public struct AppResourceContents: Hashable, Sendable {
    /// The URI of the view.
    public var uri: String
    /// The HTML document.
    public var html: String
    /// The effective metadata: the content item's `_meta.ui`, or the
    /// `resources/list` entry's when the content item has none.
    public var meta: UIResourceMeta?
    /// The content item as the server sent it.
    public var content: Resource.Content

    /// Creates the contents of a view.
    public init(uri: String, html: String, meta: UIResourceMeta? = nil, content: Resource.Content) {
        self.uri = uri
        self.html = html
        self.meta = meta
        self.content = content
    }

    /// The Content Security Policy for the view, from ``meta``.
    public var contentSecurityPolicy: String {
        meta?.contentSecurityPolicy ?? UIResourceMeta.CSP.restrictiveDefault
    }
}

extension Client {
    /// The most `resources/list` pages that
    /// ``readAppResource(uri:listing:)`` reads to find a listing entry.
    static let maxListingPages = 100

    /// Reads the view at `uri` (`resources/read`) and its effective metadata.
    ///
    /// The metadata is the content item's `_meta.ui` or, when it has none,
    /// the `resources/list` entry's (the content item takes precedence). A
    /// content item's `_meta.ui` that is not an object gives `nil` metadata,
    /// and so the restrictive default policy. Pass
    /// the `listing` entry when you have it. Without it, and when the content
    /// item has no `_meta.ui`, the client reads `resources/list` pages to
    /// find the entry, at most 100. When the listing cannot be read, the view
    /// has no metadata.
    ///
    /// Render the view in a sandbox with ``AppResourceContents/contentSecurityPolicy``.
    ///
    /// - Throws: ``AppResourceError`` when `uri` is not a `ui://` URI (in
    ///   lowercase, as ``UIResource`` requires), or the content is not an
    ///   HTML view; the server's error otherwise.
    public func readAppResource(uri: String, listing: Resource? = nil) async throws -> AppResourceContents {
        guard uri.count > 5, uri.hasPrefix("ui://") else {
            throw AppResourceError(.notUIResource, uri: uri, message: "\(uri) is not a ui:// URI")
        }
        let result = try await readResource(uri: uri)
        guard let content = result.contents.first(where: { $0.uri == uri }) else {
            throw AppResourceError(.missingContent, uri: uri, message: "the read returned no content for \(uri)")
        }
        guard let mimeType = content.mimeType, Self.isViewMimeType(mimeType) else {
            throw AppResourceError(
                .unsupportedMimeType, uri: uri,
                message: "\(uri) has MIME type \(content.mimeType ?? "none"), not \(UIResource.mimeType)")
        }
        let html: String
        if let text = content.text {
            html = text
        } else if let blob = content.blob, let data = Data(base64Encoded: blob),
            let decoded = String(data: data, encoding: .utf8)
        {
            html = decoded
        } else {
            throw AppResourceError(
                .invalidContent, uri: uri, message: "\(uri) has neither text nor a blob of base64-encoded UTF-8")
        }
        // The listing's only when `_meta.ui` is absent or null, as the
        // specification's `??`.
        var meta = content.ui
        if (content._meta?["ui"] ?? .null) == .null {
            let entry: Resource?
            if let listing, listing.uri == uri {
                entry = listing
            } else {
                // The listing only adds metadata: without it, the view has
                // the restrictive default policy.
                do {
                    entry = try await listingEntry(for: uri)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    entry = nil
                }
            }
            meta = entry?.ui
        }
        return AppResourceContents(uri: uri, html: html, meta: meta, content: content)
    }

    /// The `resources/list` entry for `uri`, from at most
    /// ``maxListingPages`` pages; `nil` when the listing does not have it.
    private func listingEntry(for uri: String) async throws -> Resource? {
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<Self.maxListingPages {
            let page = try await listResources(cursor: cursor)
            if let entry = page.resources.first(where: { $0.uri == uri }) { return entry }
            guard let next = page.nextCursor, seen.insert(next).inserted else { return nil }
            cursor = next
        }
        return nil
    }

    /// Whether `mimeType` is ``UIResource/mimeType``: `text/html` with the
    /// parameter `profile=mcp-app`. The type, the subtype and parameter names
    /// are case-insensitive, whitespace around `;` and `=` is ignored, a
    /// value can be quoted (RFC 9110), and other parameters are allowed.
    static func isViewMimeType(_ mimeType: String) -> Bool {
        let parts = mimeType.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.first?.lowercased() == "text/html" else { return false }
        return parts.dropFirst().contains { parameter in
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return pair.count == 2 && pair[0].lowercased() == "profile"
                && (pair[1] == "mcp-app" || pair[1] == "\"mcp-app\"")
        }
    }
}
