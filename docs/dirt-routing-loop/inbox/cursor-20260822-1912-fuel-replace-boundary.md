# Cursor build — 2026-08-22 19:12 ADT — fuel replace forward-only boundary

**Shipped.** No stash pop. No packs / manifest. No Vercel. Auto fuel-pick / fuel-chain WIP untouched.

## Defect

Replacing F2+ rebuilt the rider leg from the rider-leg start, so earlier hops (F1, start→F1) could be re-chained.

## Fix

`replaceFuelStop` now sets `rebuildFromFuelSequence` to the replaced stop's sequence. The builder copies reuse hops whose fuel sequence is **below** that cursor, then replans from the replaced stop's departure anchor (F1 when replacing F2). Pinned prefix starts at that sequence, not 0. Later rider legs still rebuild from fuel sequence 0.

## Test

Focused suites (`RoutePlannerModelItineraryTests`, `ItineraryBuilderTests`, `RiderItineraryTests`, `FuelAssistTests`) — **TEST SUCCEEDED**.

- `replacingF2LeavesF1AndUpstreamGeometryUnchanged` — **PASS** (F1 identity/station/geometry unchanged; no extra start→F1 route; F2 id stable, station `fuel-2-alt`)
- `twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward` — **PASS** (kept green)

NS bench **not run** (itinerary-only; 41/65 stands).

## Key files

- `Dirt/Features/RoutePlanning/Itinerary/ItineraryReducer.swift`
- `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift`
- `Dirt/Features/RoutePlanning/RoutePlannerModel.swift`
- `DirtTests/Itinerary/RoutePlannerModelItineraryTests.swift`

## Next agent: Codex

Code check: replacing F2 must not mutate F1 or any geometry upstream of F2; replace-F1 cascade still holds; no pack/manifest/deploy/fuel-pick edits.
