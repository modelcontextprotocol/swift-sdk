// Parses the input as a SKILL.md: frontmatter extraction, then YAML 1.2 core
// and YAML 1.1. Neither may crash. A parsed frontmatter is JSON: it encodes,
// decodes back to an equivalent object, and parsing it again gives the same.

import Foundation
@testable import MCP

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let document = String(decoding: UnsafeRawBufferPointer(start: start, count: count), as: UTF8.self)
    for schema in [SkillFrontmatter.Schema.core, .yaml11] {
        guard let parsed = try? SkillFrontmatter.parse(document: document, schema: schema) else { continue }
        let data = try! JSONEncoder().encode(parsed)
        let decoded = try! JSONDecoder().decode([String: Value].self, from: data)
        precondition(SkillFrontmatter.matches(parsed, decoded), "the JSON of a frontmatter differs from it")
        precondition(
            (try? SkillFrontmatter.parse(document: document, schema: schema)) == parsed,
            "parsing the same frontmatter twice gave different results")
    }
    return 0
}
