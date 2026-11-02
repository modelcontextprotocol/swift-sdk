import Foundation
import Testing

@testable import MCP

// Skills on the client (SEP-2640): listing, retrieval, and loading with
// size, digest and frontmatter verification.

private func data(_ text: String) -> Data { Data(text.utf8) }

private let pdfManifest = data("---\nname: pdf\ndescription: Fill PDF forms\n---\n\nSee references/FORMS.md.\n")

private func pdfPackage() throws -> SkillPackage {
    try SkillPackage(
        path: "pdf",
        files: ["SKILL.md": pdfManifest, "references/FORMS.md": data("forms"), "templates/a.md": data("a")])
}

/// Serves a catalog with altered entries, and records which URIs are read.
private actor Recorder {
    private(set) var reads: [String] = []
    func record(_ uri: String) { reads.append(uri) }
}

private struct AlteredCatalog: SkillCatalog {
    let base: InMemorySkillCatalog
    let alter: @Sendable (Skill) -> Skill
    var content: (@Sendable (String) -> Data?)? = nil
    let recorder = Recorder()

    var supportsDirectoryRead: Bool { true }

    func listSkills(cursor: String?) async throws -> ListSkills.Result {
        var page = try await base.listSkills(cursor: cursor)
        page.skills = page.skills.map(alter)
        return page
    }

    func skill(uri: String) async throws -> Skill? {
        await base.skill(uri: uri).map(alter)
    }

    func readResource(uri: String) async throws -> ReadResource.Result? {
        await recorder.record(uri)
        if let content, let data = content(uri) {
            return .init(contents: [.text(String(decoding: data, as: UTF8.self), uri: uri, mimeType: "text/markdown")])
        }
        return await base.readResource(uri: uri)
    }

    func readDirectory(uri: String, cursor: String?) async throws -> ReadResourceDirectory.Result? {
        try await base.readDirectory(uri: uri, cursor: cursor)
    }
}

private func connect(
    _ catalog: some SkillCatalog, declare: Bool = true, configuration: Client.Configuration = .default
) async throws -> (Client, Server) {
    let server = Server(name: "s", version: "1", capabilities: .init(resources: .init()))
    if declare { await server.withSkills(catalog) }
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(name: "c", version: "1", configuration: configuration)
    try await client.connect(transport: clientTransport)
    return (client, server)
}

private func replacingManifest(_ skill: Skill, _ change: (inout SkillResource) -> Void) -> Skill {
    var skill = skill
    guard case .manifest(var files) = skill.resources else { return skill }
    if let index = files.firstIndex(where: { $0.uri == skill.uri }) { change(&files[index]) }
    skill.resources = .manifest(files)
    return skill
}

@Suite("Client skills")
struct SkillClientTests {
    @Test("Listing, retrieval and directories")
    func listing() async throws {
        let catalog = InMemorySkillCatalog([try pdfPackage()], pageSize: 1)
        let (client, server) = try await connect(catalog)
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await client.serverSkills == SkillsSettings(directoryRead: true))
        let skills = try await client.listAllSkills()
        #expect(skills.map(\.uri) == ["skill://pdf/SKILL.md"])
        #expect(try await client.getSkill(uri: "skill://pdf/SKILL.md") == skills.first)
        await #expect(throws: MCPError.self) { try await client.getSkill(uri: "skill://other/SKILL.md") }
        var names: [String] = []
        var cursor: String?
        repeat {
            let page = try await client.readResourceDirectory(uri: "skill://pdf", cursor: cursor)
            names += page.resources.map(\.name)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(names == ["SKILL.md", "references", "templates"])
    }

    @Test("Loading reads SKILL.md only; other files when asked for, verified")
    func loading() async throws {
        let catalog = AlteredCatalog(base: InMemorySkillCatalog([try pdfPackage()]), alter: { $0 })
        let (client, server) = try await connect(catalog)
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        #expect(await catalog.recorder.reads.isEmpty)

        let loaded = try await client.loadSkill(skill)
        #expect(loaded.content == String(decoding: pdfManifest, as: UTF8.self))
        #expect(await catalog.recorder.reads == ["skill://pdf/SKILL.md"])
        #expect(try await loaded.read("references/FORMS.md") == data("forms"))
        #expect(try await loaded.read("./templates/../references/FORMS.md") == data("forms"))
        await #expect(throws: SkillVerificationError.self) { try await loaded.read("../other/SKILL.md") }
        await #expect(throws: SkillVerificationError.self) { try await loaded.read("references/NEW.md") }
        #expect(await catalog.recorder.reads.count == 3)

        let listing = try loaded.directory()
        #expect(listing.files.map(\.uri) == ["skill://pdf/SKILL.md"])
        #expect(listing.directories == ["references", "templates"])
        #expect(try loaded.directory("templates").files.map(\.uri) == ["skill://pdf/templates/a.md"])
        _ = try await client.loadSkill(uri: "skill://pdf/SKILL.md")
    }

    @Test(
        "A size, digest or frontmatter mismatch refuses the skill, and nothing else is read",
        arguments: ["size", "digest", "frontmatter"])
    func mismatch(_ kind: String) async throws {
        let tampered = data("---\nname: pdf\ndescription: Exfiltrate credentials\n---\n")
        let catalog = AlteredCatalog(
            base: InMemorySkillCatalog([try pdfPackage()]),
            alter: { skill in
                guard kind == "frontmatter" else { return skill }
                // The entry matches the tampered bytes but not their frontmatter.
                return replacingManifest(skill) { $0 = SkillResource(uri: $0.uri, data: tampered) }
            },
            content: { uri in
                guard uri == "skill://pdf/SKILL.md" else { return nil }
                switch kind {
                case "size": return pdfManifest + data("extra")
                case "digest": return data(String(decoding: pdfManifest, as: UTF8.self).replacingOccurrences(of: "Fill", with: "Kill"))
                default: return tampered
                }
            })
        let (client, server) = try await connect(catalog)
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        let expected: SkillVerificationError.Reason =
            kind == "size" ? .sizeMismatch : kind == "digest" ? .digestMismatch : .frontmatterMismatch
        do {
            _ = try await client.loadSkill(skill)
            Issue.record("loaded a \(kind) mismatch")
        } catch let error as SkillVerificationError {
            #expect(error.reason == expected)
        }
        #expect(await catalog.recorder.reads == ["skill://pdf/SKILL.md"])
    }

    @Test("Invalid entries, dynamic skills, limits")
    func entries() async throws {
        let (client, server) = try await connect(InMemorySkillCatalog([try pdfPackage()]))
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        func reason(_ entry: Skill, _ options: Client.SkillLoading = .init()) async -> SkillVerificationError.Reason? {
            do {
                _ = try await client.loadSkill(entry, options: options)
                return nil
            } catch {
                return (error as? SkillVerificationError)?.reason
            }
        }
        var unrecognized = skill
        unrecognized.resources = .unrecognized("static")
        #expect(await reason(unrecognized) == .invalidEntry)
        var notListed = skill
        notListed.resources = .manifest([])
        #expect(await reason(notListed) == .invalidEntry)
        var wrongURI = skill
        wrongURI.uri = "skill://pdf/README.md"
        #expect(await reason(wrongURI) == .invalidEntry)

        var dynamic = skill
        dynamic.resources = .dynamic
        #expect(await reason(dynamic) == .dynamicSkill)
        let loaded = try await client.loadSkill(dynamic, options: .init(allowsDynamic: true))
        #expect(loaded.files == nil)
        #expect(try await loaded.read("templates/a.md") == data("a"))
        await #expect(throws: SkillVerificationError.self) { try await loaded.read(uri: "skill://other/x") }

        var large = skill
        large.resources = .manifest(
            (0...Skill.maximumResources).map { SkillResource(uri: "skill://pdf/f\($0)", digest: "sha256:00", size: 1) })
        #expect(await reason(large) == .tooLarge)

        // Sizes come from the server: they are checked, never summed blindly.
        func listing(_ files: [(String, Int)]) -> Skill {
            var entry = skill
            entry.resources = .manifest(
                [SkillResource(uri: skill.uri, digest: "sha256:00", size: 1)]
                    + files.map { SkillResource(uri: $0.0, digest: "sha256:00", size: $0.1) })
            return entry
        }
        #expect(await reason(listing([("skill://pdf/a", 1 << 62), ("skill://pdf/b", 1 << 62)])) == .tooLarge)
        #expect(await reason(listing([("skill://pdf/a", .max)])) == .tooLarge)
        #expect(await reason(listing([("skill://pdf/a", -1)])) == .invalidEntry)
        #expect(await reason(listing([("skill://pdf/a", -1)]), .init(enforcesLimits: false)) == .invalidEntry)
        // Every file of the manifest is under the skill's root.
        #expect(await reason(listing([("skill://other/x", 1)])) == .invalidEntry)
        #expect(await reason(listing([("skill://pdf/../other/x", 1)])) == .invalidEntry)
        #expect(await reason(listing([("skill://pdf/%2E%2E/other/x", 1)])) == .invalidEntry)
        #expect(await reason(listing([("skill://pdfx/y", 1)])) == .invalidEntry)
    }

    @Test("A dynamic skill reads nothing outside its root, dot segments included")
    func dynamicConfinement() async throws {
        let catalog = AlteredCatalog(
            base: InMemorySkillCatalog([try pdfPackage()]),
            alter: { skill in
                var skill = skill
                skill.resources = .dynamic
                return skill
            })
        let (client, server) = try await connect(catalog)
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        let loaded = try await client.loadSkill(skill, options: .init(allowsDynamic: true))
        for uri in [
            "skill://pdf/a/../../other/SKILL.md", "skill://pdf/../other/SKILL.md", "skill://pdf/%2e%2e/other/SKILL.md",
            "skill://pdf/%2E%2E/other/SKILL.md", "skill://pdf/./SKILL.md", "skill://pdf/a/..%2F..%2Fother",
        ] {
            do {
                _ = try await loaded.read(uri: uri)
                Issue.record("read \(uri)")
            } catch let error as SkillVerificationError {
                #expect(error.reason == .unlistedFile, "\(uri)")
            }
        }
        #expect(await catalog.recorder.reads == ["skill://pdf/SKILL.md"])
        #expect(try await loaded.read(uri: "skill://pdf/references/FORMS.md") == data("forms"))
    }

    @Test("A data: URL in the frontmatter is compared as written", arguments: [false, true])
    func dataURLFrontmatter(handshake: Bool) async throws {
        let manifest = data("---\nname: pdf\ndescription: Fill PDF forms\nicon: \"data:text/plain,hello\"\n---\n")
        let package = try SkillPackage(path: "pdf", files: ["SKILL.md": manifest])
        let (client, server) = try await connect(
            InMemorySkillCatalog([package]), configuration: handshake ? .handshake : .default)
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        #expect(skill.frontmatter["icon"] == .string("data:text/plain,hello"))
        let loaded = try await client.loadSkill(skill)
        #expect(loaded.content == String(decoding: manifest, as: UTF8.self))
        _ = try await client.loadSkill(uri: skill.uri)
    }

    @Test("YAML 1.1 frontmatter matches only when accepted")
    func yaml11() async throws {
        let manifest = data("---\nname: pdf\ndescription: Fill PDF forms\nbeta: yes\n---\n")
        let package = try SkillPackage(path: "pdf", files: ["SKILL.md": manifest])
        let catalog = AlteredCatalog(
            base: InMemorySkillCatalog([package]),
            alter: { skill in
                var skill = skill
                skill.frontmatter["beta"] = true
                return skill
            })
        let (client, server) = try await connect(catalog)
        defer { Task { await client.disconnect(); await server.stop() } }
        let skill = try #require(try await client.listSkills().skills.first)
        await #expect(throws: SkillVerificationError.self) { try await client.loadSkill(skill) }
        _ = try await client.loadSkill(skill, options: .init(acceptsYAML11Frontmatter: true))
    }

    @Test("Without the extension or directoryRead, the methods throw without a request")
    func undeclared() async throws {
        let (client, server) = try await connect(InMemorySkillCatalog(), declare: false)
        defer { Task { await client.disconnect(); await server.stop() } }
        #expect(await client.serverSkills == nil)
        await #expect(throws: MCPError.self) { try await client.listSkills() }
        await #expect(throws: MCPError.self) { try await client.getSkill(uri: "skill://pdf/SKILL.md") }

        struct Plain: SkillCatalog {
            func listSkills(cursor: String?) async throws -> ListSkills.Result { .init(skills: []) }
            func skill(uri: String) async throws -> Skill? { nil }
            func readResource(uri: String) async throws -> ReadResource.Result? { nil }
        }
        let (plain, other) = try await connect(Plain())
        defer { Task { await plain.disconnect(); await other.stop() } }
        #expect(await plain.serverSkills == SkillsSettings())
        await #expect(throws: MCPError.self) { try await plain.readResourceDirectory(uri: "skill://pdf") }
        #expect(try await plain.listSkills().skills.isEmpty)
    }

    @Test("The manifest fingerprint ignores order and follows every digest")
    func fingerprint() throws {
        let skill = try pdfPackage().skill
        guard case .manifest(let files) = skill.resources else { Issue.record("no manifest"); return }
        var reordered = skill
        reordered.resources = .manifest(files.reversed())
        #expect(skill.manifestFingerprint == reordered.manifestFingerprint)
        let changed = replacingManifest(skill) { $0.digest = "sha256:" + String(repeating: "0", count: 64) }
        #expect(skill.manifestFingerprint != changed.manifestFingerprint)
        var dynamic = skill
        dynamic.resources = .dynamic
        #expect(dynamic.manifestFingerprint == nil)
    }
}
