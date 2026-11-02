# Skills (SEP-2640)

## Context

A skill is a directory of files, at least a `SKILL.md` that starts with YAML frontmatter
(`name`, `description`), that teaches an agent a workflow ([Agent Skills](https://agentskills.io/specification)).
The `io.modelcontextprotocol/skills` extension serves skills over MCP: each file is a resource,
conventionally `skill://<skill-path>/<file-path>`, where the last segment of `<skill-path>` is
the skill's name. Three methods sit on top:

| Method | Result | Required of a declaring server |
|---|---|---|
| `skills/list` | Entries: `uri` of the `SKILL.md`, the frontmatter as JSON, `resources` (every file with `sha256:` digest and size, or `"dynamic"`); paginated, may be empty or partial | Yes |
| `skills/get` | The entry of one skill by URI, listed or not; -32602 for a URI that is not a skill | Yes |
| `resources/directory/read` | The direct children of a directory resource (`inode/directory`); -32602 for anything else | With `directoryRead: true` |

Files are read with `resources/read`. A host verifies what it reads against the entry it holds:
the length against `size`, the SHA-256 against `digest`, and, for the `SKILL.md`, its
frontmatter field by field against the entry's. A mismatch is a verification failure, and the
skill or file is not used. Hosts fetch nothing ahead of need: `SKILL.md` when the skill is
loaded, a supporting file when it is read. Per skill, hosts must accept 512 files and 16 MiB.

The extension applies at every revision where the server declares it; from 2026-07-28 the list
and get results carry cache hints. The conformance harness tests it in the default leg only:
three server scenarios (`sep-2640-skills-enumeration`, `-manifest`, `-directory`) and four client
scenarios (`sep-2640-client-no-prefetch`, `-verify-digest`, `-verify-size`,
`-verify-frontmatter`). No other SDK implements it.

## Goals

- A server serves a directory of skills, or files in memory, in a few lines, and cannot serve
  an invalid one: the SDK computes the entry and checks the rules.
- Custom catalogs (generated, paged, dynamic skills) through one small protocol.
- Skill files reach clients through `resources/read` and `resources/list` without the
  application wiring them into its own handlers.
- A client loads a skill only through a path that verifies it, and reads nothing early.
- Frontmatter reads the same on both sides as in the other implementations (the harness uses
  the `yaml` npm package).

## Design

### Frontmatter (`Base/SkillFrontmatter.swift`)

Foundation has no YAML parser; the SDK depends on Yams (DEPENDENCY_POLICY.md) for libyaml and
its node tree, and converts the tree to JSON itself. The default is YAML 1.2 with the core
schema, the schema of the `yaml` npm package: `true`/`True`/`TRUE`, `null`/`~`/empty, decimal,
`0o` and `0x` integers, decimal and exponent floats; `yes`, `2024-01-01` and `1_000` are
strings. Yams' default resolver is YAML 1.1 and would disagree, so composing uses a resolver
that marks plain untagged scalars, and only those get the core rules. Explicit core tags are
honoured when their text fits; other tags, `.inf` and `.nan` (no JSON form), collection keys
and duplicate keys are refused. Integer, boolean and null keys are written as JavaScript does.
`scripts/frontmatter-corpus.mjs` records what `yaml` 2.9.1 (from the harness install) makes of
43 blocks and what the harness's pattern extracts from 16 documents; the tests compare. A block
`yaml` accepts only with a warning is one the SDK refuses.

The block is extracted with the harness's pattern after a byte order mark. The input is
untrusted: at most 64 KiB, at most 10,000 converted nodes with aliases and YAML 1.1 `<<` merges
expanded (a billion laughs, or a chain of merges, stops there), and libyaml's 1000 levels of
nesting. Yams checks each mapping for duplicate keys by hashing the key nodes, and a key that is
an alias of a collection hashes the expanded tree: a few hundred bytes run for hours before the
converter counts a node. A pass over libyaml's events (`CYaml`, which Yams builds on) therefore
refuses a key that is a collection, or an alias of one, before Yams composes; the converter
refuses those keys anyway. An integer literal beyond a double is refused rather than read as
infinity, which has no JSON form. Yams recurses per level and overflows a 512 KiB
secondary-thread stack at about 800, so parsing runs on a thread of its own with a 16 MiB
stack. `SkillPackage` waits for it (setup); the client's load suspends until it resumes a
continuation, so neither the client actor nor a cooperative thread is held. The work is
bounded and happens on registration and on load only. `FuzzFrontmatter` parses arbitrary
documents with both schemas.

Comparison is JSON equality: numbers by value (`1` equals `1.0`), key order ignored, and a
`data:` URL string equal to the `Value.data` it decodes to. Entries decode their frontmatter
with strings as written (`Value.Preserved`), and handler results now become `Value`s the same
way, so a server sends the frontmatter it parsed byte for byte.

### Wire types (`Base/SkillTypes.swift`)

`Skill` (`uri`, `frontmatter: [String: Value]`, `resources`, `_meta`), `SkillResource` (`uri`,
`digest`, `size`), `SkillsSettings` (`directoryRead`), `ListSkills`, `GetSkill` (both
`CacheableResult`) and `ReadResourceDirectory`. `Skill.Resources` is `.manifest`, `.dynamic`, or
`.unrecognized(Value)`: an entry with a bad `resources` decodes, so one bad entry does not fail a
listing, and the loader refuses it. The enum is frozen; the SEP defines no other form.

### Serving (`Server/Skills.swift`)

`SkillCatalog` is the protocol the server consults: `listSkills(cursor:)`, `skill(uri:)`,
`readResource(uri:)`, with defaults for `readDirectory(uri:cursor:)` (none),
`supportsDirectoryRead` (false) and `listResources(cursor:)` (one `SKILL.md` resource per listed
skill). Results are wire types, so a catalog sets its own `_meta` and cache hints.

`SkillPackage` is one skill, checked when it is created: `SKILL.md` at the root, UTF-8, with a
frontmatter `name` and `description`; the Agent Skills naming rule; the last path segment equal
to the name; unreserved characters in the path; relative file paths that stay in the skill; 512
files and 16 MiB unless `enforcesLimits` is false. It computes the entry, `SKILL.md` first, URIs
percent-encoded per component. From a directory it reads regular files; names starting with `.`
and links that resolve outside the directory are skipped; a file that is also the directory of
another (`a` and `a/b`) is refused. `InMemorySkillCatalog` (an actor) serves packages, pages
listings and directories, and derives directory resources from the file paths: each skill's
root and subdirectories, and the prefixes (`skill://acme`). Of packages with the same skill URI
the last is kept, by `init` and `setSkills(_:)` alike, so the entry, the bytes and the
directories come from one package. Its cursors are offsets; one past the end is -32602. Text that is
UTF-8 with a textual MIME type is sent as `text`, anything else as `blob`; the digest covers the
bytes either way. MIME types come from an extension table (no UTType on Linux).

`Server.withSkills(_:listInResources:)`:

- Declares `extensions["io.modelcontextprotocol/skills"]` (`{"directoryRead": true}` or `{}`)
  and `resources`, which the SEP requires alongside.
- Registers default handlers for `skills/list`, `skills/get` (-32602 for a URI that is not a
  skill), `resources/directory/read` (-32602 for a non-directory), and, when the application has
  none, `resources/read` (-32602, `resourceNotFound`) and `resources/list` (empty).
- Answers `resources/read` of a skill file from the catalog before the application's handler,
  whatever the registration order. The check is in the dispatch, not a wrapper around the
  application's handler, which never sees a skill file: access control for skills belongs in
  the catalog (it runs with `Server.currentHandlerContext`) or in the start hooks.
- `resources/list`, with `listInResources`: the first page is the application's first page
  followed by the catalog's first page of `SKILL.md` resources (name, description,
  `text/markdown`, size); later pages continue the application's listing, then the catalog's.
  Many clients read one page, so neither listing may push the other off it. The server owns
  the cursor, which carries both positions (`SkillListingCursor`); a cursor it did not issue is
  -32602. The harness warns when a `SKILL.md` is not in `resources/list` or lacks the
  frontmatter's name and description.

At 2026-07-28 `skills/list` and `skills/get` are -32601 without the declaration, and
`resources/directory/read` without `directoryRead` (`StatelessRequests.isDeclared`); their
results get cache hints (`cacheableMethods`). No client capability is required: the harness's
clients declare none, and the SEP defines none.

### Loading (`Client/ClientSkills.swift`)

`listSkills(cursor:)`, `listAllSkills()` (stops on a repeated cursor), `getSkill(uri:)` and
`readResourceDirectory(uri:cursor:)` throw -32601 locally when the server did not declare the
extension or `directoryRead`; clients MUST NOT read directories otherwise.

`loadSkill(_:options:)` is the host's skill-loading path. It refuses an entry whose `uri` is not
a `SKILL.md`, whose manifest does not list it, lists a file outside the skill's root (a `.` or
`..` segment, percent-encoded or not, counts as outside) or a negative size, or whose `resources`
is unrecognized; checks the limits from the entry alone, the count first and the sizes, which
the server chose, without overflow; then reads the `SKILL.md`, and only it, and verifies size, then
digest, then frontmatter (parsed only after the bytes are verified, so the parser sees no more
than the entry admitted). `LoadedSkill` (an actor, for the dynamic budget) holds the entry and
the content; `read(_:)` resolves a relative path against the skill's root (`.` and `..` within
it), refuses a path that leaves it or a file the entry does not list without reading it, and
verifies what it reads. `directory(_:)` answers from the manifest, which is authoritative for
what the host may read. A dynamic entry needs `allowsDynamic`; its reads are not verified,
count against 16 MiB, and are refused, without a request, for a URI outside the root. `acceptsYAML11Frontmatter` also accepts a frontmatter that matches when
read as YAML 1.1 (a server that used PyYAML). `Skill.manifestFingerprint`, a SHA-256 over the
sorted `uri` and `digest` pairs, binds an approval to the files approved.

Duties left to the host: approval and its revocation when the manifest changes, the origin
label (a skill's identity is the server and the URI, never the name), the `allowed-tools` gate,
name collisions within and across servers, fresh consent for nested skills, and not treating a
plain `resources/read` of a `SKILL.md` as a load.

## Alternatives considered

- **A separate `MCPSkills` product for Yams.** Keeps YAML out of apps that never serve skills,
  at the cost of a second product and a split API. The dependency is small (libyaml compiled
  in, no package dependencies) and adding it after 1.0.0 would be a breaking change.
- **Yams' own decoding (`Yams.load`, Codable).** YAML 1.1 resolution: `yes` becomes `true` and
  dates become `Date`, which no longer match the frontmatter other implementations publish.
- **Wrapping the application's `resources/read` handler.** Depends on registration order. Leaving
  it to the application was the other option: easy to forget, and the harness reads skill files
  through `resources/read`.
- **The application assembling `resources/list`, or skills never listed.** The first duplicates
  work in every server; the second makes the harness warn and hides skills from generic
  resource browsers.
- **The skills on pages of their own, before the application's.** A client that reads only the
  first page, as the interop drivers and many hosts do, no longer sees the application's
  resources.
- **Listing every file of every skill in `resources/list`.** Proportional to the catalog; the
  manifest already lists the files, and directories are browsable.
- **Verifying only the digest.** The SEP makes a size mismatch a failure on its own, and checking
  it first rejects a padded read before hashing it.

## Open questions

- No verified cache: a host that wants one keys it on the server identity, the URI and the
  digest. A protocol for it can come later without changing the loader's API.
- The SEP leaves cache hints on `skills/get` open; the SDK sends them, as the harness requires.
- `SkillPackage` reads a directory once; serving a changed directory means building new packages,
  `setSkills(_:)` and a `ResourceListChangedNotification`.
- No interop: no other SDK implements the extension.
