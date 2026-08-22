# Branch reconciliation — 2026-08-22 (decided by Richard)

## Decision

- **Canonical home = `feature/pack-rebuild-2026-08`** (this worktree,
  `Dirt-pack-rebuild`). Chosen because it holds Cursor's ~1.5-day base-OSM pack
  rebuild — the crown jewel — plus the routing-loop blackboard and the pinned
  38/65 NS bench baseline.
- **Codex's branch (`feature/routing-itinerary-rebuild`) code is discarded.**
  Its 29 divergent commits are NOT merged. Only its **intent** is carried over.
- The loop runs in this ONE tree. No two-tree loop. Codex and Cursor operate
  here; Claude is the hub, they are spokes.

## What was captured from Codex (intent, not code)

- `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` — Codex's consolidated
  product/routing source-of-truth doc, copied here as the **base** for the new
  construct. This is the authoritative intent document going forward.
- Fuel-chain direction Codex was reaching for (recorded in SoT §10, preserved as
  the future target, not implemented here):
  1. deploy/verify the current routing service without changing pack bytes;
  2. add an explicit client/service contract-version gate;
  3. replay the 71 km cross-track pump reproduction
     (P1 `44.764823,-63.340271` → P2 `45.636595,-63.056267`, Dirt);
  4. harden whole-chain pump selection with route-coherence rejection + full
     candidate diagnostics;
  5. add that reproduction permanently to the bench/regression suite.

## What was NOT touched

- The 8.0 GB rebuilt packs under `scripts/pack-fabric/app/data/packs/v1/**`.
  `.bin` binaries are gitignored by design (they belong on Cloudflare R2, not
  git). They remain in the working tree, unpromoted. R2 promotion is a separate
  human-gated step.
- Cursor's in-flight tracked edits (`fuel-chain.js`, `GraphV2Pack.swift`,
  `manifest.json`, etc.) and the 136 untracked pack-metadata files — left as
  Cursor's own uncommitted working state to manage in its lane.

## Frozen reference

`feature/routing-itinerary-rebuild` stays as a historical record of Codex's
work. Do not build on it; do not delete it. If more of its doc reconciliation is
wanted later, cherry-pick specific docs onto home — never a blind merge.

## Loop status after reconciliation

Home established, intent captured. Blackboard + SoT committed on home. GATE
remains **OPEN** pending Richard's explicit "go" to start the autonomous loop on
the primed Direct-overshoot turn (`inbox/claude-20260822-1414-plan.md`).
