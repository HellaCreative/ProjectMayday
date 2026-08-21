# DIRT Routing — Active Project State

Point-in-time record: 2026-08-21  
Active project lead: Codex  
Branch: `feature/routing-itinerary-rebuild`

This is an operating record, not a handoff. It captures what Phase 11 changed,
what has been verified, what still requires a physical device test, and which
known routing findings remain deliberately open.

## Product law in force

- DIRT builds rides, not fastest trips.
- Fuel continuity is part of producing a navigable ride. It is not an optional
  routing mode.
- Dirt works back from the most dirt available, Balanced targets 50/50, Direct
  follows the destination bearing with a narrow journey corridor, and Clean
  stays paved while treating urban cores and major highways as obstacles.
- Long-distance planning may use Clean-generated fuel sections to establish a
  fast, viable chain. The rider's requested route profile remains visible and
  individual sections remain editable.
- Rider waypoints and generated fuel stops are different concepts. Generated
  fuel stops never become rider waypoints.
- When a complete fuel chain cannot be proven, the route remains explorable as
  an explicit fuel gap. Start and GPX export remain available, but the gap must
  never be hidden.
- Online planning uses the live pack. Installed packs support offline planning
  and rerouting. Phase 11 did not rebuild, modify, promote, or upload map packs.

## Phase 11 implemented

### Itinerary-wide fuel planning

- Fuel planning now runs forward across the entire itinerary after rider legs
  are routed.
- Point 1 begins with a full tank. Fuel is carried across ordinary rider
  waypoints instead of being reset at every leg boundary.
- A rider waypoint within 150 m of a packed station is derived as a refuel and
  resets the tank for the following leg.
- Reused rider-leg routes retain their route response, but fuel is always
  recomputed from leg 0 after an edit.
- Candidate selection considers both surface quality and whether the choice
  leaves a viable continuation into the next rider leg.
- A rider-selected fuel station is stored separately from a per-hop route
  profile in `fuelStopOverrides`.

### Bounded recovery instead of circular retries

- Fuel windows are limited to six seconds and the itinerary fuel operation is
  limited to twenty seconds, including preliminary station lookahead.
- Recovery is capped at two retries.
- A deterministic station-set signature stops no-op retry loops.
- Transport failures, time-budget exhaustion, and a repeated station set retain
  the routed geometry and become labelled fuel gaps rather than destroying the
  route.
- The route-cache key retains normalized prior-edge inputs so a cache hit cannot
  silently reintroduce backtracking.

### Rider-visible fuel behavior

- The fuel on/off toggle has been removed. The planner always considers fuel.
- Range and reserve controls live in a compact map fuel panel. Recalculation is
  committed when the slider interaction ends.
- A gap row explains the unproven section and offers relevant rider actions,
  including moving a waypoint, selecting another pump, or acknowledging carried
  auxiliary fuel.
- Starting with an unacknowledged gap requires an explicit confirmation.
- GPX export writes visible `FUEL GAP START` and `FUEL GAP END` markers and a
  route-level warning.
- Generated fuel pins can be moved to graph-valid station candidates. The
  itinerary replans forward from the changed stop.
- Existing rider-leg rows remain canonical. Fuel hops remain expandable beneath
  the rider leg and do not become independent rider stages.

### Live and offline parity

- Forced-station selection is supported by both the live service and installed
  pack planner.
- Installed-pack candidate validation performs the same forward-connectivity
  check used by the live path.
- The server returns the station identity and metadata needed by the client to
  preserve rider intent across replans.

## Verification completed

- JavaScript routing and fuel tests: 70 passed; 1 intentionally skipped.
- Focused fuel-chain tests: 15 passed.
- iOS device-target `build-for-testing`: succeeded.
- Swift coverage includes itinerary-wide carry, waypoint station reset, forced
  fuel-stop selection, retained geometry on fuel-service failure, and visible
  GPX gap markers.
- Impeccable hardening review found no outstanding detector findings in the
  changed route-planning views.

## Fixed-pin benchmark

Authoritative result:
`scripts/pack-fabric/bench/results/6caa62e-20260821T201513Z.json`

- Code under measurement: `6caa62e`
- Live NS source: `ns-osm-20260821-02`
- Deterministic matrix: 40 always-fuel cases
- Result: **35/40 green**
- Compare target: `10e38b5`
- No new green-to-red Phase 11 fuel regression was introduced.

The five red rows remain measured work, not hidden failures:

1. Short route, Balanced: 38% dirt instead of 45–55%.
2. Musquodoboit–Sherbrooke, Balanced: 58% dirt instead of 45–55%.
3. Through Halifax, Dirt with unknown off: baseline graph route not found.
4. Through Halifax, Balanced with unknown off: baseline graph route not found.
5. Through Halifax, Direct with unknown off: baseline graph route not found.

The Halifax pins snap to permissive OSM edges for all adventure profiles. That
narrows the remaining failure to graph connectivity/search behavior after snap,
not an ineligible snapped edge.

## Awaiting production and physical validation

The following are not complete until the matching routing service and client are
deployed and exercised on White:

1. Deploy the Phase 11 live routing/fuel service.
2. Install the matching signed client on White.
3. Confirm a short route produces no generated stop when the usable range covers
   it.
4. Confirm a 350–450 km route produces visible, sequential fuel stops without a
   backtrack.
5. Add Point 3 after fuel planning and confirm the whole itinerary replans fuel
   forward without discarding unchanged route geometry.
6. Move a fuel pin and confirm only that stop and downstream fuel hops change.
7. Force a low-range gap and confirm the route remains visible, the warning is
   honest, Start requires confirmation, and GPX contains gap markers.
8. Put a rider waypoint on a station and confirm it becomes a derived refuel with
   no duplicate generated stop.
9. Move that waypoint away from the station and confirm the derived refuel is
   removed on rebuild.
10. Repeat one viable test offline with the NS pack installed to confirm behavior
    matches the live path.

## Next routing work after Phase 11 acceptance

1. Diagnose the three Halifax unknown-off connectivity failures without moving
   the benchmark pins.
2. Tighten Balanced scoring on the two measured surface misses.
3. Add and run the long cross-region BC–SK fuel benchmark when BC/SK candidate
   data is available in the benchmark environment.
4. Audit navigation-time remaining-fuel state. Phase 11 models planning from a
   full tank at Point 1; fuel already consumed when an active rider requests an
   offline reroute remains a separate navigation concern.
5. Investigate precomputed Clean routing only as a measured, separate project.
   No precomputed-Clean pack material was added in Phase 11.

## Governing documents

- `docs/08-MAP-REFINEMENT.md` — locked routing laws.
- `docs/09-OSM-PACK-QUALITY-STANDARD.md` — locked pack quality and release gate.
- `docs/10-ITINERARY-MODEL.md` — canonical itinerary and rider-intent model.
- `docs/12-FUEL-GAP-CONTRACT.md` — Phase 11 gap behavior and safety contract.

This document should be updated at each accepted routing milestone. It is the
current operational truth while Codex remains point on the project.
