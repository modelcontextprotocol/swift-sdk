# Versioning and support policy

What a version number of the `mcp-swift-sdk` package promises. Related:
[DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md), [ROADMAP.md](ROADMAP.md),
[docs/migration.md](docs/migration.md).

## Version numbers

Releases are git tags `MAJOR.MINOR.PATCH` and follow [Semantic Versioning](https://semver.org).

- **Major**: breaking changes (defined below).
- **Minor**: new features and every non-breaking change.
- **Patch**: bug fixes only.

The package is before 1.0. Under SemVer, a 0.x release may break in a minor increment, so while
the version starts with `0.`, the minor number plays the role of the major number: a breaking
change increments `0.X.0`, and anything else increments the patch number. In this document,
"major" means that position. Depend on the package with `.upToNextMinor(from:)` while it is 0.x.

## The public API

Covered:

- Every `public` declaration of the `MCP` module: names, signatures, protocol requirements,
  enum cases, and documented behavior.
- Wire behavior for each negotiated revision: what the SDK sends and what it accepts.
- Defaults: configuration defaults, default handlers, default validators.
- Supported platforms, the Swift tools versions of the manifests, and the major versions of
  dependencies.

Not covered:

- `internal` and `package` declarations.
- The conformance fixtures (`conformance/`), `Examples/`, `scripts/` and tests.
- The text of log messages and error descriptions. Error cases and codes are covered.

## Breaking changes

Held for a major:

- Removing or renaming a public declaration.
- Changing a signature, a return type, or a protocol requirement, including adding a
  requirement without a default implementation.
- Adding a case to a public enum (for example `MCPError` or `OAuthAuthorizationError`). The
  package is built without library evolution, so client `switch` statements are exhaustive and
  stop compiling.
- Changing documented behavior so that working code stops working.
- Changing wire behavior for a revision that already shipped: messages sent, validation applied,
  error codes returned.
- Changing a default: `Client.Configuration.protocolMode`, `Server.Configuration.protocolVersions`,
  `Server.init(requestStateProtection:)`, cache hints, validation pipelines.
- Dropping a protocol revision from `Version.handshake`, `Version.stateless` or
  `Version.supported`.
- Raising a platform minimum or the Swift tools version of a manifest.
- Moving a dependency to a new major version or adding a dependency to the `MCP` target
  ([DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md)).

Allowed in a minor:

- New declarations, new types, new protocol requirements with default implementations.
- New parameters with default values on functions that are not protocol requirements.
- New members on structs.
- Support for a new protocol revision that leaves the defaults unchanged.
- Bug fixes that make the SDK match its documentation or the specification. When such a fix
  changes wire behavior that clients may rely on, it is called out in the release notes.
- Deprecations.

Allowed in a patch: bug fixes that change no public API.

## Specification revisions and releases

| Change | Release |
|---|---|
| Serve a new revision, opt-in for clients | minor |
| Make a new revision the client default, or add it to `Version.supported` | major |
| Change behavior at an already supported revision to match the specification | minor, with release notes |
| Drop a revision | major |

0.13.0 follows that rule: it serves 2026-07-28, adds it to `Version.supported`, and makes
`ProtocolMode.automatic` the client default, so it is a major release in the 0.x sense above
([docs/migration.md](docs/migration.md)).

## Support window for older revisions

- Every revision in `Version.handshake` (2024-11-05 through 2025-11-25) stays supported for the
  whole major version.
- A revision is dropped only in a major release, and only after a minor release that announced
  it in the release notes and in [ROADMAP.md](ROADMAP.md).
- Protocol features that the specification deprecates follow the specification's timeline. The
  SDK keeps them working on connections that negotiate a revision that has them.

## Deprecation

- A public API on its way out is marked `@available(*, deprecated, message:)` with its
  replacement (for example `Client.initialize()`, replaced by `connect(transport:)`).
- A deprecated API keeps working for at least one minor release and is removed only in a major.
- Every removal and every breaking change between majors is described in
  [docs/migration.md](docs/migration.md), with before and after code, in the same change.

## Release notes

Each release lists breaking changes first, then features, fixes, dependency changes and
deprecations. Pull requests with a breaking change say so in their description
([CONTRIBUTING.md](CONTRIBUTING.md#pull-requests)).
