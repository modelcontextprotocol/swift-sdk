import Foundation
import Testing

@testable import MCP

// Skills on the server (SEP-2640): packages, the in-memory catalog, and the
// wire at 2026-07-28 and through `initialize`.

private func data(_ text: String) -> Data { Data(text.utf8) }

private func manifest(_ name: String, _ description: String = "Does things", extra: String = "") -> Data {
    data("---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n# \(name)\n")
}

private func package(_ path: String, _ files: [String: Data] = [:]) throws -> SkillPackage {
    let name = String(path.split(separator: "/").last!)
    return try SkillPackage(path: path, files: files.merging(["SKILL.md": manifest(name)]) { file, _ in file })
}

private func statelessMessage(id: Int, method: String, params: [String: Value] = [:]) -> String {
    var params = params
    params["_meta"] = [
        MetaKey.protocolVersion: .string(Version.v2026_07_28), MetaKey.clientCapabilities: [:],
    ]
    let value: Value = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
    return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

@Suite("Skill packages")
struct SkillPackageTests {
    @Test("The entry: SKILL.md first, digests and sizes of the bytes, verbatim frontmatter")
    func entry() throws {
        let skill = try SkillPackage(
            path: "acme/billing/refunds",
            files: [
                "SKILL.md": manifest("refunds", extra: "metadata:\n  version: \"2.1\"\n"),
                "examples/email.md": data("hi"),
                "a file.txt": data(""),
            ]
        ).skill
        #expect(skill.uri == "skill://acme/billing/refunds/SKILL.md")
        #expect(skill.rootURI == "skill://acme/billing/refunds")
        #expect(skill.frontmatter == ["name": "refunds", "description": "Does things", "metadata": ["version": "2.1"]])
        guard case .manifest(let files) = skill.resources else { Issue.record("no manifest"); return }
        #expect(
            files.map(\.uri) == [
                "skill://acme/billing/refunds/SKILL.md", "skill://acme/billing/refunds/a%20file.txt",
                "skill://acme/billing/refunds/examples/email.md",
            ])
        #expect(files[2].digest == "sha256:8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
        #expect(files[2].size == 2)
        #expect(files[1].digest == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(skill.manifestResource.name == "refunds")
        #expect(skill.manifestResource.mimeType == "text/markdown")
    }

    @Test(
        "Invalid skills are refused",
        arguments: [
            ("pdf", ["README.md": data("x")]),
            ("pdf", ["SKILL.md": data("# no frontmatter")]),
            ("pdf", ["SKILL.md": data("---\nname: pdf\n---\n")]),
            ("pdf", ["SKILL.md": data("---\nname: other\ndescription: d\n---\n")]),
            ("Pdf", ["SKILL.md": manifest("Pdf")]),
            ("a--b", ["SKILL.md": manifest("a--b")]),
            ("-a", ["SKILL.md": manifest("-a")]),
            ("x/../pdf", ["SKILL.md": manifest("pdf")]),
            ("pdf", ["SKILL.md": manifest("pdf"), "../escape": data("x")]),
            ("pdf", ["SKILL.md": manifest("pdf"), "a//b": data("x")]),
            ("pdf", ["SKILL.md": manifest("pdf"), "a\\b": data("x")]),
            ("pdf", ["SKILL.md": Data([0xFF, 0xFE])]),
            ("pdf", ["SKILL.md": data("---\nname: pdf\ndescription: d\nx: .inf\n---\n")]),
            ("pdf", ["SKILL.md": manifest("pdf"), "a": data("x"), "a/b": data("y")]),
            ("pdf", ["SKILL.md": manifest("pdf"), "SKILL.md/x": data("x")]),
        ] as [(String, [String: Data])])
    func invalid(_ path: String, _ files: [String: Data]) {
        #expect(throws: SkillPackage.ValidationError.self) { try SkillPackage(path: path, files: files) }
    }

    @Test("Limits: 512 files and 16 MiB, unless not enforced; a valid scheme")
    func limits() throws {
        var files = (0..<512).reduce(into: [String: Data]()) { $0["f\($1).txt"] = Data() }
        files["SKILL.md"] = manifest("big")
        #expect(throws: SkillPackage.ValidationError.self) { try SkillPackage(path: "big", files: files) }
        _ = try SkillPackage(path: "big", files: files, enforcesLimits: false)
        let large = ["SKILL.md": manifest("large"), "blob": Data(count: Skill.maximumTotalSize)]
        #expect(throws: SkillPackage.ValidationError.self) { try SkillPackage(path: "large", files: large) }
        #expect(throws: SkillPackage.ValidationError.self) {
            try SkillPackage(path: "pdf", files: ["SKILL.md": manifest("pdf")], scheme: "Not A Scheme")
        }
        let github = try SkillPackage(path: "owner/repo/pdf", files: ["SKILL.md": manifest("pdf")], scheme: "github")
        #expect(github.skill.uri == "github://owner/repo/pdf/SKILL.md")
    }

    @Test("A directory over the limits is refused before its files are read")
    func directoryLimits() throws {
        let skill = FileManager.default.temporaryDirectory.appendingPathComponent("large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skill) }
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try manifest("large").write(to: skill.appendingPathComponent("SKILL.md"))
        // A sparse file over 16 MiB that cannot be read: reading it would
        // throw a file error instead of the limit.
        let blob = skill.appendingPathComponent("blob")
        #expect(FileManager.default.createFile(atPath: blob.path, contents: nil))
        let handle = try FileHandle(forWritingTo: blob)
        try handle.truncate(atOffset: UInt64(Skill.maximumTotalSize) + 1)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blob.path)

        #expect(throws: SkillPackage.ValidationError.self) { try SkillPackage(path: "large", directory: skill) }
    }

    @Test("A directory: files below it, without dotfiles or links that leave it")
    func directory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let skill = root.appendingPathComponent("pdf")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("references"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try manifest("pdf").write(to: skill.appendingPathComponent("SKILL.md"))
        try data("forms").write(to: skill.appendingPathComponent("references/FORMS.md"))
        try data("x").write(to: skill.appendingPathComponent(".DS_Store"))
        try data("x").write(to: skill.appendingPathComponent(".git/HEAD"))
        try data("secret").write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("leak.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("leakdir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("forms.md"),
            withDestinationURL: skill.appendingPathComponent("references/FORMS.md"))

        let package = try SkillPackage(path: "pdf", directory: skill)
        #expect(package.files.keys.sorted() == ["SKILL.md", "forms.md", "references/FORMS.md"])
    }

    @Test("A directory: links to dotfiles inside it are skipped as the dotfiles are")
    func hiddenLinks() throws {
        // A hidden directory above the skill hides nothing in it.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(".skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("pdf")
        let manager = FileManager.default
        try manager.createDirectory(at: skill.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: skill.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try manifest("pdf").write(to: skill.appendingPathComponent("SKILL.md"))
        try data("TOKEN=x").write(to: skill.appendingPathComponent(".env"))
        try data("[core]").write(to: skill.appendingPathComponent(".git/config"))
        try data("guide").write(to: skill.appendingPathComponent("docs/guide.md"))
        for (name, target) in [
            ("env", ".env"), ("cfg", ".git/config"), ("git", ".git"), ("docs/env", "../.env"),
            ("guide.md", "docs/guide.md"),
        ] {
            try manager.createSymbolicLink(atPath: skill.appendingPathComponent(name).path, withDestinationPath: target)
        }

        let package = try SkillPackage(path: "pdf", directory: skill)
        #expect(package.files.keys.sorted() == ["SKILL.md", "docs/guide.md", "guide.md"])
        guard case .manifest(let files) = package.skill.resources else { Issue.record("no manifest"); return }
        #expect(files.map(\.uri) == ["skill://pdf/SKILL.md", "skill://pdf/docs/guide.md", "skill://pdf/guide.md"])
        for uri in ["skill://pdf/env", "skill://pdf/cfg", "skill://pdf/git/config", "skill://pdf/docs/env"] {
            #expect(package.file(at: uri)?.data == nil, "\(uri)")
        }
    }

    @Test("A file is found by its URI segment by segment; an encoded / names no file")
    func fileAtURI() throws {
        let skill = try package("pdf", ["references/FORMS.md": data("forms"), "a b/c%.md": data("c")])
        #expect(skill.file(at: "skill://pdf/references/FORMS.md")?.data == data("forms"))
        #expect(skill.file(at: "skill://pdf/%72eferences/FORMS.md")?.data == data("forms"))
        #expect(skill.file(at: "skill://pdf/a%20b/c%25.md")?.data == data("c"))
        for uri in [
            "skill://pdf/references%2FFORMS.md", "skill://pdf/references%2fFORMS.md", "skill://pdf/references//FORMS.md",
            "skill://pdf//references/FORMS.md", "skill://pdf/references/FORMS.md/", "skill://pdf/a%20b%2Fc%25.md",
            "skill://pdf/references/%E0.md",
        ] {
            #expect(skill.file(at: uri)?.data == nil, "\(uri)")
        }
    }

    @Test("Contents: UTF-8 text as text, other bytes and binary types as blobs")
    func contents() {
        let text = SkillPackage.contents(data("é"), uri: "u", mimeType: "text/markdown")
        #expect(text.text == "é")
        let invalid = SkillPackage.contents(Data([0xC3]), uri: "u", mimeType: "text/plain")
        #expect(invalid.blob == "ww==")
        let image = SkillPackage.contents(data("png"), uri: "u", mimeType: "image/png")
        #expect(image.blob != nil)
        #expect(SkillPackage.mimeType(of: "scripts/extract.py") == "text/x-python")
        #expect(SkillPackage.mimeType(of: "templates/a.MD") == "text/markdown")
        #expect(SkillPackage.mimeType(of: "LICENSE") == "text/plain")
        #expect(SkillPackage.mimeType(of: "archive.bin") == "application/octet-stream")
    }
}

@Suite("In-memory skill catalog")
struct InMemorySkillCatalogTests {
    @Test("Pages of the listing, an invalid cursor, replacing the skills")
    func listing() async throws {
        let catalog = InMemorySkillCatalog(try ["a", "b", "c"].map { try package($0) }, pageSize: 2)
        let first = try await catalog.listSkills(cursor: nil)
        #expect(first.skills.map(\.name) == ["a", "b"])
        let second = try await catalog.listSkills(cursor: try #require(first.nextCursor))
        #expect(second.skills.map(\.name) == ["c"])
        #expect(second.nextCursor == nil)
        await #expect(throws: MCPError.invalidParams("Invalid cursor")) { try await catalog.listSkills(cursor: "x") }

        await catalog.setSkills([try package("a"), try package("d"), try package("a", ["new.md": data("n")])])
        #expect(try await catalog.listSkills(cursor: nil).skills.map(\.name) == ["d", "a"])
        #expect(await catalog.readResource(uri: "skill://a/new.md") != nil)
    }

    @Test("A cursor past the end is -32602; at the end, an empty page")
    func cursorBounds() async throws {
        let catalog = InMemorySkillCatalog(try ["a", "b", "c"].map { try package($0) }, pageSize: 2)
        for cursor in ["4", "1000", String(Int.max)] {
            await #expect(throws: MCPError.invalidParams("Invalid cursor"), "\(cursor)") {
                try await catalog.listSkills(cursor: cursor)
            }
            await #expect(throws: MCPError.invalidParams("Invalid cursor"), "\(cursor)") {
                try await catalog.readDirectory(uri: "skill://a", cursor: cursor)
            }
        }
        let end = try await catalog.listSkills(cursor: "3")
        #expect(end.skills.isEmpty)
        #expect(end.nextCursor == nil)
        let last = try await catalog.listSkills(cursor: "2")
        #expect(last.skills.map(\.name) == ["c"])
        #expect(try await catalog.readDirectory(uri: "skill://a", cursor: "1")?.resources.isEmpty == true)

        let unbounded = InMemorySkillCatalog(try ["a", "b", "c"].map { try package($0) }, pageSize: .max)
        #expect(try await unbounded.listSkills(cursor: "1").skills.map(\.name) == ["b", "c"])
        #expect(try await unbounded.readDirectory(uri: "skill://a", cursor: "0")?.resources.count == 1)
    }

    @Test("Packages with one skill URI: the last wins, its entry, bytes and directories")
    func duplicates() async throws {
        let first = try package("a", ["x.md": data("one"), "old.md": data("o")])
        let second = try package("a", ["x.md": data("two")])
        let replaced = InMemorySkillCatalog()
        await replaced.setSkills([first, second])
        for catalog in [InMemorySkillCatalog([first, second]), replaced] {
            #expect(await catalog.skills.count == 1)
            let entry = try #require(await catalog.skill(uri: "skill://a/SKILL.md"))
            guard case .manifest(let files) = entry.resources else { Issue.record("no manifest"); return }
            let x = try #require(files.first { $0.uri == "skill://a/x.md" })
            let read = try #require(await catalog.readResource(uri: "skill://a/x.md"))
            #expect(read.contents.first?.text == "two")
            #expect(x.digest == SkillResource.digest(of: data("two")))
            let root = try await catalog.readDirectory(uri: "skill://a", cursor: nil)
            #expect(root?.resources.map(\.name) == ["SKILL.md", "x.md"])
        }
    }

    @Test("Files and directories, prefixes included")
    func directories() async throws {
        let catalog = InMemorySkillCatalog([
            try package("pdf", ["templates/invoice.md": data("i"), "templates/regional/eu.md": data("e")]),
            try package("acme/billing/refunds"),
        ])
        #expect(await catalog.skill(uri: "skill://pdf/SKILL.md")?.name == "pdf")
        #expect(await catalog.skill(uri: "skill://pdf/templates/invoice.md") == nil)
        let read = try #require(await catalog.readResource(uri: "skill://pdf/templates/invoice.md"))
        #expect(read.contents.first?.text == "i")
        #expect(read.contents.first?.mimeType == "text/markdown")
        #expect(await catalog.readResource(uri: "skill://pdf/missing.md") == nil)

        let root = try #require(try await catalog.readDirectory(uri: "skill://pdf", cursor: nil))
        #expect(root.resources.map(\.name) == ["SKILL.md", "templates"])
        #expect(root.resources.last?.mimeType == ReadResourceDirectory.directoryMimeType)
        let templates = try #require(try await catalog.readDirectory(uri: "skill://pdf/templates", cursor: nil))
        #expect(templates.resources.map(\.uri) == ["skill://pdf/templates/invoice.md", "skill://pdf/templates/regional"])
        #expect(templates.resources.first?.size == 1)
        let prefix = try #require(try await catalog.readDirectory(uri: "skill://acme", cursor: nil))
        #expect(prefix.resources.map(\.uri) == ["skill://acme/billing"])
        #expect(try await catalog.readDirectory(uri: "skill://pdf/SKILL.md", cursor: nil) == nil)
        #expect(try await catalog.readDirectory(uri: "skill://pdf/", cursor: nil) == nil)
    }
}

@Suite("Serving skills")
struct SkillServerTests {
    private func server(
        listInResources: Bool = true, appResources: [Resource]? = nil, appPageSize: Int = 1
    ) async throws -> WireExchange {
        let server = Server(name: "s", version: "1", capabilities: .init(tools: .init()))
        if let appResources {
            await server.withMethodHandler(ListResources.self) { params in
                let start = Int(params.cursor ?? "0") ?? 0
                let end = min(appResources.count, start + appPageSize)
                return .init(
                    resources: Array(appResources[start..<end]), nextCursor: end < appResources.count ? "\(end)" : nil)
            }
            await server.withMethodHandler(ReadResource.self) { params in
                guard params.uri == "app://doc" else { throw MCPError.resourceNotFound(uri: params.uri) }
                return .init(contents: [.text("doc", uri: params.uri)])
            }
        }
        await server.withSkills(
            InMemorySkillCatalog([
                try package("pdf", ["references/FORMS.md": data("forms")]), try package("acme/refunds"),
            ]),
            listInResources: listInResources)
        let wire = WireExchange(server: server)
        try await wire.start()
        return wire
    }

    private func result(_ wire: WireExchange, _ method: String, _ params: [String: Value] = [:]) async throws -> Value {
        let reply = try await wire.send(statelessMessage(id: 1, method: method, params: params))
        return try #require(reply.first?.objectValue?["result"], "\(reply)")
    }

    private func errorCode(_ wire: WireExchange, _ method: String, _ params: [String: Value] = [:]) async throws -> Int? {
        try await wire.send(statelessMessage(id: 1, method: method, params: params)).first?
            .objectValue?["error"]?.objectValue?["code"]?.intValue
    }

    @Test("server/discover declares the extension with directoryRead, and resources")
    func discover() async throws {
        let wire = try await server()
        defer { Task { await wire.stop() } }
        let capabilities = try await result(wire, ServerDiscover.name).objectValue?["capabilities"]
        expectWire(
            try #require(capabilities),
            matches: ["extensions": [ExtensionID.skills: ["directoryRead": true]], "resources": [:]])
    }

    @Test("skills/list and skills/get carry resultType and cache hints; an unknown skill is -32602")
    func listAndGet() async throws {
        let wire = try await server()
        defer { Task { await wire.stop() } }
        let listed = try await result(wire, ListSkills.name)
        expectWire(listed, matches: ["resultType": "complete", "ttlMs": "<any>", "cacheScope": "<any>"])
        let skills = try #require(listed.objectValue?["skills"]?.arrayValue)
        #expect(skills.compactMap { $0.objectValue?["uri"]?.stringValue } == [
            "skill://pdf/SKILL.md", "skill://acme/refunds/SKILL.md",
        ])
        let got = try await result(wire, GetSkill.name, ["uri": "skill://pdf/SKILL.md"])
        expectWire(got, matches: ["resultType": "complete", "ttlMs": "<any>", "cacheScope": "<any>"])
        #expect(got.objectValue?["skill"] == skills.first)
        #expect(got.objectValue?["nextCursor"] == nil)
        #expect(try await errorCode(wire, GetSkill.name, ["uri": "skill://nope/SKILL.md"]) == -32602)
        #expect(try await errorCode(wire, GetSkill.name, ["uri": "skill://pdf/references/FORMS.md"]) == -32602)
        for cursor in ["1000", String(Int.max)] {
            #expect(try await errorCode(wire, ListSkills.name, ["cursor": .string(cursor)]) == -32602)
            #expect(
                try await errorCode(wire, ReadResourceDirectory.name, ["uri": "skill://pdf", "cursor": .string(cursor)])
                    == -32602)
        }
    }

    @Test("resources/read: skill files first, then the application's handler")
    func read() async throws {
        let wire = try await server(appResources: [Resource(name: "doc", uri: "app://doc")])
        defer { Task { await wire.stop() } }
        let forms = try await result(wire, ReadResource.name, ["uri": "skill://pdf/references/FORMS.md"])
        expectWire(
            forms,
            matches: [
                "contents": [["uri": "skill://pdf/references/FORMS.md", "mimeType": "text/markdown", "text": "forms"]]
            ])
        let doc = try await result(wire, ReadResource.name, ["uri": "app://doc"])
        expectWire(doc, matches: ["contents": [["text": "doc"]]])
        #expect(try await errorCode(wire, ReadResource.name, ["uri": "skill://pdf/nope.md"]) == -32602)
        // The manifest encodes each component: an encoded / names no file.
        #expect(try await errorCode(wire, ReadResource.name, ["uri": "skill://pdf/references%2FFORMS.md"]) == -32602)
    }

    @Test("Without an application handler, unknown resources are -32602")
    func readWithoutApplication() async throws {
        let wire = try await server()
        defer { Task { await wire.stop() } }
        #expect(try await errorCode(wire, ReadResource.name, ["uri": "app://doc"]) == -32602)
        let listed = try await result(wire, ListResources.name)
        #expect(listed.objectValue?["resources"]?.arrayValue?.count == 2)
        #expect(listed.objectValue?["nextCursor"] == nil)
        #expect(try await result(wire, ListResources.name, ["cursor": .null]) == listed)
        for invalid: Value in [123, true, ["a": "b"], []] {
            #expect(try await errorCode(wire, ListResources.name, ["cursor": invalid]) == -32602, "\(invalid)")
        }
        // A position in an application listing that this server does not
        // have is done: the skills continue, and the listing ends.
        let foreign = try #require(
            ResourceListingCursor(application: .page("x"), sources: [.skills: .page("1")]).encoded)
        let rest = try await result(wire, ListResources.name, ["cursor": .string(foreign)])
        #expect(rest.objectValue?["resources"]?.arrayValue?.count == 1)
        #expect(rest.objectValue?["nextCursor"] == nil)
    }

    @Test("resources/list: the first page has both listings, later pages continue each")
    func composite() async throws {
        let app = [Resource(name: "one", uri: "app://1"), Resource(name: "two", uri: "app://2")]
        let wire = try await server(appResources: app)
        defer { Task { await wire.stop() } }
        func uris(_ page: Value) -> [String] {
            page.objectValue?["resources"]?.arrayValue?.compactMap { $0.objectValue?["uri"]?.stringValue } ?? []
        }
        let first = try await result(wire, ListResources.name)
        #expect(uris(first) == ["app://1", "skill://pdf/SKILL.md", "skill://acme/refunds/SKILL.md"])
        let manifest = first.objectValue?["resources"]?.arrayValue?[1] ?? .null
        expectWire(
            manifest,
            matches: [
                "uri": "skill://pdf/SKILL.md", "name": "pdf", "description": "Does things",
                "mimeType": "text/markdown",
            ])
        let cursor = try #require(first.objectValue?["nextCursor"]?.stringValue)
        let second = try await result(wire, ListResources.name, ["cursor": .string(cursor)])
        #expect(uris(second) == ["app://2"])
        #expect(second.objectValue?["nextCursor"] == nil)
        for invalid in ["1", "a", "mcp-resources:", "mcp-resources:e30="] {
            #expect(try await errorCode(wire, ListResources.name, ["cursor": .string(invalid)]) == -32602, "\(invalid)")
        }

        let unlisted = try await server(listInResources: false, appResources: app, appPageSize: 5)
        defer { Task { await unlisted.stop() } }
        let only = try await result(unlisted, ListResources.name)
        #expect(uris(only) == ["app://1", "app://2"])
        #expect(only.objectValue?["nextCursor"] == nil)
    }

    @Test("resources/list: a paged catalog follows the application's last page")
    func compositePaged() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(resources: .init()))
        await server.withMethodHandler(ListResources.self) { params in
            params.cursor == nil
                ? .init(resources: [Resource(name: "one", uri: "app://1")], nextCursor: "next")
                : .init(resources: [Resource(name: "two", uri: "app://2")])
        }
        await server.withSkills(InMemorySkillCatalog([try package("a"), try package("b")], pageSize: 1))
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        var pages: [[String]] = []
        var cursor: String?
        repeat {
            let page = try await result(wire, ListResources.name, cursor.map { ["cursor": .string($0)] } ?? [:])
            pages.append(page.objectValue?["resources"]?.arrayValue?.compactMap { $0.objectValue?["uri"]?.stringValue } ?? [])
            cursor = page.objectValue?["nextCursor"]?.stringValue
        } while cursor != nil && pages.count < 10
        #expect(pages == [["app://1", "skill://a/SKILL.md"], ["app://2"], ["skill://b/SKILL.md"]])
    }

    @Test("resources/directory/read: children, -32602 for a file")
    func directory() async throws {
        let wire = try await server()
        defer { Task { await wire.stop() } }
        let root = try await result(wire, ReadResourceDirectory.name, ["uri": "skill://pdf"])
        expectWire(
            root,
            matches: [
                "resultType": "complete",
                "resources": [
                    ["uri": "skill://pdf/SKILL.md", "name": "SKILL.md", "mimeType": "text/markdown"],
                    ["uri": "skill://pdf/references", "name": "references", "mimeType": "inode/directory"],
                ],
            ])
        #expect(try await errorCode(wire, ReadResourceDirectory.name, ["uri": "skill://pdf/SKILL.md"]) == -32602)
    }

    @Test("Without the extension, skills/* and resources/directory/read are -32601")
    func undeclared() async throws {
        let server = Server(name: "s", version: "1", capabilities: .init(resources: .init()))
        let wire = WireExchange(server: server)
        try await wire.start()
        defer { Task { await wire.stop() } }
        for method in [ListSkills.name, GetSkill.name, ReadResourceDirectory.name] {
            #expect(try await errorCode(wire, method, ["uri": "skill://pdf/SKILL.md"]) == -32601, "\(method)")
        }
    }

    @Test("Through initialize: the extension in the capabilities, skills/list without resultType")
    func handshake() async throws {
        let wire = try await server()
        defer { Task { await wire.stop() } }
        let initialize: Value = [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": [
                "protocolVersion": .string(Version.v2025_11_25), "capabilities": [:],
                "clientInfo": ["name": "c", "version": "1"],
            ],
        ]
        let reply = try await wire.send(String(decoding: try JSONEncoder().encode(initialize), as: UTF8.self))
        let capabilities = reply.first?.objectValue?["result"]?.objectValue?["capabilities"]
        expectWire(try #require(capabilities), matches: ["extensions": [ExtensionID.skills: ["directoryRead": true]]])
        try await wire.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, expecting: 0)
        let listed = try await wire.send(#"{"jsonrpc":"2.0","id":1,"method":"skills/list","params":{}}"#)
        let result = try #require(listed.first?.objectValue?["result"]?.objectValue)
        #expect(result["skills"]?.arrayValue?.count == 2)
        #expect(result["resultType"] == nil)
    }
}

@Suite("Skill wire types")
struct SkillWireTests {
    @Test("Resources: a manifest, dynamic, or kept as unrecognized")
    func resources() throws {
        func decode(_ json: String) throws -> Skill {
            try JSONDecoder().decode(Skill.self, from: Data(json.utf8))
        }
        let base = #""uri":"skill://a/SKILL.md","frontmatter":{"name":"a","description":"d","icon":"data:image/png;base64,aGk="}"#
        let manifest = try decode("{\(base),\"resources\":[{\"uri\":\"skill://a/SKILL.md\",\"digest\":\"sha256:00\",\"size\":1}]}")
        #expect(manifest.resources == .manifest([SkillResource(uri: "skill://a/SKILL.md", digest: "sha256:00", size: 1)]))
        #expect(manifest.frontmatter["icon"] == .string("data:image/png;base64,aGk="))
        #expect(try decode("{\(base),\"resources\":\"dynamic\"}").resources == .dynamic)
        #expect(try decode("{\(base),\"resources\":\"static\"}").resources == .unrecognized("static"))
        #expect(try decode("{\(base)}").resources == .unrecognized(.null))

        let encoded = String(
            decoding: try JSONEncoder().encode(try decode("{\(base),\"resources\":\"dynamic\"}")), as: UTF8.self)
        #expect(encoded.contains(#""resources":"dynamic""#))
        #expect(encoded.contains(#""icon":"data:image\/png;base64,aGk=""#))
    }

    @Test("Settings: declared as an object, with or without directoryRead")
    func settings() {
        #expect(SkillsSettings(nil) == nil)
        #expect(SkillsSettings([ExtensionID.skills: [:]]) == SkillsSettings())
        #expect(SkillsSettings([ExtensionID.skills: ["directoryRead": true]])?.directoryRead == true)
        for value: Value in [.null, false, true, "skills", []] {
            #expect(SkillsSettings([ExtensionID.skills: value]) == nil, "\(value)")
        }
    }
}
