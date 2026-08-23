# Cursor execute — 2026-08-22 16:43 ADT — spec-alignment (re-baseline)

**Plan:** CONTRACT Mode spec + exception (Rick greenlit). Not a one-knob experiment.
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.

## What landed

1. **Reverted Direct cost damage (turns 1–4)**
   `git checkout HEAD -- profile-costs.js OnDeviceProfileCosts.swift`
   Direct is again dirt-biased + highway-avoiding:
   - surface paved 1.15 / gravel 1.00 / access 0.95 / track 0.90
   - freeway 1.7 / arterial 1.45 / ramp 1.6
   - `majorHighwayAvoidMult` target 12 (no Direct exemption)
   - Direct `k` 0.018
   Balanced / Dirt / Clean tables unchanged vs HEAD (balanced paved 1.42, dirt paved 16, cleanest paved 1).

2. **Corridor widths (JS + Swift lockstep)**

   | Constant | Before | After |
   | --- | ---: | ---: |
   | `DIRECT_CORRIDOR_M` | 15000 | **25000** |
   | `BALANCED_CORRIDOR_M` | 40000 | **25000** |
   | `DIRT_CORRIDOR_M` | 50000 | **60000** |
   | `DIRT_CORRIDOR_MAX_M` (new) | unbounded `Infinity`/`nil` | **80000** (Dirt only, after 60 km fails) |

   Direct and Balanced search **one** hard band. No multiplier ladder. No unbounded last attempt.
   Dirt searches 60 km; 80 km only if that search is empty.

3. **Direct bench assert retired**
   Was: `length ≤ shortest+15km`
   Now: `dirt ≥ 60%` AND `maxCrossTrackMeters ≤ DIRECT_CORRIDOR_M` (25 km).
   Bench now threads `debug.searchMeta.maxCrossTrackMeters` into the result.

## Files (this turn)

Allowed / requested:
- `scripts/pack-fabric/routing/lib/hop-search.js`
- `scripts/pack-fabric/routing/lib/find-path-v2.js` (width loop; Allowed)
- `Dirt/Routing/OnDevice/OnDeviceRouter.swift`
- `scripts/pack-fabric/bench/run-ns-bench.js` (user: retire Direct assert)

Lockstep SoT / tests (not on Allowed list; required for the constants to exist in Swift and for `npm test`):
- `Dirt/Routing/HopSearchPolicy.swift` — Swift corridor constants live here, not in OnDeviceRouter
- `scripts/pack-fabric/routing/lib/hop-search.test.js`
- `DirtTests/ItineraryRebuildTests.swift`

Did **not** wire Balanced `surfaceMultiplier` into `searchBalancedResource` (that was a different job).

## Verify

- `npm test`: **59 pass, 1 skip, 0 fail**
- `npm run bench:ns` local, promoted NS `ns-osm-20260821-02`
- **38 / 65 green — NEW BASELINE.** Green drop is expected. Did not auto-revert.

## Direct under the new assert

Every **completed** Direct route passed `corridor ≤25km`. Remaining Direct reds are dirt% or `no_route`.

| Case | km | Dirt | xt m | Result |
| --- | ---: | ---: | ---: | --- |
| `dartmouth-capebreton/direct/fuel-off` | 424.9 | **66%** | 16181 | **GREEN** (was overshoot-red) |
| `dartmouth-antigonish/direct/fuel-off` | 310.3 | **69%** | 17366 | **GREEN** (was overshoot-red) |
| `short-no-fuel/direct` | 8.1 | 19% | 2207 | red dirt (was shortest-green) |
| `musq-sherbrooke/direct` fuel-off/on | 55.2 | 40% | 3876 | red dirt (was shortest-green) |
| `dartmouth-antigonish/direct/fuel-on` | 237.5 | 52% | 21323 | red dirt (was shortest-green) |
| `antigonish-sydney/direct/fuel-off` | 317.7 | 50% | 24632 | red dirt |
| `three-waypoint/direct/fuel-off` | 477.0 | 57.9% | 18962 | red dirt (close) |
| `three-waypoint/direct/fuel-on` | 623.5 | 49% | 21916 | red dirt |
| `dartmouth-capebreton/direct/fuel-on` | — | — | — | `no_route` (hard 25 km, no unbounded) |
| `antigonish-sydney/direct/fuel-on` | — | — | — | `no_route` |
| `through-halifax/direct/*` | — | — | — | `no_route` (unchanged class) |

Old “protected Direct greens” (`short-no-fuel`, `musq-sherbrooke`, `antigonish-sydney/fuel-on`) were shortest-assert greens with low dirt. The new spec correctly fails them.

## Other notable shifts from the cap

- `dartmouth-capebreton/balanced/fuel-on` and `antigonish-sydney/balanced/fuel-on`: **new `no_route`** (40 km + unbounded → 25 km hard).
- Dirt fuel-off longs still ≥70% (Cape Breton 84%, Dartmouth–Antigonish 87%, musq 92%, Antigonish–Sydney 82%, three-waypoint 82%).
- Balanced fuel-off longs still in band (50 / 50 / 51 / 48.2). `musq-sherbrooke/balanced` still 40% — surface table unused (`costMode: balancedResource`).

## Codex

Independent `npm test` + `npm run bench:ns`. Confirm JS↔Swift corridor constants lockstep (hop-search.js ↔ HopSearchPolicy.swift). Confirm Direct costs match HEAD. **Accept 38/65 as the new baseline** — do not reject on green drop. One-knob rule resumes after this turn. No Vercel. No stash pop.
