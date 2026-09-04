# DIRT — Product and Routing Source of Truth

**Authority:** canonical product, routing, fuel, pack-source, and current-state document

**Owner:** Richard Smith

**Primary engineering agent:** Codex

**Last reconciled:** 2026-09-03 — routing release candidate frozen at
`94b467a11375e3ea3233c127b07af2ef039d0658`

**Repository:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`

**Branch:** `feature/routing-itinerary-rebuild`

This is the first document to read before changing DIRT routing. It exists so a
new session does not revive a superseded idea, treat an old phase report as
current, or repair one path by breaking another.

This is the only active routing authority. All earlier routing, pack-law,
itinerary, fuel-gap, handback, phase, and stabilization documents are archived
historical evidence. They do not retain narrower authority and cannot supersede
or supplement this document without Richard explicitly restoring a rule here.

Release boundary: [ROUTING-FREEZE-2026-09-03.md](ROUTING-FREEZE-2026-09-03.md).
Regional replication: [PACK-FACTORY.md](PACK-FACTORY.md). Android parity:
[ANDROID-PARITY.md](ANDROID-PARITY.md).

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
- May leave a sensible paved line for an optional dirt excursion only when that
  excursion provides at least 1 km of continuous, explicitly known unpaved
  riding. Unknown surface contributes zero metres. Sub-kilometre dirt is
  re-priced as pavement rather than deleted, so necessary connectors, rider-
  placed waypoints, and destination access remain routable.
- Shortest distance is not an objective.
- A result near Balanced is not acceptable merely because it connects; a low
  dirt result must be labelled and supported by evidence about the eligible
  fabric or a search limit.

### Balanced

- Targets the closest feasible result to 50% dirt and 50% paved.
- Does not optimize shortest distance.
- A miss must be labelled with the closest connected result rather than
  represented as a successful 50/50 route.

### Clean

- Stay on pavement unless the snapped road at A or B is unpaved, or pavement
  cannot connect. Then use that road for as many kilometres as it takes. Never
  hunt dirt. There is no dirt% cap.
- Direction = gravity toward the next waypoint. Paths must keep flowing toward B.
  Going around water, terrain, or a city for many kilometres is legal if that is
  how the pavement still flows toward B.
- When two arounds both flow toward B, shorter pavement wins. A long loop that
  better “points at B” or avoids a short around loses.
- Soft forward preference only — mild tax on edges that move away from B, never
  stronger than the extra kilometres of the long around (~2/km). No chord
  cross-track cone; that treats a short around-the-lake as flowing uphill.
- No Clean corridor. No hard progress-regression gate.
- Avoid major urban cores and freeways (motorway + ramp). Arterial is normal
  Clean pavement. Not OSM towns, not rural numbered trunks, not collectors.
  Cross metros/freeways only after a proved no-path on eligible fabric; label
  the fallback.
- Snap nearest eligible road/path/trail. Never prefer pavement for Clean.
- Untagged local/service remain impassable on through-edges. The snapped edge at
  A and at B is always traversable. Allow Unknown is forced off.
- Pack duplicate nodes on a continuous OSM way may be bridged at search time so
  visibly continuous road fabric stays connected for every profile.

### Corridors

A corridor is an internal search optimization for Dirt and Balanced —
not a Clean product rule, distance allocation, or target the route is expected
to fill. Search may use progressively wider tiers only when benchmarks show that
doing so improves speed without suppressing the profile objective. Successful
tiers belong in diagnostics, not the rider interface.

## 3. Road eligibility, surface, and access

- The foundational routing fabric is OSM-only.
- OSM roads, tracks, and eligible motorized paths are included according to the
  locked adapter rules.
- An explicit OSM `surface=*` value wins.
- Missing surface stays unknown except for the documented conventional-major-
  road paved default.
- Dataset identity never proves surface or access.
- Access precedence is `motorcycle` → `motor_vehicle` → `vehicle` → `access`.
- Legacy CanVec `track` and `service` imports without explicit motor-access
  evidence are `motorized_unknown`. Their import source proves historical
  geometry, not present-day public permission.
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

These are the active normalization, access, topology, and release laws. Detailed
historical build procedures remain auditable in the routing archive, but they
are not separate authority.

## 4. Approved live-planning and navigation-download policy

Online route planning uses the live routing service. Regional downloads are
prepared when the rider starts navigation so the same route fabric is available
for offline rerouting; they are not a prerequisite for ordinary online planning.

### Source of truth and consumer routing

- A live candidate is the source of truth while a regional revision is being
  tested.
- After approval, the exact graph, geometry, and fuel bytes are promoted as an
  immutable downloadable revision.
- Ordinary consumer planning with connectivity routes through the live service
  against the selected live regional pack, whether or not that pack is already
  installed on the phone.
- An installed pack is used when connectivity is unavailable and for offline
  rerouting during navigation. Its presence must not silently divert an online
  planning request away from the live service.

Every route result must identify its source and pack revision so accuracy is
reproducible.

### Automatic acquisition

Waypoint placement and online route creation do not trigger routing-pack
downloads. Routing-pack acquisition is rolling and follows the rider's actual
location; a long itinerary is never permission to bulk-download every province
or state at Start Navigation. When Start Navigation requires the current
regional pack and it is not installed:

1. DIRT identifies only the province/state containing the rider's start.
2. DIRT explains that the download enables offline rerouting and asks the rider
   to accept it.
3. On acceptance, DIRT downloads the current approved graph, geometry, and fuel
   sidecar before navigation begins.
4. On refusal, the already-created online route remains valid, but DIRT records
   and displays that offline rerouting is unavailable.

After Begin Ride, DIRT observes actual rider location. On entry into a new
province/state it activates that installed pack or quietly acquires the current
approved pack. One boundary acquisition may run at a time. Repeated GPS fixes in
the same region do no work, and later itinerary regions are not scanned or
downloaded in advance.

Riders may delete installed packs but do not pre-emptively browse and download
arbitrary packs. Only the current rider region is requested automatically.

### Updates

- Currency is compared by immutable manifest identity and checksums, not dates
  alone.
- A newer approved revision is recommended, not forced.
- Declining an update keeps the itinerary pinned to its installed older
  revision.
- Accepting an update before navigation rebuilds and revalidates the route
  because topology, access, surface, seams, or fuel stations may have changed.
- The currently published packs remain untouched until the next deliberately
  approved pack release.

### Preparing for navigation

Before participation begins, Start Navigation verifies the basemap tiles for the
first visible rider/fuel stage and the routing pack for the rider's current
province/state. It must not inspect or acquire the full itinerary's regional
chain. After Begin Ride, the next basemap stage is saved quietly and later stages
advance one at a time; routing packs advance only when actual rider location
enters their region. If the rider previously declined a current required pack,
DIRT warns that offline rerouting may be unavailable and offers the download
again before proceeding. During the ride the app may move in and out of coverage;
the prepared near-term corridor must remain usable for zooming, obstruction
recovery, backtracking, and rerouting. This rolling end-to-end behaviour remains
a required navigation acceptance test.

Spoken cues, HUD countdown, Junction versus Rally, and named waypoint callouts
are defined only in
[00-NAVIGATION-SOURCE-OF-TRUTH.md](00-NAVIGATION-SOURCE-OF-TRUTH.md).

### Live candidates and downloadable packs

The live pack is tested first. A new regional build is uploaded under an
immutable live-candidate identity. Only after live automated and physical
approval may those exact bytes be promoted to the downloadable manifest.

Once promoted, live and downloadable routing use the same selected `graph.v3.bin`
(or advertised V2 fallback for a region not yet promoted to V3),
`geometry.v1.bin`, and `fuel.v1.json` bytes. Online versus offline describes
delivery and availability, not two different road networks.

## 5. Canonical itinerary and rider-facing legs

### Rider intent

`RiderItinerary` is the only durable source of routing intent. It contains:

- rider waypoints numbered `1, 2, 3, …`;
- one `RiderLeg` between each pair of adjacent rider waypoints;
- per-rider-leg default profile and Allow Unknown intent;
- departure-anchor-keyed per-stage profile, Allow Unknown, and Clean highway
  overrides;
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
hierarchy. Each row exposes its own profile control. Generated fuel waypoints are
not freely dragged or directly deleted; they can be inspected and replaced with
a graph-valid alternative.

Deletion acts on a rider-ending leg. In `Point 1 → F1 → Point 2`, deleting the
second leg removes Point 2 and preserves the primary `Point 1 → F1` leg. F1 then
becomes the current route endpoint. Dropping another destination builds forward
from F1. The primary leg cannot be deleted independently; Clear Route removes
the complete route.

From Here uses Point 1 for the current location and Point 2 for the destination.
Switching to Plan preserves those points. Inserting a new rider waypoint between
Points 1 and 2 renumbers the sequence to 1, 2, 3.

These ownership and rebuild rules are canonical. Implementation details must
conform to them rather than redefining them in a second document.

## 6. Fuel is part of route creation

Automatic fuel planning is the default safety system. The rider may deliberately
turn it off and place fuel waypoints manually; in that state DIRT adds no fuel
stops and makes no claim that the route is fuel-safe. Tank range and reserve stay
saved so automatic planning can be restored without re-entry.

### Fuel laws

- Point 1 begins with a full tank. This is a documented planning assumption.
- The rider sets tank range and reserve. Usable range is the range after reserve.
- The planner computes the minimum safe stop count from routed distance and
  reserve-adjusted usable range, then compares complete feasible chains with
  that stop count before considering ride character.
- The first 75% of reserve-adjusted usable range is devoted to the selected ride
  objective. When a stop is required, the final quarter opens pump selection:
  choose the first sensible, forward, route-connected pump instead of continuing
  a province-wide search. Fuel already consumed advances this boundary by the
  same amount.
- The 75% boundary never manufactures a stop. It is the preferred beginning of
  pump selection among otherwise equal, sensible choices, not a required stop
  distance or a replacement hard range. An earlier pump remains valid only when
  it is required to preserve a safe continuation through sparse geography.
- If the destination is reachable, DIRT goes directly there with zero generated
  stops only when the fuel remaining on arrival can also reach the nearest pump
  by road from that destination. This destination-escape search is 360° because
  there is no later travel direction. If the rider's destination waypoint sits
  on a packed pump, arrival resets the tank and no separate escape allowance is
  required.
- A valid watched pump excludes earlier automatic pumps. An earlier pump is used
  only when it is the sole safe continuation through a sparse corridor. A rider-
  selected pump waypoint remains selectable regardless of its distance from the
  prior anchor.
- Fuel consumption is currently modelled in routed kilometres, not litres.
- Only a packed, route-connected station or a rider waypoint derived on a
  station resets the tank.
- Ordinary rider waypoints do not reset the tank.
- Fuel proof is advisory to route geometry. A proven fuel gap or an interrupted,
  timed-out, unavailable, or unreadable fuel source never destroys an otherwise
  valid road route. DIRT completes the affected rider leg without a fuel-range
  ceiling and attaches the warning to that exact leg.
- A profile or Allow Unknown edit made on a visible Point/F row belongs only to
  that row's departure-to-arrival stage. The selected stage and its fuel-
  dependent suffix inside the same primary rider leg are regenerated because a
  longer or shorter route may move the next pump. Only the selected stage uses
  the edited policy; each following stage applies its own stored policy or the
  primary rider-leg default. Completed stages before the selected departure and
  all earlier and later primary rider legs remain exact. The rebuilt primary leg
  must meet or improve its preserved arrival-fuel ceiling so the untouched
  itinerary suffix is not made less safe.
- Waypoint topology edits and global fuel-range/reserve changes may still
  revalidate forward from the earliest affected rider leg.
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

Unchanged built sections are reused according to ownership. A visible-stage
profile or access edit inherits the proven fuel state at that stage's departure,
preserves every earlier stage, and rebuilds the selected stage plus the fuel-
dependent suffix only as far as the owning primary rider waypoint. If the first
stage's added dirt requires an earlier pump, that pump and the following stages
may move, but Allow Unknown does not leak into them. The former safe arrival
ceiling at the primary rider leg's exit is retained. A waypoint/topology or
global fuel-setting edit may rebuild the affected suffix when its boundaries have
actually changed.

### Clean foundation for fuel and long routes

Automatic Clean-first construction applies ONLY when a rider segment (a) spans at
least 1,000 km, OR (b) crosses a true province/state boundary (e.g. NS→NB). It
establishes a fast, stable connectivity and fuel skeleton before the rider adjusts
the visible Point/F legs. It does NOT apply to a sub-1,000 km, within-province
route merely because fuel search is difficult.

**Internal pack regions are a storage detail, invisible to routing.** A province's
graph may be split into multiple internal region shards to fit size/upload/memory
limits (V8 ~16.7M Map cap, Cloudflare R2/wrangler upload cap, on-device memory) and
is stitched back together with seam edges. This sharding is NOT a Vercel-plan
artifact and is unrelated to Hobby/Pro. Crossing an internal shard seam — e.g.
mainland NS → Cape Breton, or Halifax → western NS — is NOT a "regional boundary":
it MUST NOT trigger Clean-first and MUST NOT change the rider's chosen profile. The
cross-boundary test uses the province/state, never the internal shard id.

Clean-first never locks the rider out. The selected profile stays visible and the
selected rider leg recalculates when the rider switches profile. Changing one
Clean leg to Dirt can lengthen the ride or require another pump, but that work stays
between the same two primary waypoints; valid upstream and downstream rider legs
remain unchanged.

### Automatic pump selection

An automatic fuel chain must be physically viable and route-coherent:

1. every pump must be route-connected and reachable within usable range;
2. the next pump or rider waypoint must remain reachable after refuelling;
3. candidates must cover the forward corridor and meaningful geographic
   alternatives, not merely the stations nearest empty-tank distance;
4. the complete chain is evaluated, not only the first hop;
5. ranking order is minimum complete-chain stop count, directional coherence
   and forward progress, then journey distance/detour;
6. water, terrain, and sparse-road detours are allowed when they remain a
   sensible continuation toward the rider waypoint, but a fuel-only chain may
   not materially inflate the graph-routed foundation journey;
7. a short forecourt connector may repeat, but a meaningful down-and-back fuel
   stem is ineligible; and
8. profile quality, including Dirt percentage, is the final tiebreaker among
   otherwise sensible chains—it never justifies a random fuel detour.

This is a fuel-skeleton coherence rule, not a global shortest-route objective.

### Fuel-stop replacement

Tapping a committed F pin or its row enters replacement mode. The fuel waypoint
is a hybrid rigid anchor: it is fixed to a verified station and cannot be freely
dragged, but the rider can replace it. Alternatives receive pulsing candidate
halos only when they are reachable from the preceding anchor within usable
range and preserve a viable forward chain. Selecting one replans from the
affected preceding anchor forward. Upstream geometry and fuel identities remain
unchanged when still valid.

### Fuel result states

- **Ready:** every hop is proven and within range.
- **Gap:** a route exists but an exhaustive station-chain proof found no complete
  chain. The complete route and exact routed shortage remain visible with advice
  to carry extra fuel or reshape that rider leg.
- **Unknown:** the complete route exists but fuel safety could not be verified
  because fuel data or planning was unavailable, unreadable, interrupted, or
  timed out. It remains distinct from a proven gap and may be retried.
- **Failed:** route geometry itself could not be produced.

Start and GPX export remain possible with a visible gap or unknown-fuel warning,
but the warning must never be silent in the planner or exported GPX. A proven gap
still requires the existing explicit start acknowledgement.

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
- Ferry edges remain valid timed transport connectors, are excluded from road-
  surface percentages, and paint as a distinct marine-blue dashed crossing.
  The route sheet must state that a ferry is included and tell the rider to
  verify departure times, seasonal service, and motorcycle boarding.

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

The latest exact-pack NS table is
`scripts/pack-fabric/bench/results/42c8d48-20260823T020222Z.json`:

- source: immutable `ns-osm-20260821-02` candidate;
- graph SHA-256: `a9c5cb27eba2dc298344d9c80298881e1e0cfc0d40435d17cd9c4e210d1bef51`;
- seed: `3511091208`;
- result: 33/40 green; and
- seven red rows: two Balanced surface misses, one Antigonish–Sydney Dirt
  surface miss, three Halifax unknown-off connectivity failures, and one
  Dartmouth–Antigonish unknown-on timing miss.

The runner now downloads graph, geometry, and fuel from the immutable release,
verifies byte counts and SHA-256 values, and prevents stale local files from
shadowing that identity. That table is valid only for the pinned pack and code
under measurement. Timing remains a measured assertion and may expose runtime
variance even when route geometry is unchanged.

Every routing or fuel change requires:

1. a fixed-coordinate reproduction test;
2. focused unit/integration tests;
3. `npm run bench:ns` and a before/after comparison against the same pack;
4. no unexplained green-to-red regressions;
5. a matching client/service contract version; and
6. physical validation on White after automated gates pass.

Simulator work must reuse the existing simulator and DerivedData locations. Do
not create or duplicate simulators for routine regression testing.

Production pack lockstep verification is always scoped to one explicit region:
`ship-routing.js --assert --region <id>`. It has no all-regions default, so an
unrelated province or state cannot block validation of the region under test.

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

R0 now adds contract `dirt-routing.r0.v1`, deployment-build identity, and exact
graph, geometry, and fuel hashes to local route/fuel responses and device logs.
The client rejects a missing or stale service contract. Installed pack files
are also checksum-verified instead of being trusted merely because they exist.
**Further fuel-device acceptance remains blocked until this matched client and
service are deployed together and the coordinates above are replayed.**

This historical defect subsequently received approval for repair. Its original
recommended validation order was:

1. deploy and verify the committed R0 routing service without changing pack bytes;
2. build the matching client on White and confirm its identity log;
3. replay the exact coordinates above;
4. harden whole-chain pump selection with route-coherence rejection and complete
   candidate diagnostics; and
5. add the reproduction permanently to the benchmark/regression suite.

### Build 6 approved fuel-selection repair — 2026-08-26

A second physical reproduction exposed the priority inversion directly:

- Point 1: `44.764839,-63.340268`
- first generated pump: `44.778483,-63.084597`
- erroneous second pump: `45.707419,-63.284407`
- Point 2: `45.399717,-62.495696`

The second pump was about 68 km cross-track and created a north/west fuel-only
journey expansion before returning southeast to Point 2, despite coherent fuel
options along the journey. Build 6 repairs this without changing pack bytes:

1. a rider waypoint reachable within remaining usable range wins with zero
   generated stops only when the rider can still reach a pump by road afterward;
2. this historical build used an earlier 50%/70% watch/preference rule; the
   frozen release candidate supersedes it with first-sensible pump selection
   after 75% of usable range as defined in §6;
3. complete-chain stop count and forward coherence precede profile quality;
4. graph-foundation detour checks accommodate obstacles while rejecting gross
   fuel-only expansion; and
5. meaningful repeated-road fuel stems are rejected, with a 1 km allowance for
   short station access geometry.

The on-device and live-service implementations must remain lockstep. The fixed
coordinates above and the earlier Gulf/Truro case are permanent regressions.

### R0 physical evidence — 2026-08-23

White ran app `1.2 (4)` against the deployed R0 service. The diagnostic log
proved all tested route and fuel responses came from:

- service contract `dirt-routing.r0.v1`;
- service build `fb28806514b904d1f1334dc9fe0380e7f48f7fe3`;
- NS graph SHA-256 `a9c5cb27eba2dc298344d9c80298881e1e0cfc0d40435d17cd9c4e210d1bef51`;
- NS geometry SHA-256 `01e2741006ae4ee2e4324e2254ca21d6e5ced7cdc2f3c16d0c07688cc09decc6`;
  and
- NS fuel SHA-256 `999e1cbd5901b2bb28f7c09d7578abe2e7c69ad3e68c25b0b776c0172305fdd2`.

The installed-pack registry reported `[ns]` while the pack existed and `[]`
immediately after the rider deleted it. This validates R0 service/data identity
and registry observability. The device log still labels the release
`stable-or-local` rather than the immutable candidate ID and identifies the
client only as app version/build; exact release-ID and client-source-SHA display
remain provenance follow-ups.

The same session exposed a blocking fuel-planning defect outside R0's
publication-safety scope:

- rider range was 230 km with 5% reserve, correctly producing 218.5 km usable;
- Dirt routes of 253.826 km, 342.943 km, and 343.028 km correctly declared that
  at least one stop was needed;
- Balanced similarly declared a stop was needed for a 248.191 km route;
- the fuel service returned six station candidates, so station data was present;
- Dirt and Balanced station-route probes took approximately 12–18 seconds per
  attempt, returned `probe_inconclusive`, retried once, and then emitted a fuel
  gap with no generated fuel waypoint; and
- Clean selected station `osm:n5292116667` and successfully produced
  two Point/F legs for comparable routes.

Therefore the immediate defect is profile-dependent station-probe completion,
not missing pumps or incorrect range arithmetic. Dirt and Balanced must not
convert an inconclusive timed probe into proof that no fuel chain exists. The
repair belongs in the fuel/search reconciliation after the benchmark contract
is corrected, and must include fixed reproductions for these device coordinates.

The session also confirmed that deleting NS produced
`packsCover=false installed=[]` while online routing correctly continued against
the live service. Required-pack acquisition belongs at Start Navigation, where
the route's touched regions are known and offline rerouting can be prepared.

### Ontario live-search repair — 2026-09-02

The first long Ontario physical test used the live service correctly even though
no Ontario pack was installed on the phone. The fixed reproduction is:

- Point 1: `45.16042827226568,-76.07416570548115`
- Point 2: `49.267740201600496,-88.12280920479155`
- requested profile: Balanced
- Ontario graph: approximately 1.47 million nodes and 1.76 million edges

The service failed with `time_cap` after spending work on a provably undersized
40 km corridor and using a fixed 2.2-second Balanced search ceiling inherited
from much smaller regional graphs. The repair does not change pack bytes or
client source selection. It:

1. uses an exact A* distance reference instead of an unbounded Dijkstra scan;
2. starts long Balanced rides at the 80 km corridor tier;
3. scales the Balanced server search allowance when graph size is materially
   large, with a further bounded increase for genuinely long rides; and
4. reports the requested profile in a search-limit message.

The exact Ontario route now completes locally at approximately 1,275 km. The
fixed NS benchmark has zero route, surface, fuel-stop, hop-length, backtrack, or
restricted-access deltas against the same `c2bb1b0` code and immutable NS pack.
Production acceptance still requires deployment and replay from White.

### Live planning operation reuse — 2026-09-02

Ontario and Quebec exposed a system-wide planning defect rather than a
province-specific routing defect. The client and live service repeatedly
measured the same corridor for fuel, discarded already-calculated route work,
then requested each selected hop again. Large v2 graphs also fetched graph and
geometry sequentially, copied both buffers before decoding, rematched every
regional pump, and received an ever-growing list of historical edge IDs.

The approved repair does not change pack bytes or profile objectives:

1. the selected profile route and the regional fuel sidecar load concurrently;
2. that profile route becomes the foundation for the fuel decision instead of
   disposable preflight work;
3. one live fuel response may return a bounded, fully routed multi-stop window;
   the client validates the complete window before committing any of it;
4. station alternatives remain grouped by their departure pump and available
   to **Choose another pump**; choosing one preserves upstream legs and rebuilds
   the affected suffix because every later fuel distance changes;
5. rider-placed waypoints remain durable planning boundaries. Per-hop rider
   profile overrides deliberately keep one-hop planning rather than allowing a
   multi-stop response to erase those choices;
6. destination escape uses a targeted nearest-route-connected-pump search, not
   a usable-range flood of the province graph;
7. only pumps physically capable of fitting in the current tank are snapped to
   the graph. Route reachability and the active profile still prove every pump;
8. graph/geometry downloads run concurrently and decode their original buffers;
   warm function isolates reuse immutable graph, fuel, and pump-snap data;
9. a live client planning context retains proven pump IDs across Dirt, Balanced,
   and Clean changes for the same rider corridor. Retained IDs are priority
   hints only and can never bypass current range, access, continuation, or route
   checks; and
10. backtrack history is bounded to the recent 30 km / 256 edges. It protects
    the current departure without sending or penalizing an entire long ride;
    and
11. Dirt, Balanced, and Clean retain their established search ceilings on small
    regional graphs, while both wall-clock and exploration limits scale on a
    province/state-sized graph. This changes capacity only: profile costs,
    corridors, access policy, route selection, rider pins, and pack bytes remain
    unchanged; and
12. fuel candidate routing ends once a complete minimum-stop plan is proven and
    every remaining pump is mathematically worse on forward direction, progress,
    or total distance. Profile quality remains the final tiebreaker among pumps
    that can still compete, and a complete one-stop branch is never recursively
    expanded into a slower two-stop branch.

The fixed Quebec 67 km route completes locally against live pack data in about
1.3 seconds cold, down from the prior repeated multi-pass behaviour measured in
tens of seconds to minutes. A representative same-region Ontario ride completes
in about 5.4 seconds cold, of which about 4.8 seconds is the one-time live fuel
sidecar transfer. The extreme 1,800 km Ontario stress route returns its first two
fully proven pumps and their routes in about 19 seconds under the bounded
long-haul window. Cross-country and complete extreme-window acceptance remain a
separate Gate 2 concern; they do not justify splitting the rider-visible region
or changing route quality. A fixed approximately 67–80 km Ontario reproduction
now completes locally under serverless settings for Dirt, Balanced, and Clean;
before the graph-sized allowance, each could stop at a small-region search cap.

### Profile-quality and urban-topology correction — 2026-09-02

A fixed Nova Scotia reproduction proved three independent search regressions:
the configured major-urban-core wall was not being enforced, ordinary smaller
settlements were being used as hard walls instead of scored avoidance, and a
two-metre duplicate-node seam on one continuous OSM road was connected for
Clean but not for Dirt or Balanced. The disconnected adventure graph could then
fall back through Halifax and return DIRT with less dirt than Balanced.

The correction is pack-agnostic and does not alter or rebuild pack bytes:

1. every profile enforces embedded major urban cores during its primary search
   and may relax one only after a proved no-path result;
2. smaller settlements remain strongly scored but do not sever road fabric;
3. the same zero-distance duplicate-node topology bridge is available to Dirt,
   Balanced, and Clean, including bounded resource and reverse-distance work;
4. the established pavement-minimizing DIRT search remains primary so accepted
   high-DIRT routes and their speed do not change; and
5. only when every primary DIRT candidate is below 70% does one bounded
   dirt-share recovery compete with it. That recovery may use the full lateral
   corridor while preserving the forward-progress guard, but its total path
   length is bounded relative to the already-proven DIRT ride and by any harder
   fuel-range ceiling. A completed wide search whose route is wholly contained
   by the next narrower corridor is reused instead of solved again. Final
   selection still rejects purposeless meander, re-prices sub-kilometre dirt
   diversions, and prefers the highest coherent dirt share before less pavement.

The exact regression now avoids the Halifax core, has no optional dirt run
under one kilometre, and returns 29% known dirt versus Balanced at 23% with
Allow Unknown off. With Allow Unknown on, the same endpoints return 74% dirt;
that difference is expected because unknown-access roads become eligible. The
historic fixed DIRT routes remain above 70%. Ontario reproductions return
79–83% DIRT, 63–64% Balanced, and 7–9% Clean without an urban fallback.

All behaviour keys off the shared graph-v3 schema, embedded urban/settlement
metadata, node count, and route geometry—not a province name. Future state and
province packs built through the v3 registry therefore receive the same search
logic. Live/download verification must continue to name exactly one explicit
`--region <id>` so validating a new pack cannot fail on or mutate another
region.

### Whole-journey Dirt quality contract — 2026-09-03

Aggregate Dirt percentage is necessary but not sufficient. A ride with a paved
opening or ending, one long uninterrupted paved stem, or a major urban crossing
does not become a good Dirt ride merely because later kilometres raise the
total. Dirt candidate selection therefore uses one shared, auditable journey
quality summary:

1. known Dirt percentage for the complete ride;
2. known Dirt percentage in four equal-distance quarters, including the weakest
   quarter;
3. the longest continuous paved run; and
4. metres travelled inside a configured major urban core.

The current ready target is at least 70% known Dirt overall, at least 35% in
every quarter, no urban-core crossing, and no continuous paved run longer than
the greater of 20 km or 6% of the ride. Unknown surface remains visible in the
route's map/display totals but does not masquerade as confirmed Dirt in this
quality contract. Missing a quality target never destroys a connected legal
route; it returns a structured degraded-quality explanation.

When aggregate Dirt candidates are within two percentage points, selection now
prefers no urban crossing, the stronger weakest quarter, and the shorter paved
run before aggregate pavement and purposeless meander. A material Dirt gain
still wins. This makes the contract a close-candidate quality decision rather
than a new source of unconstrained route length.

The fixed `44.764830,-63.340265` → `43.612692,-65.798147` Nova Scotia case also
proved that a global 15 km progress-regression ceiling falsely disconnected a
valid wall-respecting Dirt route and opened the Halifax fallback. A finite Dirt
corridor now earns a proportional detour allowance equal to 25% of its width,
bounded between the existing 15 km floor and a 60 km ceiling. Balanced remains
at its existing 10 km rule and an unbounded connectivity proof remains
unbounded. Against the exact device graph, the fixed route completes in about
1.5 seconds without entering Halifax; its first-quarter known Dirt rises from
about 20% to 32%. It remains honestly classified as degraded at about 61% known
Dirt, so future improvement belongs to a measured topology/surface-evidence
audit rather than another silent fallback or province-specific weight tweak.

### Hard live-planning window and dense-region repair — 2026-09-03

Ontario device traces showed that fast downloads were followed by unbounded
CPU work: a 15-second fuel window could run for 53–60 seconds, match almost
5,000 pumps, explore 3.7 million states, and then either return late or die at
the platform timeout. The repair is pack-agnostic and does not alter pack
bytes, route-profile objectives, fuel priorities, or rider waypoint semantics:

1. the fuel window is now one absolute deadline shared by route-first work,
   graph reachability, pump matching, candidate routing, and continuation
   proof. Route-first receives a smaller portion of that window so fuel work
   always has time to run. Dirt, Balanced, and Clean receive the same 67%
   route-first allowance (capped at 10 seconds); profile choice must not make
   a dense-region cold start fail sooner. The foundational route and fuel
   search share one request-scoped decoded graph/runtime, so a memory-safe
   serverless worker never reloads the same province between those phases;
2. before route-first begins, geographic endpoint distance is used only as a
   mathematically safe lower bound. When that lower bound already exceeds the
   fuel remaining in the tank, a zero-stop ride is impossible, so the planner
   skips the full destination route and gives the window to forward pump
   discovery and proof. It does not treat straight-line distance as a routed
   distance, choose a pump from it, or weaken any active-profile route proof;
3. every large inner loop observes the same deadline and request-cancellation
   signal. The iOS client also enforces a true wall-clock timeout—independent of
   the networking stack's inactivity timeout—and abandoning or replacing a
   build cancels server work;
4. reaching a time or exploration ceiling is explicitly inconclusive. It may
   never be reported as a disconnected route or a proven fuel gap;
5. when Balanced has already proved a legal, access-correct road connection
   but cannot finish its 50/50 preference refinement before the deadline, it
   returns that bounded connection with the explicit
   `balanced_distance_fallback` diagnostic and warning. A cancelled request
   never uses this fallback. The province-scale distance proof initializes
   only graph nodes it actually visits instead of clearing every Ontario- or
   Quebec-sized work array before the first search step;
6. dense pump regions use a forward-oriented matching working set capped at
   192 newly snapped candidates per planning origin after at least 48 pumps
   have matched. This is a candidate-generator bound, not a reduction in the
   live fuel sidecar or the pumps shown on the map. Sparse regions remain
   uncapped. A retained candidate still has to pass the
   current tank range, access, forward-progress, active-profile route, and
   continuation proof; and
7. a resumable partial window may commit a pump only after both its active-
   profile approach and a sensible forward continuation are proved inside the
   deadline. Late or unproved pumps are discarded. Province-scale active-
   profile candidates are proved serially in graph-rank order so two expensive
   searches cannot consume the same CPU window and leave both unfinished. The
   approach and continuation proofs run on the same request runtime as the
   foundational route instead of reopening the province graph per candidate.
   A candidate whose already-computed destination-rooted graph distance fits
   the next tank proceeds directly to its active-profile continuation proof;
   another province-wide reachability search runs only when that direct
   continuation cannot be proved and a later pump may still be required. Once
   that pump is proved, its continuation is evaluated from a full tank; fuel
   consumed before the pump cannot reduce the post-refuel arrival allowance or
   manufacture a duplicate continuation/second stop.
   When an authoritative admin polygon owns a pin, endpoint resolution accepts
   that ownership without loading the same region merely to disambiguate
   overlapping province/state rectangles. Pins outside or between those
   polygons still use eligible-road probing; and
8. the iOS live-planning window is 20 seconds. This is a maximum, never a
   minimum delay: a proved short ride returns immediately. For a pump candidate,
   the approach receives only its allotted portion of the remaining window so
   it cannot consume the continuation proof's reserved time. A pump is still
   committed only after both sides are proved. Bounded fuel-route work skips a
   diagnostic-only full-pack dirt-corridor scan after the route is known; normal
   route requests retain that diagnostic.

The diagnostic contract now records the route-first budget and outcome,
profile failure reason/timing/exploration count, pumps physically in range,
cache-versus-fresh target matches and each target pass, every routed candidate's
rank/timing/outcome/rejection, whether dense matching was limited, the exact
deadline phase, whether route-first shared its request runtime, and whether
candidate proofs shared that runtime, endpoint-resolution time/source/probe
count, whether route-first was attempted or safely skipped, the direct-distance
lower bound, the remaining first-leg range, planning-data load time, and whether
the request was cancelled. It also records route-first snap/search/post-process
timing and exploration count, the deadline remaining before and after each
candidate route, each candidate's approach allocation, and whether the bounded
route omitted the diagnostic-only corridor scan. These fields distinguish data
loading, endpoint matching, graph search, result processing, and exhausted
continuation time without changing route selection.
The fixed Ontario
two-point fuel reproduction now
returns a safe one-stop chain in about 6.2 seconds locally instead of 53
seconds. The appended-leg reproduction with only 122.5 km remaining returns a
proved, resumable pump window in about 7.4 seconds instead of reaching the
60-second platform timeout. Target preparation fell from about 14.9 seconds to
milliseconds on the cached reproduction. Exact timings are machine-dependent; the semantic gates are
the hard deadline, no false no-route/no-fuel result, and no unproved pump.

### Foundation-route fuel reuse and route-coherent pump selection — 2026-09-03

The next device pass exposed a more fundamental source of both latency and
route-quality drift. The planner first proved the selected Dirt/Balanced/Clean
ride, then treated fuel insertion as permission to route the profile again to
several pumps and back to the destination. In a dense or winding region that
could consume the entire 20-second window. More importantly, Dirt could abandon
an already-better route, drive a long paved approach to a remote dirt segment,
and finish with less dirt than Balanced. Fuel planning now obeys these
pack-independent laws:

1. the completed selected-profile ride is the authoritative foundation for the
   fuel decision. When one pump snapped to that route makes both fuel hops safe,
   the planner partitions the existing geometry at the pump and reuses it. It
   does not search the profile again merely because fuel was enabled;
2. every returned partition receives its own distance, surface statistics,
   maneuvers, restricted-distance accounting, backtrack metrics, and a bounded
   pump-to-road access connector. All other safe pumps matched to the same
   foundation remain available to **Choose another pump**;
3. the 192-pump dense matching working set is ordered by proximity to the
   actual winding foundation route before straight-chord proximity. This keeps
   a pump beside the chosen road from being crowded out by thousands of pumps
   that happen to be nearer the endpoint chord. Route proximity is recomputed
   per request; it is never persisted in the reusable road-snap cache;
4. if an exact geometry partition is unavailable, candidate selection compares
   the complete approach-plus-continuation chain. Minimum stop count and
   meaningful forward progress remain primary; the active profile's whole-chain
   quality is then evaluated. A pump beside the foundation route may tolerate a
   bounded 20 km chord-relative continuation reversal because a winding road can
   make that diagnostic appear backward even while the route progresses. Tank
   range, route-connected continuation proof, total chain length, and the
   existing detour/retrace guards remain mandatory; and
5. the LIVE iOS builder no longer sends a speculative request for the next rider
   leg while the current combined route/fuel operation is running. It consumes a
   cached next-leg distance when one exists; otherwise it builds forward once
   and rewinds the prior fuel choice only if the real suffix proves it unsafe.
   On-device planning retains its local bounded look-ahead; and
6. loading and inflating a regional graph is prerequisite I/O, not selected-
   profile search. The bounded route-first search allowance starts after the
   graph and fuel sidecar are available, while the outer fuel-window deadline
   remains the absolute cap. A cold Ontario request therefore receives the same
   route proof as the identical warm request instead of losing half its search
   budget to graph preparation; and
7. long regional chains are incremental. If the active profile finishes the
   route to a forward pump inside that pump's approach allowance but the
   continuation proof reaches the outer deadline, the service returns the
   routed pump prefix as a successful incomplete window. The client commits the
   pump and resumes from it with a full tank and a fresh window. A pump whose
   own approach finishes after its deadline is never committed, and a completed
   non-timeout search that proves no forward continuation remains a real gap.
   Cross-region fuel planning does not first measure the entire multi-province
   profile route. It uses the endpoint lower bound only to seed the minimum stop
   count, then proves every regional route and tank-limited hop incrementally.

The diagnostics identify foundation reuse, foundation route distance and dirt
percentage, matched and route-priority pump counts, selected pump, final chain
distance/dirt percentage, avoided profile-route attempts, and for each pump its
source, along-route/off-route placement, route-cell distance, full-chain
distance/dirt percentage, and continuation backtrack. The client also records
when speculative LIVE look-ahead was skipped in favour of forward build/rewind.
Cold-start diagnostics additionally record the window remaining after load,
profile-search allowance actually granted, milliseconds restored by excluding
the load, and the explicit after-load budget boundary. Incremental timeout
windows report `selectedReason=routed_prefix_timeout` and
`partialReason=approach_proved_continuation_timeout`, so a future field log can
distinguish safe progress from an all-or-nothing failure.

Fixed production-pack reproductions now cover the reported coordinates. On the
reference development machine, Halifax-to-southwest Nova Scotia completes in
about 5.3 seconds with zero pump profile reroutes; central Ontario completes in
about 4.8 seconds at 85% dirt instead of timing out; and the northern Ontario
surface switch retains the same useful pump while Dirt improves from about 53%
to 66% dirt. The September 3 Halifax-to-Ottawa-area reproduction
(`44.764830,-63.340265` to `45.645111,-75.907752`, 374 km usable range) returns
three routed pumps in its first incomplete regional window instead of returning
a 422 with zero pumps. Timing is diagnostic, not a route law. The gates are a
completed safe chain, preservation or improvement of the selected profile
objective, sensible progress toward the rider waypoint, and retained pump
alternatives.
The fixed-coordinate command is `npm run bench:fuel-regressions`.

### Cross-region retained-pump recovery — 2026-09-03

The Nova Scotia-to-Ontario device route
(`44.764830,-63.340265` to `44.792905,-79.211817`, 289 km usable range)
proved a final distinction between fuel-graph reachability and a rider-visible
profile route. After five valid pumps, the fuel graph selected a Quebec-to-
Ontario pump near `45.469495,-76.680414`; the real Dirt route then failed at
the authored provincial seam. The client had no alternate from the completed
fuel search, repeated a province-wide match with only five seconds left, and
kept a 791 km unverified tail. That is recovery failure, not evidence of a
fuel gap.

Cross-region pump selection now obeys these additional laws:

1. a graph-only pump is a ranked candidate, not a committed waypoint, until
   the client proves its real Dirt, Balanced, or Clean approach within the
   current tank;
2. the service retains up to four ranked graph-valid candidates from the
   already-completed search. The public response remains capped at six choices
   for the pump-replacement interface;
3. every retained candidate carries its own ordered regional graph minima, so
   the client validates the alternate against the correct seam budgets rather
   than reusing the selected pump's final segment;
4. if the selected pump fails real profile routing, the client immediately
   tries the retained forward candidates in rank order. Rejected candidates
   never appear as fuel waypoints and are excluded from any later search;
5. a successfully recovered pump is committed once, resets the fuel tank and
   planning watchdog, and starts the next one-pump window with the full time
   allowance. Candidate deliberation is bounded; it never expands back into a
   search over hundreds or thousands of pumps; and
6. exhausting the shortlist may start one fresh search with every rejected
   station excluded. A timeout remains unknown coverage and preserves the road
   route; only a completed proof may report a fuel gap.

The fixed regression rejects the first seam-incompatible pump, commits the
second retained pump, keeps every built hop at or below 289 km, and continues
from that pump without repeating fuel search for the failed window. This repair
changes neither route-profile costs nor graph, geometry, fuel, or seam pack
bytes.

Android must implement the same semantics before parity is claimed: a hard
total request deadline, cancellation propagation, the explicit bounded
Balanced fallback, dense forward pump matching, and proof-before-commit for
partial windows. The added diagnostic fields are optional and
forward-compatible so an older Android decoder will not break, but Android
must emit them when its live and on-device routing twins receive this repair.
Android receives the LIVE foundation-route repair from the shared service; its
offline twin must also partition an already-proved profile route when safe,
retain route-priority alternatives, rank whole chains rather than isolated pump
approaches, avoid concurrent speculative next-leg work, and commit only an
in-deadline routed pump prefix when a later continuation proof times out.

## 11. Current product status

### Implemented and covered locally

- Canonical rider itinerary and generation-guarded builder.
- Flat Point/F leg presentation rather than parent/subleg hierarchy.
- Default-on automatic fuel planning, deliberate manual-off mode, and fuel-gap states.
- Hard live fuel-planning windows, dense-region pump matching, cancellation,
  and explicit inconclusive-search diagnostics.
- Fuel waypoint alternatives and forward station overrides.
- Clear Route availability repairs.
- Eligible-edge endpoint resolver and NS/PEI overlap regression coverage.
- Fuel-layer visible-bounds cache, deterministic clusters, and candidate halos.
- Fixed-pin Nova Scotia benchmark.
- Identity-safe pack promotion that merges only approved regions into the
  current remote catalog and rejects bare local publication.
- Immutable-release benchmark loading with graph, geometry, and fuel checksum
  verification.
- Shared route/fuel service contract and exact pack identity in diagnostics.
- Installed-pack byte and checksum verification with mismatched-file repair.
- Large-graph Dirt, Balanced, and Clean live-search scaling with fixed Ontario
  short-route and long-route regressions and unchanged small-region limits.
- Shared live route/fuel planning, returned route-window reuse, targeted
  destination escape, bounded prior-edge history, and warm fuel/pump context.
- Cross-profile duplicate-node topology, hard-primary urban-core avoidance,
  scored smaller-settlement avoidance, and bounded low-DIRT share recovery.

### Not yet accepted end to end

- Android parity with the frozen iOS/shared-routing candidate.
- Pack Factory replication and promotion for the remaining provinces,
  territories, and states.
- Full online/offline parity for every newly promoted regional pack.
- Navigation-time fuel carry after the rider has already consumed fuel.
- Complete navigation/off-route/incident recovery audit.

The September 3 White pass accepted route creation at app 2 (13): short,
single-region, cross-region, direct-in-range, automatic-fuel, stage-local edit,
incremental long-chain, and honest remote-gap behaviour. The exact service and
reference-pack identities are frozen in
[ROUTING-FREEZE-2026-09-03.md](ROUTING-FREEZE-2026-09-03.md). Cross-country
routing remains a stress case rather than the ordinary product use case, but it
no longer blocks regional pack production.

### Work priority and stabilization gates

The first applicable priority is always a blocker preventing meaningful device
testing. Do not move to pack promotion, navigation hardening, onboarding, or
polish until route creation is trustworthy.

**Gate 1 — Route creation:** short and long single-region routes, eligible-edge
snapping, forward fuel chains, flat Point/F legs, fuel replacement, From Here →
Plan preservation, waypoint operations, Clear Route, profile isolation, and
cross-region seams all pass fixed regressions.

**Gate 2 — Permanent routing matrix:** fixed Nova Scotia, Atlantic cross-region,
BC–Alberta, and BC–Washington coordinates run across every profile, representative
fuel ranges, applicable Allow Unknown states, installed/live source paths,
waypoint editing, and fuel replacement with deterministic before/after results.

**Gate 3 — Pack release:** record immutable candidate identities, validate graph,
geometry, fuel, seams, and the routing matrix, complete physical acceptance, then
promote the exact approved bytes. Current published packs remain untouched until
that deliberate release.

**Gate 4 — Navigation:** prepare corridor layers and routing packs, survive
connectivity loss, reroute around reported obstructions offline, preserve state,
and verify cues, progress, arrival, off-route detection, incident sync, active
fuel continuity, and visible route gaps.

**Gate 5 — Onboarding and polish:** explain DIRT and pack preparation clearly,
request permissions in context, make first-route creation understandable, and
verify accessibility, motion, layout, empty, loading, failure, and recovery
states.

When deciding what comes next, choose in order: a blocker preventing testing; a
regression in previously working behaviour; an unresolved Gate 1 issue; missing
coverage for a Gate 1 repair; Gate 2; Gate 3; Gate 4; then Gate 5.

## 12. Change discipline

1. Device feedback produces a reviewable diagnosis before code changes.
2. Richard approves the proposed behavioural correction before implementation.
3. Pack bytes and routing/search code do not change in the same repair.
4. Each defect receives a fixed regression test using the original coordinates.
5. Each work package is bounded to declared files and one focused commit.
6. Client and live service are deployed and tested as a matched release.
7. Logs must record the inputs, revision, candidates, rejection reasons,
   fallback/cap status, and final decision.
   Every live route, fuel-chain, and fuel-data request also records one echoed
   request ID, start, HTTP response or transport failure, elapsed time, byte
   count, timeout/cancellation state, and a terminal generation disposition.
   Fuel diagnostics record profile-route attempt count, the slowest candidate
   route IDs and timings, longest candidate hop, requested window budget, and
   any budget overrun so a cancelled pin move can be distinguished from a
   server search that never returned.
8. A timeout never masquerades as a no-path or proven fuel gap.
9. Historical measurements remain archived but are never used as a current
   baseline after code or pack bytes change.
10. No design skill or agent may remove existing product functionality without
    rider approval.

## 13. Single-document authority

This is the only active routing document. Previous routing introductions, locked
law documents, itinerary contracts, fuel-gap contracts, handbacks, project-state
snapshots, phase corrections, visibility reviews, build plans, pack notes, and
refactor findings are decommissioned under `docs/archive/routing/`.

Pack data model / Graph-v3 build order: see `docs/PACK-DATA-V3-AUTHORITY.md`
(authoritative for pack data).

Pack production and release workflow: see `docs/PACK-FACTORY.md`. Android
routing/fuel/navigation parity: see `docs/ANDROID-PARITY.md`.

The archive is evidence, not authority. No archived instruction may drive new
work unless Richard explicitly restores it and this document is updated in the
same change. Every accepted routing decision, current blocker, release-policy
change, or work-priority change must be recorded here so a future agent has one
place to read and one place to update.
