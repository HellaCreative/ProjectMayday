# Codex fuel-replacement verification — DEFECT FOUND

Date: 2026-08-22 18:56 ADT

Cursor's focused itinerary/fuel suites pass independently, and most of the shipped contract is present. One forward-only boundary is not satisfied.

## Independent test

Ran the iPhone 17 / iOS 26.5 focused suites:

- `RoutePlannerModelItineraryTests`
- `ItineraryBuilderTests`
- `RiderItineraryTests`
- `FuelAssistTests`

Result: **TEST SUCCEEDED**, including `twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward` and `fuelReplacementRequiresTwoStepReachability`.

## Verified

- Generated stops receive distinct UUIDs, persist through `fuelAnchors`, and are reused by rider-leg/sequence during rebuild. Map and sheet rows address the UUID rather than a shared rider-leg ID.
- Replacement candidates are marked valid only when both previous→candidate and candidate→next graph distances fit their respective caps. Only valid candidates pulse and `selectFuelAlternate` rejects invalid candidates.
- Replacing a stop pins its stable identity, removes later anchors, and recomputes downstream stops. Rider waypoint and rider-leg identities are preserved.
- Fuel markers and candidate markers are locked against map dragging; model movement accepts only `wp:` markers in Plan and none in From Here.
- Fuel-expanded rows cannot be deleted through `canDeleteStage`; `canDeleteFuelStop` is always false.

## Defect — replacement of F2+ can reroute an earlier hop

`replaceFuelStop` returns `rebuildFrom: legIndex`, where `legIndex` is the rider-leg index. The builder can reuse only complete rider legs before that index. For multiple fuel stops inside one rider leg, replacing F2 rebuilds that rider leg from its original rider waypoint. `consecutivePinnedStops` retains F1 as a waypoint, but the builder calls `source.route` again for original start→F1 before routing F1→new F2.

Therefore the implementation is forward-only across rider-leg boundaries, but not across fuel-hop boundaries inside the same rider leg. An unchanged F1 identity/station may receive changed upstream geometry. The current cascade test replaces F1, so it cannot detect this.

Recommended single hypothesis for Cursor: add subleg-prefix reuse keyed by the replaced fuel anchor (or an equivalent rebuild cursor), and add a test that replaces F2 in a two-stop rider leg while asserting the complete start→F1 `BuiltLeg` is reused unchanged and only F1-forward requests are made.

No product code was changed during this verification. No stash pop, pack/manifest touch, or deploy.

## Handoff

Next agent: **Claude** to decide whether strict hop-level forward-only behavior is required before ride testing and, if so, plan the single correction above.
