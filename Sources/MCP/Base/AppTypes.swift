import Foundation

// MCP Apps (SEP-1865): a server delivers interactive HTML views as `ui://`
// resources, and its tools refer to them in `_meta.ui`. The specification is
// the `io.modelcontextprotocol/ui` extension: modelcontextprotocol/ext-apps
// at v2.0.4 (7af9a75d), specification/draft/apps.mdx. This file has the wire
// types. The View-Host bridge (`ui/*` messages) is not implemented.

extension ExtensionID {
    /// The MCP Apps extension (SEP-1865).
    public static let ui = "io.modelcontextprotocol/ui"
}

/// The settings of the MCP Apps extension that a client (a host) declares in
/// `capabilities.extensions`.
public struct UIExtensionSettings: Hashable, Codable, Sendable {
    /// The content types of the views that the host renders, such as
    /// ``UIResource/mimeType``.
    public var mimeTypes: [String]

    /// Creates the settings. The default is the HTML views of the
    /// specification.
    public init(mimeTypes: [String] = [UIResource.mimeType]) {
        self.mimeTypes = mimeTypes
    }

    /// The settings that `extensions` declares, or `nil` when it does not
    /// declare the extension with an object. Entries of `mimeTypes` that are
    /// not strings are ignored.
    public init?(_ extensions: [String: Value]?) {
        guard let value = extensions?[ExtensionID.ui]?.objectValue else { return nil }
        mimeTypes = value["mimeTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Whether the host renders views of `mimeType`.
    public func supports(_ mimeType: String = UIResource.mimeType) -> Bool {
        mimeTypes.contains(mimeType)
    }

    /// The settings as the value of `extensions[ExtensionID.ui]`.
    var value: Value {
        ["mimeTypes": .array(mimeTypes.map(Value.string))]
    }
}

extension Client.Capabilities {
    /// The MCP Apps extension settings in ``extensions``; `nil` when the
    /// client does not declare the extension. Set it to declare the extension;
    /// setting it replaces the extension's settings object.
    public var ui: UIExtensionSettings? {
        get { UIExtensionSettings(extensions) }
        set {
            var updated = extensions ?? [:]
            updated[ExtensionID.ui] = newValue?.value
            extensions = updated.isEmpty ? nil : updated
        }
    }
}

// MARK: - Resource metadata

/// The `_meta.ui` of a view resource: its security and rendering
/// configuration.
///
/// It can be on the `resources/list` entry, on the `resources/read` content
/// item, or on both. The content item's value takes precedence. Decoding is
/// lenient: a field of the wrong type is read as absent.
public struct UIResourceMeta: Hashable, Codable, Sendable {
    /// The external origins that the view uses. `nil` means the restrictive
    /// default policy, ``CSP/restrictiveDefault``.
    public var csp: CSP?
    /// The browser features that the view asks for. A host can refuse them.
    public var permissions: Permissions?
    /// A dedicated origin for the view. The format is host-specific.
    public var domain: String?
    /// Whether the host shows a border and background. `nil` lets the host
    /// decide.
    public var prefersBorder: Bool?

    /// Creates resource metadata.
    public init(csp: CSP? = nil, permissions: Permissions? = nil, domain: String? = nil, prefersBorder: Bool? = nil) {
        self.csp = csp
        self.permissions = permissions
        self.domain = domain
        self.prefersBorder = prefersBorder
    }

    /// The Content Security Policy for the view: ``CSP/policy()`` of
    /// ``csp``, or ``CSP/restrictiveDefault`` when ``csp`` is `nil`.
    public var contentSecurityPolicy: String {
        csp?.policy() ?? CSP.restrictiveDefault
    }

    private enum CodingKeys: String, CodingKey {
        case csp, permissions, domain, prefersBorder
    }

    static let keys = ["csp", "permissions", "domain", "prefersBorder"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        csp = (try? container.decodeIfPresent(CSP.self, forKey: .csp)) ?? nil
        permissions = (try? container.decodeIfPresent(Permissions.self, forKey: .permissions)) ?? nil
        domain = (try? container.decodeIfPresent(String.self, forKey: .domain)) ?? nil
        prefersBorder = (try? container.decodeIfPresent(Bool.self, forKey: .prefersBorder)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(csp, forKey: .csp)
        try container.encodeIfPresent(permissions, forKey: .permissions)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(prefersBorder, forKey: .prefersBorder)
    }

    /// The external origins of a view, from which a host builds the view's
    /// Content Security Policy.
    ///
    /// An origin can have a wildcard subdomain, such as
    /// `https://*.example.com`. An empty or `nil` list allows no external
    /// origin.
    public struct CSP: Hashable, Codable, Sendable {
        /// The origins of network requests (fetch, XHR, WebSocket):
        /// `connect-src`.
        public var connectDomains: [String]?
        /// The origins of scripts, styles, images, fonts and media:
        /// `script-src`, `style-src`, `img-src`, `font-src` and `media-src`.
        public var resourceDomains: [String]?
        /// The origins of nested frames: `frame-src`.
        public var frameDomains: [String]?
        /// The allowed base URIs of the document: `base-uri`.
        public var baseUriDomains: [String]?

        /// Creates the origins of a view.
        public init(
            connectDomains: [String]? = nil, resourceDomains: [String]? = nil, frameDomains: [String]? = nil,
            baseUriDomains: [String]? = nil
        ) {
            self.connectDomains = connectDomains
            self.resourceDomains = resourceDomains
            self.frameDomains = frameDomains
            self.baseUriDomains = baseUriDomains
        }

        /// The policy that a host must use for a view without `csp`.
        public static let restrictiveDefault = [
            "default-src 'none'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "media-src 'self' data:",
            "object-src 'none'",
            "connect-src 'none'",
        ].joined(separator: "; ")

        /// The Content Security Policy for these origins, as the
        /// specification constructs it.
        ///
        /// The policy uses the declared sources as given, except that a source
        /// that contains whitespace, a control character, `;`, `,`, `'` or `"`
        /// is dropped, so that it cannot add a source keyword or a directive.
        /// A declared `*`, or a scheme such as `https:`, allows any origin: a
        /// host that does not trust the server's declarations filters
        /// ``connectDomains`` and the other lists first. A host can make the
        /// policy more restrictive, but must not allow more origins.
        public func policy() -> String {
            func sources(_ domains: [String]?) -> String {
                (domains ?? []).filter(Self.isSafeSource).joined(separator: " ")
            }
            func directive(_ name: String, _ fixed: String, _ domains: [String]?) -> String {
                [name, fixed, sources(domains)].filter { !$0.isEmpty }.joined(separator: " ")
            }
            let frames = sources(frameDomains)
            let bases = sources(baseUriDomains)
            return [
                "default-src 'none'",
                directive("script-src", "'self' 'unsafe-inline'", resourceDomains),
                directive("style-src", "'self' 'unsafe-inline'", resourceDomains),
                directive("connect-src", "'self'", connectDomains),
                directive("img-src", "'self' data:", resourceDomains),
                directive("font-src", "'self'", resourceDomains),
                directive("media-src", "'self' data:", resourceDomains),
                "frame-src " + (frames.isEmpty ? "'none'" : frames),
                "object-src 'none'",
                "base-uri " + (bases.isEmpty ? "'self'" : bases),
            ].joined(separator: "; ")
        }

        static func isSafeSource(_ source: String) -> Bool {
            !source.isEmpty
                && !source.unicodeScalars.contains {
                    $0.properties.isWhitespace || $0.properties.generalCategory == .control
                        || ";,'\"".unicodeScalars.contains($0)
                }
        }

        private enum CodingKeys: String, CodingKey {
            case connectDomains, resourceDomains, frameDomains, baseUriDomains
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // As written: a `data:` URL stays a string.
            func strings(_ key: CodingKeys) -> [String]? {
                ((try? container.decodeIfPresent([Value.Preserved].self, forKey: key)) ?? nil)?
                    .compactMap(\.value.stringValue)
            }
            connectDomains = strings(.connectDomains)
            resourceDomains = strings(.resourceDomains)
            frameDomains = strings(.frameDomains)
            baseUriDomains = strings(.baseUriDomains)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(connectDomains, forKey: .connectDomains)
            try container.encodeIfPresent(resourceDomains, forKey: .resourceDomains)
            try container.encodeIfPresent(frameDomains, forKey: .frameDomains)
            try container.encodeIfPresent(baseUriDomains, forKey: .baseUriDomains)
        }
    }

    /// The browser features that a view asks for. On the wire, each feature
    /// is a key with an empty object. Decoding also accepts `true`; other
    /// values do not ask.
    public struct Permissions: Hashable, Codable, Sendable {
        /// The camera: Permissions Policy `camera`.
        public var camera: Bool
        /// The microphone: Permissions Policy `microphone`.
        public var microphone: Bool
        /// The location: Permissions Policy `geolocation`.
        public var geolocation: Bool
        /// Writing to the clipboard: Permissions Policy `clipboard-write`.
        public var clipboardWrite: Bool

        /// Creates the features of a view.
        public init(camera: Bool = false, microphone: Bool = false, geolocation: Bool = false, clipboardWrite: Bool = false)
        {
            self.camera = camera
            self.microphone = microphone
            self.geolocation = geolocation
            self.clipboardWrite = clipboardWrite
        }

        /// The Permissions Policy features of the requested permissions, for
        /// the `allow` attribute of the view's frame.
        public var policyFeatures: [String] {
            [
                (camera, "camera"), (microphone, "microphone"), (geolocation, "geolocation"),
                (clipboardWrite, "clipboard-write"),
            ].filter(\.0).map(\.1)
        }

        private enum CodingKeys: String, CodingKey {
            case camera, microphone, geolocation, clipboardWrite
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func requested(_ key: CodingKeys) -> Bool {
                guard let value = try? container.decodeIfPresent(Value.self, forKey: key) else { return false }
                switch value {
                case .object, .bool(true): return true
                default: return false
                }
            }
            camera = requested(.camera)
            microphone = requested(.microphone)
            geolocation = requested(.geolocation)
            clipboardWrite = requested(.clipboardWrite)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            for (requested, key) in [
                (camera, CodingKeys.camera), (microphone, .microphone), (geolocation, .geolocation),
                (clipboardWrite, .clipboardWrite),
            ] where requested {
                try container.encode([String: Value](), forKey: key)
            }
        }
    }
}

// MARK: - Tool metadata

/// The `_meta.ui` of a tool: the view that renders its results, and who can
/// call it.
///
/// Decoding is lenient: a field of the wrong type is read as absent, and
/// entries of `visibility` that are not strings are ignored.
public struct ToolUIMeta: Hashable, Codable, Sendable {
    /// The `ui://` URI of the view that renders the tool's results.
    public var resourceUri: String?
    /// Who can call the tool. `nil` means both ``Visibility/model`` and
    /// ``Visibility/app``.
    public var visibility: [Visibility]?

    /// Creates tool metadata.
    public init(resourceUri: String? = nil, visibility: [Visibility]? = nil) {
        self.resourceUri = resourceUri
        self.visibility = visibility
    }

    /// Who can call a tool.
    ///
    /// Open to values this SDK does not know.
    public struct Visibility: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
        CustomStringConvertible
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var description: String { rawValue }

        /// The agent (the model) sees the tool and can call it.
        public static let model: Self = "model"
        /// The view can call the tool, from the same server connection only.
        public static let app: Self = "app"
    }

    /// The deprecated flat key of the view URI, `_meta["ui/resourceUri"]`.
    /// The SDK reads it and never writes it.
    static let legacyResourceUriKey = "ui/resourceUri"

    static let keys = ["resourceUri", "visibility"]

    private enum CodingKeys: String, CodingKey {
        case resourceUri, visibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceUri = (try? container.decodeIfPresent(String.self, forKey: .resourceUri)) ?? nil
        // As written: a `data:` URL stays a string.
        visibility = ((try? container.decodeIfPresent([Value.Preserved].self, forKey: .visibility)) ?? nil)?
            .compactMap(\.value.stringValue).map(Visibility.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(resourceUri, forKey: .resourceUri)
        try container.encodeIfPresent(visibility, forKey: .visibility)
    }
}

// MARK: - Accessors

extension Tool {
    /// The MCP Apps metadata in `_meta.ui`; `nil` when the tool has none.
    ///
    /// The getter reads the deprecated flat key `_meta["ui/resourceUri"]`
    /// when `_meta.ui` has no `resourceUri`. The setter writes the known
    /// fields of `_meta.ui`, keeps its other top-level keys, and removes the
    /// flat key. Setting `nil` removes `_meta.ui`.
    public var ui: ToolUIMeta? {
        get {
            var ui: ToolUIMeta? = UIMetaField.read(_meta)
            if ui?.resourceUri == nil, let legacy = _meta?[ToolUIMeta.legacyResourceUriKey]?.stringValue {
                ui = ToolUIMeta(resourceUri: legacy, visibility: ui?.visibility)
            }
            return ui
        }
        set {
            UIMetaField.write(newValue, keys: ToolUIMeta.keys, into: &_meta)
            UIMetaField.remove(ToolUIMeta.legacyResourceUriKey, from: &_meta)
        }
    }

    /// Whether the agent sees the tool: its visibility includes
    /// ``ToolUIMeta/Visibility/model``, or it has no visibility.
    ///
    /// A host must not give the agent a tool for which this is `false`.
    public var isVisibleToModel: Bool {
        ui?.visibility?.contains(.model) ?? true
    }

    /// Whether a view can call the tool: its visibility includes
    /// ``ToolUIMeta/Visibility/app``, or it has no visibility.
    ///
    /// A host must refuse a view's `tools/call` of a tool for which this is
    /// `false`, and of any tool of another server.
    public var isCallableFromApp: Bool {
        ui?.visibility?.contains(.app) ?? true
    }
}

extension Resource {
    /// The MCP Apps metadata in `_meta.ui` of a `resources/list` entry; `nil`
    /// when it has none.
    ///
    /// The setter writes the known fields of `_meta.ui` and keeps its other
    /// top-level keys; `csp` and `permissions` are written as the SDK models
    /// them. Setting `nil` removes `_meta.ui`.
    public var ui: UIResourceMeta? {
        get { UIMetaField.read(_meta) }
        set { UIMetaField.write(newValue, keys: UIResourceMeta.keys, into: &_meta) }
    }
}

extension Resource.Content {
    /// The MCP Apps metadata in `_meta.ui` of a `resources/read` content
    /// item; `nil` when it has none. It takes precedence over the
    /// `resources/list` entry's.
    ///
    /// The setter writes the known fields of `_meta.ui` and keeps its other
    /// top-level keys; `csp` and `permissions` are written as the SDK models
    /// them. Setting `nil` removes `_meta.ui`.
    public var ui: UIResourceMeta? {
        get { UIMetaField.read(_meta) }
        set { UIMetaField.write(newValue, keys: UIResourceMeta.keys, into: &_meta) }
    }
}

/// Reads and writes `_meta.ui`. The raw `_meta` stays the source of truth.
private enum UIMetaField {
    static let key = "ui"

    static func read<T: Decodable>(_ meta: Metadata?) -> T? {
        guard let value = meta?[key], case .object = value, let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Codable>(_ newValue: T?, keys: [String], into meta: inout Metadata?) {
        var fields = meta?.fields ?? [:]
        if let newValue, let encoded = (try? Value.preservingStrings(newValue))?.objectValue {
            var ui = fields[key]?.objectValue ?? [:]
            for known in keys { ui[known] = nil }
            ui.merge(encoded) { _, new in new }
            fields[key] = .object(ui)
        } else {
            fields[key] = nil
        }
        set(fields, into: &meta)
    }

    static func remove(_ field: String, from meta: inout Metadata?) {
        guard var fields = meta?.fields, fields[field] != nil else { return }
        fields[field] = nil
        set(fields, into: &meta)
    }

    private static func set(_ fields: [String: Value], into meta: inout Metadata?) {
        guard !fields.isEmpty else {
            meta = nil
            return
        }
        var updated = meta ?? Metadata()
        updated.fields = fields
        meta = updated
    }
}
