# Conformance

Fixtures and baselines for the [MCP conformance suite](https://github.com/modelcontextprotocol/conformance)
(`@modelcontextprotocol/conformance`, pinned to `0.2.0-alpha.12` by
`scripts/conformance-harness/package-lock.json`).

| Path | Product | Role |
|---|---|---|
| `everything-server/` | `mcp-everything-server` | Streamable HTTP server on `http://localhost:3001/mcp` (`--port` to change). Routes requests with a stateless `MCP-Protocol-Version` and no session to one shared `Server` on `StatelessHTTPServerTransport`, and the rest to a `Server` per session. |
| `everything-client/` | `mcp-everything-client` | Client the harness starts per scenario. Reads `MCP_CONFORMANCE_SCENARIO`, `MCP_CONFORMANCE_PROTOCOL_VERSION` and `MCP_CONFORMANCE_CONTEXT`. |
| `baseline.yml`, `baseline.<rev>.yml` | | Expected failures per leg. Generated. |

The fixtures use only the public `MCP` API. A failing scenario is fixed in the SDK, not in the
fixture.

## Legs and baselines

| Leg | Command | Baseline |
|---|---|---|
| 2025-11-25 wire | `scripts/run-conformance.sh --spec-version 2025-11-25` | `baseline.2025-11-25.yml` |
| 2026-07-28 wire | `scripts/run-conformance.sh --spec-version 2026-07-28` | `baseline.2026-07-28.yml` |
| default wire | `scripts/run-conformance.sh` | `baseline.yml`; the only leg with extension scenarios (`tasks-*`, the skills `sep-2640-*`, the `auth/` extensions) |
| tier score | `scripts/run-conformance.sh --requirements <rev>` | none; scores the frozen requirement set |

- Every baseline leg runs `--suite all`, including pending and draft scenarios.
- Entries are `<scenario>:<check-id>`, or `<scenario>` for a scenario that produced no checks.
- A run fails on an unlisted failure and on a listed entry that now passes. `WARNING` counts as
  a failure.
- Regenerate with `--update-baseline` in the same change that alters results.
- A tier-scored scenario passes with at least one `SUCCESS` check and no `FAILURE` check
  (`scripts/conformance-score.mjs`).
- Results and logs go to `.build/conformance/<leg>/`.
- Run the harness on Node 22, as CI does. On Node 26 `server-sse-multiple-streams` can end the
  harness with an unhandled promise rejection after its checks pass: Node's web streams reject a
  `pipeTo` write that arrives after the harness cancels the reader, and nothing handles it.
  Whether it happens depends on when the server's events arrive.

## One scenario

```sh
export npm_config_registry=https://registry.npmjs.org
swift build
BIN="$(swift build --show-bin-path)"
H=@modelcontextprotocol/conformance@0.2.0-alpha.12

# server scenario
"$BIN/mcp-everything-server" --port 3001 &
npx --yes $H server --url http://localhost:3001/mcp --scenario <name> --spec-version 2026-07-28

# client scenario
npx --yes $H client --command "$BIN/mcp-everything-client" --scenario <name> --spec-version 2026-07-28

# scenario names in a frozen requirement set
npx --yes $H list --requirements 2026-07-28
```

More: [CONTRIBUTING.md](../CONTRIBUTING.md#conformance), [ROADMAP.md](../ROADMAP.md#conformance).
