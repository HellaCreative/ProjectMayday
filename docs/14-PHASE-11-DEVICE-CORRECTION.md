# DIRT Routing — Phase 11 Device Correction

Status: proposed for rider approval; no implementation started  
Evidence: physical From Here test on White, 2026-08-21 17:34 America/Halifax

## What failed

A roughly 510 km From Here route produced two fuel stops. The navigable chain
was:

1. Point 1 → F1
2. F1 → F2
3. F2 → Point 2

The route sheet instead rendered a 510.8 km `Point 1 → Point 2` parent row and
then nested those three actual riding sections underneath it. This expresses two
different hierarchies at once, wastes vertical space, and makes a long itinerary
unmanageable. A Nova Scotia-to-BC route would become one enormous parent leg
with a large collection of subordinate rows.

Plan mode also fails to make every route anchor actionable. Fuel pins exist on
the map, but the alternative-pump interaction is only exposed when a drag begins.
A normal fuel-pin tap or selection from the route sheet does not clearly enter
pump-replacement mode.

Finally, the route-clear action disappears while the fuel-plan list is expanded.
The rider must not have to change planning modes and choose Start Anew simply to
discard a route.

## Confirmed implementation causes

1. `stageListContent` iterates `RiderItinerary.legs` to create an aggregate parent
   card, then appends the matching `BuiltLeg` fuel hops as a second nested card.
2. `stageList` counts both rider legs and built stages when sizing the list,
   reinforcing the duplicated hierarchy.
3. Pump alternatives are populated by `beginPlannerPinDrag`; tap selection does
   not invoke an equivalent state transition.
4. Both From Here and Plan wrap `clearAllButton` in
   `if !fuelLegsExpanded`, explicitly hiding it in the state shown on the device.

## Correct rider-facing vocabulary

- **Rider waypoint:** a persistent point the rider placed: Point 1, Point 2,
  Point 3, and so on.
- **Fuel waypoint:** a generated but visible and replaceable route anchor: F1,
  F2, F3, and so on.
- **Leg:** one rideable section between any two consecutive route anchors,
  whether those anchors are rider waypoints or fuel waypoints.
- **Rider leg:** an internal itinerary ownership boundary between two rider
  waypoints. It remains useful to the canonical model but is not shown as a
  redundant parent row when fuel has divided it.

The route sheet uses the rider-facing definition of **leg**. The canonical
itinerary continues to keep rider waypoints and generated fuel stops separate.

## Proposed correction contract

### 1. Flat leg list

When a fuel plan exists, render exactly one top-level row per `BuiltLeg` and no
aggregate rider-leg parent row.

For the device evidence, the list must show exactly:

1. `Point 1 → F1` — 208.4 km — 82% dirt — Dirt
2. `F1 → F2` — 204.4 km — 51% dirt — Balanced
3. `F2 → Point 2` — remaining km and surface — Dirt

Rows are sequentially numbered 1, 2, 3. There is no nested section and no
duplicate 510.8 km row. The route-level total remains available in the summary
statistics, not as a fake leg.

If there are no generated fuel stops, `Point 1 → Point 2` remains one visible
leg. If Point 3 is added, its built fuel sections simply continue the same flat
ordered list.

### 2. Every visible leg is controllable

- Every row shows endpoints, kilometres, dirt percentage, and current profile.
- The row's profile control applies to that exact built section.
- Changing a section replans from that section's departure anchor forward;
  completed upstream sections remain unchanged.
- Swipe-delete remains a rider-waypoint operation. A generated fuel waypoint is
  replaced or replanned, not silently promoted into a persistent rider waypoint.
- Internal rider-leg ownership remains available for rebuild scope, logging,
  and deleting rider-created waypoints, but is not rendered as another row.

The first section of a rider leg needs an explicit departure-anchor override
path. It cannot clear every downstream hop override merely because its departure
is a rider waypoint rather than a station. This is a model amendment that must be
implemented and tested with the flat list, not hidden in view-only code.

### 3. Fuel waypoint selection and replacement

Tapping F1 or F2 on the map must:

1. select and visually emphasize that fuel waypoint;
2. pulse all graph-valid alternative stations returned for that stop;
3. focus or identify the corresponding adjoining leg in the route sheet;
4. allow a direct tap on an alternative pump to select it;
5. replan from the replaced fuel waypoint forward; and
6. retain all upstream geometry and upstream station identities.

Selecting the fuel waypoint from the route sheet must enter the same state.
Dragging remains an optional direct-manipulation shortcut, not the only way to
discover alternatives. A visible Cancel action exits replacement mode without
changing the itinerary.

### 4. Persistent route clearing

Whenever any route exists:

- From Here exposes `Clear route`.
- Plan exposes `Clear route`.
- Fuel-plan expansion cannot hide it.
- The action sits outside the scrolling leg list so a large itinerary cannot
  push it out of reach.
- It requires one destructive confirmation, then clears rider waypoints,
  generated fuel stops, overrides, route geometry, warnings, and selection state
  and returns the current planning mode to its empty state.

Recommended placement while fuel legs are expanded: a compact red `Clear route`
action in the fuel-plan header beside `Done`. Collapsed and non-fuel states may
retain the existing full-width clear action.

## Model boundary

This correction changes the presentation and control surface, not the canonical
ownership law:

- `RiderItinerary` still stores only rider-created waypoints and rider legs.
- `BuiltItinerary` still derives fuel waypoints and built legs.
- Fuel waypoints do not become rider waypoints merely because they are visible.
- The flat display list is derived from the ordered built chain.
- Fuel-stop replacement remains rider intent through `fuelStopOverrides`.
- Per-section profile intent remains separate from fuel-stop selection.

## Required tests

1. Two rider waypoints plus two fuel stops render exactly three rows and no
   aggregate parent row.
2. A no-stop route renders exactly one row.
3. Multiple rider legs with generated stops render one globally ordered flat
   sequence with correct Point/F endpoint labels.
4. Selecting F1 by map tap and by route-row action produces the same candidate
   set and selected state.
5. Selecting an alternative for F1 retains Point 1 → F1 upstream geometry where
   appropriate and replans from F1 forward.
6. Changing the profile of leg 2 leaves leg 1 byte-identical.
7. Changing the first built section does not erase explicit downstream section
   overrides.
8. `Clear route` is visible in From Here collapsed, From Here expanded, Plan
   collapsed, and Plan expanded states.
9. Clearing removes the full plan and returns to the empty state.
10. A synthetic Nova Scotia-to-BC itinerary with many stops remains a flat,
    scrollable list without nested route hierarchy.

## Acceptance criteria for the next White build

- The 510 km reproduction displays three and only three leg rows.
- F1 and F2 are selectable without first dragging them.
- Valid replacement pumps visibly pulse and can be selected by tap.
- Replacing F1 does not rebuild Point 1 → F1 or discard upstream intent.
- The rider can clear the route from the exact expanded screen shown in the
  evidence without switching modes.
- No map pack or pack manifest change is involved.
