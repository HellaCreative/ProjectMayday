# Fuel gap contract

Phase 11 implementation contract. This document defines planner behaviour; it
does not change road or fuel data in any map pack.

## Assumptions

- Every planned itinerary begins with a full tank at Point 1.
- A packed fuel station and a rider waypoint derived within 150 m of one reset
  the tank.
- Fuel consumption remains routed metres until the later surface-economy phase.
  DIRT reports shortages in kilometres and never fabricates litres.
- Fuel planning is always attempted. Failure to prove a station chain never
  discards an otherwise valid route.

## States

Each rider leg has one fuel state in derived output:

- `ready`: every generated hop is proven route-connected and within usable range.
- `gap`: the route is known, but no complete station chain is proven. The result
  contains the best reachable prefix, the last reachable anchor, the first
  downstream station or rider waypoint reachable from the far side, routed gap
  metres, and `overByMeters = max(0, gapMeters - usableRangeMeters)`.
- `unknown`: route geometry is known, but fuel data is unavailable, unreadable,
  or unavailable from both the selected live/installed source. This is not a
  claim that no pumps exist.
- `failed`: routing geometry itself could not be produced. Fuel-chain failure
  alone never creates this state.

The gap is measured along the selected profile's routed geometry between its
bracketing anchors. Straight-line or raw graph distance is never presented as
fuel demand.

## Builder behaviour

- The builder keeps the rider route and progressively commits every proven hop.
- It makes at most two materially different backtrack attempts within one
  itinerary-wide budget. Attempt one requires a later final station derived from
  the following leg's first reachable station. Attempt two requires an additional
  station before that final station. A repeated ordered station-set signature
  stops immediately.
- Exhaustion returns `gap`; unavailable fuel data returns `unknown`; neither spins.
- A rider waypoint on a station is a derived reset and may bracket a gap.

## Rider acknowledgement

`I'll carry fuel` acknowledges the exact current gap fingerprint. It does not
change range, estimate volume, or suppress the gap. The row changes to
`Fuel gap acknowledged · N km beyond planned range` and remains visible.

Gap acknowledgement is available for every route profile. Fuel physics does not
change between Dirt, Balanced, Direct, and Clean.

## Start and export

- Start remains available with acknowledged or unacknowledged gaps.
- Before Start, every unacknowledged gap is shown in a confirmation sheet. The
  rider may review the leg, acknowledge it, or continue without acknowledgement.
- GPX export remains available. It writes visible `FUEL GAP START` and
  `FUEL GAP END` waypoints plus a route description containing the shortage in
  kilometres. A GPX must never contain a silent gap.
- Unknown fuel state is likewise visible in the card, Start confirmation, and
  GPX description.

## Offline and navigation boundary

Online planning uses live graph and fuel data. Offline planning uses installed
packs. A missing installed fuel sidecar produces `unknown`, not a false no-pump
claim. Tracking actual fuel consumed after Start is deferred to the navigation
audit; Phase 11 continues to model a full tank at Point 1 and resets at pumps.

## Long-haul planning

Routes requiring more than three generated pumps may offer `Build quickly using
Clean sections`. The rider must explicitly accept it. Clean remains pavement-
first, urban-wall, and major-highway-avoiding; it is not described as shortest
path. The selected route profile is never silently overwritten.
