# Scoreboard

Updated by **Cursor** after every `npm run bench:ns` (or noted “not run”).

## Current

| Field | Value |
| --- | --- |
| As of | 2026-08-22 17:40 ADT |
| Green | **41 / 65** |
| Durable note | Rick spec: Balanced bench band **35–65%**. +3 conversions, no green flips. Routes unchanged (assert only). `antigonish-sydney/balanced/fuel-on` still `no_route` (25 km cap). Ladder next is still **45**. |
| Source | `scripts/pack-fabric/bench/results/latest.md` + `a965d91-20260822T204051Z.json` |
| Ladder | 38 → **41** (this turn) → **45** (next) → 50 → 56 |
| Last turn | Clean-sections default gated to **≥1000 km OR >3 pumps** (was any fuel stop). Inbox `cursor-20260822-1952-longhaul-clean-gate.md`. Fix landed in Dirt itinerary-rebuild `ItineraryBuilder.swift`. Bench not run. 41/65 stands. |

## Red clusters (work these in order)

1. **Direct dirt ≥60** — corridor holding. Remaining: `short-no-fuel/direct` 19%, `musq-sherbrooke/direct` 40%, `antigonish-sydney/direct/fuel-off` 50%, `dartmouth-antigonish/direct/fuel-on` 52%, `three-waypoint/direct` 57.9%/49%.
2. **Fuel-on `no_route` (25 km hard cap)** — `dartmouth-capebreton/{balanced,direct}/fuel-on`, `antigonish-sydney/{balanced,direct}/fuel-on`. Not a band problem.
3. **Dirt fuel-on dirt% / chain** — `dartmouth-capebreton/dirt/fuel-on` 62.8%, `dartmouth-antigonish/dirt/fuel-on` 54%, `antigonish-sydney/dirt/fuel-on` 25%; `three-waypoint/dirt/*/fuel-on` no_route_connected_fuel_chain.
4. **Through-halifax** — Dirt/Balanced/Direct still `no_route`; Clean fuel-on 20% dirt.

Do not expand this list mid-turn. Claude may re-rank in `inbox/claude-*.md` then Cursor updates this section.

## History

| When | Green | Note |
| --- | ---: | --- |
| 2026-08-21 `f129df4` | 38 | Promoted NS + ≤4000ms/hop — prior durable baseline |
| 2026-08-22 16:43 | **38 / 65 NEW BASELINE** | Spec-alignment |
| 2026-08-22 17:01–17:21 | 38 / 65 | Balanced surface table live + Swift compile fix |
| 2026-08-22 17:33 | 37 / 65 | Balanced paved 1.70 **REJECTED**. Reverted. |
| 2026-08-22 17:35 | 38 / 65 | Post-revert restore |
| 2026-08-22 17:40 | **41 / 65** | Balanced bench band 35–65 (Rick). +3: short-no-fuel 44%, musq 40%/40%. |

## Pack / live notes (fabric)

- CA: promoted stable. US: live-candidates via `R2_REGION_BASE_OVERRIDES`.
- This turn: **no** Vercel deploy, **no** pack rebuild, **no** R2 promote. Fuel-chain WIP remains in `stash@{0}`/`@{1}` — not popped.
