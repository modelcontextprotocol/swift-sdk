import Foundation
import Testing

@testable import MCP

// SKILL.md frontmatter (SEP-2640): extraction, YAML 1.2 core against the
// `yaml` npm package (Generated/FrontmatterCorpus.swift), YAML 1.1, limits
// and comparison.

private func json(_ text: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(text.utf8))
}

/// Parses on its own executor and reports whether the parse finished, so a
/// test can see whether the actor is free while the parser runs.
private actor Parsing {
    private(set) var started = false
    private(set) var finished = false

    func parse(_ document: String) async throws {
        started = true
        _ = try await SkillFrontmatter.parseInBackground(document: document)
        finished = true
    }

    func state() -> (started: Bool, finished: Bool) { (started, finished) }
}

@Suite("Skill frontmatter")
struct SkillFrontmatterTests {
    @Test("The block is the one the harness's pattern extracts", arguments: frontmatterDocuments.indices)
    func extraction(_ index: Int) {
        let (name, document, block) = frontmatterDocuments[index]
        #expect(SkillFrontmatter.block(in: document).map(String.init) == block, "\(name)")
    }

    @Test("YAML 1.2 core: the same JSON as the yaml package, or refused", arguments: frontmatterCorpus.indices)
    func corpus(_ index: Int) throws {
        let (name, yaml, expected) = frontmatterCorpus[index]
        guard let expected else {
            #expect(throws: SkillFrontmatter.Failure.self, "\(name)") { try SkillFrontmatter.parse(yaml) }
            return
        }
        let parsed = try SkillFrontmatter.parse(yaml)
        let value = try json(expected)
        #expect(SkillFrontmatter.equivalent(.object(parsed), value), "\(name): \(parsed) != \(value)")
    }

    @Test("Strings stay strings, numbers keep their kind")
    func kinds() throws {
        let parsed = try SkillFrontmatter.parse("a: 2.1.0\nb: '1'\nc: 1\nd: 1.5\ne: 0x10\nf: data:text/plain;base64,aGk=")
        #expect(parsed["a"] == "2.1.0")
        #expect(parsed["b"] == "1")
        #expect(parsed["c"] == 1)
        #expect(parsed["d"] == 1.5)
        #expect(parsed["e"] == 16)
        #expect(parsed["f"] == .string("data:text/plain;base64,aGk="))
        #expect(try SkillFrontmatter.parse("n: 1" + String(repeating: "0", count: 30))["n"] == 1e30)
    }

    @Test("Integers beyond a double are refused, not infinite")
    func hugeIntegers() {
        for literal in [
            "1" + String(repeating: "0", count: 400), "-" + String(repeating: "9", count: 400),
            "0x" + String(repeating: "f", count: 300), "0o" + String(repeating: "7", count: 400),
        ] {
            #expect(throws: SkillFrontmatter.Failure.invalidValue(literal)) {
                try SkillFrontmatter.parse("n: \(literal)")
            }
            #expect(throws: SkillFrontmatter.Failure.self) { try SkillFrontmatter.parse("n: !!int \(literal)") }
        }
    }

    @Test("Parsing in the background leaves the caller's actor free")
    func background() async throws {
        // A large block: many nodes, well under the limits.
        let fields = (0..<1500).map { "k\($0): [a, b, c]" }.joined(separator: "\n")
        let document = "---\n" + fields + "\n---\n"
        #expect(try await SkillFrontmatter.parseInBackground(document: document).count == 1500)
        let parsing = Parsing()
        let task = Task { try await parsing.parse(document) }
        while true {
            let state = await parsing.state()
            guard state.started else {
                await Task.yield()
                continue
            }
            #expect(!state.finished)
            break
        }
        try await task.value
        #expect(await parsing.state().finished)
    }

    @Test("A document: missing frontmatter, a non-mapping, the body ignored")
    func documents() throws {
        #expect(throws: SkillFrontmatter.Failure.missing) { try SkillFrontmatter.parse(document: "# Title\n") }
        #expect(throws: SkillFrontmatter.Failure.notAMapping) { try SkillFrontmatter.parse(document: "---\n\n---\n") }
        let parsed = try SkillFrontmatter.parse(document: "\u{FEFF}---\r\nname: a\r\ndescription: b\r\n---\r\n: not yaml [")
        #expect(parsed == ["name": "a", "description": "b"])
    }

    @Test("Duplicate keys are refused, quoted or not")
    func duplicates() {
        #expect(throws: SkillFrontmatter.Failure.self) { try SkillFrontmatter.parse("a: 1\na: 2") }
        #expect(throws: SkillFrontmatter.Failure.duplicateKey("a")) { try SkillFrontmatter.parse("a: 1\n'a': 2") }
        #expect(throws: SkillFrontmatter.Failure.duplicateKey("1")) { try SkillFrontmatter.parse("1: a\n'1': b") }
    }

    @Test("Limits: block size, expanded nodes, nesting")
    func limits() async throws {
        let large = "a: \"" + String(repeating: "x", count: SkillFrontmatter.maximumSize) + "\""
        #expect(throws: SkillFrontmatter.Failure.tooLarge(large.utf8.count)) { try SkillFrontmatter.parse(large) }

        // Nine levels of ten aliases: a billion nodes from a few hundred bytes.
        var laughs = "a: &a [lol, lol, lol, lol, lol, lol, lol, lol, lol, lol]\n"
        let names = Array("bcdefghij")
        for (index, name) in names.enumerated() {
            let previous = index == 0 ? "a" : String(names[index - 1])
            let refs = Array(repeating: "*\(previous)", count: 10).joined(separator: ", ")
            laughs += "\(name): &\(name) [\(refs)]\n"
        }
        #expect(throws: SkillFrontmatter.Failure.tooManyNodes) { try SkillFrontmatter.parse(laughs) }

        // The same tree as a key: composing would hash it expanded, so a key
        // that is a collection, or an alias of one, is refused before.
        let clock = ContinuousClock()
        let start = clock.now
        for key in ["*j : x", "? *j\n: x", "[*j]: x", "{k: *j}: x"] {
            #expect(throws: SkillFrontmatter.Failure.self, "\(key)") { try SkillFrontmatter.parse(laughs + key) }
            #expect(throws: SkillFrontmatter.Failure.self, "\(key)") {
                try SkillFrontmatter.parse(laughs + key, schema: .yaml11)
            }
        }
        #expect(clock.now - start < .seconds(1))
        #expect(try SkillFrontmatter.parse("k: &k name\n*k : v") == ["k": "name", "name": "v"])

        // YAML 1.1 merges count too: twenty levels of two merges each.
        var merges = "l0: &l0 {}\n"
        for level in 1...20 { merges += "l\(level): &l\(level) {<<: [*l\(level - 1), *l\(level - 1)]}\n" }
        #expect(throws: SkillFrontmatter.Failure.tooManyNodes) { try SkillFrontmatter.parse(merges, schema: .yaml11) }
        #expect(clock.now - start < .seconds(2))

        // libyaml stops at 1000 levels. Just below, Yams and the converter
        // recurse deeper than a task's stack allows: parsing has its own.
        let deep = "a: " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        let result = await Task { Result { try SkillFrontmatter.parse(deep) } }.value
        #expect(throws: SkillFrontmatter.Failure.self) { try result.get() }
        for (depth, style) in [(990, "flow"), (300, "block")] {
            let nested =
                style == "flow"
                ? "a: " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
                : (0..<depth).map { String(repeating: " ", count: $0) + "k:" }.joined(separator: "\n") + " 1"
            let parsed = await Task { Result { try SkillFrontmatter.parse(nested) } }.value
            #expect(throws: Never.self, "\(style)") { try parsed.get() }
        }
    }

    @Test("YAML 1.1: booleans, numbers, merge keys, timestamps as written")
    func yaml11() throws {
        let yaml = """
            a: yes
            b: Off
            c: 1_000
            d: 0b101
            e: 2024-01-01
            f: y
            base: &base {x: 1, y: 2}
            merged:
              <<: *base
              y: 3
            list:
              <<: [{p: 1}, {p: 2, q: 2}]
            """
        let parsed = try SkillFrontmatter.parse(yaml, schema: .yaml11)
        #expect(parsed["a"] == true)
        #expect(parsed["b"] == false)
        #expect(parsed["c"] == 1000)
        #expect(parsed["d"] == 5)
        #expect(parsed["e"] == "2024-01-01")
        #expect(parsed["f"] == "y")
        #expect(parsed["merged"] == ["x": 1, "y": 3])
        #expect(parsed["list"] == ["p": 1, "q": 2])

        let core = try SkillFrontmatter.parse(yaml)
        #expect(core["a"] == "yes")
        #expect(core["merged"] == ["<<": ["x": 1, "y": 2], "y": 3])
        #expect(throws: SkillFrontmatter.Failure.self) { try SkillFrontmatter.parse("a: .inf", schema: .yaml11) }
    }

    @Test("Comparison: numbers by value, key order ignored, data: URLs as strings")
    func comparison() throws {
        let file = try SkillFrontmatter.parse("n: 1.0\nm: {b: 2, a: 1}\nl: [1, 2]\nd: data:text/plain;base64,aGk=")
        let entry = try json(#"{"m":{"a":1,"b":2},"l":[1,2],"n":1,"d":"data:text/plain;base64,aGk="}"#)
        guard case .object(let object) = entry else { Issue.record("not an object"); return }
        #expect(object["d"]?.dataValue != nil)
        #expect(SkillFrontmatter.matches(file, object))

        #expect(!SkillFrontmatter.equivalent([1, 2], [2, 1]))
        #expect(!SkillFrontmatter.equivalent(true, 1))
        #expect(!SkillFrontmatter.equivalent("1", 1))
        #expect(!SkillFrontmatter.equivalent(.null, ""))
        #expect(!SkillFrontmatter.matches(["a": 1], ["a": 1, "b": .null]))
        #expect(!SkillFrontmatter.equivalent(.data(mimeType: "text/plain", Data("hi".utf8)), "hi"))
    }
}
