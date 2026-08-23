# Cursor execute — 2026-08-22 15:05 ADT — Direct road-class flatten

**Plan:** `inbox/claude-20260822-1454-turn2.md` + `inbox/codex-20260822-1501.md`
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.

## Knob (one) + turn-1 cleanup

1. Reverted Direct corridor `k` **0.036 → 0.018** (JS + Swift). Matches HEAD.
2. Flattened **Direct road-class only** toward neutral:
   - freeway 1.7 → **1.0**
   - arterial 1.45 → **1.0**
   - ramp 1.6 → **1.0**
   - collector/local/service/track unchanged
3. Direct **surface** table untouched. Balanced / Dirt / Clean untouched.

**Files:** `scripts/pack-fabric/routing/lib/profile-costs.js`, `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift`

## Bench

`npm run bench:ns` local, promoted NS `ns-osm-20260821-02`.

**39 / 65 measured · 38 durable.** Did not revert.

Protected Direct greens held:

| Case | After |
| --- | --- |
| `short-no-fuel/direct/unknown-off/fuel-off` | green 8.1 km |
| `dartmouth-antigonish/direct/unknown-off/fuel-on` | green 237.5 km |
| `musq-sherbrooke/direct/unknown-off/fuel-off` | green 55.2 km |
| `musq-sherbrooke/direct/unknown-off/fuel-on` | green 55.2 km |

Timing (ignore as progress): `dartmouth-capebreton/balanced/fuel-on` still green; `three-waypoint/balanced/fuel-on` red again (4246ms hop). Direct knob cannot cause that.

## Direct-overshoot cluster — 0/5 converted

Lengths match the durable 38 baseline (not the k=0.036 run):

| Case | Baseline | This run |
| --- | ---: | ---: |
| `antigonish-sydney/direct/.../fuel-on` | 237293 | 237293 |
| `antigonish-sydney/direct/.../fuel-off` | 277832 | 277832 |
| `dartmouth-antigonish/direct/.../fuel-off` | 310292 | 310292 |
| `dartmouth-capebreton/direct/.../fuel-off` | 424859 | 424785 |
| `dartmouth-capebreton/direct/.../fuel-on` | 431644 | 431570 |

Codex’s static table counterfactual did not show up in search. Live `majorHighwayAvoidMult` still renormalizes freeway/arterial/ramp to **effective 12.0** whenever table weight < 12 (`target / current`). Flattening 1.7→1.0 is therefore a no-op for the Dijkstra. Not changed this turn (would be a second knob).

## Next

**Codex** — `npm test` + JS↔Swift lockstep (Direct highway class 1.0, `k` 0.018). Confirm no durable/protected green flipped. Verdict for Claude: table flatten rejected as live lever; name `majorHighwayAvoidMult` (Direct-only exception or lower Direct target) as the next single knob if they want the highway spine.
