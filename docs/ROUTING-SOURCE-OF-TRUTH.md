# DIRT routing — source of truth

Updated: 2026-09-13. Owner: Richard Smith.

## 1. Authority and purpose

This is the single maintained document for DIRT routing: product intent,
architecture, routing data, fuel, regional continuity, acceptance, and current
work. Change this document in place when a decision changes. Remove the replaced
rule; do not append a competing rule, create another routing specification, or
use an old experiment as current instructions. Git history retains old decisions.
Richard's current instructions take precedence over this document.

Routing is being rebuilt from a fresh statement of the vision. Existing code,
packs, tests, and measured experiments are assets to evaluate, not obligations
to preserve an unsuccessful architecture. This reset does not authorize erasing
code, rebuilding data, reverting the app, or changing the accepted interface.

There is no requirement to use live server routing, keep complete regional
graphs in a persistent service, publish every experiment, maintain identical
JavaScript and Swift implementations, or use a particular third-party engine.
There is no distance or province-boundary rule that automatically selects the
server or changes the rider's requested style.

Other product documents may cover navigation presentation, maps, accounts,
subscriptions, privacy, and release operations. They must link here for routing
requirements rather than maintain their own versions. Routing requirements for
future Android work also live here; implementation or parity is not implied.

## 2. The rider's result

DIRT helps motorcycle riders create useful adventures over connected roads and
trails, through their chosen places, with understandable surface choices and
fuel planning. Short rides, long rides, and province/state crossings are all
part of the intended product. A border is not an error or the end of a journey.

The rider chooses places and riding preferences. DIRT should produce a legal,
connected route promptly, preserve useful progress on long calculations, and
explain any limitation accurately. A long trip may take longer than a short one;
the app must not hang, exhaust memory, silently change the trip, or claim a
destination was reached when it was not. Planning in stages remains an option,
not a substitute for fixing regional continuity.

### Riding styles and preferences

| Control | Intended outcome |
| --- | --- |
| Dirt | Seek as much meaningful continuous known dirt as feasible connected alternatives support, within legal access, fuel, coherence, and rider preferences. Use paved connections when needed. Avoid repeated spurs or gratuitous loops that merely inflate a statistic; disclose search limits. |
| Balanced | Seek the closest feasible mix to half dirt/unpaved and half paved across the owning rider leg, subject to the other constraints. Fuel stops do not each restart the mix target. |
| Clean | Prefer paved backroads. Do not hunt for dirt; disclose necessary other-surface endpoint access or connections. |
| Wander | Continuously adjust willingness to travel farther within the selected style. Zero must not turn Dirt into Clean. Adjacent values can select the same roads; a unique route at every tick is not required. |
| Allow Unknown | Explicitly permit the supported uncertain-road/access category. It never overrides known motorcycle prohibitions, barriers, or closures. Clean keeps it off. Unknown surface and uncertain motor access are distinct facts. |

Respect the rider's settlement/highway avoidance and access settings. Small
rural towns, necessary endpoint access, and real geographic connections must
remain distinguishable from an unnecessary trip through a large built-up area.
Do not revive arbitrary geographic boxes or a paved-only corridor as product law.

Report the actual surface composition, including unknown portions. Preserve
the source's separate paved, gravel, dirt/technical, and unknown facts. Never
count unknown as proven dirt. If a UI summarizes known unpaved riding as Dirt,
retain its breakdown and a consistent calculation. A Dirt candidate must not
ignore a better otherwise eligible dirt-rich route already found for Balanced.
Do not claim an optimum when a bounded search only found a feasible candidate.

### Rider points, edits, and saved routes

- From Here preserves the chosen origin and destination. Plan preserves the
  ordered rider points. Computation, fuel generation, and regional subdivision
  must not silently delete, reorder, or substitute them.
- Rider points and generated fuel stops have distinct stable identities. A
  rider-selected station remains a rider point; generated stops remain F1, F2,
  and so on. Internal regional boundaries are not extra rider waypoints.
- Generated fuel points remain bound to mapped stations rather than freely
  draggable locations. A replacement must verify legal incoming and onward
  routing/fuel, retain unaffected earlier stages, and reject stale results.
- A selected rider waypoint highlights and can be dragged. After movement and
  release, ask the rider to confirm placement. Yes initiates rebuilding; No
  permits further refinement. Inserting a draft into a leg alone does not show
  that confirmation or start routing before the movement/confirmation flow.
- Match placement to a nearby legally usable road. Show the matched position;
  do not secretly move a point across water, a barrier, or onto an unrelated
  distant road to force success. Preserve requested and matched coordinates.
- Edits preserve unaffected stages and settings. Revalidate downstream fuel
  when a changed approach or distance affects it. Cancelled or older results
  cannot overwrite newer rider intent.
- Save, reopen, and start preserve the chosen route, points, settings, fuel
  identities, and generation identity. New rides or relevant edits may choose
  different qualified roads. A performance-only change should preserve results
  where equivalent behavior is expected; a deliberate routing correction can
  change newly generated geometry with explicit comparison and evidence.

### Loop and navigation handoff

Preserve the accepted Loop experience while repairing destination routing.
A loop returns to its original start, seeks a circuit with limited retracing,
and respects the configured target and preferred exploration direction.
That direction is not a mandatory first bearing. Shared access roads may be
necessary; a perfect circle is not promised. Initial refuelling does not replace
the original return anchor. Do not incidentally reopen Loop tuning.

Navigation receives the same chosen route and ordered named stages. Recalculation
preserves completed progress, remaining rider anchors, and fuel state. Cue,
speech, HUD, and lifecycle requirements are in
[the navigation document](00-NAVIGATION-SOURCE-OF-TRUTH.md).

### GPX preservation and deferred conversion

An imported trace is evidence of a line, not proof of a legal navigable road.
Preserve its original geometry and segment boundaries. Do not silently replace
it with a generated route or bridge unmatched sections with invented roads.
Graph conversion remains deferred unless Richard requests it. When undertaken,
produce a separate proposed route, make loop entry/direction explicit, preserve
monotonic progress through crossings, disclose unmatched sections/deviation,
and retain the original for comparison. Converted routes use the same access,
fuel, and continuity requirements as ordinary routes.

## 3. Architecture: do useful work without loading everything

The intended direction is device-first routing with a bounded working set of
road data. Load what a calculation needs, expand as necessary, and reuse useful
preparation. Local availability must mean local calculation can actually run;
online connectivity is not a reason to force a server calculation.

Distinguish three quantities in both design and measurements:

1. **Stored/downloaded data:** immutable road packs or derived indexes on disk.
2. **Resident working data:** the subset occupying real process memory now.
3. **Searched data:** the roads and turn-aware states examined for this request.

Having a whole region on disk does not require decoding it all into memory.
Restricting a search after allocating whole-region arrays does not satisfy
selective loading. Include metadata, reverse indexes, geometry, label pools,
queues, caches, and retained references in the memory accounting.

The "fog of war" idea means loading a useful connected neighborhood around
the origin, destination, required points, and the developing route. It does not
mean following only the nearest road toward a straight-line target. The search
must be able to discover a bridge, detour, border crossing, useful dirt route,
or fuel station outside the initial loaded area. Unloaded is not disconnected.

A compact reusable connectivity/index layer may guide which detailed areas to
load. Keep detailed geometry and legal search state demand-driven, with bounded
caches and explicit cancellation. Loading more after a route is returned may
prepare navigation or later edits; it cannot retroactively prove that route's
legality, connectivity, or fuel sufficiency.

Region pack boundaries are a storage/distribution choice. They must not dictate
the search horizon or require whole-province joining on every request. Internal
tiles/pages/shards may differ from the rider's download regions. A small remote
service may provide distribution, indexes, or other justified lightweight help;
any heavier hybrid role needs measured benefit and an explicit update here.
Do not choose another engine merely because old experiment notes recommended it.

### Data acquisition and network responsibility

Pack delivery through a CDN/object store is different from routing on a server.
Downloadable data may still be hosted. There is no mandatory live per-route
graph loading/joining service and no requirement to publish a local experiment
before it can be tested.

For the current local candidate, determine the necessary compatible planning
data and use the existing informed acquisition flow before calculating. Include
intermediate regions when needed, show download size/progress, support decline,
cancellation, retry, and reuse. Preserve the rider's pins and settings. Declining
or missing data pauses local calculation; it must not trigger a hidden live
fallback, run an empty graph, or report "no path."

Improve selective acquisition as the architecture supports it. Do not turn the
interim whole-file acquisition workflow into a permanent requirement to fetch
every pack along every possible journey or the whole country. Expand and request
additional data honestly when necessary. During riding, prepare needed maps and
routing data progressively without blocking the main thread or misrepresenting
which later sections are available offline.

## 4. One continuous legal road network

Published map tiles are display data; routing graphs encode connectivity;
geometry describes road shapes and matching; fuel data describes station
locations. A visible line or pump is not proof of a usable route or station
entrance. Pair routing inputs by validated identity, not appearance or filename.

- Preserve original OSM node/way identity, directed travel, surface/access
  leaves, grade, barriers, and turn restrictions. Coordinates alone never
  create a junction. Unknown surface never implies motor permission.
- Retain incoming directed-edge and via-way restriction progress across search
  pages, regional seams, waypoint/fuel stages, cancellation/resumption, and
  virtual snaps. Array indices from different packs are not global identifiers.
- A seam must represent verified source topology with compatible identity,
  source epoch, direction, grade, access, and boundary-spanning restrictions.
  Do not bridge nearby disconnected roads, water, or grade separation by distance.
- Find connected geographic alternatives rather than assuming the fewest
  administrative regions or the first border chain is the only viable journey.
  Region crossings do not reset destination intent, avoidance, or fuel.
- Validate graph, geometry, fuel, and seam/catalog identity before use. Reject
  corrupt, incomplete, unsupported, or incompatible data with a data error.
  A decoded header alone is not evidence of a compliant search.

Use the existing immutable packs to fix loading, search, and integration first.
Do not rebuild packs to compensate for a runtime defect. Exact, disposable
spatial/connectivity/reverse-adjacency indexes derived from verified bytes are
permitted; bind them to their input hashes and format version, and invalidate
them on mismatch. They must not fabricate connectivity or discard legal facts.
If a specific source-data defect genuinely requires a new pack, document the
evidence and scope here and obtain authorization for that data revision. Never
overwrite a sealed release or promote data implicitly during a code repair.

Motorcycle access uses applicable vehicle-specific and directional rules;
explicit motorcycle denial is not reopened by ATV permission. Endpoint-only
access is not through access. Preserve conditional/seasonal rules and applicable
timezones; unsupported or ambiguous safety conditions cannot be treated as open.
Snap and fuel connectors must obey the same directions, barriers, and turns.
Source provenance and required licensing/attribution survive this consolidation.

## 5. Fuel belongs to the whole journey

With automatic fuel enabled, first approach the closest legally reachable mapped
station, even when it is nearby. Being at a mapped station can satisfy that
approach. This is a separate distance/reachability phase; recreational routing
begins at that planned refill. Preserve the legal arrival orientation while
resetting recreational history appropriately. Do not assume an arbitrary origin
has a full tank. A planned approach is not knowledge of actual starting fuel.

After a planned refill, use the configured range minus reserve. Count actual
selected road distance, including approaches, connectors, and seam tails.
Ordinary rider points and regional boundaries do not reset the tank. A proposed
stop or passing a pump does not prove a physical refill or current availability.

Select reachable mapped stations that support useful onward progress and the
selected riding style. Earlier refuelling is valid where needed. Do not impose
historical 75-percent barriers, fixed candidate counts, or a global minimum-stop
objective that overrides the ride. Avoid needless repetitive stops and preserve
already proved useful stages. Reconsider a prior choice when its downstream
region or station exit makes the rest infeasible.

Before declaring fuel coverage, verify the actual connected chain. Include legal
station approach/exit, reserve across the full stage, and the final destination.
At a destination without refuelling, account for the legal onward route to fuel;
a short lower bound does not prove a longer chosen Dirt route fits the range.
Do not spend the entire range reaching a regional anchor and forget its tail.

Fuel off means no automatic stops and no claim of fuel sufficiency. Road-route
completion and fuel verification are independent:

| Outcome | Meaning |
| --- | --- |
| Road complete, fuel verified | A connected route reaches every rider point and the planned fuel chain satisfies the stated assumptions. |
| Road complete, fuel unknown | The road route is usable with the appropriate warning/acknowledgement; missing data, a timeout, or an incomplete search has not proved fuel coverage or a gap. |
| Road complete, demonstrated fuel gap | Explain the demonstrated gap and assumptions; do not claim coverage or throw away valid road geometry. |
| Road incomplete | Identify the unfinished section and cause. Do not draw a false connector or mark the requested destination reached. |

When fuel cannot be proved, continue/retain the valid requested road route with
honest fuel status and existing warning behavior. Preserve earlier useful work.
Do not discard a completed road route merely because pump planning failed.

## 6. Performance, limits, and completion

Measure from rider action through data preparation, matching, search, fuel,
geometry, validation, and visible completion. Separate download time from local
calculation, and cold startup from reused preparation. Report total elapsed
time as well as individual windows; a fast inner loop is not a fast product.

Each calculation/window must have explicit resource bounds and cancellation,
including preparation and allocation. Long itineraries may progress through
fresh bounded windows after a valid committed rider/fuel stage. Do not impose
one short immutable deadline over an arbitrarily long trip or count successful
fuel stops toward a failed-retry limit. Bound failed/no-progress repetition;
never reset internal clocks invisibly to hide overruns.

Memory must be bounded by useful loaded work, not by blindly allocating every
possible label for all roads in all touched provinces. Measure real peak resident
memory, allocation peaks, retained references, page/cache bytes, and disk/network
work. Cache limits alone do not bound memory while other objects retain the data.

Define numerical performance targets against named test hardware and workloads
before accepting an implementation. Targets are measured engineering decisions,
not arbitrary inherited constants. A candidate must materially improve memory
and/or latency while preserving legality, fuel correctness, and riding character.
No claim of consumer scale follows from one successful route or a warmed cache.
For any retained server computation, test concurrent requests, bounded admission,
per-request memory, cancellations, and cold behavior on the actual service class.

## 7. Qualification and working method

Continue the authorized build → review → test → repair cycle until a coherent
candidate meets its declared acceptance criteria or a specific external blocker
prevents progress. Passing one microbenchmark is not the end of the job. Answer
Richard's questions and continue work; provide concise findings, failures, and
next actions rather than silent work or unsupported success claims.

Use existing fixtures and raw results. Record exact app/source identity, dirty
changes, pack hashes/epoch, endpoints, settings, seed, fuel range/reserve, device,
and computation source. Repeat relevant cold/warm cases. Use focused tests for
each repair and run the necessary integrated suite once the candidate is stable.
Do not rerun unrelated suites or change acceptance to make a result green.

The acceptance matrix must cover:

- Empty/missing/incompatible packs; consent/decline/cancel/retry; preserved pins.
- Short single-region rides and long dense-region rides, especially southern
  Ontario without needless northern data residency.
- NS–NB, NS–QC/ON, Canada–US, and longer multi-region chains, in both relevant
  directions, including alternate connections around lakes/water/ferries.
- Dirt, Balanced, Clean, supported Unknown settings, and meaningful Wander
  values; fuel on/off and the rider's actual reserve-adjusted ranges.
- Initial nearby fuel, legal same-edge station access, arrival-direction
  restrictions, late-stage fuel choice, destination escape, and journeys with
  more than sixteen valid fuel continuations.
- Edit/cancel/resume, stale replies, generated-versus-rider point identity,
  save/reopen/start, and unaffected-stage preservation.
- Honest road/fuel outcomes for limits, real disconnection, missing data, and
  unsupported controls. Compare riding character alongside time and memory.

Honor the repository's single-existing-simulator policy. Physical device
installation and production promotion require current owner authorization;
automated proof and real-device acceptance must be reported separately. A repair
does not require rebuilding a shipped app when only an already-used server
changes, but native binary changes do require a new build to reach a device.
Verify the actual path; never promise a server fix reaches a local-only binary.

## 8. Current state and next work

This section is a dated starting inventory, not a claim that the vision is
implemented. Update it as results change instead of adding another status file.

| Item, as reviewed 2026-09-13 | State |
| --- | --- |
| Main product checkout | `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`, app checkpoint `91cc3cc`; preserve the accepted app rather than restoring an older shell. |
| Existing native candidate | `.build/engine-architecture`, branch `audit/baseline-recovery-20260913`, HEAD `b4c2393` plus uncommitted repairs. Verify status before editing. |
| Device checkpoint | Owner task reports build 42 remains installed; build 43 was not installed. Compilation or install does not prove routing-data readiness. |
| Candidate data | Phone catalog `fabric-v4-20260909-02`; some historical fixtures use `fabric-v4-20260908-02`. Results against one do not automatically qualify the other. |
| Verified acquisition repair | DEV planning now waits for the existing pack prompt and verified installation, then resumes the same pins; missing data is not reported as disconnected roads. Model-level consent/resume/decline tests pass; actual download progress/cancellation and app presentation still need integrated verification. |
| Owner-log replay | All four build-42 requests complete with initial refuelling in the real native simulator path using catalog `fabric-v4-20260909-02`, exact logged coordinates/seeds and 200 km range / 10% reserve. Zoom is available only to the logged decimal precision. The 33-test focused result is `/tmp/Dirt-Phone42-Exact-Requests-R2-20260913.xcresult`; raw geometry is in `.build/recovery-evidence/phone42-exact-requests`. This is not phone acceptance. |
| Latest integrated evidence | `/tmp/Dirt-DEV43-Readiness-Full-Serial-20260913.xcresult`: 345/350 tests pass; failures include two full fuel aggregates, a now-removed duplicate focused aggregate, and two UI checks. Historical and initial-fill fuel replays each complete 17/21. All 19 direct comparisons preserve geometry and reported dirt; two completed Clean cross-region fuel shapes differ by exact border-node matching. |
| Known qualification gaps | Whole-region decoding/indexing/search allocation is still present. Successful fuel continuations currently consume a sixteen-attempt cutoff; same-leg pump reconsideration, legal-state continuity, Wander and full riding-character qualification remain open. Unknown-access reporting in the owner replay also needs checking against V4 directed permissions. No real resident/allocation peak has yet been measured; device capacity and cache limits are not such measurements. |
| Legacy hosted services | DEV was last audited at `139a173`; production at `af96ca97`. These are observations, not desired architecture or current deployment proof. Recheck only when relevant. |
| Release | No deployment, archive, device replacement, or App Review submission is part of documentation consolidation. |

The next implementation pass should verify existing acquisition repairs, then
address whole-graph preparation/allocation, turn-aware regional continuity,
fuel range reserved for complete stages, and successful long-chain continuation.
Check the reported sixteen-attempt cutoff and incomplete destination fuel proof
against current code before changing them. Preserve useful fixes; do not start
over from an old app or repeat an engine comparison without a concrete reason.

Raw evidence remains under `.build/` and benchmark/test fixtures. Historical
worktrees there are code/evidence snapshots, not current documentation sources.
Do not load their AGENTS/specifications as routing instructions or resume an old
checkout without applying this current authority. Main and the active candidate
carry the same canonical document; keep this path synchronized when accepted
decisions move between them. Do not create separately evolving routing guides.

## 9. Existing V4 data format reference

This describes the existing data that must remain readable during the repair;
it is not a requirement to rebuild or publish packs. Check encoder/reader tests
when changing implementation. Legacy V2/V3 decoding is not V4 legal-topology
qualification. Every participating region must satisfy the required schema,
capabilities, paired identities, and compatible source epoch.

Objects: `graph.v4.bin` (DRT4, little-endian magic `0x34545244`, version 4),
paired `geometry.v1.bin` (GEOM v1), `fuel.v1.json`, and `pack-manifest.v2.json`.
Manifest fields include `schema`, `fabricReleaseId`, `regionId`,
`capabilities: ["legal-topology.v1"]`, `sourceEpoch`, `timezone`, and graph,
geometry, fuel entries with `name`, `bytes`, and `sha256`.

The V4 header is 140 bytes. Offsets below are byte positions in that header;
stored offsets address sections in the file. Multi-byte numbers are little-endian.

| Offset | Field / referenced section |
| --- | --- |
| 0 | magic u32 `0x34545244` |
| 4 | version u16 `4` |
| 6 | flags u16: bit0 from/to; bit1 leaves; bit2 crossing-seconds; bit3 required legal-topology; bit4 derived edge IDs when present |
| 8, 12, 16 | nodeCount, undirectedEdgeCount, directedArcCount (u32) |
| 20 | headerSize u32 `140` |
| 24 | nodeOffsets: Int32[nodeCount + 1] |
| 28, 32 | edgeTargets, edgeUndirectedIndex: Int32[directedArcCount] |
| 36, 40 | edgeAttrs: UInt16[edgeCount] derived cache; edgeMeters: UInt32[edgeCount] |
| 44 | nodeCoords: Float32[nodeCount * 2] |
| 48, 52 | edge ID offsets and UTF-8 ID blob when explicit IDs are present |
| 56, 60 | enumsJson and metaJson |
| 64, 68 | edgeFrom, edgeTo: Int32[edgeCount] |
| 72, 76 | edgeSurfaceLeaf, edgeRoadClassLeaf: UInt8[edgeCount] dictionary indices |
| 80, 84 | edgeGrade: UInt8[edgeCount]; edgeLayer: Int8[edgeCount] |
| 88, 92, 96 | edgeStructureLeaf, edgeAccessLeaf, edgeFlags: UInt8[edgeCount] |
| 100 | crossing-seconds section when present; follow the existing codec's type/length validation |
| 104, 108 | osmNodeIds: Int64[nodeCount]; osmWayIds: Int64[edgeCount] |
| 112 | edgeAccess: UInt8[edgeCount * 2], interleaved forward/reverse for each edge |
| 116, 120, 124 | barriers, restrictions, conditionals |
| 128, 132, 136 | provenanceJson, capabilitiesJson, paired geometry SHA-256 (32 bytes) |

Legal-topology flag bit3 and offsets 104–136 are required. Directed arc count
means legal travel arcs, not twice the undirected edge count. Derived-ID V4
packs use `w<osmWayId>:<fromNodeIndex>:<toNodeIndex>` instead of the redundant
UTF-8 table; readers must handle explicit-ID and derived-ID variants. Such an ID
still requires pack/region context; original OSM identity governs seams.

Leaves preserve surface, highway class, structure, access, layer, tracktype,
and smoothness separately. Dictionaries use index zero as the missing/unknown
sentinel and cannot overflow their encoded index type. Preserve compound surface
tokens. Coarse attributes are derived caches, not a substitute for source facts.
`edgeGrade`: lower nibble tracktype (0 missing, 1–5 grade1–5); upper nibble
smoothness (0 missing, 1 excellent, 2 good, 3 intermediate, 4 bad, 5 very_bad,
6 horrible, 7 very_horrible, 8 impassable). `edgeFlags` includes bit0 ATV
designation and bit1 seasonal; those facts do not override legal motorcycle access.

Directed `edgeAccess`: 0 through allowed; 1 unknown; 2 denied; 3 endpoint
destination only; 4 endpoint customers only; 5 fail-closed conditional/seasonal.
Allow Unknown may affect 1, never reopen 2–5 as through permission.

Barrier section: u32 count then 16-byte records: osmNodeId i64, graphNode u32,
decision u8 (0 allow, 1 block, 2 fail-closed ambiguous), padding 3 bytes.

Restriction section: u32 count then variable records. Each record has a 32-byte
base: osmRelationId i64 at 0; kind u8 at 8; flags u8 at 9; viaWayCount u16 at 10;
fromEdge u32 at 12; toEdge u32 at 16; viaNode i32 at 20 (-1 for via-way only);
exceptMask u16 at 24; vehicleMask u16 at 26 (bit0 motorcycle, bit1 motor_vehicle,
bit2 all); conditionalIndex i32 at 28 (-1 none). This is followed by
viaWayCount interleaved 12-byte pairs: viaWayId i64 and viaEdgeIndex i32
(-1 if not encoded). Flags: bit0 fail-closed unused, bit1 only-*, bit2 malformed rejected;
rejected rows belong in provenance, not accepted restriction records.
Kinds 0–9: no_left_turn, no_right_turn, no_straight_on, no_u_turn,
only_left_turn, only_right_turn, only_straight_on, only_u_turn, no_entry, no_exit.

Conditionals: a UTF-8 JSON object with `rules`, `timezone`, and
`policy: "fail_closed"`; there is no leading binary count. Rules preserve id,
tag, outcomeOpen, evaluable, timezone, and windows. Unsupported/unevaluable
safety conditions are not open. Provenance includes sourceUrl, sourceBytes,
sourceSha256, osmTimestamp, clipPolygonId/sha256, haloMeters, toolVersions,
factoryCommit, sourceEpoch, rejection reasons, counts, and unprovenStitches=0.

Validate the actual geometry hash against the graph and manifest before use.
Original OSM node ID zero is invalid in stored topology; runtime virtual snap
nodes retain parent directed-edge identity and fraction. Validate section
bounds/counts, dictionary references, restriction members, and safety capability;
do not silently ignore missing safety data or mix V3 and V4 in a legal search.

## 10. Keeping this document current

For each accepted change: edit the affected requirement, remove conflicting
wording, update current verified state and remaining work, and cite the exact
test/result artifact when applicable. Keep transient logs in machine evidence
or the task conversation. Add no new routing handoff, freeze, mission, workbook,
parity appendix, or competing source-of-truth document. If an idea fails, change
this vision and its evidence/status directly; recover old prose from Git only
when explicitly investigating history.
