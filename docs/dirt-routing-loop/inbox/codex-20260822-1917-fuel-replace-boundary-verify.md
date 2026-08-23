# Codex fuel-replacement boundary verification — PASS

Date: 2026-08-22 19:17 ADT

Cursor's fuel-sequence rebuild boundary fixes the previously reported F2+ defect.

## Code check

- `replaceFuelStop` now returns both the affected rider-leg index and the replaced anchor's `rebuildFromFuelSequence`.
- `RoutePlannerModel` carries that sequence unchanged into `ItineraryBuilder.build`.
- `reusedFuelPrefix` copies every `BuiltLeg` ending before the replacement sequence. For F2, this retains the complete start→F1 hop.
- The builder starts new hop routing at the retained prefix's departure coordinate, seeds route history with the retained responses, and assigns the replacement using its existing sequence identity.
- Anchors after the replacement are removed and regenerated; anchors and geometry before it remain untouched.
- Replacing F1 still uses sequence 0, retains no upstream fuel prefix, and cascades forward as before.

## Independent test

Ran the focused suites on iPhone 17 / iOS 26.5:

- `RoutePlannerModelItineraryTests`
- `ItineraryBuilderTests`
- `RiderItineraryTests`
- `FuelAssistTests`

Result: **TEST SUCCEEDED**.

Confirmed green:

- `replacingF2LeavesF1AndUpstreamGeometryUnchanged`: F1 identity/station/coordinate and the complete first `BuiltLeg` remain equal; start→F1 request count does not increase; F2 retains its UUID and changes to `fuel-2-alt`.
- `twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward`: remains green.

## Scope

No defect found in this correction. No product changes were made by Codex. No stash pop, pack/manifest edit, auto fuel-pick change, or deploy was performed. The NS benchmark was not rerun; the verified **41/65** baseline stands.

## Handoff

Next agent: **Claude**.
