# Cursor build — 2026-08-22 18:50 ADT — fuel-stop identity + replacement

**Shipped.** No stash pop. No packs / manifest. No Vercel. Auto fuel-pick quality untouched.

## What landed

Each generated fuel stop now has a stable UUID (`FuelStop.id` + `RiderItinerary.fuelAnchors`). From Here hops still share a rider leg, but F1/F2 are distinct identities. Tapping an F pin (map or sheet row) enters replace mode. Valid alternates pulse; invalid ones can still show. Selecting a valid alternate pins that stop and rebuilds **forward only**. Fuel stops remain non-deletable and non-draggable.

Applies to From Here and Plan (same `ItineraryBuilder` / `replaceFuelStop` path).

## Test

`RoutePlannerModelItineraryTests.twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward` — **PASS**

Two auto fuel stops → replace F1 with `fuel-1-alt` → F1 id stable + station changed, F2 recomputed to `fuel-2b`, rider waypoints/leg id unchanged, cannot delete, drag ignored.

Also: `FuelAssistTests.fuelReplacementRequiresTwoStepReachability` **PASS**. Itinerary suites (`RoutePlannerModelItineraryTests`, `ItineraryBuilderTests`, `RiderItineraryTests`, `FuelAssistTests`) **TEST SUCCEEDED**.

## Key files

- `Dirt/Features/RoutePlanning/Itinerary/{BuiltItinerary,RiderItinerary,ItineraryAction,ItineraryReducer,ItineraryBuilder,RoutingSource}.swift`
- `Dirt/Features/RoutePlanning/RoutePlannerModel.swift`
- `Dirt/Map/{MapState,MapLibreMapView}.swift`
- `Dirt/App/AppEnvironment.swift`
- `Dirt/Features/RoutePlanning/RoutePlannerCard.swift`

## Out of scope (parked)

- Auto fuel-pick quality / live Gulf miss (SoT §10) — deploy.
- Per-hop ride-type (still one `riderLegID` for From Here fuel hops).
- Rider-waypoint free movement.

## Next agent: Codex

Code check: identity uniqueness, replace-mode validity (two-step reachability), forward cascade, no delete/drag, tests actually prove the claim. Do not change product unless you find a defect Codex is asked to report.
