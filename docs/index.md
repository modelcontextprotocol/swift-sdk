# docs/index.md

The MCP Swift SDK docs site anchor. This folder is the **published documentation layer** the MCP SDK Tiering System (SEP-1730) asks for at Tier 2 (`basic documentation covering core features`) and the minimum before Tier 1 (`comprehensive documentation with examples for all features`).

Nothing here repeats the README. The README (`README.md`) is the single-source usage guide (client / server / transports / auth). This folder is the **scannable reference layer**:

| File | Purpose |
|---|---|
| `usage/` | Where to find every API surface in the README, by feature |
| `dependency-policy.md` | Published dependency policy (also at repo root as `DEPENDENCIES.md`) |
| `roadmap.md` | Public plan toward Tier 1 (also `ROADMAP.md` at root) |
| `contributing.md` | Contribution workflow (points at `CONTRIBUTING.md` on the primary branch) |
| `tier-status.md` | Current tier + evidence index (keeps this audit reviewable) |

## How to update

- Adding a feature? Add a short entry under `usage/` and cross-link from `README.md`.
- Changing the dependency policy? Update `DEPENDENCIES.md` **and** `dependency-policy.md`.
- Adding a roadmap step? Update `roadmap.md` and its summary line.

<!-- verified 2026-11-26 · swift-sdk fork at feature/mcp-2026-07-28-clean2 · upstream org = modelcontextprotocol/swift-sdk@main · tier criteria sourced from SEP-1730 (modelcontextprotocol.io/community/sdk-tiers.md) -->
