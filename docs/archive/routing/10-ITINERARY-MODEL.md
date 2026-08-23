# Canonical itinerary model

> **DECOMMISSIONED:** This is no longer a separate canonical document.
> Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

> **Supporting authority:** this is the canonical internal ownership and
> mutation model. Product meaning, rider-facing routing laws, release state, and
> current work priority are maintained in
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

The planner has one durable source of rider intent: `RiderItinerary`. It owns an
ordered list of rider waypoints (`1 → 2 → 3 → …`), the deterministic legs between
them, the current generation, and reported impassable edge IDs. It never contains
fuel stops, route geometry, or routing progress.

Phase 10 item 8 adds rider intent for generated fuel hops without promoting
pumps into waypoints: each `RiderLeg` may hold `hopOverrides[stationID] = profile`.
The key is the station a hop departs from. Changing one override preserves built
hops through that station and replans forward; changing the leg profile clears
the leg's overrides. Overrides for stations absent from the replacement chain
are pruned after a successful build.

Phase 11 deliberately adds a second, distinct kind of rider intent for moving a
generated pump. `fuelStopOverrides[departureAnchorID] = chosenStationID` says
which pump must follow a particular departure anchor. The anchor is the rider
waypoint ID for the first fuel hop or the preceding station ID for a later hop.
It is not stored on a derived `FuelStop`, and it is not combined with
`hopOverrides`: one chooses a station while the other chooses a routing profile.
The builder validates every requested pump with forward two-step reachability,
replans from the departure anchor, and prunes overrides whose anchor or chosen
station disappears from the accepted replacement chain. Changing a rider-leg
profile clears both kinds of override on that leg.

An accepted fuel gap is also rider intent. `acceptedFuelGapIDs` contains only
deterministic fingerprints of the current built gap: rider-leg ID, bracketing
anchors, usable range, and gap metres. Acceptance means “I will manage
additional fuel”; it never invents litres, changes range, or turns an unproved
station chain into a proved one. Any route, range, reserve, waypoint, station,
profile, access, or pack-revision change produces a different fingerprint and
therefore requires a new acknowledgement.

`RoutePlannerModel.apply(_:source:)` is the single mutation door. Append, insert,
move, delete, profile, access, fuel rebuild, and impassable actions go through the
pure `ItineraryReducer`. Every real change advances the generation and identifies
the first rider leg that must be rebuilt. Drag moves alone are coalesced for 420 ms.

`ItineraryBuilder` turns canonical intent into an immutable `BuiltItinerary`.
`BuiltLeg` contains route geometry, surface results, carried fuel, and an optional
derived `FuelStop`. Fuel stops reset the tank but never become rider waypoints.
Earlier unaffected legs may be reused; the edited leg and everything after it are
rebuilt without attachment to old geometry. Progress is committed one rider leg at
a time, and generation checks discard stale asynchronous results.

The core invariants are:

- `legs.count == max(0, waypoints.count - 1)`.
- Each leg connects adjacent waypoint IDs in order.
- Waypoint IDs are unique and leg IDs are deterministic from their endpoints.
- Fuel-stop geometry and ordering exist only in built output; canonical fuel
  identity appears only in station-keyed hop profiles and explicit
  departure-anchor fuel-stop overrides.
- A fuel gap remains derived output. Only its exact deterministic acceptance
  fingerprint may be persisted as rider intent.
- One touch resolves to one of pin, route, or map, in that order.

Every canonical edit emits `itinerary action=… source=… gen=…` with coordinates for
geometry-changing actions. Builds emit their generation, rebuild boundary, source,
progress, fuel reset/carry events, and final commit/drop/failure. These lines are a
replayable contract; see `docs/itinerary-refactor/REPLAY.md`.

Routing is supplied through `RoutingSource`. Online planning selects the live
source; offline planning and mid-ride recovery select an installed pack. The
builder is source-independent, so fuel, progressive reveal, reuse, and generation
rules are identical in both modes.
