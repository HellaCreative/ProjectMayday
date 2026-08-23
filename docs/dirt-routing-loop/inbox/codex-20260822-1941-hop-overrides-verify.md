# Codex per-hop overrides verification — PASS

Date: 2026-08-22 19:41 ADT

Cursor's per-hop ride type and Allow Unknown correction passes code review and independent focused tests.

## Code check

- `RiderItinerary.hopOverrides` persists independent profile/access policy by hop identity: a fuel-ending hop uses that fuel stop's stable UUID; the final destination hop uses the rider-leg UUID.
- Fuel-expanded stage controls dispatch `setHopProfile` / `setHopAllowUnknown` with the visible hop's identity and sequence. Non-fuel Plan rows continue to use the existing rider-leg actions.
- The reducer mutates only the selected override, forces Allow Unknown off for Clean, preserves the current fuel anchors, and sets the rebuild cursor to the edited hop sequence.
- The builder reuses every earlier `BuiltLeg`, seeds history from those hops, and applies `hopPolicy` independently to each newly routed subleg.
- Because policy edits set `preserveFuelStops`, the existing chain remains fixed rather than invoking auto fuel selection again.
- Fuel replacement remains compatible: replacement retains the selected stop's identity/override and removes later anchors and later hop overrides before cascading forward.

## Independent test

Ran the focused suites on iPhone 17 / iOS 26.5:

- `RoutePlannerModelItineraryTests`
- `ItineraryBuilderTests`
- `RiderItineraryTests`
- `FuelAssistTests`

Result: **TEST SUCCEEDED**.

Confirmed green:

- `fromHereFuelHopsEditRideTypeAndAllowIndependently`: three hops resolve to `[Dirt, Clean, Dirt]`; only hop 3 has Allow Unknown; hop 1 is reused after editing hop 2, and hops 1–2 are reused after editing hop 3.
- `twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward`.
- `replacingF2LeavesF1AndUpstreamGeometryUnchanged`.
- Existing Plan rider-leg profile/reuse coverage.

## Scope

No defect found. Codex made no product changes. No stash pop, pack/manifest edit, auto fuel-pick change, or deploy was performed. The NS benchmark was not rerun; the verified **41/65** baseline stands.

## Handoff

Next agent: **Claude**.
