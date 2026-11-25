# Versioning and support policy

What a version number of the `mcp-swift-sdk` package promises. Related:
[DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md), [ROADMAP.md](ROADMAP.md),
[docs/migration.md](docs/migration.md).

## Version numbers

Releases are git tags `MAJOR.MINOR.PATCH` and follow [Semantic Versioning](https://semver.org).

- **Major**: breaking changes (defined below).
- **Minor**: new features and every non-breaking change.
- **Patch**: bug fixes only.

Depend on the package with `.upToNextMajor(from: "1.0.0")`. Before 1.0 the minor number played
the role of the major number; [docs/migration.md](docs/migration.md) lists the changes from
0.12.1 to 1.0.0.

## Release branches

Each minor version has one branch, `release-MAJOR.MINOR`, and its releases are tags on that
branch: `release-1.0` carries `1.0.0`, `1.0.1`, `1.0.2`. A patch release needs no branch of its
own. [Kubernetes](https://github.com/kubernetes/kubernetes) works the same way.

- `main` develops the next minor or major version.
- `release-X.Y` is cut from `main` for `X.Y.0`. After that it takes bug fixes only, released as
  patch versions.
- A fix lands on `main` first. It is then cherry-picked (`git cherry-pick -x`) onto each release
  branch that ships it, in a pull request into that branch. A fix for code that only a release
  branch has goes straight to that branch, and its pull request says why.
- `X.Y.0` is tagged on a commit that `main` has too, so on `main` the `api-breakage` job compares
  with the newest minor version. Patch tags exist only on their release branch, and there the job
  compares with the newest patch.
- CI runs on pull requests into, and pushes to, `main` and every `release-*` branch.

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
- Adding a case to a public enum ([Enums and open types](#enums-and-open-types)). The package is
  built without library evolution, so client `switch` statements are exhaustive and stop
  compiling.
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
- New members on structs, including new static members of an open type.
- Support for a new protocol revision that leaves the defaults unchanged.
- Bug fixes that make the SDK match its documentation or the specification. When such a fix
  changes wire behavior that clients may rely on, it is called out in the release notes.
- Deprecations.

Allowed in a patch: bug fixes that change no public API.

## Enums and open types

Every public enum is one of three kinds, and its documentation says which:

| Kind | Promise | When the protocol adds a value |
|---|---|---|
| Frozen enum | No case is added in a minor release; switch exhaustively | Cannot happen: an external definition closes the set |
| Enum with an `unknown` case | No case is added in a minor release | It arrives through the `unknown` case; a minor release may add a typed accessor |
| Open type (a struct) | New static members in minor releases; a `switch` needs a `default` | A new static member |

| Kind | Types |
|---|---|
| Frozen | `ID`, `ProgressToken`, `Value`, `LogLevel`, `Prompt.Message.Role`, `Sampling.Message.Role`, `Resource.Annotations.Audience`, `CreateElicitation.Result.Action`, `Sampling.ContextInclusion`, `Elicitation.RequestSchema.SchemaType`, `Icon.Theme`, `CompletionReference`, `Sampling.Message.Content`, `OAuthConfiguration.ApplicationType`, `OAuthConfiguration.PrivateKeyJWTAssertionError`, `OAuthConfiguration.EnterpriseIdentityProvider.Endpoint`, `Client.ProtocolMode`, `HTTPResponse`, `AcceptHeaderValidator.Mode` |
| `unknown` case | `Tool.Content`, `Prompt.Message.Content`, `Sampling.Message.Content.ContentBlock`, `Sampling.ToolResultContent.ContentBlock`, `InputRequest`, `InputResponse`, `CreateElicitation.Parameters`; `MCPError`, where `serverError(code:message:data:)` plays that role |
| Open | `OAuthAuthorizationError` and its `Code`, `MCPError.Code`, `OAuthConfiguration.GrantType`, `OAuthConfiguration.TokenEndpointAuthentication`, `OAuthConfiguration.PrivateKeyJWTSigningAlgorithm`, `BearerTokenValidationResult`, `Elicitation.Mode`, `CreateSamplingMessage.ToolChoice.Mode`, `ResultType`, `CacheScope` |

How a type is classified:

1. Its values are closed by an external definition (JSON-RPC 2.0, the JSON data model,
   RFC 5424, OpenID Connect, CSS) or by the SDK's own structure: frozen.
2. Otherwise it is extensible when its values grew between 2024-11-05 and 2026-07-28, or a
   registry or a pending SEP adds more.
3. An extensible type without associated values, or one that users only construct: open type.
4. An extensible type that users pattern-match with associated values (errors, content): an
   enum with an `unknown` case, which keeps those patterns working.

Enums without cases (`Version`, `MetaKey`, `HTTPHeaderName`, the `Method` types) are
namespaces; new members are additions. A type added in 1.x for a growing set starts as an open
type.

## Specification revisions and releases

| Change | Release |
|---|---|
| Serve a new revision, opt-in for clients | minor |
| Make a new revision the client default, or add it to `Version.supported` | major |
| Change behavior at an already supported revision to match the specification | minor, with release notes |
| Drop a revision | major |

1.0.0 follows that rule: it serves 2026-07-28, adds it to `Version.supported`, and
makes `ProtocolMode.automatic` the client default ([docs/migration.md](docs/migration.md)).

## Support window for older revisions

- Every revision in `Version.handshake` (2024-11-05 through 2025-11-25) stays supported for the
  whole major version.
- A revision is dropped only in a major release, and only after a minor release that announced
  it in the release notes and in [ROADMAP.md](ROADMAP.md).
- Protocol features that the specification deprecates follow the specification's timeline. The
  SDK keeps them working on connections that negotiate a revision that has them. The list:
  [Deprecated by the specification](docs/rough_edges.md#deprecated-by-the-specification).

## Deprecation

- A public API on its way out is marked `@available(*, deprecated, message:)` with its
  replacement (for example `Version.latest`, replaced by `Version.latestHandshake`).
- A deprecated API keeps working for at least one minor release and is removed only in a major.
- Every removal and every breaking change between majors is described in
  [docs/migration.md](docs/migration.md), with before and after code, in the same change.

## Release notes

Each release lists breaking changes first, then features, fixes, dependency changes and
deprecations, in [CHANGELOG.md](CHANGELOG.md). Pull requests with a breaking change say so in their description
([CONTRIBUTING.md](CONTRIBUTING.md#pull-requests)).
