# Scoreboard

Updated by **Cursor** after every `npm run bench:ns` (or noted “not run”).

## Current

| Field | Value |
| --- | --- |
| As of | 2026-08-22 (seeded from last committed bench; re-run to refresh) |
| Green | **38 / 65** |
| Source | `scripts/pack-fabric/bench/results/latest.md` (git `f129df4`, promoted NS pack) |
| Ladder | 38 → **45** (next) → 50 → 56 |
| Last turn | loop folder created; no new router patch yet |

## Red clusters (work these in order)

1. **Dirt fuel-on loses dirt% and/or exceeds 4s/hop** — e.g. `dartmouth-capebreton/dirt/.../fuel-on`, `dartmouth-antigonish/dirt/.../fuel-on`
2. **Balanced off 45–55** — e.g. `short-no-fuel/balanced/...`, `musq-sherbrooke/balanced/...`
3. **Direct overshoot** — e.g. `dartmouth-capebreton/direct/...`, `dartmouth-antigonish/direct/fuel-off`
4. **Through-halifax / three-waypoint** — no_route or fuel-chain failures (see latest.md)

Do not expand this list mid-turn. Claude may re-rank in `inbox/claude-*.md` then Cursor updates this section.

## History

| When | Green | Note |
| --- | ---: | --- |
| 2026-08-21 (old candidate assert era) | ~56 | Pre-promote / looser hop budget — not the current baseline |
| 2026-08-21 `f129df4` | 38 | Promoted NS + ≤4000ms/hop — **current baseline** |
| 2026-08-22 | — | Loop started |

## Pack / live notes (fabric)

- CA: promoted stable. US: live-candidates via `R2_REGION_BASE_OVERRIDES`.
- Fuel backfill 2026-08-22: me/nh/nv/wy candidates re-shipped with `fuel.v1.json`.
- Acceptance theme dump: `scripts/pack-fabric/routing/data/reports/pack-rebuild-2026-08/ACCEPTANCE-TRIAGE.md` (secondary to NS bench).
