# Canonical itinerary model

The planner has one durable source of rider intent: `RiderItinerary`. It owns an
ordered list of rider waypoints (`1 → 2 → 3 → …`), the deterministic legs between
them, the current generation, and reported impassable edge IDs. It never contains
fuel stops, route geometry, or routing progress.

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
- Fuel identity exists only in built output.
- One touch resolves to one of pin, route, or map, in that order.

Every canonical edit emits `itinerary action=… source=… gen=…` with coordinates for
geometry-changing actions. Builds emit their generation, rebuild boundary, source,
progress, fuel reset/carry events, and final commit/drop/failure. These lines are a
replayable contract; see `docs/itinerary-refactor/REPLAY.md`.

Routing is supplied through `RoutingSource`. Online planning selects the live
source; offline planning and mid-ride recovery select an installed pack. The
builder is source-independent, so fuel, progressive reveal, reuse, and generation
rules are identical in both modes.
