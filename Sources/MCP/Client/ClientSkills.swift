import Foundation

// Skills on the client (SEP-2640): listing and retrieving entries, reading
// directories, and loading a skill with its content verified against the
// entry it was loaded under.

/// The error thrown when a skill's content is not what its entry promises,
/// or when the entry cannot be loaded.
///
/// Content that fails verification is never returned. A digest or size
/// mismatch can also mean the skill changed after the entry was fetched:
/// get the current entry with ``Client/getSkill(uri:)`` and load it again,
/// which also revokes any approval bound to the old entry.
public struct SkillVerificationError: Swift.Error, Hashable, Sendable, CustomStringConvertible {
    /// Why verification failed.
    public struct Reason: Hashable, Sendable, CustomStringConvertible {
        /// The reason's identifier.
        public let rawValue: String

        init(_ rawValue: String) { self.rawValue = rawValue }

        public var description: String { rawValue }

        /// The read has a different length than the entry's `size`.
        public static let sizeMismatch = Reason("sizeMismatch")
        /// The read's SHA-256 is not the entry's `digest`.
        public static let digestMismatch = Reason("digestMismatch")
        /// The `SKILL.md` frontmatter differs from the entry's, or cannot be parsed.
        public static let frontmatterMismatch = Reason("frontmatterMismatch")
        /// The file is not listed in the entry's `resources`, or is outside the skill.
        public static let unlistedFile = Reason("unlistedFile")
        /// The entry is not loadable: its `resources` is neither a manifest nor
        /// `dynamic`, its manifest does not list its `SKILL.md`, or its URI is
        /// not a `SKILL.md`.
        public static let invalidEntry = Reason("invalidEntry")
        /// The entry's `resources` is `dynamic`, which offers no integrity, and
        /// ``Client/SkillLoading/allowsDynamic`` is off.
        public static let dynamicSkill = Reason("dynamicSkill")
        /// The skill exceeds 512 files or 16 MiB.
        public static let tooLarge = Reason("tooLarge")
        /// The read returned no content for the URI.
        public static let unreadable = Reason("unreadable")
    }

    /// Why verification failed.
    public let reason: Reason
    /// The file or skill concerned.
    public let uri: String
    /// What happened.
    public let message: String

    /// Creates the error.
    public init(_ reason: Reason, uri: String, message: String) {
        self.reason = reason
        self.uri = uri
        self.message = message
    }

    public var description: String { message }
}

extension Skill {
    /// A SHA-256 over the entry's files and digests, for binding an approval
    /// to the content approved: it changes when any file does. `nil` when
    /// `resources` is not a manifest.
    public var manifestFingerprint: String? {
        guard case .manifest(let files) = resources else { return nil }
        let lines = files.map { "\($0.uri)\u{0}\($0.digest)\n" }.sorted().joined()
        return SkillResource.digest(of: Data(lines.utf8))
    }
}

/// A skill loaded under an entry: its verified `SKILL.md`, and reads of its
/// other files, each fetched when asked for and verified against the entry.
///
/// Get one from ``Client/loadSkill(_:options:)``. Nothing beyond `SKILL.md`
/// is fetched until ``read(_:)``.
public actor LoadedSkill {
    /// The entry the skill was loaded under.
    public nonisolated let skill: Skill
    /// The text of `SKILL.md`, verified.
    public nonisolated let content: String
    /// The URI of the skill's root directory, which relative paths resolve against.
    public nonisolated let rootURI: String

    private let client: Client
    private let options: Client.SkillLoading
    /// Bytes read so far, for a dynamic skill's budget.
    private var bytesRead: Int

    init(skill: Skill, content: String, rootURI: String, client: Client, options: Client.SkillLoading, bytesRead: Int) {
        self.skill = skill
        self.content = content
        self.rootURI = rootURI
        self.client = client
        self.options = options
        self.bytesRead = bytesRead
    }

    /// The files the entry lists, or `nil` for a dynamic skill.
    public nonisolated var files: [SkillResource]? {
        if case .manifest(let files) = skill.resources { return files }
        return nil
    }

    /// The URI of `path`, relative to the skill's root (`references/FORMS.md`).
    ///
    /// - Throws: ``SkillVerificationError`` with
    ///   ``SkillVerificationError/Reason/unlistedFile`` for a path that leaves
    ///   the skill.
    public nonisolated func uri(of path: String) throws -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard components.popLast() != nil else {
                    throw SkillVerificationError(.unlistedFile, uri: path, message: "\(path) leaves the skill")
                }
            default: components.append(String(component))
            }
        }
        guard !components.isEmpty else {
            throw SkillVerificationError(.unlistedFile, uri: path, message: "\(path) is not a file of the skill")
        }
        return rootURI + "/" + components.map(SkillPackage.percentEncoded).joined(separator: "/")
    }

    /// Reads the file at `path`, relative to the skill's root, and verifies
    /// it against the entry.
    ///
    /// - Throws: ``SkillVerificationError``, for a file the entry does not
    ///   list (without reading it) or content that does not match; or the
    ///   error of the read.
    public func read(_ path: String) async throws -> Data {
        try await read(uri: uri(of: path))
    }

    /// Reads the file at `uri`, which must be one of the skill's, and
    /// verifies it against the entry.
    public func read(uri: String) async throws -> Data {
        switch skill.resources {
        case .manifest(let files):
            guard let file = files.first(where: { $0.uri == uri }) else {
                throw SkillVerificationError(
                    .unlistedFile, uri: uri, message: "\(uri) is not listed in the entry of \(skill.uri)")
            }
            return try await Client.fetchVerified(file, client: client)
        case .dynamic:
            guard uri.hasPrefix(rootURI + "/") else {
                throw SkillVerificationError(.unlistedFile, uri: uri, message: "\(uri) is outside \(rootURI)")
            }
            let data = try await Client.fetch(uri, client: client)
            bytesRead += data.count
            if options.enforcesLimits, bytesRead > Skill.maximumTotalSize {
                throw SkillVerificationError(
                    .tooLarge, uri: skill.uri, message: "\(skill.uri) exceeds \(Skill.maximumTotalSize) bytes")
            }
            return data
        case .unrecognized:
            throw SkillVerificationError(.invalidEntry, uri: skill.uri, message: "\(skill.uri) has no valid resources")
        }
    }

    /// The direct children of the directory at `path` (empty for the root),
    /// from the entry: files as their entries, subdirectories by name.
    public nonisolated func directory(_ path: String = "") throws -> (files: [SkillResource], directories: [String]) {
        guard let files else { return ([], []) }
        let prefix = path.isEmpty ? rootURI + "/" : try uri(of: path) + "/"
        var children: [SkillResource] = []
        var directories = Set<String>()
        for file in files where file.uri.hasPrefix(prefix) {
            let rest = file.uri.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                directories.insert(String(rest[..<slash]).removingPercentEncoding ?? String(rest[..<slash]))
            } else {
                children.append(file)
            }
        }
        return (children, directories.sorted())
    }
}

extension Client {
    /// How ``loadSkill(_:options:)`` treats a skill.
    public struct SkillLoading: Hashable, Sendable {
        /// Load skills whose `resources` is `dynamic`, which have no digests:
        /// their content cannot be verified or bound to an approval.
        public var allowsDynamic: Bool
        /// Also accept frontmatter that matches the entry when read as YAML
        /// 1.1, as from a server that used PyYAML (`yes` for `true`).
        public var acceptsYAML11Frontmatter: Bool
        /// Refuse skills of more than 512 files or 16 MiB, which hosts need
        /// not accept.
        public var enforcesLimits: Bool

        /// Creates the options.
        public init(allowsDynamic: Bool = false, acceptsYAML11Frontmatter: Bool = false, enforcesLimits: Bool = true) {
            self.allowsDynamic = allowsDynamic
            self.acceptsYAML11Frontmatter = acceptsYAML11Frontmatter
            self.enforcesLimits = enforcesLimits
        }
    }

    /// The skills extension settings the server declared, or `nil`.
    public var serverSkills: SkillsSettings? {
        SkillsSettings(serverCapabilities?.extensions)
    }

    private func requireSkills(_ method: String) throws -> SkillsSettings {
        guard let settings = serverSkills else {
            throw MCPError.methodNotFound("\(method): the server does not declare \(ExtensionID.skills)")
        }
        return settings
    }

    /// Lists one page of the server's skills (`skills/list`). The listing may
    /// be empty or partial: a skill that is not listed can still be loaded by
    /// URI.
    ///
    /// - Throws: -32601, without a request, when the server does not declare
    ///   the skills extension.
    public func listSkills(cursor: String? = nil) async throws -> ListSkills.Result {
        _ = try requireSkills(ListSkills.name)
        return try await send(ListSkills.request(.init(cursor: cursor))).value
    }

    /// Lists every skill, following `nextCursor` until the last page. Stops
    /// at a cursor seen before.
    public func listAllSkills() async throws -> [Skill] {
        var skills: [Skill] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await listSkills(cursor: cursor)
            skills += page.skills
            cursor = page.nextCursor.flatMap { $0.isEmpty || !seen.insert($0).inserted ? nil : $0 }
        } while cursor != nil
        return skills
    }

    /// Gets the entry of the skill whose `SKILL.md` is at `uri`
    /// (`skills/get`), listed or not.
    ///
    /// - Throws: -32602 from the server when it serves no such skill.
    public func getSkill(uri: String) async throws -> Skill {
        _ = try requireSkills(GetSkill.name)
        return try await send(GetSkill.request(.init(uri: uri))).value.skill
    }

    /// Lists the direct children of a directory resource
    /// (`resources/directory/read`).
    ///
    /// - Throws: -32601, without a request, when the server does not declare
    ///   `directoryRead`.
    public func readResourceDirectory(uri: String, cursor: String? = nil) async throws
        -> ReadResourceDirectory.Result
    {
        guard try requireSkills(ReadResourceDirectory.name).directoryRead == true else {
            throw MCPError.methodNotFound("\(ReadResourceDirectory.name): the server does not declare directoryRead")
        }
        return try await send(ReadResourceDirectory.request(.init(uri: uri, cursor: cursor))).value
    }

    /// Gets the entry of the skill at `uri` and loads the skill under it.
    public func loadSkill(uri: String, options: SkillLoading = .init()) async throws -> LoadedSkill {
        try await loadSkill(try await getSkill(uri: uri), options: options)
    }

    /// Loads a skill under `skill`, an entry from ``listSkills(cursor:)`` or
    /// ``getSkill(uri:)``.
    ///
    /// Reads the skill's `SKILL.md`, and only that, and verifies it as
    /// SEP-2640 requires: its length against the entry's `size`, its SHA-256
    /// against the `digest`, then its YAML frontmatter, field by field,
    /// against the entry's `frontmatter`. Other files are read with
    /// ``LoadedSkill/read(_:)``, each verified when it is read.
    ///
    /// Loading is the host's skill-loading path: deciding whether the user
    /// approves the skill, and showing where it comes from, is the host's.
    ///
    /// - Throws: ``SkillVerificationError`` when the content is not the
    ///   entry's or the entry cannot be loaded; the error of the read.
    public func loadSkill(_ skill: Skill, options: SkillLoading = .init()) async throws -> LoadedSkill {
        guard let rootURI = skill.rootURI else {
            throw SkillVerificationError(
                .invalidEntry, uri: skill.uri, message: "\(skill.uri) is not the URI of a \(Skill.manifestFileName)")
        }
        let data: Data
        switch skill.resources {
        case .manifest(let files):
            if options.enforcesLimits {
                let total = files.reduce(0) { $0 + max(0, $1.size) }
                guard files.count <= Skill.maximumResources, total <= Skill.maximumTotalSize else {
                    throw SkillVerificationError(
                        .tooLarge, uri: skill.uri,
                        message: "\(skill.uri) has \(files.count) files and \(total) bytes; the limits are \(Skill.maximumResources) and \(Skill.maximumTotalSize)"
                    )
                }
            }
            guard let manifest = files.first(where: { $0.uri == skill.uri }) else {
                throw SkillVerificationError(
                    .invalidEntry, uri: skill.uri, message: "The entry of \(skill.uri) does not list it")
            }
            data = try await Self.fetchVerified(manifest, client: self)
        case .dynamic:
            guard options.allowsDynamic else {
                throw SkillVerificationError(
                    .dynamicSkill, uri: skill.uri, message: "\(skill.uri) is dynamic: its content cannot be verified")
            }
            data = try await Self.fetch(skill.uri, client: self)
            if options.enforcesLimits, data.count > Skill.maximumTotalSize {
                throw SkillVerificationError(
                    .tooLarge, uri: skill.uri, message: "\(skill.uri) exceeds \(Skill.maximumTotalSize) bytes")
            }
        case .unrecognized:
            throw SkillVerificationError(.invalidEntry, uri: skill.uri, message: "\(skill.uri) has no valid resources")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw SkillVerificationError(.frontmatterMismatch, uri: skill.uri, message: "\(skill.uri) is not UTF-8")
        }
        try Self.verifyFrontmatter(of: content, against: skill, options: options)
        return LoadedSkill(
            skill: skill, content: content, rootURI: rootURI, client: self, options: options, bytesRead: data.count)
    }

    private static func verifyFrontmatter(of document: String, against skill: Skill, options: SkillLoading) throws {
        let core: [String: Value]
        do {
            core = try SkillFrontmatter.parse(document: document)
        } catch {
            if options.acceptsYAML11Frontmatter,
                let legacy = try? SkillFrontmatter.parse(document: document, schema: .yaml11),
                SkillFrontmatter.matches(legacy, skill.frontmatter)
            {
                return
            }
            throw SkillVerificationError(.frontmatterMismatch, uri: skill.uri, message: "\(skill.uri): \(error)")
        }
        if SkillFrontmatter.matches(core, skill.frontmatter) { return }
        if options.acceptsYAML11Frontmatter,
            let legacy = try? SkillFrontmatter.parse(document: document, schema: .yaml11),
            SkillFrontmatter.matches(legacy, skill.frontmatter)
        {
            return
        }
        let fields = Set(core.keys).union(skill.frontmatter.keys).sorted().filter { key in
            !SkillFrontmatter.equivalent(core[key] ?? .null, skill.frontmatter[key] ?? .null)
                || (core[key] == nil) != (skill.frontmatter[key] == nil)
        }
        throw SkillVerificationError(
            .frontmatterMismatch, uri: skill.uri,
            message: "The frontmatter of \(skill.uri) differs from its entry: \(fields.joined(separator: ", "))")
    }

    /// The bytes of `file`, after its size, then its digest, match the entry.
    static func fetchVerified(_ file: SkillResource, client: Client) async throws -> Data {
        let data = try await fetch(file.uri, client: client)
        guard data.count == file.size else {
            throw SkillVerificationError(
                .sizeMismatch, uri: file.uri, message: "\(file.uri) is \(data.count) bytes; the entry says \(file.size)")
        }
        guard SkillResource.digest(of: data) == file.digest else {
            throw SkillVerificationError(
                .digestMismatch, uri: file.uri, message: "\(file.uri) does not match the digest of its entry")
        }
        return data
    }

    /// The bytes of the resource at `uri`: its text as UTF-8, or its blob.
    static func fetch(_ uri: String, client: Client) async throws -> Data {
        let result = try await client.readResource(uri: uri)
        guard let content = result.contents.first(where: { $0.uri == uri }) ?? result.contents.first else {
            throw SkillVerificationError(.unreadable, uri: uri, message: "\(uri) returned no content")
        }
        if let text = content.text { return Data(text.utf8) }
        if let blob = content.blob, let data = Data(base64Encoded: blob) { return data }
        throw SkillVerificationError(.unreadable, uri: uri, message: "\(uri) returned no text or blob")
    }
}
