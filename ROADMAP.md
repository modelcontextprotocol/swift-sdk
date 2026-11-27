# ROADMAP.md

MCP Swift SDK — public roadmap. Tracks the path from **Tier 3 (Experimental)** toward **Tier 1 (Fully Supported)** per SEP-1730.

Legend: ✅ met · ⏳ in-progress · ❓ blocked

## Current state (as of 2026-11-26)

| Requirement | Tier 2 | Tier 1 | Actual |
|---|---|---|---|
| Conformance tests | 80% | 100% | ✅ 100% on the 2026-07-28 revision (`rel/1.0.0` @ `5c3af99`) |
| New protocol features | within 6 mo | before each spec release | ✅ shipped 2026-07-28 stateless rev in `rel/1.0.0` |
| Stable release | ≥1 stable release | 1.0.0+ clear versioning | ✅ `rel/1.0.0`, semantic versioning |
| Documentation | basic core features | comprehensive, examples | ⚠️ README only; `docs/` landing (this folder) |
| Dependency policy | published | published | ✅ `DEPENDENCIES.md` + `envit` pinned |
| Roadmap | published plan | published roadmap | ✅ this file |

## Goals

- **Q1 (this quarter):** Ship `docs/` (usage reference + index + contributing pointer), `DEPENDENCIES.md`, and `ROADMAP.md`. These close the Tier-2 documentation and dependency-policy gaps.
- **Q2:** Open the tier-advancement issue in the MCP org (`modelcontextprotocol/modelcontextprotocol`) with this file + the conformance evidence; request SDK WG review.
- **Q3:** Strengthen `docs/` to Tier-1 (examples for all features), stand up issue triage (≤2 business days), and publish the Tier-1 conformance runs on `main`.

## Risks / blockers

- **Triage cadence** — no published SLA yet; Tier 1 needs ≤2 business-day triage and ≤7-day critical-bug resolution.
- **CI signal** — conformance for `main` runs as PR-gated CI; a non-PR `main` gate is not yet publishing.
- **Conformance baseline** — `conformance-baseline.yml` is currently `client: []`; it should be reconciled against the passing suite before the Tier-1 claim is made.

<!-- verified 2026-11-26 · SEP-1730 criteria · upstream swift-sdk@main state (2026-11-26) -->
