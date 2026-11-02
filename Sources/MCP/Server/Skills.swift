import Foundation

// Serving skills (SEP-2640): the catalog a server consults, the packages an
// in-memory catalog holds, and `Server.withSkills`.

/// The skills a server serves.
///
/// ``Server/withSkills(_:listInResources:)`` answers `skills/list`,
/// `skills/get` and, when ``supportsDirectoryRead`` is true,
/// `resources/directory/read` from the catalog, and consults it for
/// `resources/read` before the application's handler. ``InMemorySkillCatalog``
/// serves ``SkillPackage``s; another conformance can generate entries, page
/// a large catalog, or serve skills whose `resources` is
/// ``Skill/Resources/dynamic``.
public protocol SkillCatalog: Sendable {
    /// Whether the catalog answers ``readDirectory(uri:cursor:)``; the server
    /// then declares `directoryRead`. Defaults to `false`.
    var supportsDirectoryRead: Bool { get }

    /// A page of the listing. It may be empty or partial: a skill that is not
    /// listed is still served by URI.
    func listSkills(cursor: String?) async throws -> ListSkills.Result

    /// The entry of the skill whose `SKILL.md` is at `uri`, or `nil` when the
    /// catalog serves no such skill.
    func skill(uri: String) async throws -> Skill?

    /// The contents of a skill file, or `nil` when `uri` is not one; the
    /// application's `resources/read` handler is asked next.
    func readResource(uri: String) async throws -> ReadResource.Result?

    /// The children of the directory at `uri`, or `nil` when it is not a
    /// directory. Defaults to `nil`.
    func readDirectory(uri: String, cursor: String?) async throws -> ReadResourceDirectory.Result?

    /// A page of the skills' `SKILL.md` resources for `resources/list`.
    /// Defaults to one per listed skill: its name, description and
    /// `text/markdown`.
    func listResources(cursor: String?) async throws -> ListResources.Result
}

extension SkillCatalog {
    /// `false`: no directory reads.
    public var supportsDirectoryRead: Bool { false }

    /// `nil`: no directory reads.
    public func readDirectory(uri: String, cursor: String?) async throws -> ReadResourceDirectory.Result? {
        nil
    }

    /// The `SKILL.md` resource of each skill on the page of `listSkills`.
    public func listResources(cursor: String?) async throws -> ListResources.Result {
        let page = try await listSkills(cursor: cursor)
        return ListResources.Result(resources: page.skills.map(\.manifestResource), nextCursor: page.nextCursor)
    }
}

extension Skill {
    /// The skill's `SKILL.md` as a resource: the frontmatter's name and
    /// description, `text/markdown`, and its size when the manifest has it.
    public var manifestResource: Resource {
        var size: Int?
        if case .manifest(let files) = resources { size = files.first { $0.uri == uri }?.size }
        let segment = rootURI.flatMap { $0.split(separator: "/").last.map(String.init) }
        return Resource(
            name: name ?? segment ?? Skill.manifestFileName, uri: uri, description: description,
            mimeType: SkillPackage.markdownMimeType, size: size)
    }
}

// MARK: - Packages

/// A skill's files, checked and ready to serve: the skill path, the files
/// by relative path, and the entry computed from them.
///
/// Creating one checks what SEP-2640 requires of a skill: a `SKILL.md` at
/// the root whose YAML frontmatter has a `name` and a `description`; a name
/// of at most 64 lowercase letters, digits and single hyphens that is the
/// last segment of the path; relative file paths that stay in the skill,
/// none of them also the directory of another; and, unless
/// `enforcesLimits` is false, at most 512 files and 16 MiB.
public struct SkillPackage: Sendable {
    /// Where the skill is in the server's namespace, such as `git-workflow`
    /// or `acme/billing/refunds`. The last segment is the skill's name.
    public let path: String
    /// The URI scheme, `skill` by default.
    public let scheme: String
    /// The files, keyed by their path relative to the skill's root, such as
    /// `SKILL.md` or `references/FORMS.md`.
    public let files: [String: Data]
    /// The entry `skills/list` and `skills/get` return.
    public let skill: Skill

    /// The MIME type of `SKILL.md` and other Markdown files.
    public static let markdownMimeType = "text/markdown"

    /// The error thrown for a skill that cannot be served.
    public struct ValidationError: Error, Hashable, CustomStringConvertible {
        /// What is wrong.
        public let message: String
        /// A textual description of the error.
        public var description: String { message }

        init(_ message: String) { self.message = message }
    }

    /// A skill made of `files`, at `path`.
    ///
    /// - Throws: ``ValidationError`` when the skill does not follow SEP-2640.
    public init(path: String, files: [String: Data], scheme: String = "skill", enforcesLimits: Bool = true) throws {
        try Self.checkScheme(scheme)
        let segments = try Self.pathSegments(path)
        guard let manifest = files[Skill.manifestFileName] else {
            throw ValidationError("\(path): no \(Skill.manifestFileName) at the root")
        }
        guard let document = String(data: manifest, encoding: .utf8) else {
            throw ValidationError("\(path)/\(Skill.manifestFileName) is not UTF-8")
        }
        let frontmatter: [String: Value]
        do {
            frontmatter = try SkillFrontmatter.parse(document: document)
        } catch {
            throw ValidationError("\(path)/\(Skill.manifestFileName): \(error)")
        }
        guard let name = frontmatter["name"]?.stringValue, !name.isEmpty else {
            throw ValidationError("\(path)/\(Skill.manifestFileName): the frontmatter has no name")
        }
        guard let description = frontmatter["description"]?.stringValue, !description.isEmpty else {
            throw ValidationError("\(path)/\(Skill.manifestFileName): the frontmatter has no description")
        }
        guard Self.isValidName(name) else {
            throw ValidationError(
                "\(path): the name \(name) is not 1 to 64 lowercase letters, digits and single hyphens")
        }
        guard segments.last == name else {
            throw ValidationError("\(path): the last segment of the path must be the name, \(name)")
        }
        if enforcesLimits {
            let total = files.values.reduce(0) { $0 + $1.count }
            guard files.count <= Skill.maximumResources, total <= Skill.maximumTotalSize else {
                throw ValidationError(
                    "\(path): \(files.count) files and \(total) bytes; hosts need accept only \(Skill.maximumResources) files and \(Skill.maximumTotalSize) bytes"
                )
            }
        }
        let root = "\(scheme)://\(segments.joined(separator: "/"))"
        var entries: [SkillResource] = []
        for relative in files.keys.sorted(by: Self.manifestFirst) {
            let components = try Self.fileComponents(relative, in: path)
            for depth in 1..<components.count where files[components[..<depth].joined(separator: "/")] != nil {
                throw ValidationError(
                    "\(path): \(components[..<depth].joined(separator: "/")) is a file and the directory of \(relative)")
            }
            let uri = root + "/" + components.map(Self.percentEncoded).joined(separator: "/")
            entries.append(SkillResource(uri: uri, data: files[relative]!))
        }
        self.path = segments.joined(separator: "/")
        self.scheme = scheme
        self.files = files
        self.skill = Skill(
            uri: root + "/" + Skill.manifestFileName, frontmatter: frontmatter, resources: .manifest(entries))
    }

    /// The skill in `directory`, at `path`.
    ///
    /// Reads every regular file under the directory. Names that start with
    /// `.` (`.git`, `.DS_Store`) are skipped, and so is a symbolic link that
    /// leads out of the directory.
    ///
    /// - Throws: ``ValidationError``, or the error reading a file.
    public init(path: String, directory: URL, scheme: String = "skill", enforcesLimits: Bool = true) throws {
        try self.init(
            path: path, files: try Self.readFiles(in: directory), scheme: scheme, enforcesLimits: enforcesLimits)
    }

    /// The file at `uri`, with its MIME type.
    func file(at uri: String) -> (data: Data, mimeType: String)? {
        let prefix = skill.rootURI.map { $0 + "/" } ?? ""
        guard uri.hasPrefix(prefix) else { return nil }
        let encoded = uri.dropFirst(prefix.count)
        guard let relative = encoded.removingPercentEncoding, let data = files[relative] else { return nil }
        return (data, Self.mimeType(of: relative))
    }

    // MARK: Rules

    /// The Agent Skills naming rule.
    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-")
        else { return false }
        var previous: UInt8 = 0
        for byte in bytes {
            let allowed = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
            guard allowed, !(byte == 0x2D && previous == 0x2D) else { return false }
            previous = byte
        }
        return true
    }

    private static func checkScheme(_ scheme: String) throws {
        let bytes = Array(scheme.utf8)
        let valid =
            bytes.first.map { ($0 >= 0x61 && $0 <= 0x7A) } == true
            && bytes.allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E
            }
        guard valid else { throw ValidationError("\(scheme) is not a URI scheme") }
    }

    /// The segments of a skill path: unreserved URI characters only.
    private static func pathSegments(_ path: String) throws -> [String] {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..",
                segment.unicodeScalars.allSatisfy({ unreserved.contains($0) })
            else {
                throw ValidationError(
                    "\(path): a skill path is segments of letters, digits, -, ., _ and ~, separated by /")
            }
        }
        return segments
    }

    /// The components of a relative file path that stays inside the skill.
    private static func fileComponents(_ relative: String, in path: String) throws -> [String] {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.contains("\\"), !relative.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ValidationError("\(path): \(relative) is not a relative path inside the skill")
        }
        return components
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func percentEncoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    private static func manifestFirst(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == Skill.manifestFileName { return rhs != lhs }
        if rhs == Skill.manifestFileName { return false }
        return lhs < rhs
    }

    // MARK: Files

    private static func readFiles(in directory: URL) throws -> [String: Data] {
        let root = directory.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let manager = FileManager.default
        var files: [String: Data] = [:]
        for relative in try manager.subpathsOfDirectory(atPath: root.path) {
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            // A link is followed only when it stays in the directory.
            let resolved = root.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPath),
                (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files[relative] = try Data(contentsOf: resolved)
        }
        return files
    }

    /// The MIME type of a file, from its extension.
    static func mimeType(of relative: String) -> String {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "text/plain" }
        return mimeTypes[name[name.index(after: dot)...].lowercased()] ?? "application/octet-stream"
    }

    private static let mimeTypes: [String: String] = [
        "md": markdownMimeType, "markdown": markdownMimeType, "txt": "text/plain", "text": "text/plain",
        "html": "text/html", "htm": "text/html", "css": "text/css", "csv": "text/csv",
        "xml": "application/xml", "json": "application/json", "yaml": "application/yaml",
        "yml": "application/yaml", "toml": "application/toml", "js": "text/javascript",
        "mjs": "text/javascript", "ts": "text/x-typescript", "py": "text/x-python", "rb": "text/x-ruby",
        "sh": "text/x-shellscript", "swift": "text/x-swift", "go": "text/x-go", "rs": "text/x-rust",
        "java": "text/x-java", "c": "text/x-c", "h": "text/x-c", "sql": "application/sql",
        "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "zip": "application/zip",
    ]

    /// Contents as text when the bytes are UTF-8 and the type is textual, as
    /// a blob otherwise: the digest covers the bytes either way.
    static func contents(_ data: Data, uri: String, mimeType: String) -> Resource.Content {
        let textual =
            mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/yaml"
            || mimeType == "application/xml" || mimeType == "application/toml" || mimeType == "application/sql"
            || mimeType == "image/svg+xml"
        if textual, let text = String(data: data, encoding: .utf8), Data(text.utf8) == data {
            return .text(text, uri: uri, mimeType: mimeType)
        }
        return .binary(data, uri: uri, mimeType: mimeType)
    }
}

// MARK: - In-memory catalog

/// A catalog of ``SkillPackage``s, held in memory, that answers directory
/// reads.
///
/// Every directory of the skills' namespace is a directory resource: each
/// skill's root and subdirectories, and the prefixes of skill paths, such
/// as `skill://acme` for `acme/billing/refunds`. After ``setSkills(_:)``
/// changes the catalog, send a `ResourceListChangedNotification`.
public actor InMemorySkillCatalog: SkillCatalog {
    /// Directory reads are answered.
    public nonisolated var supportsDirectoryRead: Bool { true }

    /// The skills, in listing order.
    public private(set) var skills: [SkillPackage] = []

    private let pageSize: Int
    private var bySkillURI: [String: SkillPackage] = [:]
    private var directories: [String: [Resource]] = [:]

    /// A catalog of `skills`, listed `pageSize` at a time. A later package
    /// with the same skill URI as an earlier one replaces it.
    public init(_ skills: [SkillPackage] = [], pageSize: Int = 100) {
        self.pageSize = max(1, pageSize)
        let skills = Self.deduplicated(skills)
        let (bySkillURI, directories) = Self.index(skills)
        self.skills = skills
        self.bySkillURI = bySkillURI
        self.directories = directories
    }

    /// Replaces the skills. A later package with the same skill URI as an
    /// earlier one replaces it.
    public func setSkills(_ skills: [SkillPackage]) {
        self.skills = Self.deduplicated(skills)
        (bySkillURI, directories) = Self.index(self.skills)
    }

    /// The last package of each skill URI, in the order of the last ones.
    private static func deduplicated(_ skills: [SkillPackage]) -> [SkillPackage] {
        var seen = Set<String>()
        return skills.reversed().filter { seen.insert($0.skill.uri).inserted }.reversed()
    }

    /// A page of the skills, in order.
    public func listSkills(cursor: String?) async throws -> ListSkills.Result {
        let start = try offset(cursor, count: skills.count)
        let end = start + min(pageSize, skills.count - start)
        return ListSkills.Result(
            skills: skills[start..<end].map(\.skill), nextCursor: end < skills.count ? String(end) : nil)
    }

    /// The entry of the skill whose `SKILL.md` is at `uri`.
    public func skill(uri: String) async -> Skill? {
        bySkillURI[uri]?.skill
    }

    /// The contents of the skill file at `uri`.
    public func readResource(uri: String) async -> ReadResource.Result? {
        for package in skills {
            if let (data, mimeType) = package.file(at: uri) {
                return ReadResource.Result(contents: [SkillPackage.contents(data, uri: uri, mimeType: mimeType)])
            }
        }
        return nil
    }

    /// A page of the children of the directory at `uri`.
    public func readDirectory(uri: String, cursor: String?) async throws -> ReadResourceDirectory.Result? {
        guard let children = directories[uri] else { return nil }
        let start = try offset(cursor, count: children.count)
        let end = start + min(pageSize, children.count - start)
        return ReadResourceDirectory.Result(
            resources: Array(children[start..<end]), nextCursor: end < children.count ? String(end) : nil)
    }

    /// The offset a cursor names in a collection of `count` elements: at
    /// most `count`, which is an empty page.
    private func offset(_ cursor: String?, count: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard let offset = Int(cursor), (0...count).contains(offset) else {
            throw MCPError.invalidParams("Invalid cursor")
        }
        return offset
    }

    private static func index(_ skills: [SkillPackage]) -> ([String: SkillPackage], [String: [Resource]]) {
        var bySkillURI: [String: SkillPackage] = [:]
        var children: [String: [String: Resource]] = [:]
        for package in skills {
            bySkillURI[package.skill.uri] = package
            let base = package.path.split(separator: "/").map(String.init)
            for (relative, data) in package.files {
                let components = base + relative.split(separator: "/").map(String.init)
                for depth in 1..<components.count {
                    let parent = uri(package.scheme, components[..<depth])
                    let name = components[depth]
                    let child = uri(package.scheme, components[...depth])
                    if depth == components.count - 1 {
                        children[parent, default: [:]][name] = Resource(
                            name: name, uri: child, mimeType: SkillPackage.mimeType(of: relative), size: data.count)
                    } else if children[parent]?[name] == nil {
                        children[parent, default: [:]][name] = Resource(
                            name: name, uri: child, mimeType: ReadResourceDirectory.directoryMimeType)
                    }
                }
            }
        }
        let directories = children.mapValues { $0.values.sorted { $0.name < $1.name } }
        return (bySkillURI, directories)
    }

    private static func uri(_ scheme: String, _ components: ArraySlice<String>) -> String {
        "\(scheme)://" + components.map(SkillPackage.percentEncoded).joined(separator: "/")
    }
}

// MARK: - Merged resources/list

/// Where a `resources/list` that includes skills stands in the
/// application's listing and in the skills': a page still to read, by its
/// cursor (`nil` for the first), or done.
struct SkillListingCursor: Equatable {
    enum Position: Equatable {
        case page(String?)
        case done
    }

    var application: Position
    var skills: Position

    static func start(listsApplication: Bool) -> Self {
        .init(application: listsApplication ? .page(nil) : .done, skills: .page(nil))
    }

    private static let prefix = "mcp-skills:"

    /// The cursor of this position, or `nil` when both listings are done.
    var encoded: String? {
        guard application != .done || skills != .done else { return nil }
        var object: [String: Value] = [:]
        if case .page(let cursor) = application { object["a"] = cursor.map(Value.string) ?? .null }
        if case .page(let cursor) = skills { object["s"] = cursor.map(Value.string) ?? .null }
        guard let data = try? JSONEncoder().encode(Value.object(object)) else { return nil }
        return Self.prefix + data.base64EncodedString()
    }

    /// The position a cursor of ``encoded`` names; `nil` for any other string.
    init?(_ cursor: String) {
        guard cursor.hasPrefix(Self.prefix), let data = Data(base64Encoded: String(cursor.dropFirst(Self.prefix.count))),
            let value = try? JSONDecoder().decode([String: Value.Preserved].self, from: data)
        else { return nil }
        func position(_ key: String) -> Position? {
            switch value[key]?.value {
            case nil: return .done
            case .null?: return .page(nil)
            case .string(let cursor)?: return .page(cursor)
            default: return nil
            }
        }
        guard let application = position("a"), let skills = position("s"), application != .done || skills != .done
        else { return nil }
        self.init(application: application, skills: skills)
    }

    init(application: Position, skills: Position) {
        self.application = application
        self.skills = skills
    }
}

// MARK: - Server

extension Server {
    /// Serves the skills of `catalog` (SEP-2640).
    ///
    /// The server declares the `io.modelcontextprotocol/skills` extension,
    /// with `directoryRead` when the catalog supports it, and the `resources`
    /// capability; it answers `skills/list`, `skills/get` (-32602 for a URI
    /// that is not a skill) and `resources/directory/read`. A `resources/read`
    /// of a skill file is answered from the catalog, before the application's
    /// handler, which never sees it: an access check in that handler does not
    /// cover skill files. Check access in the catalog, whose methods run with
    /// ``Server/currentHandlerContext`` set, or refuse the client with the
    /// hooks of ``Server/start(transport:initializeHook:statelessRequestHook:)``.
    /// With `listInResources`, `resources/list` includes the skills'
    /// `SKILL.md` resources: the first page is the application handler's
    /// first page and the skills' first page, so a client that reads one
    /// page sees both; the cursors are the server's own.
    ///
    /// Call it before the server starts.
    @discardableResult
    public func withSkills(_ catalog: some SkillCatalog, listInResources: Bool = true) -> Self {
        installSkills(catalog, listInResources: listInResources)
        return self
    }
}
