# Cursor build — 2026-08-22 19:36 ADT — per-hop ride type + Allow Unknown

**Shipped.** No stash pop. No packs / manifest. No Vercel. Auto fuel-pick / fuel-chain WIP untouched.

## Found

From Here (and Plan) fuel hops showed per-row Dirt/Clean/Allow chips, but
`setStageProfile` / `setStageAllowUnknown` wrote the **shared `riderLegID`**.
One From Here A→B rider leg owns F1/F2 hops, so changing hop 2 to Clean then hop 3
to Dirt collapsed all three rows back to Dirt. Plan rider-leg pairs (no fuel)
already worked.

## Fix

`RiderItinerary.hopOverrides` keyed by fuel-stop identity (or rider-leg id for the
tail hop). Fuel-expanded sheet rows call `setHopProfile` / `setHopAllowUnknown`.
The builder routes each subleg with that hop's policy and replans from the edited
hop forward, reusing upstream hops and preserving the existing fuel chain.

Applies to From Here and Plan (same stage chips / builder).

## Test

Focused suites (`RoutePlannerModelItineraryTests`, `ItineraryBuilderTests`,
`RiderItineraryTests`, `FuelAssistTests`) — **TEST SUCCEEDED**.

- `fromHereFuelHopsEditRideTypeAndAllowIndependently` — **PASS**
  From Here, two fuel stops, three hops. Leg 2 → Clean, leg 3 → Dirt →
  `[Dirt, Clean, Dirt]`. Allow Unknown on hop 3 only. Hop 1 geometry reused;
  hop 2 reused when only hop 3 Allow changes.
- Replace-F1 / replace-F2 / Plan per-rider-leg profile tests remain green.

NS bench **not run** (itinerary-only; 41/65 stands).

## Key files

- `Dirt/Features/RoutePlanning/Itinerary/{RiderItinerary,ItineraryAction,ItineraryReducer,ItineraryBuilder,ItineraryLog}.swift`
- `Dirt/Features/RoutePlanning/RoutePlannerModel.swift`
- `DirtTests/Itinerary/RoutePlannerModelItineraryTests.swift`

## Next agent: Codex

Code check: hop overrides are independent; editing hop 2 does not rewrite hop 1
ride type; Allow Unknown is per-hop; only edited hop + forward reroutes; no
pack/manifest/deploy/fuel-pick edits.
