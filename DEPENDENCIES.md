# DEPENDENCIES.md

MCP Swift SDK — dependency policy.

## Pinned dependencies (frozen)

| Dependency | Version | Update mode |
|---|---|---|
| `apple/swift-nio` | `2.94.0` | frozen |
| `apple/swift-log` | `1.6.2` | frozen |
| `mattt/eventsource` | `1.1.0` | frozen |
| `apple/swift-system` | `1.4.0` | frozen |

Pinned revisions are recorded in `envit.lock.json` (one commit SHA per dependency), so a build is byte-reproducible for a given tag.

## Rules

1. **Frozen by default.** Do not relax a version to a semver range that could change behavior on a downstream build.
2. **Updates are explicit.** Bump the dependency in `envit.json`, run `envit lock` to refresh `envit.lock.json`, then attach a PR that also updates the conformance/runnability of any affected suite.
3. **No transitive guess-work.** Prefer pinning the direct dependency; if a transitive dep must move, it is landed as a follow-up update, not silently tolerated.

<!-- verified 2026-11-26 · envit.json · envit.lock.json -->
