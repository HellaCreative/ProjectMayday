# Cursor execute — 2026-08-22 15:22 ADT — Direct majorHighwayAvoidMult

**Plan:** Claude hub redirect (skip standalone turn-2 Codex verify; fold into this turn).
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.

## Knob (one)

`majorHighwayAvoidMult()` returns **1 for Direct** (no 12× highway clamp). Balanced / Dirt / Clean unchanged (still target 12.0). Turn-2 Direct freeway/arterial/ramp **1.0** kept so the table is the highway cost.

Chose “no penalty” over target ~1.5: with Direct paved 1.15, a 1.5× avoid still makes the 219.9 km highway lose to the 279 km minor-road path.

**Files:** `scripts/pack-fabric/routing/lib/profile-costs.js`, `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift`

## Bench

`npm run bench:ns` local, promoted NS `ns-osm-20260821-02`.

**40 / 65 measured · 39 durable.** Did not revert. No protected / durable green flipped.

Protected Direct greens held (and shortened):

| Case | Before | After |
| --- | ---: | ---: |
| `short-no-fuel/direct/unknown-off/fuel-off` | 8.1 green | **7.4 green** |
| `dartmouth-antigonish/direct/unknown-off/fuel-on` | 237.5 green | **233.0 green** |
| `musq-sherbrooke/direct/unknown-off/fuel-off` | 55.2 green | **55.1 green** |
| `musq-sherbrooke/direct/unknown-off/fuel-on` | 55.2 green | **55.1 green** |

## Direct-overshoot cluster — 1/5 converted; all 5 shorter

| Case | Baseline km | This run km | Line | Result |
| --- | ---: | ---: | ---: | --- |
| `antigonish-sydney/direct/.../fuel-on` | 237.3 | **234.8** | 234.9 | **GREEN** |
| `antigonish-sydney/direct/.../fuel-off` | 277.8 | **253.7** | 234.9 | still red (−24 km) |
| `dartmouth-antigonish/direct/.../fuel-off` | 310.3 | **297.3** | 243.5 | still red (−13 km) |
| `dartmouth-capebreton/direct/.../fuel-off` | 424.9 | **374.0** | 335.7 | still red (−51 km) |
| `dartmouth-capebreton/direct/.../fuel-on` | 431.6 | **384.0** | 335.7 | still red (−48 km) |

Timing (not progress): `three-waypoint/balanced/fuel-on` green this run; `dartmouth-capebreton/balanced/fuel-on` red on 4373ms hop.

## Next

**Codex** — CONTRACT safety gate: `npm test`, JS↔Swift lockstep (Direct avoidMult=1, highway class 1.0, `k` 0.018). Confirm protected greens held and `antigonish-sydney/direct/fuel-on` is a real Direct conversion. Remaining overshoot still red; do not stack another knob this pass.
