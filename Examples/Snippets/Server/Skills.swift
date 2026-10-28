import Foundation
import MCP

// Snippets for docs/server.md: skills (SEP-2640).

// snippet: skills-server
/// A server that serves the skills in `directory`, one subdirectory each:
/// `pdf-processing/SKILL.md`, `pdf-processing/references/FORMS.md`, ...
func makeSkillsServer(directory: URL) async throws -> Server {
    let server = Server(
        name: "docs", version: "1.0.0", capabilities: .init(resources: .init(listChanged: true)))
    var skills: [SkillPackage] = []
    for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        // Checks the skill and computes its entry; throws for an invalid one.
        skills.append(try SkillPackage(path: entry.lastPathComponent, directory: entry))
    }
    await server.withSkills(InMemorySkillCatalog(skills))
    return server
}
// endsnippet

// snippet: skills-package
/// A skill from files in memory, under the prefix `acme/billing`.
func makeRefundsSkill() throws -> SkillPackage {
    try SkillPackage(
        path: "acme/billing/refunds",
        files: [
            "SKILL.md": Data(
                """
                ---
                name: refunds
                description: Process customer refund requests per company policy
                ---

                Answer with the template in examples/email.md.
                """.utf8),
            "examples/email.md": Data("Dear customer, your refund is on its way.\n".utf8),
        ])
}
// endsnippet

// snippet: skills-catalog
/// A skill generated on each read: not listed, served by URI, with no
/// digests to publish.
struct DailyReportSkill: SkillCatalog {
    static let uri = "skill://reports/daily/SKILL.md"
    static let frontmatter: [String: Value] = ["name": "daily", "description": "Today's figures"]

    func listSkills(cursor: String?) async throws -> ListSkills.Result {
        ListSkills.Result(skills: [])
    }

    func skill(uri: String) async throws -> Skill? {
        uri == Self.uri ? Skill(uri: uri, frontmatter: Self.frontmatter, resources: .dynamic) : nil
    }

    func readResource(uri: String) async throws -> ReadResource.Result? {
        guard uri == Self.uri else { return nil }
        let text = "---\nname: daily\ndescription: Today's figures\n---\n\nSales: \(Int.random(in: 1...100))\n"
        return ReadResource.Result(contents: [.text(text, uri: uri, mimeType: "text/markdown")])
    }
}
// endsnippet
