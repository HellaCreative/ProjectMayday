# DIRT Routing — Phase 11 Device Correction

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

> **2026-08-22 release erratum:** an exact production `/api/fuel-chain` replay
> reports the older `candidateK=3` planner and old candidate payload, while the
> current repository uses six geographically distinct candidates and richer
> forward-validity diagnostics. The production alias therefore cannot presently
> be treated as a proven match for the current client/repository. The deployment
> statement below records what was attempted at the time; current fuel acceptance
> is blocked until a service contract/version proves the match. See
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md#10-current-blocking-defect--2026-08-22).

Status: rider-approved; implementation verified locally and deployed to production
Evidence: physical From Here and Plan tests on White, 2026-08-21

## Implementation checkpoint — 2026-08-21

Implemented in the current working phase:

- route rows are the flat ordered `BuiltLeg` chain; aggregate rider-leg parent
  rows and nested fuel-hop rows are removed;
- fuel stops required by a rider leg use a Clean connectivity foundation, while
  each visible Point/F section retains its own profile control;
- selecting a fuel waypoint from the map or its row reveals graph-valid pump
  alternatives, and selecting an alternative records a fuel-stop override and
  replans forward;
- `Clear route` remains reachable with the fuel list expanded;
- planning chrome is limited to routing tools, route overview/recenter, and the
  compass; navigation-only 3D, cue, and rider-status controls appear only after
  navigation starts;
- overlapping pack rectangles are candidate discovery only. The shared server
  resolver proves an eligible edge within 500 m in the primary graph, then
  checks overlapping packs only when the primary cannot snap. The exact NS/PEI
  overlap reproduction is covered by an automated test;
- a transport error, timeout, decode error, or server failure is no longer
  converted into a proven fuel gap; and
- a failed rider leg remains visible in the route sheet with its original
  endpoints and failure reason.

No graph, fuel, map, or manifest pack bytes changed. The endpoint correction is
runtime selection logic. The matching routing service was deployed to production
as Vercel deployment `dpl_Cz45cYuCXcrtdE2nER3G9tmy2t7M` before the White build.

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

A second Plan test added Point 1 in Nova Scotia, Point 2 in New Brunswick, and
Point 3 in Quebec. The first cross-region leg began as Balanced, the long second
leg took too long, no fuel chain was committed, and the UI offered auxiliary
fuel even though live viewport queries saw dense station coverage.

A third Plan test placed both rider waypoints inside Nova Scotia, one near
`45.874661,-61.910289` and one near `43.651303,-65.684758`. Both visibly touched
mapped roads. Routing failed immediately with `No eligible edge within 500 m of
start (hop 1/3)`, then the sheet displayed the empty-plan instructions while both
waypoint pins remained on the map.

Moving Point 1 from the original mapped road to a more major highway allowed the
same plan to route and place fuel stops. This confirms that the route and fuel
chain are possible and isolates the failure to endpoint region/snap resolution.
It is not acceptable recovery behavior: an eligible NS road must not require the
rider to relocate to a major highway merely because PEI's coarse rectangle
overlaps the coordinate.

## Confirmed implementation causes

1. `stageListContent` iterates `RiderItinerary.legs` to create an aggregate parent
   card, then appends the matching `BuiltLeg` fuel hops as a second nested card.
2. `stageList` counts both rider legs and built stages when sizing the list,
   reinforcing the duplicated hierarchy.
3. Pump alternatives are populated by `beginPlannerPinDrag`; tap selection does
   not invoke an equivalent state transition.
4. Both From Here and Plan wrap `clearAllButton` in
   `if !fuelLegsExpanded`, explicitly hiding it in the state shown on the device.
5. Initial route discovery decides long-haul from straight-line distance greater
   than three usable tanks. It does not treat crossing a region boundary as an
   immediate Clean-foundation requirement.
6. For some routes the builder first requests a complete adventure-profile route,
   calculates its distance, and only then changes discovery to Clean. This spends
   the expensive work before applying the speed policy.
7. The long-haul log reason is hard-coded as `more_than_3_stops`, even when the
   actual trigger was endpoint distance. This makes diagnosis misleading.
8. A fuel timeout or transport failure is converted into a derived `.gap`. The
   card therefore offers `I'll carry fuel` even though the solver did not prove
   that a chain was impossible.
9. Region ownership is inferred from overlapping rectangular bounding boxes.
   The northern NS coordinate also falls inside the coarse PEI rectangle, and
   the smallest-box rule incorrectly assigns it to PEI. The server consequently
   manufactures a PEI/NB/NS three-hop chain for a route wholly inside NS and
   attempts to snap an NS road point against the PEI graph.
10. A baseline routing failure can leave rider waypoints and map pins intact while
    the legacy stage projection becomes empty. The card then tells the rider to
    place Point 1 and Point 2 again instead of showing the failed Point 1 → Point
    2 row and a recovery action.

## Second device evidence: confirmed timeline

The exported log `dirt-app-debug-2026-08-21T204445Z.txt` shows:

- 20:37:58 — NS → NB started as `balanced`, cross-region, live source.
- 20:38:04 — its 521.7 km discovery route required two fuel stops.
- 20:38:14 — NB → QC was appended; its discovery request used `cleanest`.
- 20:38:48 — the client logged a long-haul Clean default only after route
  discovery had been running.
- 20:39:42 — the itinerary fuel budget was exceeded with zero recovery attempts;
  the service returned regional segment 1/2 as an unconnected chain.
- 20:41:07 — a subsequent production fuel request ended in Vercel
  `FUNCTION_INVOCATION_TIMEOUT` (504).
- Live viewport requests reported up to 84 packed stations during the test.

The test used a Phase 11 client against the prior production service because the
matching Phase 11 Vercel deployment was rejected by the daily deployment quota.
The client-side hierarchy, clearing, and policy evidence is valid. The live fuel
result is a mismatched-release result and is not an acceptance test of the new
server implementation.

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

### 5. Clean-foundation policy before the first request

A newly created rider leg starts as Clean when either condition is true:

- its endpoints resolve to different province/state packs; or
- endpoint straight-line distance is at least 1,000 km.

This policy runs before any route request. It does not run Balanced or Dirt first
and then fall back. The card shows Clean immediately so the rider sees the actual
foundation being built.

The Clean foundation follows the existing DIRT law: paved, avoids urban cores,
avoids major highways, and is optimized for fast connectivity rather than a
Google-style fastest arrival. After the fuel chain exists, the rider may change
each flat fuel leg to Dirt, Balanced, Direct, or Clean independently.

A cross-region leg below 1,000 km still starts Clean because a pack seam is
itself a foundation-routing condition. A leg longer than 1,000 km within one
region also starts Clean because distance is sufficient on its own.

### 6. Linear long-route construction

For a Clean-foundation leg, the builder must not calculate a monolithic A → B
adventure route and then retrofit pumps. It builds the navigable chain forward:

1. Start at the current rider/fuel waypoint with the current remaining range.
2. Request at most three forward fuel stops with a six-second service budget.
3. Commit each completed route section through `onProgress` as soon as it is
   available.
4. Continue from the last committed pump in another bounded window.
5. Route to the destination when it becomes reachable within range.
6. Stop after the itinerary-wide budget with a retryable planning failure—not a
   fabricated proof of no fuel.

This is the linear behavior the product had when pumps appeared progressively on
the map. The provisional route ahead of the last committed pump is disposable;
the rider has never accepted or ridden it.

### 7. Proof-gated auxiliary fuel

`I'll carry fuel` is a last-resort rider decision. It is shown only when the
solver returns a completed, auditable proof that no route-connected packed pump
chain satisfies the current range.

The fuel result state must distinguish:

- **planned:** a complete pump chain exists;
- **proven gap:** eligible station data was present, all bounded alternatives
  were exhausted, and no chain exists;
- **fuel data unavailable:** the required live/installed station source could
  not be read;
- **planning interrupted:** timeout, cancellation, server 5xx, decode error, or
  connectivity failure;
- **route seam failure:** pumps may exist, but a regional graph connection could
  not be proven.

Only **proven gap** exposes `Move waypoint` and `I'll carry fuel`. Interrupted,
unavailable, and seam states expose `Retry fuel planning` plus an honest reason.
They never claim the rider needs auxiliary fuel.

The server proof payload must include candidate counts, regions searched,
rejected-chain reason categories, and an `exhaustive=true` marker. A bare 422,
504, or client budget expiry is never exhaustive proof.

### 8. Matching client/server acceptance

No further device fuel acceptance is valid until the Phase 11 server deployment
and the matching client build are both live. The app should expose a diagnostic
service contract/version so a mismatched client can report `Routing service
update required` instead of producing misleading fuel behavior.

### 9. Authoritative region ownership and eligible-edge snap

Rectangular pack bounds remain useful for quickly finding candidate regions, but
they are not province/state ownership truth and must not decide a route chain.

Endpoint resolution becomes a two-stage operation shared by client and server:

1. Use a compact, versioned province/state coverage geometry to determine the
   administrative owner of each rider waypoint. The geometry is generated once
   from the same OSM administrative boundaries and consumed by both Swift and
   JavaScript.
2. Validate that ownership by snapping against the nearest profile-eligible graph
   edge within 500 m. Where boundary geometry or islands produce more than one
   candidate, probe each candidate pack and choose the closest eligible edge.

The resolved endpoint record contains region ID, edge ID, access class, snap
distance, and resolver version. Route chaining uses those resolved region IDs,
never raw bounding-box overlap.

This is routing metadata, not a graph-pack rebuild. Existing graph and fuel pack
bytes remain unchanged. The same coverage artifact ships with the app/server so
online and offline decisions cannot disagree.

For `45.874661,-61.910289`, the resolver must return NS and an NS eligible edge.
For `43.651303,-65.684758`, it must also return NS. The resulting request is one
NS route, not a three-hop regional chain.

If no eligible edge exists after probing the correct region and adjacent boundary
candidates, report which coordinate failed, which regions were probed, nearest
edge distance/access in each, and an actionable `Move Point N` control. Never
label an internally generated seam hop as the rider's start point.

### 10. Preserve the rider's failed plan

A routing failure does not erase or hide rider intent:

- Point 1 and Point 2 remain in `RiderItinerary` and on the map.
- The route sheet shows a `Point 1 → Point 2` failed row.
- The row carries the precise reason and `Move Point 1`, `Move Point 2`, Retry,
  and Clear route actions as appropriate.
- Empty-plan guidance appears only when fewer than two rider waypoints exist.
- A failed baseline route does not invoke fuel planning and does not expose fuel
  gap or auxiliary-fuel actions.

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
11. NS → NB begins Clean before the first route request.
12. A same-region endpoint chord of at least 1,000 km begins Clean before the
    first route request.
13. A short same-region leg retains the rider-selected profile.
14. A long Clean foundation commits fuel sections progressively and never waits
    for a monolithic adventure route before displaying its first pump.
15. A 504, timeout, decode failure, or cancellation never exposes auxiliary fuel.
16. Only a response with `exhaustive=true` can produce a proven gap and expose
    auxiliary fuel.
17. A client/server contract mismatch blocks fuel acceptance with an honest
    service-version message.
18. The two Nova Scotia reproduction coordinates both resolve to NS and generate
    a single-region request.
19. A coordinate in the NS/PEI bounding-box overlap resolves using coverage
    geometry and eligible graph edges, not smallest rectangle.
20. Every province/state overlap fixture resolves identically in Swift and
    JavaScript.
21. A genuine cross-region endpoint pair still produces the correct region chain.
22. A failed two-waypoint route retains both waypoints and renders one failed leg
    row with recovery and Clear route actions.
23. Fuel planning is not invoked after a baseline edge-snap failure.

## Acceptance criteria for the next White build

- The 510 km reproduction displays three and only three leg rows.
- F1 and F2 are selectable without first dragging them.
- Valid replacement pumps visibly pulse and can be selected by tap.
- Replacing F1 does not rebuild Point 1 → F1 or discard upstream intent.
- The rider can clear the route from the exact expanded screen shown in the
  evidence without switching modes.
- NS → NB and NB → QC both show Clean immediately when their rider legs are
  created; no Balanced discovery request precedes Clean.
- Fuel stops appear progressively in bounded forward windows.
- Dense station coverage cannot be represented as a proven fuel gap merely
  because the service timed out.
- The Nova Scotia north-to-south reproduction is resolved as NS → NS and no
  longer emits `hop 1/3` or probes PEI for the start edge.
- Failed routing leaves the rider's waypoints visible and editable in the sheet.
- No map pack or pack manifest change is involved.
