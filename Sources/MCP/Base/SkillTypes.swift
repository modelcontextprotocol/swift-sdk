import Crypto
import Foundation

// The skills extension (SEP-2640): skills served as resources, enumerated by
// `skills/list`, retrieved by `skills/get`, and navigated by
// `resources/directory/read`.

extension ExtensionID {
    /// The skills extension (SEP-2640).
    public static let skills = "io.modelcontextprotocol/skills"
}

/// The settings of the skills extension in a server's
/// `capabilities.extensions`.
public struct SkillsSettings: Hashable, Codable, Sendable {
    /// Whether the server implements `resources/directory/read`.
    public var directoryRead: Bool?

    /// Creates the settings.
    public init(directoryRead: Bool? = nil) {
        self.directoryRead = directoryRead
    }

    /// The settings `capabilities` declares, or `nil` when it does not
    /// declare the extension with an object.
    public init?(_ extensions: [String: Value]?) {
        guard let value = extensions?[ExtensionID.skills]?.objectValue else { return nil }
        directoryRead = value["directoryRead"]?.boolValue
    }

    /// The settings as the value of `extensions[ExtensionID.skills]`.
    var value: Value {
        directoryRead.map { ["directoryRead": .bool($0)] } ?? [:]
    }
}

/// A skill entry: a skill's frontmatter and its files, as `skills/list` and
/// `skills/get` return them.
public struct Skill: Hashable, Codable, Sendable {
    /// The URI of the skill's `SKILL.md`, such as
    /// `skill://pdf-processing/SKILL.md`.
    public var uri: String
    /// The YAML frontmatter of the `SKILL.md`, rendered as JSON. It has at
    /// least `name` and `description`.
    public var frontmatter: [String: Value]
    /// The skill's files.
    public var resources: Resources
    /// Metadata of the entry.
    public var _meta: Metadata?

    /// Creates a skill entry.
    public init(
        uri: String, frontmatter: [String: Value], resources: Resources, _meta: Metadata? = nil
    ) {
        self.uri = uri
        self.frontmatter = frontmatter
        self.resources = resources
        self._meta = _meta
    }

    /// The skill's name, from its frontmatter.
    public var name: String? { frontmatter["name"]?.stringValue }
    /// The skill's description, from its frontmatter.
    public var description: String? { frontmatter["description"]?.stringValue }

    /// The URI of the skill's root directory: ``uri`` without `/SKILL.md`.
    public var rootURI: String? {
        uri.hasSuffix("/" + Skill.manifestFileName) ? String(uri.dropLast(Skill.manifestFileName.count + 1)) : nil
    }

    /// `SKILL.md`, the file every skill has at its root.
    public static let manifestFileName = "SKILL.md"

    /// The most files a host must accept in one skill, `SKILL.md` included.
    public static let maximumResources = 512
    /// The most bytes a host must accept in one skill: 16 MiB.
    public static let maximumTotalSize = 16 * 1024 * 1024

    /// The files of a skill.
    ///
    /// Frozen: no case is added in 1.x.
    public enum Resources: Hashable, Sendable {
        /// Every file of the skill, `SKILL.md` included, each once, with its
        /// digest and size.
        case manifest([SkillResource])
        /// The skill's content is generated; it has no digests to verify.
        case dynamic
        /// A value that is neither: the entry is invalid and a host does not
        /// load it. Kept so that one bad entry does not fail a listing.
        case unrecognized(Value)
    }

    private enum CodingKeys: String, CodingKey {
        case uri, frontmatter, resources, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        // As written: a `data:` URL in the frontmatter stays a string.
        frontmatter = try container.decode([String: Value.Preserved].self, forKey: .frontmatter)
            .mapValues(\.value)
        if let manifest = try? container.decode([SkillResource].self, forKey: .resources) {
            resources = .manifest(manifest)
        } else if let value = try container.decodeIfPresent(Value.Preserved.self, forKey: .resources)?.value {
            resources = value == "dynamic" ? .dynamic : .unrecognized(value)
        } else {
            resources = .unrecognized(.null)
        }
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(frontmatter, forKey: .frontmatter)
        switch resources {
        case .manifest(let files): try container.encode(files, forKey: .resources)
        case .dynamic: try container.encode("dynamic", forKey: .resources)
        case .unrecognized(.null): break
        case .unrecognized(let value): try container.encode(value, forKey: .resources)
        }
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

/// A file of a skill: its URI, the SHA-256 digest and the length of its
/// bytes.
public struct SkillResource: Hashable, Codable, Sendable {
    /// The file's resource URI.
    public var uri: String
    /// `sha256:` and 64 lowercase hexadecimal digits.
    public var digest: String
    /// The length of the file's bytes.
    public var size: Int

    /// Creates a file entry.
    public init(uri: String, digest: String, size: Int) {
        self.uri = uri
        self.digest = digest
        self.size = size
    }

    /// The entry of `data`, a file at `uri`.
    public init(uri: String, data: Data) {
        self.init(uri: uri, digest: Self.digest(of: data), size: data.count)
    }

    /// The digest of `data`: `sha256:` and its SHA-256 in lowercase hexadecimal.
    public static func digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Methods

/// Lists the skills a server serves (`skills/list`). The listing may be
/// empty or partial: skills can be served without being listed.
public enum ListSkills: Method {
    public static let name = "skills/list"

    /// The parameters of `skills/list`.
    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        /// The cursor from the `nextCursor` of a previous result, or `nil` for the first page.
        public var cursor: String?

        /// Creates the parameters of a request for the first page.
        public init() {}

        /// Creates the parameters of a request for the page at `cursor`.
        public init(cursor: String?) {
            self.cursor = cursor
        }
    }

    /// The result of `skills/list`.
    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        /// The skills on this page. A skill's entry is never split across pages.
        public var skills: [Skill]
        /// The cursor of the next page, or `nil` on the last page.
        public var nextCursor: String?
        /// Metadata of the result.
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        /// Creates the result of a `skills/list` request.
        public init(
            skills: [Skill], nextCursor: String? = nil, _meta: Metadata? = nil, ttlMs: Int? = nil,
            cacheScope: CacheScope? = nil
        ) {
            self.skills = skills
            self.nextCursor = nextCursor
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey {
            case skills, nextCursor, _meta, ttlMs, cacheScope
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            skills = try container.decode([Skill].self, forKey: .skills)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(skills, forKey: .skills)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }
    }
}

/// Returns the entry of one skill, listed or not (`skills/get`). A URI that
/// is not a skill the server serves is -32602.
public enum GetSkill: Method {
    public static let name = "skills/get"

    /// The parameters of `skills/get`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The URI of the skill's `SKILL.md`.
        public var uri: String

        /// Creates the parameters of a `skills/get` request.
        public init(uri: String) {
            self.uri = uri
        }
    }

    /// The result of `skills/get`.
    public struct Result: Hashable, Codable, Sendable, CacheableResult {
        /// The skill's entry.
        public var skill: Skill
        /// Metadata of the result.
        public var _meta: Metadata?
        /// How long the result may be reused, in milliseconds (SEP-2549).
        public var ttlMs: Int?
        /// Who may reuse the result (SEP-2549).
        public var cacheScope: CacheScope?

        /// Creates the result of a `skills/get` request.
        public init(skill: Skill, _meta: Metadata? = nil, ttlMs: Int? = nil, cacheScope: CacheScope? = nil) {
            self.skill = skill
            self._meta = _meta
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
        }

        private enum CodingKeys: String, CodingKey {
            case skill, _meta, ttlMs, cacheScope
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            skill = try container.decode(Skill.self, forKey: .skill)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            ttlMs = container.decodeTTL(forKey: .ttlMs)
            cacheScope = container.decodeCacheScope(forKey: .cacheScope)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(skill, forKey: .skill)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
            try container.encodeIfPresent(cacheScope, forKey: .cacheScope)
        }
    }
}

/// Lists the direct children of a directory resource
/// (`resources/directory/read`), for a server whose skills extension
/// declares `directoryRead`. A URI that is not a directory is -32602.
public enum ReadResourceDirectory: Method {
    public static let name = "resources/directory/read"

    /// The MIME type of a directory resource.
    public static let directoryMimeType = "inode/directory"

    /// The parameters of `resources/directory/read`.
    public struct Parameters: Hashable, Codable, Sendable {
        /// The directory's URI, without a trailing slash.
        public var uri: String
        /// The cursor from the `nextCursor` of a previous result, or `nil` for the first page.
        public var cursor: String?

        /// Creates the parameters of a `resources/directory/read` request.
        public init(uri: String, cursor: String? = nil) {
            self.uri = uri
            self.cursor = cursor
        }
    }

    /// The result of `resources/directory/read`.
    public struct Result: Hashable, Codable, Sendable {
        /// The directory's children on this page: files, and subdirectories
        /// with the MIME type ``ReadResourceDirectory/directoryMimeType``.
        public var resources: [Resource]
        /// The cursor of the next page, or `nil` on the last page.
        public var nextCursor: String?
        /// Metadata of the result.
        public var _meta: Metadata?

        /// Creates the result of a `resources/directory/read` request.
        public init(resources: [Resource], nextCursor: String? = nil, _meta: Metadata? = nil) {
            self.resources = resources
            self.nextCursor = nextCursor
            self._meta = _meta
        }
    }
}
