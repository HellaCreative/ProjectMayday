# Cursor execute — 2026-08-22 14:38 ADT — Direct corridor tax

**Plan:** `inbox/claude-20260822-1414-plan.md`
**Knob (one):** Direct `directCrossTrackExtra` / `corridorCrossTrackExtra` `k` **0.018 → 0.036** (2×). Balanced 0.014 and Dirt 0.005 unchanged.

**Files:**
- `scripts/pack-fabric/routing/lib/profile-costs.js`
- `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` (lockstep)

**Bench:** `npm run bench:ns` local against promoted NS `ns-osm-20260821-02`. No Vercel deploy.

**Green: 38 → 40 / 65.** No former green flipped red. Did not revert.

## Protected greens (held)

| Case | After |
| --- | --- |
| `short-no-fuel/direct/unknown-off/fuel-off` | still green (8.1 km) |
| `dartmouth-antigonish/direct/unknown-off/fuel-on` | still green (237.4 km) |
| `musq-sherbrooke/direct/unknown-off/fuel-off` | still green (55.2 km) |
| `musq-sherbrooke/direct/unknown-off/fuel-on` | still green (55.2 km) |

## Direct-overshoot cluster (target) — 0/5 converted

| Case | Before | After | Line (shortest+15km) |
| --- | ---: | ---: | ---: |
| `antigonish-sydney/direct/.../fuel-on` | 237293 | 237296 | 234886 |
| `antigonish-sydney/direct/.../fuel-off` | 277832 | 279040 | 234886 |
| `dartmouth-antigonish/direct/.../fuel-off` | 310292 | 312888 | 243531 |
| `dartmouth-capebreton/direct/.../fuel-off` | 424859 | 428234 | 335735 |
| `dartmouth-capebreton/direct/.../fuel-on` | 431644 | 427133 | 335735 |

Hypothesis did not bite. Fuel-off lengths mostly grew a few km; fuel-on Cape Breton shrank ~4.5 km and is still ~91 km over the line.

## Where +2 came from (not the cluster)

These were red on hop-time, now green; dirt% unchanged:

- `dartmouth-capebreton/balanced/unknown-off/fuel-on` — hop 6712ms → under 4000ms (route still 375.6 km / 50.5% dirt)
- `three-waypoint/balanced/unknown-off/fuel-on` — hop 4896ms → under 4000ms (route still 602.3 km / 50.7% dirt)

Treat as machine-load / hop-budget noise, not proof the Direct knob moved Balanced.

## Bench note

Dirty `routing/lib/fuel-chain.js` WIP requires missing `../regional/endpoint-resolver` and blocked `bench:ns`. Bench ran against **HEAD** fuel-chain; WIP was restored afterward. Do not treat this turn as a fuel-chain change.

## Next

**Codex** — CONTRACT safety gate: `npm test`, JS↔Swift lockstep on the `k` change, confirm no protected green flipped. Cluster still red; do not stack the surface-table fallback this turn (plan: revert first if going that way — greens did not drop, so patch stays unless Codex finds a lockstep/`npm test` fail).
