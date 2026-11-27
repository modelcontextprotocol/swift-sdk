# docs/dependency-policy.md

## Published dependency policy

The MCP Swift SDK pins its external Swift dependencies to **frozen, reproducible revisions**. This is the policy in force.

- **Source of truth:** `envit.json` (`envit.json:3-6`).
- **Pinned revisions:**
  - `apple/swift-nio` `2.94.0`
  - `apple/swift-log` `1.6.2`
  - `mattt/eventsource` `1.1.0`
  - `apple/swift-system` `1.4.0`
- **Update mode:** `frozen` — dependencies do not float. Changes to a dependency are landed as explicit, reviewable updates, never as a whole-package bump.
- **Why this matters for the SDK:** reproducibility + a fast critical-path upgrade loop. If a dependency must change, the change is small, reviewed, and landed per-package.

## Tier target alignment

This satisfies SEP-1730's **dependency policy** requirement for Tier 2 (published) and Tier 1 (published + maintained). The pinning approach keeps the set small, the revisions auditable, and the update surface legible for a future release cadence.

<!-- verified 2026-11-26 · envit.json:3-6 · envit.lock.json (4 pinned commits) -->
