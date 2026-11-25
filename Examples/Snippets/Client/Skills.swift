import Foundation
import MCP

// Snippets for docs/client.md: skills (SEP-2640).

// snippet: client-skills
/// Builds a registry from the listing, then loads one skill and reads the
/// file it refers to.
func answerRefund(_ client: Client) async throws -> String? {
    // The listing alone: names, descriptions and manifests, no file content.
    let skills = try await client.listAllSkills()
    guard let entry = skills.first(where: { $0.name == "refunds" }) else { return nil }
    do {
        // Reads SKILL.md, and checks its size, digest and frontmatter.
        let skill = try await client.loadSkill(entry)
        // Read when needed, and verified the same way.
        let template = try await skill.read("examples/email.md")
        return skill.content + "\n" + String(decoding: template, as: UTF8.self)
    } catch let error as SkillVerificationError {
        // Not what the listing promised, or the skill changed since: the
        // current entry is one skills/get away.
        print("Refused \(error.uri): \(error.reason)")
        return nil
    }
}
// endsnippet
