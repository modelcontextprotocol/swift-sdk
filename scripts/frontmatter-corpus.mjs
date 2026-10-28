#!/usr/bin/env node
// Writes Tests/MCPTests/Generated/FrontmatterCorpus.swift: SKILL.md
// frontmatter blocks and the JSON the `yaml` npm package parses them to,
// the parser the conformance harness compares frontmatter with. The Swift
// tests check that SkillFrontmatter (YAML 1.2, core schema) agrees. A block
// that `yaml` parses only with a warning (an unknown tag, an explicit tag
// that does not fit its text) is one the SDK refuses: `nil` below. So are
// the cases with a third element, which `yaml` turns into something that is
// not the JSON of the file (a Buffer, a Date, a stringified collection key).
//
// Usage: node scripts/frontmatter-corpus.mjs
//   Run scripts/run-conformance.sh once first: `yaml` comes from the
//   harness install in .build/conformance-harness (package-lock.json).
//   Add a case below, run the script and commit both files.

import { createRequire } from "node:module";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(join(root, ".build/conformance-harness/package.json"));
const YAML = require("yaml");
const { version } = require("yaml/package.json");

// [name, frontmatter block, why the SDK refuses what `yaml` accepts]
const cases = [
  ["minimal", "name: pdf-processing\ndescription: Extract, fill, and assemble PDF documents"],
  ["metadata", "name: refunds\ndescription: Process refunds\nlicense: Apache-2.0\nmetadata:\n  version: \"2.1.0\"\n  owner: billing"],
  ["integers", "a: 1\nb: -0\nc: +12\nd: 0o14\ne: 0x1F\nf: 007\ng: 12345678901234567890"],
  ["floats", "a: 1.5\nb: .5\nc: 1.\nd: -1.5E-3\ne: 1e3\nf: +2.0\ng: 0.1"],
  ["yaml 1.1 numbers are strings", "a: 1_000\nb: 0b101\nc: 1:30\nd: 0o9\ne: 0xG"],
  ["booleans", "a: true\nb: True\nc: TRUE\nd: false\ne: False\nf: FALSE"],
  ["yaml 1.1 booleans are strings", "a: yes\nb: no\nc: on\nd: off\ne: y\nf: n\ng: tRUE"],
  ["nulls", "a: null\nb: Null\nc: NULL\nd: ~\ne:\nf: nULL"],
  ["timestamps are strings", "a: 2024-01-01\nb: 2001-12-14t21:59:43.10-05:00"],
  ["quoted scalars", "a: \"1\"\nb: 'true'\nc: \"null\"\nd: 'it''s'\ne: \"tab\\tline\\nend \\u00e9\"\nf: ''"],
  ["block scalars", "a: |\n  line one\n  line two\nb: >\n  folded\n  text\n\n  paragraph\nc: |-\n  stripped\nd: |+\n  kept\n\ne: 1"],
  ["plain multi-line", "description: This skill does\n  several things\n  at once"],
  ["sequences", "a: [1, two, 3.5, true, null]\nb:\n  - x\n  - - nested\n    - list\n  - k: v"],
  ["mappings", "a: {b: 1, c: [d, e]}\n\"quoted key\": 1\n'single': 2\nkey with spaces: 3"],
  ["anchors and aliases", "base: &b\n  x: 1\n  y: [1, 2]\ncopy: *b\nlist: [*b, *b]"],
  ["merge key is a string", "<<: {a: 1}\nb: 2"],
  ["explicit tags", "a: !!str 123\nb: !!int \"12\"\nc: !!float 1.0\nd: !!bool \"true\"\ne: !!null ''\nf: ! 12\ng: !!str true\nh: !!float 1e3\ni: !!map {a: 1}\nj: !!seq [1]"],
  ["scalar keys", "1: a\n007: b\ntrue: c\nnull: d\n'2': e"],
  ["unicode", "name: émoji\ndescription: \"日本語 🙂\"\nkey-é: ü"],
  ["comments", "# leading\nname: a # trailing\n# middle\ndescription: b"],
  ["strings that look special", "a: 1.2.3\nc: .\nd: \"-\"\ne: 1e\nf: 0x\ng: +\nh: .e3\ni: 1e+3\nj: 0o\nk: --1\nl: 1-2"],
  ["colons and urls", "url: https://example.com/a:b\ntime: \"12:30\"\nratio: 1:2"],
  ["empty mapping value nested", "metadata: {}\ntags: []"],
  // Refused by both.
  ["duplicate keys", "a: 1\na: 2"],
  ["infinity", "a: .inf"],
  ["negative infinity", "a: -.Inf"],
  ["not a number", "a: .nan"],
  ["not a mapping", "- a\n- b"],
  ["scalar root", "just a string"],
  ["invalid yaml", "a: [1, 2\nb: 3"],
  ["tab indentation", "a:\n\tb: 1"],
  ["block sequence on the key line", "b: -"],
  ["float tag on an integer", "a: !!float 1"],
  ["int tag on a float", "a: !!int 1.5"],
  ["bool tag on yes", "a: !!bool yes"],
  ["null tag on zero", "a: !!null 0"],
  ["unknown tag", "a: !!foo bar"],
  ["local tag", "a: !thing bar"],
  ["binary", "a: !!binary aGk=", "a Buffer"],
  ["timestamp tag", "a: !!timestamp 2024-01-01", "a Date"],
  ["set", "a: !!set {x}", "an empty object"],
  ["str tag on a sequence", "a: !!str [1]"],
  ["collection key", "? [a]\n: b", "a key that is not a scalar"],
];

// [name, SKILL.md document]: the block the harness extracts, with its regex.
const documents = [
  ["lf", "---\nname: a\n---\nbody"],
  ["crlf", "---\r\nname: a\r\n---\r\nbody"],
  ["byte order mark", "\ufeff---\nname: a\n---\n"],
  ["closing at the end", "---\nname: a\n---"],
  ["closing with spaces and tabs", "---\nname: a\n--- \t\nbody"],
  ["closing with text is not closing", "---\nname: a\n---x\nb: 1\n---\n"],
  ["four dashes do not close", "---\na: 1\n----\nb: 2\n---\n"],
  ["dashes inside a line", "---\na: ---\n---\n"],
  ["empty block", "---\n\n---\n"],
  ["no blank block", "---\n---\n"],
  ["no opening", "name: a\n---\n"],
  ["opening not alone", "--- name: a\n---\n"],
  ["leading blank line", "\n---\nname: a\n---\n"],
  ["unclosed", "---\nname: a\n"],
  ["second block ignored", "---\na: 1\n---\n---\nb: 2\n---\n"],
  ["cr before closing", "---\na: 1\r\n---\n"],
];
const frontmatterPattern = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/;

const lines = [
  "// Generated by scripts/frontmatter-corpus.mjs from the `yaml` npm package " + version + ". Do not edit.",
  "",
  "/// A frontmatter block and the JSON `yaml` parses it to; `nil` when it refuses it.",
  "let frontmatterCorpus: [(name: String, yaml: String, json: String?)] = [",
];
// A JSON string literal is a Swift one, but for \uXXXX, \b and \f.
const swiftString = (s) =>
  JSON.stringify(s)
    .replace(/\\(u[0-9a-fA-F]{4}|.)/g, (escape, body) =>
      body.startsWith("u") && body.length === 5 ? `\\u{${body.slice(1)}}` :
      body === "b" ? "\\u{8}" : body === "f" ? "\\u{C}" : escape)
    .replace(/\ufeff/g, "\\u{FEFF}");

for (const [name, yaml, refusedBySDK] of cases) {
  let json = null;
  if (!refusedBySDK) try {
    const doc = YAML.parseDocument(yaml);
    if (doc.errors.length > 0 || doc.warnings.length > 0) throw new Error("refused");
    const value = doc.toJS();
    const finite = JSON.stringify(value, (_, v) => {
      if (typeof v === "number" && !Number.isFinite(v)) throw new Error("non-finite");
      return v;
    });
    if (value !== null && typeof value === "object" && !Array.isArray(value)) json = finite;
  } catch {
    json = null;
  }
  lines.push(`    (${swiftString(name)}, ${swiftString(yaml)}, ${json === null ? "nil" : swiftString(json)}),`);
}
lines.push("]", "");

lines.push(
  "/// A document and the frontmatter block the harness extracts from it; `nil` for none.",
  "let frontmatterDocuments: [(name: String, document: String, block: String?)] = [",
);
for (const [name, document] of documents) {
  const text = document.charCodeAt(0) === 0xfeff ? document.slice(1) : document;
  const match = text.match(frontmatterPattern);
  lines.push(`    (${swiftString(name)}, ${swiftString(document)}, ${match ? swiftString(match[1]) : "nil"}),`);
}
lines.push("]", "");

const out = join(root, "Tests/MCPTests/Generated/FrontmatterCorpus.swift");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join("\n"));
console.log(`wrote ${cases.length} cases and ${documents.length} documents to ${out}`);
