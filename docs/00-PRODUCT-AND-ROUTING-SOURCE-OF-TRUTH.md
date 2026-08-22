# DIRT — Product and Routing Source of Truth

**Authority:** canonical product, routing, fuel, pack-source, and current-state document

**Owner:** Richard Smith

**Primary engineering agent:** Codex

**Last reconciled:** 2026-08-22

**Repository:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`

**Branch:** `feature/routing-itinerary-rebuild`

This is the first document to read before changing DIRT routing. It exists so a
new session does not revive a superseded idea, treat an old phase report as
current, or repair one path by breaking another.

If another document conflicts with this one about current product behaviour,
current release state, or work priority, **this document wins**. The locked map,
pack, itinerary, and fuel-gap documents remain authoritative for their narrower
technical contracts unless this document explicitly records a later rider
decision.

## 1. What DIRT is

DIRT is an adventure-routing and navigation product for dual-sport motorcycle
riders. The ride is the activity. Getting from one point to another quickly is
not the product.

The product must let a rider:

1. create a route whose character matches the selected riding profile;
2. understand the road-surface and access assumptions used to create it;
3. include a physically viable fuel chain as part of the route;
4. inspect and edit rider waypoints, fuel waypoints, profiles, and access policy;
5. save or export the resulting ride;
6. download the map corridor and routing packs needed for participation;
7. navigate inside that corridor with or without cellular service; and
8. report an obstruction and reroute, backtrack, or recover while offline.

Google Maps and Waze optimize arrival. DIRT creates the riding experience
between the points. Distance and speed may constrain feasibility, but they do
not silently replace the selected ride objective.

## 2. Routing profiles

### Dirt

- Works backward from the highest achievable dirt percentage, conceptually
  starting at 100%.
- May use the widest corridor and may meander when that earns meaningful dirt.
- Does not consume the available corridor merely because it exists.
- Rejects arbitrary backward travel, lateral tourism, loops, and backtracking
  when they do not materially improve the ride.
- Shortest distance is not an objective.
- A result near Balanced is not acceptable merely because it connects; a low
  dirt result must be labelled and supported by evidence about the eligible
  fabric or a search limit.

### Balanced

- Targets the closest feasible result to 50% dirt and 50% paved.
- Uses a narrower corridor than Dirt because it is allowed less journey.
- Does not optimize shortest distance.
- A miss must be labelled with the closest connected result rather than
  represented as a successful 50/50 route.

### Direct

- Follows the Point N to Point N+1 crow-flies alignment.
- Uses the narrowest practical corridor and minimizes lateral journey.
- May use dirt or pavement according to the available aligned fabric.
- “Direct” means geometrically direct, not shortest-road distance.

### Clean

- Is pavement-first, not shortest-path routing.
- Treats every recognized major urban core as a wall unless a rider endpoint is
  inside that core.
- Avoids major highways and major population centres.
- May use a rural unpaved connector before crossing an unrelated urban core.
- Relaxes an urban wall only after a proved no-path result, never because of a
  timeout, score, or search cap. The fallback must be labelled.
- Forces Allow Unknown off.

### Corridors

A corridor is an outer search envelope, not a distance allocation or a target
the route is expected to fill. Dirt may search wider envelopes than Balanced;
Direct searches a narrow alignment. A wider corridor grants permission to find
a better ride—it never instructs the router to travel to the boundary.

## 3. Road eligibility, surface, and access

- The foundational routing fabric is OSM-only.
- OSM roads, tracks, and eligible motorized paths are included according to the
  locked adapter rules.
- An explicit OSM `surface=*` value wins.
- Missing surface stays unknown except for the documented conventional-major-
  road paved default.
- Dataset identity never proves surface or access.
- Access precedence is `motorcycle` → `motor_vehicle` → `vehicle` → `access`.
- Known private or purpose-limited access is not permissive through-routing.
- Allow Unknown opens `motorized_unknown`; it does not manufacture access.
- Clean never uses Allow Unknown.
- Provincial/state overlays such as DRA, FTEN, NRN, NSTDB, and Access Roads are
  inactive in the foundational product. They may be evaluated later as an
  explicit secondary layer after OSM passes.
- Lines displayed by the live graph are OSM routing data. Green means eligible,
  amber means unknown/Allow-gated, orange means restricted, and red means
  excluded. Visual contact alone does not override the packed topology, but a
  visibly continuous OSM road that fails to connect is a pack/topology defect to
  investigate rather than dismiss.

The complete normalization, stitch, seam, urban, and release laws remain in
[`08-MAP-REFINEMENT.md`](08-MAP-REFINEMENT.md) and
[`09-OSM-PACK-QUALITY-STANDARD.md`](09-OSM-PACK-QUALITY-STANDARD.md).

## 4. Online, offline, and pack policy

### Online

When either Wi-Fi or cellular connectivity is available:

- route search uses the live routing service;
- fuel planning and fuel pins use the matching live fuel data;
- live graph display uses the matching live graph data; and
- a preinstalled downloadable pack does not silently replace or rescue a failed
  live request.

A live failure must be reported honestly. Silent fallback makes testing
meaningless because the rider cannot know which revision produced the result.

### Offline

When neither Wi-Fi nor cellular connectivity is available:

- planning, rerouting, fuel lookup, and graph display use installed packs;
- absence of a required pack or fuel sidecar is reported honestly; and
- fuel-data absence is unknown, not proof that no pump exists.

### Preparing for navigation

Before participation begins, Start Navigation must make the corridor basemap
layers and every touched province/state routing pack available for offline use.
During the ride the app may move in and out of coverage; the route corridor must
remain usable for zooming, obstruction recovery, backtracking, and rerouting.
This end-to-end behaviour remains a required navigation acceptance test.

### Live candidates and downloadable packs

The live pack is tested first. A new regional build is uploaded under an
immutable live-candidate identity. Only after live automated and physical
approval may those exact bytes be promoted to the downloadable manifest.

Once promoted, live and downloadable routing use the same `graph.v2.bin`,
`geometry.v1.bin`, and `fuel.v1.json` bytes. Online versus offline describes
delivery and availability, not two different road networks.

## 5. Canonical itinerary and rider-facing legs

### Rider intent

`RiderItinerary` is the only durable source of routing intent. It contains:

- rider waypoints numbered `1, 2, 3, …`;
- one `RiderLeg` between each pair of adjacent rider waypoints;
- per-rider-leg profile and Allow Unknown intent;
- station-keyed per-hop profile overrides;
- explicit fuel-station replacement overrides;
- accepted fuel-gap fingerprints; and
- reported impassable edge IDs.

It does not store generated fuel waypoints or route geometry. All mutation goes
through the reducer. Derived results are generation-guarded so stale asynchronous
work cannot overwrite current intent.

### Rider waypoint versus fuel waypoint

- **Rider waypoint:** placed by the rider and numbered Point 1, Point 2, Point 3,
  and so on.
- **Fuel waypoint:** generated from a packed station and labelled F1, F2, F3,
  and so on.
- A fuel waypoint is visible and editable but never becomes a rider waypoint.
- A rider waypoint within 150 m of a packed fuel station is derived as a refuel;
  moving it away removes that reset.

### Leg presentation

The route sheet uses the rider-facing definition of a leg: one rideable section
between consecutive visible route anchors.

For `Point 1 → F1 → F2 → Point 2`, the sheet shows exactly:

1. Point 1 → F1
2. F1 → F2
3. F2 → Point 2

There is no aggregate Point 1 → Point 2 parent row and no hidden subleg
hierarchy. Each row may expose its own profile control. Fuel rows are not
deletable rider stages; the committed fuel waypoint can instead be inspected or
replaced with a graph-valid alternative.

From Here uses Point 1 for the current location and Point 2 for the destination.
Switching to Plan preserves those points. Inserting a new rider waypoint between
Points 1 and 2 renumbers the sequence to 1, 2, 3.

The complete ownership and rebuild rules are in
[`10-ITINERARY-MODEL.md`](10-ITINERARY-MODEL.md).

## 6. Fuel is part of route creation

Fuel planning is not an optional enhancement. A route that cannot support the
rider's configured range is not yet a navigable route.

### Fuel laws

- Point 1 begins with a full tank. This is a documented planning assumption.
- The rider sets tank range and reserve. Usable range is the range after reserve.
- Fuel consumption is currently modelled in routed kilometres, not litres.
- Only a packed, route-connected station or a rider waypoint derived on a
  station resets the tank.
- Ordinary rider waypoints do not reset the tank.
- Fuel is recomputed forward from itinerary leg 0 after every material edit,
  even when unchanged route responses are reused.
- A transport error, timeout, decode error, or missing fuel source is not proof
  that no chain exists.
- Carry Fuel is offered only for a proven fuel gap, never as the first recovery
  for dense station territory or interrupted planning.

### Forward construction

Fuel planning constructs the itinerary linearly:

`Point 1 → F1 → F2 → … → Point 2 → …`

It does not generate a disposable Point 1 → Point 2 route and then force the
rider away from and back onto that geometry. A selected pump becomes the next
anchor; the next section is created forward from that pump.

Unchanged upstream built sections may be reused after a fuel-stop or profile
edit. Fuel state itself is always recomputed from the beginning so carried fuel
cannot become stale.

### Clean foundation for fuel and long routes

When a rider leg needs generated fuel waypoints, crosses a regional boundary,
or spans at least 1,000 km, the system may use Clean sections to establish a
fast, stable connectivity and fuel skeleton. This is not permission to silently
change the rider's chosen route profile. The selected profile stays visible and
each Point/F section can be changed independently afterward.

### Automatic pump selection

An automatic fuel chain must be physically viable and route-coherent:

1. every pump must be route-connected and reachable within usable range;
2. the next pump or rider waypoint must remain reachable after refuelling;
3. candidates must cover the forward corridor and meaningful geographic
   alternatives, not merely the stations nearest empty-tank distance;
4. the complete chain is evaluated, not only the first hop;
5. arbitrary lateral excursions, directional regression, and avoidable
   backtracking lose to a coherent feasible chain; and
6. profile quality differentiates coherent candidates—it does not justify a
   random fuel detour.

This is a fuel-skeleton coherence rule, not a global shortest-route objective.

### Fuel-stop replacement

Tapping a committed F pin or its row enters replacement mode. Valid forward
alternatives receive pulsing candidate halos; ordinary fuel stations remain
visible for context. Selecting a candidate snaps the fuel waypoint to that pump
and replans only from the affected anchor forward. Upstream geometry and fuel
identities remain unchanged when still valid.

### Fuel result states

- **Ready:** every hop is proven and within range.
- **Gap:** a route exists but an exhaustive station-chain proof found no complete
  chain. The exact shortage remains visible.
- **Unknown:** the route exists but fuel data is unavailable or unreadable.
- **Interrupted:** timeout, cancellation, service 5xx, decode, or connectivity
  failure. Retry is offered; auxiliary fuel is not.
- **Failed:** route geometry itself could not be produced.

Start and GPX export remain possible with a visible gap, but the gap must never
be silent. See [`12-FUEL-GAP-CONTRACT.md`](12-FUEL-GAP-CONTRACT.md).

## 7. Routing interaction and presentation

- A route can always be cleared when one exists, whether the sheet is collapsed
  or expanded and whether From Here or Plan is active.
- Route rows open only through their explicit chevron/control; incidental touch
  must not steal a horizontal swipe or map gesture.
- Rider-leg deletion is a left swipe revealing Delete.
- One touch resolves in order: pin, route, then map.
- Tapping the painted route may insert a rider waypoint; selecting an existing
  pin must not also add another waypoint.
- One-finger map pan remains available after zooming and after collapsing the
  route sheet.
- Planning-mode map chrome contains routing tools: Packs, Graph, Fuel, Show
  Entire Route, Re-centre, and compass reset. Navigation-only 3D, cue, and rider
  status controls appear only after navigation begins.
- General fuel stations remain spatially stable across actionable zoom levels;
  clusters split deterministically into individual pumps. A failed refresh never
  blanks already proven same-source fuel data.

## 8. Pack and regional release state

As of this reconciliation:

- All 13 Canadian provinces and territories are promoted in the stable
  downloadable manifest.
- Nova Scotia's last recorded promoted release is `ns-osm-20260821-02`.
- The public stable manifest was generated `2026-08-21T14:26:33.708Z`, contains
  63 regions, and records Nova Scotia graph SHA-256
  `a9c5cb27eba2dc298344d9c80298881e1e0cfc0d40435d17cd9c4e210d1bef51`.
- United States regions were uploaded as candidates and were not approved for
  promotion in the recorded phase state.
- Cursor completed a later rebuild of the live candidate packs. Those candidate
  IDs, checksums, and live service overrides have not yet been committed to this
  repository's release record.
- The later live candidates have not been promoted to downloadable packs.

Therefore no one may call the later rebuild “approved” or use its results as a
benchmark baseline until its exact candidate identities are recorded.

## 9. Verification and benchmark truth

The latest committed deterministic NS table is
`scripts/pack-fabric/bench/results/1da4442-20260822T160913Z.json`:

- source: immutable `ns-osm-20260821-02` candidate;
- seed: `3511091208`;
- result: 35/40 green; and
- five known red rows: two Balanced surface misses and three Halifax
  unknown-off connectivity failures.

That table is valid only for the pinned pack and code under measurement. It is
not a baseline for the unrecorded Cursor live-candidate rebuild.

Every routing or fuel change requires:

1. a fixed-coordinate reproduction test;
2. focused unit/integration tests;
3. `npm run bench:ns` and a before/after comparison against the same pack;
4. no unexplained green-to-red regressions;
5. a matching client/service contract version; and
6. physical validation on White after automated gates pass.

Simulator work must reuse the existing simulator and DerivedData locations. Do
not create or duplicate simulators for routine regression testing.

## 10. Current blocking defect — 2026-08-22

Physical From Here test:

- Point 1: `44.764823,-63.340271`
- Point 2: `45.636595,-63.056267`
- requested profile: Dirt
- Clean fuel foundation: 252.989 km
- usable range: 237.5 km
- chosen pump: Gulf `osm:n11084635754` at
  `45.962505,-63.883625`
- first hop: 237.278 km
- final built itinerary: 356.668 km, 9% dirt, 5.5% backtrack

The pump is approximately 71 km cross-track from the endpoint axis. A route only
15.489 km beyond usable range inflated by 103.679 km after fuel planning.

This is not missing fuel data: production matched 668 stations. The production
shortlist was concentrated around Wallace/Pugwash/Oxford and omitted coherent
Truro/onward choices.

The same replay also proved a release mismatch:

- production reports the older `candidateK=3` fuel planner and old candidate
  payload shape;
- the current repository uses six geographically distinct candidates and emits
  departure, location, and forward-validity data; and
- running current repository logic against the same public pack selected a
  coherent station near Truro instead of the distant Gulf.

Because the service exposes no contract/commit version, the exact stale server
revision cannot be identified from the client response. **Further fuel-device
acceptance is blocked until client and service versions are proven to match.**

Approved repair has not yet been given. The recommended order for rider review
is:

1. deploy and verify the current routing service without changing pack bytes;
2. add an explicit client/service contract version gate;
3. replay the exact coordinates above;
4. harden whole-chain pump selection with route-coherence rejection and complete
   candidate diagnostics; and
5. add the reproduction permanently to the benchmark/regression suite.

## 11. Current product status

### Implemented and covered locally

- Canonical rider itinerary and generation-guarded builder.
- Flat Point/F leg presentation rather than parent/subleg hierarchy.
- Always-on fuel planning and fuel-gap states.
- Fuel waypoint alternatives and forward station overrides.
- Clear Route availability repairs.
- Eligible-edge endpoint resolver and NS/PEI overlap regression coverage.
- Fuel-layer visible-bounds cache, deterministic clusters, and candidate halos.
- Fixed-pin Nova Scotia benchmark.

### Not yet accepted end to end

- Current client against a provably matching production service.
- The active fuel-selection defect above.
- Exact identity and benchmark baseline for Cursor's rebuilt live candidates.
- Full online/offline parity with promoted packs.
- Cross-country long-route performance and fuel-window behaviour.
- Navigation-time fuel carry after the rider has already consumed fuel.
- Complete navigation/off-route/incident recovery audit.
- Promotion of rebuilt downloadable packs.

### Work priority

Follow [`16-PRODUCT-STABILIZATION-BUILD-PLAN.md`](16-PRODUCT-STABILIZATION-BUILD-PLAN.md).
The first applicable priority is always a blocker preventing meaningful device
testing. The current blocker is service-version and automatic-pump-selection
correctness. Do not move to pack promotion, navigation hardening, onboarding, or
polish until Gate 1 route creation is trustworthy.

## 12. Change discipline

1. Device feedback produces a reviewable diagnosis before code changes.
2. Richard approves the proposed behavioural correction before implementation.
3. Pack bytes and routing/search code do not change in the same repair.
4. Each defect receives a fixed regression test using the original coordinates.
5. Each work package is bounded to declared files and one focused commit.
6. Client and live service are deployed and tested as a matched release.
7. Logs must record the inputs, revision, candidates, rejection reasons,
   fallback/cap status, and final decision.
8. A timeout never masquerades as a no-path or proven fuel gap.
9. Historical measurements remain archived but are never used as a current
   baseline after code or pack bytes change.
10. No design skill or agent may remove existing product functionality without
    rider approval.

## 13. Document authority and consolidation map

| Document | Role after this reconciliation |
| --- | --- |
| **This document** | Canonical product intent, current routing behaviour, source policy, release state, blockers, and work order. |
| `08-MAP-REFINEMENT.md` | Locked search, eligibility, surface, access, urban, corridor, and seam laws. Supporting authority. |
| `09-OSM-PACK-QUALITY-STANDARD.md` | Locked repeatable build and live-before-download release gate. Supporting authority. |
| `10-ITINERARY-MODEL.md` | Canonical internal ownership and mutation model. Supporting authority. |
| `12-FUEL-GAP-CONTRACT.md` | Canonical fuel gap, acknowledgement, Start, and GPX safety contract. Supporting authority. |
| `16-PRODUCT-STABILIZATION-BUILD-PLAN.md` | Active checklist and “what next?” decision rule. |
| `00-OVERVIEW.md`, `02-ROUTING.md` | Technical introductions. They must defer here for current policy/status. |
| `11-ROUTING-HANDBACK.md` | Historical Phase 0–10 handback. Never current status. |
| `13-ROUTING-PROJECT-STATE.md` | Historical Phase 11 snapshot. Never current status. |
| `14-PHASE-11-DEVICE-CORRECTION.md` | Phase 11 defect/decision/acceptance evidence. |
| `15-FUEL-MAP-VISIBILITY-REVIEW.md` | Fuel-layer design decision and implementation evidence. |

Phase documents are evidence, not instructions to repeat completed work. When a
new decision is accepted, update this document and the affected narrow contract
in the same documentation commit.
