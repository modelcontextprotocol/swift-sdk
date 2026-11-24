import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A static document that describes a remote MCP server before a client
/// connects: its identity, its endpoints and the protocol versions they serve
/// (SEP-2127).
///
/// The format is the one of the Server Card extension
/// (`modelcontextprotocol/ext-server-card` at `526201bb`). A card does not
/// list tools, resources or prompts, and does not declare capabilities.
///
/// A card is advisory: a client must not use it for security or access
/// decisions, and prefers the values of `server/discover` when the two
/// disagree (``mismatches(with:)``).
///
/// - Server: build a card with ``init(info:endpoint:protocolVersions:name:description:)``
///   and serve it with ``ServerCardValidator``.
/// - Client: get a card with ``fetch(from:session:)``. Find its URL in an AI
///   Catalog, or use ``cardURL(forEndpoint:)`` for the recommended location.
public struct ServerCard: Hashable, Codable, Sendable {
    /// The media type of a Server Card: `application/mcp-server-card+json`.
    public static let mediaType = "application/mcp-server-card+json"

    /// The only valid `$schema` value: the v1 Server Card schema.
    public static let schemaURL = "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json"

    /// The JSON Schema URI the document conforms to; ``schemaURL``.
    public var schema: String
    /// The server name in reverse-DNS format, with exactly one `/`, such as
    /// `com.example/weather`.
    public var name: String
    /// The server version, such as `1.0.2`. Not a range.
    public var version: String
    /// What the server does, in 1 to 100 characters.
    public var description: String
    /// A display name, in 1 to 100 characters.
    public var title: String?
    /// The server's homepage or documentation.
    public var websiteUrl: String?
    /// Where the source code is.
    public var repository: Repository?
    /// Icons for a user interface.
    public var icons: [Icon]?
    /// The HTTP endpoints of the server.
    public var remotes: [Remote]?
    /// Vendor metadata, with reverse-DNS keys. Not for capabilities.
    public var _meta: Metadata?

    /// Creates a card.
    public init(
        name: String,
        version: String,
        description: String,
        title: String? = nil,
        websiteUrl: String? = nil,
        repository: Repository? = nil,
        icons: [Icon]? = nil,
        remotes: [Remote]? = nil,
        _meta: Metadata? = nil
    ) {
        self.schema = Self.schemaURL
        self.name = name
        self.version = version
        self.description = description
        self.title = title
        self.websiteUrl = websiteUrl
        self.repository = repository
        self.icons = icons
        self.remotes = remotes
        self._meta = _meta
    }

    /// Creates the card of a server from its implementation information.
    ///
    /// The card has one Streamable HTTP remote at `endpoint` that serves
    /// `protocolVersions`, such as the server's
    /// ``Server/Configuration/protocolVersions``. `name` and `description`
    /// default to the information's; a card needs both, and the name must be
    /// in reverse-DNS format. Use the same name in `info`: a client compares
    /// the card with the `serverInfo` it gets when it connects.
    public init(
        info: Server.Info,
        endpoint: URL,
        protocolVersions: [String],
        name: String? = nil,
        description: String? = nil
    ) {
        self.init(
            name: name ?? info.name,
            version: info.version,
            description: description ?? info.description ?? "",
            title: info.title,
            websiteUrl: info.websiteUrl,
            icons: info.icons,
            remotes: [Remote(type: .streamableHTTP, url: endpoint.absoluteString, supportedProtocolVersions: protocolVersions)])
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name, version, description, title, websiteUrl, repository, icons, remotes, _meta
    }
}

// MARK: - Nested types

extension ServerCard {
    /// Where the source code of the server is.
    public struct Repository: Hashable, Codable, Sendable {
        /// The repository URL, for browsing and `git clone`.
        public var url: String
        /// The hosting service, such as `github`.
        public var source: String
        /// The path of the server in the repository, for a monorepo.
        public var subfolder: String?
        /// The identifier the hosting service gives the repository.
        public var id: String?

        /// Creates repository metadata.
        public init(url: String, source: String, subfolder: String? = nil, id: String? = nil) {
            self.url = url
            self.source = source
            self.subfolder = subfolder
            self.id = id
        }
    }

    /// An HTTP endpoint of the server.
    public struct Remote: Hashable, Codable, Sendable {
        /// The transport of an endpoint.
        ///
        /// New types can appear in a later revision, so a `switch` needs a
        /// `default`. A type the SDK does not know decodes as itself.
        public struct TransportType: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public var description: String { rawValue }

            /// Streamable HTTP.
            public static let streamableHTTP = TransportType(rawValue: "streamable-http")
            /// HTTP+SSE, from 2024-11-05. Deprecated by the specification
            /// (SEP-2596); the SDK does not implement it.
            public static let sse = TransportType(rawValue: "sse")
        }

        /// The transport.
        public var type: TransportType
        /// The URL, or a URL template with `{variable}` placeholders.
        public var url: String
        /// The HTTP headers the endpoint needs or accepts.
        public var headers: [KeyValueInput]?
        /// The variables of `url` and of the header values, by name.
        public var variables: [String: Input]?
        /// The protocol versions the endpoint serves.
        public var supportedProtocolVersions: [String]?

        /// Creates an endpoint.
        public init(
            type: TransportType, url: String, headers: [KeyValueInput]? = nil,
            variables: [String: Input]? = nil, supportedProtocolVersions: [String]? = nil
        ) {
            self.type = type
            self.url = url
            self.headers = headers
            self.variables = variables
            self.supportedProtocolVersions = supportedProtocolVersions
        }

        /// The URL with each `{variable}` replaced.
        ///
        /// A variable takes its value from `values`, then its `value`, then its
        /// `default`. A variable without a value is an error when it is
        /// required or not in ``variables``; an optional one becomes empty.
        ///
        /// A value is percent-encoded except for the unreserved characters, as
        /// in an RFC 6570 simple expansion, so it cannot add a path, query or
        /// user to the URL or change its host. A placeholder that starts the
        /// URL, such as `{base}/mcp`, is the scheme and host and is inserted
        /// as given; the others are encoded, also after a starting placeholder
        /// that is empty.
        ///
        /// The result can be `http` on any host: a card may list a plaintext
        /// endpoint, and the `https` rule of ``ServerCard/fetch(from:session:)``
        /// covers the card, not its remotes. Check the scheme before you
        /// connect when the connection needs TLS.
        ///
        /// - Throws: ``ServerCardError`` with ``ServerCardError/Reason/missingVariable``
        ///   or ``ServerCardError/Reason/invalidCard`` when the result is not an
        ///   `http` or `https` URL.
        public func url(resolving values: [String: String] = [:]) throws -> URL {
            var result = ""
            var rest = Substring(url)
            while let open = rest.firstIndex(of: "{") {
                result += rest[..<open]
                guard let close = rest[open...].firstIndex(of: "}") else {
                    throw ServerCardError(.invalidCard, "The remote URL has an unclosed {: \(url)")
                }
                let name = String(rest[rest.index(after: open)..<close])
                let input = variables?[name]
                if let value = values[name] ?? input?.value ?? input?.default {
                    // `rest` shares the indices of `url`. Only the placeholder at
                    // the start is the scheme and host, even when it is empty.
                    result += open == url.startIndex ? value : Self.percentEncoded(value)
                } else if input == nil || input?.isRequired == true {
                    throw ServerCardError(.missingVariable, "The remote URL needs a value for {\(name)}")
                }
                rest = rest[rest.index(after: close)...]
            }
            result += rest
            guard let resolved = URL(string: result),
                let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
                resolved.host?.isEmpty == false
            else {
                // The template, not the result: values can be secrets.
                throw ServerCardError(.invalidCard, "The remote URL is not an http or https URL: \(url)")
            }
            return resolved
        }

        /// `value` with every character but `A-Z a-z 0-9 - . _ ~` percent-encoded.
        private static func percentEncoded(_ value: String) -> String {
            var unreserved = CharacterSet(charactersIn: "-._~")
            unreserved.formUnion(CharacterSet(charactersIn: "a"..."z"))
            unreserved.formUnion(CharacterSet(charactersIn: "A"..."Z"))
            unreserved.formUnion(CharacterSet(charactersIn: "0"..."9"))
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
    }

    /// A value the user or the card supplies, for a URL variable or a header.
    public struct Input: Hashable, Codable, Sendable {
        /// The format of an input.
        ///
        /// New formats can appear in a later revision, so a `switch` needs a
        /// `default`. A format the SDK does not know decodes as itself.
        public struct Format: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public var description: String { rawValue }

            /// A string.
            public static let string = Format(rawValue: "string")
            /// A decimal number.
            public static let number = Format(rawValue: "number")
            /// `true` or `false`.
            public static let boolean = Format(rawValue: "boolean")
            /// A path to a file of the user.
            public static let filepath = Format(rawValue: "filepath")
        }

        /// What the input is.
        public var description: String?
        /// Whether the connection needs the input.
        public var isRequired: Bool?
        /// Whether the input is a secret, such as a token.
        public var isSecret: Bool?
        /// The format of the value.
        public var format: Format?
        /// The default value.
        public var `default`: String?
        /// An example to show while the user configures the input.
        public var placeholder: String?
        /// A fixed value, which the user does not configure.
        public var value: String?
        /// The values the user can choose from.
        public var choices: [String]?

        /// Creates an input.
        public init(
            description: String? = nil, isRequired: Bool? = nil, isSecret: Bool? = nil, format: Format? = nil,
            default: String? = nil, placeholder: String? = nil, value: String? = nil, choices: [String]? = nil
        ) {
            self.description = description
            self.isRequired = isRequired
            self.isSecret = isSecret
            self.format = format
            self.default = `default`
            self.placeholder = placeholder
            self.value = value
            self.choices = choices
        }
    }

    /// An HTTP header of an endpoint: an ``Input`` with a name, whose value can
    /// refer to `{variable}` placeholders.
    public struct KeyValueInput: Hashable, Codable, Sendable {
        /// The header name.
        public var name: String
        /// What the header is.
        public var description: String?
        /// Whether the connection needs the header.
        public var isRequired: Bool?
        /// Whether the value is a secret, such as a token.
        public var isSecret: Bool?
        /// The format of the value.
        public var format: Input.Format?
        /// The default value.
        public var `default`: String?
        /// An example to show while the user configures the header.
        public var placeholder: String?
        /// A fixed value, which can refer to `variables`.
        public var value: String?
        /// The values the user can choose from.
        public var choices: [String]?
        /// The variables of `value`, by name.
        public var variables: [String: Input]?

        /// Creates a header input.
        public init(
            name: String, description: String? = nil, isRequired: Bool? = nil, isSecret: Bool? = nil,
            format: Input.Format? = nil, default: String? = nil, placeholder: String? = nil, value: String? = nil,
            choices: [String]? = nil, variables: [String: Input]? = nil
        ) {
            self.name = name
            self.description = description
            self.isRequired = isRequired
            self.isSecret = isSecret
            self.format = format
            self.default = `default`
            self.placeholder = placeholder
            self.value = value
            self.choices = choices
            self.variables = variables
        }
    }
}

// MARK: - Errors

/// A Server Card that cannot be fetched or does not follow the format.
public struct ServerCardError: LocalizedError, Hashable, Sendable, CustomStringConvertible {
    /// Why the card was refused.
    public struct Reason: Hashable, Sendable, CustomStringConvertible {
        /// The reason's identifier.
        public let rawValue: String

        init(_ rawValue: String) { self.rawValue = rawValue }

        public var description: String { rawValue }

        /// The URL has no host, is not `https` and not `http` on a loopback
        /// host, or has a private IP address; or a redirect was refused.
        public static let insecureURL = Reason("insecureURL")
        /// The server answered with a status other than 200 or 304.
        public static let httpStatus = Reason("httpStatus")
        /// The card is larger than 1 MiB.
        public static let tooLarge = Reason("tooLarge")
        /// The body is not a card: it does not decode, or a required field is
        /// missing.
        public static let notACard = Reason("notACard")
        /// The card does not follow the format: a field is too long, or does
        /// not have the required pattern.
        public static let invalidCard = Reason("invalidCard")
        /// A URL variable without a value.
        public static let missingVariable = Reason("missingVariable")
    }

    /// Why the card was refused.
    public let reason: Reason
    /// What happened.
    public let message: String

    /// Creates the error.
    public init(_ reason: Reason, _ message: String) {
        self.reason = reason
        self.message = message
    }

    public var description: String { message }

    /// The message, for `localizedDescription`.
    public var errorDescription: String? { message }
}

// MARK: - Validation

extension ServerCard {
    /// Checks the rules of the format that decoding does not check.
    ///
    /// - Throws: ``ServerCardError`` with ``ServerCardError/Reason/invalidCard``
    ///   and the first problem.
    public func validate() throws {
        if let problem = problems().first {
            throw ServerCardError(.invalidCard, problem)
        }
    }

    /// Every rule of the format that the card breaks.
    func problems() -> [String] {
        var problems: [String] = []
        if schema != Self.schemaURL {
            problems.append("$schema must be \(Self.schemaURL), not \(schema)")
        }
        let nameLength = name.unicodeScalars.count
        if !(3...200).contains(nameLength) || !Self.isReverseDNSName(name) {
            problems.append("name must be 3 to 200 characters in reverse-DNS format with one /, such as com.example/weather: \(name)")
        }
        if version.unicodeScalars.count > 255 {
            problems.append("version has more than 255 characters")
        }
        if Self.isVersionRange(version) {
            problems.append("version must be one version, not a range: \(version)")
        }
        if !(1...100).contains(description.unicodeScalars.count) {
            problems.append("description must have 1 to 100 characters")
        }
        if let title, !(1...100).contains(title.unicodeScalars.count) {
            problems.append("title must have 1 to 100 characters")
        }
        if let websiteUrl, !Self.isAbsoluteURI(websiteUrl) {
            problems.append("websiteUrl is not a URI: \(websiteUrl)")
        }
        if let repository, !Self.isAbsoluteURI(repository.url) {
            problems.append("repository.url is not a URI: \(repository.url)")
        }
        for (index, remote) in (remotes ?? []).enumerated() where !Self.isRemoteURL(remote.url) {
            problems.append("remotes[\(index)].url must start with http://, https:// or a {variable}: \(remote.url)")
        }
        return problems
    }

    /// `^[a-zA-Z0-9.-]+/[a-zA-Z0-9._-]+$`
    private static func isReverseDNSName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[0].unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "-" }
            && parts[1].unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// Ranges such as `^1.2.3`, `~1.2.3`, `>=1.2.3`, `1.x` and `1.*`. An `x`
    /// counts only before the pre-release or build part, as in `1.0.0-alpha.x`.
    private static func isVersionRange(_ version: String) -> Bool {
        if version.unicodeScalars.contains(where: { "^~<>=*| ".unicodeScalars.contains($0) }) { return true }
        let core = version.prefix { $0 != "-" && $0 != "+" }
        return core.split(separator: ".").contains { $0 == "x" || $0 == "X" }
    }

    /// `^(https?://[^\s]+|\{[a-zA-Z_][a-zA-Z0-9_]*\}[^\s]*)$`
    private static func isRemoteURL(_ url: String) -> Bool {
        guard !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return false
        }
        if url.hasPrefix("http://") { return url.count > 7 }
        if url.hasPrefix("https://") { return url.count > 8 }
        guard url.hasPrefix("{"), let close = url.firstIndex(of: "}") else { return false }
        let name = url[url.index(after: url.startIndex)..<close].unicodeScalars
        guard let first = name.first, isLetter(first) || first == "_" else { return false }
        return name.allSatisfy { isAlphanumeric($0) || $0 == "_" }
    }

    private static func isAbsoluteURI(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || ("0"..."9").contains(scalar)
    }
}

// MARK: - Client

extension ServerCard {
    /// The largest card ``fetch(from:session:)`` reads: 1 MiB.
    public static let maximumSize = 1 << 20

    /// The recommended location of the card of the server at `endpoint`:
    /// `<endpoint>/server-card`.
    public static func cardURL(forEndpoint endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            return endpoint.appendingPathComponent("server-card")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/server-card"
        components.query = nil
        components.fragment = nil
        return components.url ?? endpoint.appendingPathComponent("server-card")
    }

    /// The outcome of a fetch with an entity tag.
    ///
    /// Frozen: no case is added in 1.x (HTTP revalidation has two outcomes).
    public enum FetchResult: Hashable, Sendable {
        /// The card, and its `ETag` for the next fetch.
        case card(ServerCard, etag: String?)
        /// The card did not change since the fetch that returned the entity tag.
        case notModified
    }

    /// Fetches the card at `url`, decodes it and checks it.
    ///
    /// The request asks for ``mediaType``. `url` must have a host and be
    /// `https`, or `http` on a loopback host for local development. Its host
    /// must not be a private or reserved IP literal, such as `10.0.0.5` or
    /// `169.254.169.254`, since the URL can come from an untrusted catalog;
    /// loopback hosts are allowed. A redirect is followed only to an `https`
    /// URL, or from loopback `http` to loopback `http`; it goes to a loopback
    /// host only from a loopback host, and never to a private IP literal. Host
    /// names are not resolved: a name whose address is private is fetched. The
    /// body is read up to ``maximumSize``.
    ///
    /// - Throws: ``ServerCardError``, or the error of the session.
    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> ServerCard {
        switch try await fetch(from: url, ifNoneMatch: nil, session: session) {
        case .card(let card, _): return card
        case .notModified:
            throw ServerCardError(.httpStatus, "The server answered 304 to a request without If-None-Match")
        }
    }

    /// Fetches the card at `url` unless it is unchanged since the fetch that
    /// returned `etag`.
    ///
    /// Send the `etag` of the last fetch to revalidate a cached card: the
    /// server answers 304 when the card did not change.
    ///
    /// - Throws: ``ServerCardError``, or the error of the session.
    public static func fetch(from url: URL, ifNoneMatch etag: String?, session: URLSession = .shared)
        async throws -> FetchResult
    {
        try checkSecure(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(mediaType, forHTTPHeaderField: HTTPHeaderName.accept)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: HTTPHeaderName.ifNoneMatch)
        }
        // Each hop is checked before it is requested, as for OAuth discovery.
        let redirects = OAuthRedirectGuard(policy: .validated, validator: OAuthURLValidator())
        let streaming = StreamingSession(configuration: session.configuration, redirects: redirects)
        defer { streaming.invalidate() }
        let (body, response) = try await session.responseBody(for: request, streaming: streaming)
        defer { body.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ServerCardError(.httpStatus, "The response is not an HTTP response")
        }
        // A refused redirect is the response.
        if (300..<400).contains(http.statusCode), http.statusCode != 304,
            let location = http.value(forHTTPHeaderField: "Location"),
            let target = URL(string: location, relativeTo: http.url ?? url)?.absoluteURL,
            // The hop the guard judged it from, not the first URL.
            !redirects.allows(from: http.url ?? url, to: target)
        {
            throw ServerCardError(
                .insecureURL,
                "A Server Card redirect needs https, or loopback http from loopback http, and no private address: \(target.absoluteString)"
            )
        }
        if let final = http.url { try checkSecure(final) }
        if http.statusCode == 304, etag != nil { return .notModified }
        guard http.statusCode == 200 else {
            throw ServerCardError(.httpStatus, "The server answered \(http.statusCode) for \(url.absoluteString)")
        }
        guard http.expectedContentLength <= Int64(maximumSize) else {
            throw ServerCardError(
                .tooLarge, "The card has \(http.expectedContentLength) bytes, more than \(maximumSize)")
        }
        let data = try await body.collect(limit: maximumSize + 1)
        guard data.count <= maximumSize else {
            throw ServerCardError(.tooLarge, "The card has more than \(maximumSize) bytes")
        }
        let card: ServerCard
        do {
            card = try JSONDecoder().decode(ServerCard.self, from: data)
        } catch {
            throw ServerCardError(.notACard, "The body is not a Server Card: \(error)")
        }
        try card.validate()
        return .card(card, etag: http.value(forHTTPHeaderField: HTTPHeaderName.etag))
    }

    /// The rules of a redirect target (`OAuthRedirectGuard`) for the URL the
    /// caller passes, with loopback hosts allowed: a host, no private IP
    /// literal, and `https` or loopback `http`.
    private static func checkSecure(_ url: URL) throws(ServerCardError) {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty,
            !OAuthURLValidator().isPrivateIPHost(host),
            scheme == "https" || (scheme == "http" && OAuthLoopbackHost.isLoopback(host))
        {
            return
        }
        throw ServerCardError(
            .insecureURL,
            "A Server Card needs https, or http on a loopback host, and no private IP address: \(url.absoluteString)")
    }
}

// MARK: - Consistency with server/discover

extension ServerCard {
    /// A value of the card that the live server contradicts.
    public struct Mismatch: Hashable, Sendable, CustomStringConvertible {
        /// The field of a mismatch.
        public struct Field: Hashable, Sendable, CustomStringConvertible {
            /// The field's identifier.
            public let rawValue: String

            init(_ rawValue: String) { self.rawValue = rawValue }

            public var description: String { rawValue }

            /// `name`, against `serverInfo.name`.
            public static let name = Field("name")
            /// `version`, against `serverInfo.version`.
            public static let version = Field("version")
            /// `title`, against `serverInfo.title`.
            public static let title = Field("title")
            /// A version in a remote's `supportedProtocolVersions` that the
            /// server does not serve.
            public static let protocolVersion = Field("protocolVersion")
        }

        /// The field.
        public let field: Field
        /// The card's value.
        public let card: String
        /// The live value; `nil` when the server does not have it.
        public let server: String?

        public var description: String {
            "\(field): the card says \(card), the server says \(server ?? "nothing")"
        }
    }

    /// The values of the card that the `server/discover` result contradicts.
    ///
    /// A card is advisory. Prefer the live values when the two disagree.
    /// Fields the server does not report, such as a `serverInfo` it does not
    /// send, are not compared.
    public func mismatches(with discovery: ServerDiscover.Result) -> [Mismatch] {
        var result: [Mismatch] = []
        if let info = discovery._meta?.serverInfo {
            if info.name != name { result.append(Mismatch(field: .name, card: name, server: info.name)) }
            if info.version != version {
                result.append(Mismatch(field: .version, card: version, server: info.version))
            }
            if let title, let live = info.title, live != title {
                result.append(Mismatch(field: .title, card: title, server: live))
            }
        }
        let served = Set(discovery.supportedVersions)
        var reported: Set<String> = []
        for remote in remotes ?? [] {
            for version in remote.supportedProtocolVersions ?? [] where !served.contains(version) {
                if reported.insert(version).inserted {
                    result.append(Mismatch(field: .protocolVersion, card: version, server: nil))
                }
            }
        }
        return result
    }
}
