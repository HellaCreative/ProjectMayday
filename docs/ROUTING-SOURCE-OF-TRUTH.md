# DIRT routing — source of truth

Updated: 2026-09-15. Owner: Richard Smith.

## 1. Authority and purpose

This is the single maintained document for DIRT routing: product intent,
architecture, routing data, fuel, regional continuity, acceptance, and current
work. Change this document in place when a decision changes. Remove the replaced
rule; do not append a competing rule, create another routing specification, or
use an old experiment as current instructions. Git history retains old decisions.
Richard's current instructions take precedence over this document.

Routing is being rebuilt from a fresh statement of the vision. Existing code,
packs, tests, and measured experiments are assets to evaluate, not obligations
to preserve an unsuccessful architecture. Richard subsequently authorized deleting the old Swift routing implementation
and rebuilding it greenfield from the successful JavaScript live-pack pipeline.
Preserve Swift infrastructure supporting the JavaScript/app flow. This does not
authorize rebuilding published data, reverting the app, or changing its interface.

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
| Dirt | Strive for 100% meaningful continuous known dirt. Richard expects substantial dirt riding, ordinarily 70–80% or better where the connected legal network supports it; the 675 km / 47% Porters Lake–St Stephen phone result is explicitly rejected. Seek worthwhile meandering dirt alternatives instead of optimizing a straight or short journey. Meaningful dirt is a continuous run of roughly a kilometre or more between paved connectors; a dirt segment shorter than about 500 m does not count as dirt and must never be chosen merely to raise the percentage — this prevents dipping in and out of a paved connector to inflate the statistic. A Dirt result that approaches half pavement has failed as Dirt, not merely scored low. Use paved connections when necessary, preserve fuel/access, and avoid repeated spurs that only inflate the statistic. A low-dirt completed route is not successful Dirt qualification; explain limitations without silently redefining the chosen style. |
| Balanced | Seek the closest feasible mix to half dirt/unpaved and half paved across the owning rider leg, subject to the other constraints. Fuel stops do not each restart the mix target. |
| Clean | Prefer paved backroads. Do not hunt for dirt; disclose necessary other-surface endpoint access or connections. |
| Wander | Continuously adjust willingness to meander and travel farther within the selected style. Full Wander must allow substantial coherent dirt detours; decreasing Wander limits detour appetite without silently converting Dirt to Balanced or Clean. It is not a guarantee that arbitrary endpoints have a 100% dirt connection. Adjacent Wander values may select the same roads; Wander granularity need not make every tick differ. Route-to-route variety across separate generations is a distinct requirement (see "A different ride every time"). |
| Allow Unknown | Explicitly permit the supported uncertain-road/access category. It never overrides known motorcycle prohibitions, barriers, or closures. Clean keeps it off. Unknown surface and uncertain motor access are distinct facts. |

DIRT is a back-roads product. Avoid highways, divided highways, and major
thoroughfares in every style — Clean included — unless a short unavoidable
connector or legal endpoint access requires one. Small rural towns remain usable
and are often necessary: they carry the fuel. An unnecessary trip through a large
city or built-up area is avoided; passing through a small town is not.

This avoidance is a default preference, not an absolute rule. A rider point
placed on or near a highway, in a city, or inside a large settlement is
deliberate intent and must be reached: use the minimum necessary highway or urban
travel to serve that pin, then resume back-roads character before and after it. A
route is never failed for the highway or city mileage a rider's own placement
requires. The default only governs the ride the engine composes between the
rider's chosen points. Respect the rider's settlement/highway avoidance and
access settings. Small rural towns, necessary endpoint access, and real
geographic connections must remain distinguishable from an unnecessary trip
through a large built-up area. Do not revive arbitrary geographic boxes or a
paved-only corridor as product law.

Report the actual surface composition, including unknown portions. Preserve
the source's separate paved, gravel, dirt/technical, and unknown facts. Never
count unknown as proven dirt. If a UI summarizes known unpaved riding as Dirt,
retain its breakdown and a consistent calculation. A Dirt candidate must not
ignore a better otherwise eligible dirt-rich route already found for Balanced.
Do not claim an optimum when a bounded search only found a feasible candidate.

### Progress without a straight line

A waypoint — a destination or a fuel stop — is a place the ride reaches, not a
line the ride follows. Progress toward the next waypoint is a gentle preference,
not a straight-line constraint. The route may head away from a waypoint, or well
to the side of the direct line, when that is how it reaches a coherent dirt
network or a more interesting back road; the value is the riding in between, not
the shortest path to the point. "Always move toward the waypoint" means keep the
waypoint as the pull, not hug the chord to it.

Bound this with a wide tolerance corridor rather than a narrow chord. Exploration
is unconstrained inside a generous envelope around the journey and only
discouraged beyond it, so the search neither tours an unrelated region nor is
squeezed back onto the direct line. The pull toward a waypoint must stay a soft
gradient: heading briefly away to reach real dirt is affordable, not priced out
by a steep penalty. A near-straight result on terrain that offered genuine dirt
or back-road alternatives is a failure of this preference, not a success. The
only hard anchors are the rider's own points; between them the engine is free to
compose the interesting journey.

### A different ride every time

Creating a route is generative, not a lookup. Each new generation — the same
origin, destination, and settings requested again — should aim to produce a
different, equally interesting ride rather than one canonical answer. A fresh
generation seed drives this; the seed already threads the search. This is a
strong aspiration, not an all-or-nothing guarantee: where the legal network
genuinely offers only one good ride — a single dirt corridor out of a location,
say — returning that ride again is correct. Never fabricate variety or distort a
route to manufacture a difference that the roads do not support. Prefer real
alternatives when they exist; accept the honest repeat when they do not. A saved,
resumed, or navigating route freezes its seed and geometry, so reopening or
continuing reproduces the identical ride. Qualification and tests pin an explicit
seed for reproducibility. Do not return a previous route as the default answer to
a new interactive create; reusing a completed route as the incumbent is intended
for an explicitly frozen seed — a saved route, a resume, or a pinned test.

### Rider points, edits, and saved routes

- From Here preserves the chosen origin and destination. Plan preserves the
  ordered rider points. Computation, fuel generation, and regional subdivision
  must not silently delete, reorder, or substitute them.
- Rider points and generated fuel stops have distinct stable identities. A
  rider-selected station remains a rider point; generated stops remain F1, F2,
  and so on. Internal regional boundaries are not extra rider waypoints.
- Fuel stops and distance breaks are movable like rider waypoints (see the owner
  contract in §5, rule 14). A dropped fuel stop snaps to a mapped pump when one
  is under it. A replacement must verify legal incoming and onward routing/fuel,
  retain unaffected earlier stages, and reject stale results.
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

The "fog of war" idea is the core speed mechanism: a whole region can sit on disk
without decoding it all into memory. Load a useful connected neighborhood — on
the order of a 10–20 km working radius — around the origin, destination, required
points, and the developing route, and expand it as the search advances. It does
not mean following only the nearest road toward a straight-line target. Crucially,
this neighborhood must follow the wide tolerance corridor of "Progress without a
straight line," not a tight band on the chord: the frontier pulls in new data as
the search explores off-axis, so fog-of-war loading and creative routing
reinforce each other instead of fighting. The search must be able to discover a
bridge, detour, border crossing, useful dirt route, or fuel station outside the
initial loaded area. Unloaded is not disconnected. Bounding resident memory to
this moving neighborhood — rather than decoding whole downloaded regions — is the
main lever for fast on-device routing and remains the key open performance work
(see section 8).

A compact reusable connectivity/index layer may guide which detailed areas to
load. Keep detailed geometry and legal search state demand-driven, with bounded
caches and explicit cancellation. Loading more after a route is returned may
prepare navigation or later edits; it cannot retroactively prove that route's
legality, connectivity, or fuel sufficiency.

Region pack boundaries are a storage/distribution choice. They must not dictate
the search horizon or require whole-province joining on every request. Internal
tiles/pages/shards may differ from the rider's download regions.

The server exists to let the product scale to hundreds of thousands of riders
cheaply. It does only stateless, cacheable, or account work that a CDN and a
light service scale well: (1) accounts, authentication, and subscription state;
(2) delivery of the immutable graph packs and navigation map tiles from a
CDN/object store; (3) fuel and point-of-interest data that ships into the packs
for offline use; (4) a lightweight region/connectivity index that tells the app
which regional packs a journey needs before any local routing; and (5) catalog,
versioning, and anonymous operational telemetry. The route calculation itself
never runs on the server, and no per-route graph loading or joining service is
required. Every route is computed on the device from downloaded packs, so a
thousand riders planning at once cost the server almost nothing. Any heavier
hybrid role needs measured benefit and an explicit update here. Do not choose
another engine merely because old experiment notes recommended it.

### Data acquisition and network responsibility

Pack delivery through a CDN/object store is different from routing on a server.
Downloadable data may still be hosted. There is no mandatory live per-route
graph loading/joining service and no requirement to publish a local experiment
before it can be tested.

For the current local candidate, determine the necessary compatible planning
data and use the existing informed acquisition flow before calculating. Download
the whole regional packs the rider's points span, including every geographically
required intermediate region: a Nova Scotia → New Brunswick → Quebec journey
downloads all three; an eight-state chain downloads all eight. Once those packs
are on the device the rider may create unlimited routes within them with no
further server dependency — that is the point of downloading. Include
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

## 5. Routing, waypoints, and fuel

### Owner contract: legs and waypoints (15 Sep)

This contract governs routing. Where any other sentence in this document or any
code comment disagrees, this contract wins.

**The ride**

1. The ride is the product. Every leg between two waypoints is the best, most
   interesting ride in that leg's style. It is never the simplest or shortest
   route.
2. Every leg is selectable, whatever its waypoints are (rider-placed or distance
   break). Each leg has its own style and is held to that style's target:
   - Dirt: strive for 100% dirt.
   - Balanced: strive for 50% dirt and 50% pavement on that leg.
   - Clean: strive for 100% pavement on back roads, no highways.
   A route may mix styles leg by leg (for example leg 1 Dirt, leg 2 Balanced).
3. Leg shape. S-curves and wide swings are good. No loops. No out-and-back or W
   shape into or out of any waypoint on the same road. Re-ride a road only when
   absolutely necessary.
4. Dirt means real riding. Dirt runs under 1 km do not count and are not worth a
   detour.
5. Direction of travel follows the roads, not the straight line. "Ahead" means
   closer to the next waypoint by road, so a lake or bay is ridden around, not
   treated as a wall.
6. Wander sets how far the ride may roam: tight and direct at low wander, big
   S-curves and wide swings at high wander. It sets how much of each leg's ridden
   distance may go sideways instead of toward the next rider waypoint.

**Waypoints and experience**

7. Long legs are broken up. Where a leg would run past 350 to 400 km, place a
   distance-break waypoint and continue from there, so the route builds in
   pieces the rider can reshape.
8. Waypoint kinds are rider-placed and distance break. Both are movable with the
   same drag and confirm. Moving one rebuilds only the legs on either side. Both
   are saved and restored with the route.
9. Legs appear one after another as they are built. A long trip may take longer
   to finish; the rider watches it grow.

**Fuel is not part of route building (owner decision, 15 Sep evening)**

10. Route building never consults fuel range, reserve, or pumps, and never places
    a fuel stop. No fuel windows, sweeps, fans, progress shares, or fuel gap
    cards take part in building a route. Hunting for fuel while composing the
    ride produced paved legs and wrong-way detours; the ride comes first.
11. Fuel becomes an advisory layer in a later phase (below). Until it ships,
    routes are ridden with the rider's own fuel judgement, and the app must not
    imply a route has been checked for fuel.

**Tests before any phone build of a routing change**

Routes: Porters Lake to Cape Breton, to Yarmouth, and to north New Brunswick,
each in Dirt, Balanced, and Clean. Report per leg: waypoint kinds, km, dirt %,
and that style's target (100 / 50 / 0), plus total seconds. No fuel stops may
appear. A leg built as a shortest route fails.

### Later phase: fuel and points of interest, advisory only

Parked until the core routing above is built and accepted. Nothing here changes
a route.

Fuel is the primary point of interest and ships first, because running dry ends
a ride. The same "what is near this route" index then serves the rest with no new
machinery, each kind opt-in so a rider only hears about what they care about:

| Kind | Why a dual-sport rider wants it |
| --- | --- |
| Fuel | Primary. Range is the limit on where the ride can go. |
| Camping and accommodation | Where the day can end: campgrounds, sites, motels. |
| Food and water | Diners, general stores, and the last store before a long empty stretch. |
| Sightseeing | Viewpoints, lookouts, waterfalls, beaches, landmarks: reasons the long way is the better way. |
| Repairs and tyres | Motorcycle and general repair, welding, hardware. A long way from home this matters. |
| Rider services | Toilets, showers, water refill, shelter. |

Each kind carries the same facts: distance along the route, distance off the
route, name, and whatever the pack knows about it. What differs is when it is
worth saying: fuel is driven by range, accommodation by time of day and distance
remaining, food by mealtime and by how long since the last one, sightseeing by
simple proximity. Sightseeing may also be shown at planning time so a rider can
drag a waypoint onto something worth seeing.

- After a route exists, walk it once and index the points of interest near it:
  distance along the route, distance off the route, name, and kind. No searching
  and no route changes.
- Fuel tracking is a setting, and turning it on states plainly what it means:
  the rider will get notifications while navigating; the rider must flag when
  they filled up, because the app cannot know otherwise; pump data may be wrong,
  closed, or out of date, so cues are information, not promises.
- Starting navigation asks whether the tank is full. If it is not, offer a route
  to the nearest pump, then rejoin the planned route.
- While navigating, a soft nudge may use the rider's own threshold (for example
  half a tank): name the pump ahead and the distance to the one after it. The
  hard prompt is last chance, not a percentage: fire when the remaining range is
  about to fall below the distance to the last pump still reachable ahead, plus a
  margin. In pump-dense country this rarely fires; in the Cape Breton Highlands
  it fires early, because it has to.
- Accepting a prompt routes a short detour to the pump, then rejoins the
  remaining route at its nearest point. Asking "filled up?" resets the range.
- The planning screen may say where a route outruns the range and where the
  pumps near it are. It never changes the route for fuel.
- Advisory fuel cannot promise the rider reaches a pump. It reports where they
  would run dry on the ride they chose.

Road completion and fuel are independent facts:

| Outcome | Meaning |
| --- | --- |
| Road complete | A connected route reaches every rider point in the chosen styles. Fuel is not asserted. |
| Road complete, fuel advisory shown | The advisory layer reported pumps near the route and where the range runs out, from the rider's declared fuel. |
| Road incomplete | Identify the unfinished section and cause. Do not draw a false connector or mark the requested destination reached. |

The automatic fuel chaining built on 15 September (windows, sweep, fan, progress
share, gap cards) is removed from the routing path and kept in git history. If it
returns, it returns as a rider setting after the ride quality above is met.

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
The current engineering targets for the existing iPhone17 / iOS26.5 simulator
on MacBookPro17,1 (Apple M1, 16 GiB) are: the exact first owner build-42 request
with 200 km / 10% reserve within 8 seconds on first use and 5 seconds on repeat;
the existing southern Ontario Kingston–Orillia endpoints with fuel off within
15 seconds on first use and 10 seconds on repeat for each profile. Target peak
process footprint is 256 MiB for NS and 384 MiB for southern Ontario, with RSS
reported alongside it rather than substituted for footprint. Show initial
progress within 250 ms and acknowledge cancellation within one second. These are
qualification targets, not new routing cutoffs or claims of achieved performance.
They require isolated cold/repeated runs and separate physical-device targets
before phone acceptance; no whole-journey deadline follows from them.

For any retained server computation, test concurrent requests, bounded admission,
per-request memory, cancellations, and cold behavior on the actual service class.

## 7. Qualification and working method

### Active owner-directed sequence — September 14

Work in `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`, branch
`cursor/on-device-routing-speed-37c5`, starting commit `5f7cb8d`.
Richard's latest instruction replaces the earlier incremental native-repair and
routing-before-fuel sequence: remove the old Swift routing implementation and
its lockstep copies, and build a fresh implementation from the JavaScript
live-pack reference. Port the complete pipeline, including fuel and regional
continuity. Preserve native app infrastructure required by the successful live
flow. The new routing path must use installed packs without network access;
network access is for pack acquisition, never an automatic routing fallback.

The build-45 rollback is `8a7bc98` (restoring `0da738f`). The checked-in JavaScript
reference at this task's starting commit is recorded with per-file hashes in
`Packages/DirtRoutingEngine/ReferenceIdentity.json`. Those source hashes do not
by themselves prove the exact server deployment used in the successful phone
test. Keep that distinction explicit in acceptance evidence.

Correct JavaScript defects and improve efficiency where justified. Record and
test deliberate behavioral changes rather than describing different behavior as
exact parity. No implementation can be called perfected from small fixtures.

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

## 8. Current state and Cursor handoff — September 15

### Read this before changing code

Owner instruction (15 Sep): Cursor continues the work and Claude reviews what
Cursor reports. Work directly in `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt` on branch
`cursor/on-device-routing-speed-37c5`. Do not create extra worktrees or copies of
the project; the owner builds DIRT Dev from this checkout and accepts work only
after a phone build. One commit per step.

- HEAD `6be017a`. Fallback: tag `pre-find-speed-2026-09-15` (commit `cda849b`, the
  exact 15 Sep 05:45 working tree including the previously uncommitted greenfield
  work), also pushed to the internal-disk repository.
- `ccb3e1e`: Balanced crash fix (an infinite corridor width was printed with
  `Int`), `SearchCounter`, probe options, `Scripts/speed-matrix.sh`,
  `Scripts/compare-receipts.py`. `300d2c3`: honest app log. `22fccc8`: endpoint
  reachability check after a failed pair, corridor reuse, multi-destination
  compass cache. `5ce0320` added whole-module flags; `6be017a` reverts them.
- Verified: 41 package tests; clean DIRT Dev build for generic iOS; all 16 matrix
  routes identical to the receipts taken before these changes.

### Measurement

- Probe: `swift build --package-path Packages/DirtRoutingEngine -c release --product dirt-routing-probe`.
  Environment: `DIRT_ALLOW_UNKNOWN=1`, `DIRT_ARRIVAL_EDGE`, `DIRT_PRIOR_EDGES=<file>`,
  `DIRT_FUEL_MIN_STOPS`, `DIRT_FUEL_MAX_STOPS`, `DIRT_FUEL_ALLOW_PARTIAL=1`,
  `DIRT_FUEL_ESCAPE=0`, `DIRT_PROBE_COMPACT=1`. Receipts include searches, total
  states, stages and a hash of the selected edges.
- Matrix: `zsh Packages/DirtRoutingEngine/Scripts/speed-matrix.sh PROBE OUTDIR` (16
  cases on the NS/NB evidence packs), then `compare-receipts.py BEFORE AFTER`
  (IDENTICAL, TIMED or DIFFERENT). Run it alone on an idle machine: recovery and
  corridor cut-offs depend on elapsed time.
- App log `pack route` / `pack fuel`: `searches`, `pops` and `usPerPop` over every
  search; `peakLabels`; `stages` (match, compass, reachability, recovery,
  fuel-foundation); `prepare=[open,join,index,fuel]`; `footprintMB` and
  `peakFootprintMB`; `selectedPops`; `candidates`. Failures also log.
- A performance-only change must give IDENTICAL receipts. A route-changing change
  needs a side-by-side table (km, dirt %, end road, time, searches) and an owner
  phone test.

### Build rule

Do not add `-wmo`/whole-module flags to the package. They pass SwiftPM and
incremental Xcode builds, but a clean DIRT Dev build fails because per-file
dependency and `.swiftconstvalues` outputs are missing. DIRT Dev compiles the
engine per file, where cross-file generics and `any RoadGraph` calls are not
specialized (2.5–4.7× slower than release on identical routes). Recover that speed
in code (task 7).

### Measured state (owner phone, DIRT Dev at these commits)

- Dirt Porters Lake → Yarmouth: 5.7 s (prepare 1.4 s, recovery 2.8 s), 5 searches,
  807k states, 54% dirt, peak 450 MB. Other Dirt routes 1.2–3.2 s at 39–51% dirt.
- Balanced Porters Lake → (44.00, −64.80): 10.2 s, 1.6 M label cap, 26% dirt, peak
  698 MB.
- Clean: 0.4–1.5 s, but the owner reports broad arbitrary loops (399 km where Dirt
  took 378 km to the same point).
- Fuel: still times out or is cancelled (35 s, 38 searches, 5.1 M states).
- Desktop release: 3–5 µs per state. Time is dominated by the number of searches
  and states, not the cost of each.

### Ordered tasks

1. **Destination arrival direction (route-changing; owner approval pending).**
   `PathSearch.attachEnd` requires arrival in `end.forward`, which is scored
   against the B→A bearing (`intent+180`). JS `find-path-v4.js` and `router.js`
   never use the destination direction; the bearing only ranks which road is
   chosen. Wrong-way arrivals flood every corridor and the final pairing can end
   on another road. Branch `experiment/destination-direction` holds the fix
   (arrival in either legal direction, reachability finishing at either end,
   duplicate pairings skipped in `RoutingEngine` and `FuelPlanner`, tests).
   Measured: Allow Unknown Yarmouth 25.9 s → 0.7 s and 45 → 1 search, with the pin
   on its own road instead of a service road 170 m away; Antigonish 313.4 km / 70.1%
   → 305.3 km / 71.8%; other routes unchanged or 0.3–2.7 km shorter at arrival.
2. **Dirt wander.** `ProfilePolicy.approachAway` runs whenever a road compass
   exists (always) and ignores `wander`; the Dirt pavement objective multiplies it
   by 10 (about 95 per km heading away, against 150/km paved and 0.02–0.05/km
   dirt). `waypointPull`, which honours wander, only runs without a compass. Scale
   the away tax with wander, sweep multipliers 10/4/2/1 on the Dirt matrix routes,
   and compare dirt %, km, `RouteQuality.backwardMeters`, lateral metres and
   longest paved run. Owner goal: substantially more dirt without loops or
   backtracking.
3. **Balanced (approved redesign, target 50/50).** The corridor search uses
   `.balancedResource` with 20 dirt-ratio buckets and keeps expanding past B until
   50 ± 0.5% or exhaustion, so it hits the 1.6 M label cap. Replace it with a
   bounded method aiming for 45–55% dirt over the rider leg, for example a few
   ordinary profile searches with a dirt-preference weight adjusted toward 50%.
   Budget ≤ 2 s desktop and ≤ 256 MB.
4. **Clean.** Owner: like Google Maps or Waze, but no highways, no major roads,
   all back roads. Clean runs with an unbounded corridor and a weak away tax
   (2–2.5 per km), which lets it loop. Give it a strong goal pull (compass lower
   bound as the A* heuristic), exclude motorway/trunk except pin access, penalise
   arterials heavily, prefer collector and local paved roads, and add a distance
   regression test against the shortest legal route.
5. **Fuel — superseded 15 Sep by waypoint-chaining Stages 0–3 below.** Do not
   tune `FuelPlanner`'s DFS/flood/shortest-hop search. The 45 s / 98-search /
   0-stop phone result is the shape failing, not a missing prune.
6. **Dirt recovery search.** 2.2–2.8 s of about 5.7 s on the phone and often
   discarded. Bound or replace it, in the same way as task 3.
7. **Per-state cost and memory (exact).** Precompute per-edge tables (surface
   family, tier, ferry, access, restriction alias) and flat adjacency in
   `IndexedGraph`; remove strings, dictionary literals and allocations from
   `ProfilePolicy.step` and `PathSearch`; compute cross-track once per arc; use a
   packed-key state table and compact labels (about 128 bytes each now). Receipts
   must stay IDENTICAL.
8. **Preparation.** Hash each pack file once (graph twice and geometry three times
   per open today); verify at install or update and keep a receipt; keep NS and
   NS+NB prepared together.

### Owner decisions (15 Sep)

Fuel search shape: superseded by waypoint-chaining (this subsection). Pack
verification: once at install or update. Balanced: redesign approved, 50/50
target. Re-riding the same road only when absolutely necessary, because the ride
is about interest and quality rather than efficiency; the 128-step overlap window
from `fd73b76` contradicts that, so confirm with the owner before restoring
whole-route overlap checking as its own tested change.

### Waypoint-chaining redesign (Stage 0 approved 15 Sep; Stage 1 in progress)

Waypoints are the only mechanism. Rider taps, fuel stops, and distance-based
breaks are the same kind of object: a point the route passes through. Some are
rider-movable; all are built with the same bounded, personality-aware per-leg
search. This replaces “solve fuel as a separate reachability problem.”

Owner approved Stage 0 with two Stage 1 fold-ins (below). Persistence formats
are still proposal-only until Stage 3.

#### What exists today (this checkout)

| Surface | Type / field | Role |
| --- | --- | --- |
| Plan itinerary | `RiderItinerary.waypoints: [RiderWaypoint]` | Rider taps only. `id: UUID`, `coordinate: RouteCoordinate`. Comment in `RiderItinerary.swift`: fuel never appears here. |
| Plan spans | `RiderItinerary.legs: [RiderLeg]` | One `RiderLeg` per consecutive rider pair. `from`/`to` are waypoint UUIDs. `id = RiderItinerary.legID(from:to)`. Owns `profile`, `allowUnknown`, `avoidMotorways`, `hopOverrides`, `hopAllowUnknown`, `hopAvoidMotorways`, `fuelStopOverrides`. |
| Built hops | `BuiltLeg` | Geometry between two coordinates. Optional `endsAtFuelStop: FuelStop?`. Several `BuiltLeg`s can sit under one `RiderLeg`. |
| Generated pump | `FuelStop` | `coordinate`, `stationID`, `name`, `afterRiderLegID`, `resetsTank`. Lives on `BuiltLeg`, not on `RiderItinerary`. Display marker id `fuel:{riderLegID}:{builtLegIndex}`, `MapState.MarkerKind.fuel`, label `F1`… |
| Rider-on-pump | `BuiltItinerary.waypointFuelStops: [UUID: FuelStop]` | Derived each build by snapping a rider waypoint to a packed station (`ItineraryRangeArithmetic.fuelWaypointSnapMeters`). Not persisted on `RiderWaypoint`. |
| Pump pick | `RiderLeg.fuelStopOverrides: [String: String]` | Departure anchor (`from.uuidString` or previous `stationID`) → chosen `stationID`. |
| Rider drag | `ItineraryAction.move(waypointID:to:)` | Marker `wp:{UUID}`. Confirm-then-rebuild. `reduce` sets `rebuildFromLegIndex = max(0, waypointIndex-1)` and `rebuildThroughLegIndex = nil` → rebuilds the **suffix**, then fuel re-solves. |
| Fuel “drag” | `RoutePlannerModel.moveFuelStop` / `beginPlannerPinDrag` | Separate path. Drop must land on `validFuelTargets` within 5 km (or a probed replacement). Writes `setFuelStopOverride`. Not free placement. |
| Loop (Generate) | `LoopPlan.anchors` → `ItineraryAction.replaceAll` | Five rider coordinates `[start, left, far, right, start]` (or mirrored). Last point is a **new** `RiderWaypoint` whose coordinate equals the first; two UUIDs, same place. Fuel then runs per `RiderLeg`. |
| Loop (Plan close) | `closeLoop()` → `.append(coordinate: start)` | Same: extra rider waypoint at the start pin, not a special route type. |
| Saved library | `SavedRoute` (`SwiftData`) | `coordinatesData` (full polyline), `segmentsData?`, `profileRawValue` (one profile for the whole record), `ridePreferencesData?`, `routeSeedsData?`, stats. **No `RiderItinerary`.** |
| Reopen | `loadSavedRoute` → `applyStoredRouteGeometry` | Frozen `.saved` track with pins `start`/`dest`. Does not restore waypoints or fuel stops. Re-planning requires a new From Here / Plan. |
| Current fuel | `FuelRangePrefs` | `kilometers` (tank), `reservePercent` (default 10), `automaticPlanningEnabled`. Snapshot: `tankMeters`, `usableMeters = tank * (1 - reserve/100)`. **No remaining-fuel-now field.** Trip-start `firstLegMaxMeters` is `usableMeters` (full usable tank). |

§2 still says generated fuel points stay bound to mapped stations and are not
freely draggable. This redesign **supersedes that sentence** if approved: fuel
and distance-break pins use the same drag/confirm path as rider pins. A fuel
stop should still prefer a mapped `stationID` when the drop is on a pump.

#### 1. Single waypoint list

Keep one ordered array. Do not keep generated pumps only on `BuiltLeg`.

```
enum RouteWaypointKind: String, Codable {
    case rider
    case fuelStop
    case distanceBreak
}

struct RouteWaypoint {
    let id: UUID
    var coordinate: RouteCoordinate
    var kind: RouteWaypointKind
    /// Nil on `.rider`. On generated points: the two rider endpoints of the
    /// span this point was inserted into. Never skip or merge those riders.
    var spanFromRiderID: UUID?
    var spanToRiderID: UUID?
    /// `.fuelStop` only. Mapped pump when the pin is on a station; nil if the
    /// rider dragged it off a pump (Stage 2 surfaces range failure; do not
    /// silently pick another station).
    var stationID: String?
    var stationName: String?
    /// Tank resets only for `.fuelStop`. `.distanceBreak` and `.rider` do not
    /// refill unless `waypointFuelStops` still snaps a rider pin onto a pump.
    var resetsTank: Bool { kind == .fuelStop }
    /// True after the rider moved this generated pin. Saved so reopen keeps
    /// the drag rather than re-chaining.
    var riderAdjusted: Bool
}
```

Display labels stay derived, not stored: rider pins `1…n` in rider-only order;
fuel `F1…`; distance-breaks `D1…`. Stable identity is `id`.

`RiderLeg` stays the **span** between consecutive `.rider` waypoints (including
a loop return pin). Generated points do not create new spans and do not restart
Balanced mix (§2). Search legs are consecutive pairs in the mixed list:

`waypoints[i] → waypoints[i+1]` → one personality-aware `PathSearch` (Stage 1).

`hopOverrides` / `hopAllowUnknown` / `hopAvoidMotorways` key by departing
`RouteWaypoint.id.uuidString` (today: rider UUID or pump `stationID`). Drop
`fuelStopOverrides`; replacing a pump is moving or replacing that `.fuelStop`
row.

Invariants: mixed `waypoints` unique `id`s; `legs.count` equals consecutive
`.rider` pairs, not mixed-list count minus one; a generated point’s
`spanFromRiderID`/`spanToRiderID` always name existing `.rider` rows; a `.rider`
is never deleted by chaining.

#### 2. Which kinds move, and what rebuilds

| `kind` | Movable | Gesture |
| --- | --- | --- |
| `.rider` | yes (except a live GPS From-Here origin while navigating) | today’s `wp:{id}` drag → confirm Yes/No |
| `.fuelStop` | yes | **same** `ItineraryAction.move`, not `moveFuelStop` |
| `.distanceBreak` | yes | same `move` |

On `move(waypointID:to:)`:

- Rebuild **only** the search legs that share that waypoint: incoming
  `waypoints[i-1]→[i]` and outgoing `[i]→[i+1]` (0, 1, or 2 legs).
- Set `rebuildFromLegIndex` / `rebuildThroughLegIndex` to that mixed-list
  window. Do **not** pass `rebuildThrough = nil` (today’s suffix rebuild).
- Do not re-chain other generated points in the span. Do not re-run fuel for
  untouched spans.
- After a `.fuelStop` move: if either adjacent search exceeds the leg budget
  (usable range when fuel is on; nominal budget when off), stop with an
  explicit `LegStatus.gap` / failure string such as `"no fuel stop found
  within range near <location>"`. No `fuel advisory fallback`, no keep-the-A→B-
  line-anyway path.
- Marker rendering: distinct `MapState.MarkerKind` (keep `.fuel`; add
  `.distanceBreak`). Drag code path is shared.

This is also the speed rule: a drag is one or two bounded personality searches,
not a 45 s fuel DFS.

#### 3. Save / reopen (proposal only; Stage 3 implements)

Add optional SwiftData column, same pattern as `segmentsData`:

```
SavedRoute.itineraryData: Data?   // JSON SavedItineraryV1
```

```
struct SavedItineraryV1: Codable {
    var schemaVersion: Int          // 1
    var waypoints: [RouteWaypoint]
    var spans: [RiderLeg]           // rider-to-rider only; existing Codable
    var generation: Int
    var impassableEdgeIDs: Set<String>
}
```

Keep `coordinatesData` / `segmentsData` as the assembled polyline for overview,
GPX, and old clients.

- Save writes the mixed waypoint list **in the current (possibly dragged)
  positions**, including `.fuelStop` / `.distanceBreak`.
- Reopen with `itineraryData != nil`: restore that list into Plan (or From Here
  if only two rider pins), restore polyline, **do not re-solve fuel**.
- Reopen with `itineraryData == nil` (today’s library rows): keep frozen
  `.saved` overview; no invented waypoints.
- GPX: still the track; optional `<wpt>` for `.fuelStop` / `.distanceBreak` can
  wait (backlog) so Stage 3 stays on the in-app library.

§2 “Save, reopen, and start preserve … fuel identities” becomes this list,
not a re-solve.

#### 4. Loops

No loop-specific fuel type. Generate Loop already materializes rider waypoints
`[start, side, far, side, start]`. Plan “close loop” already `.append`s the
start coordinate as a new `.rider` with a new `id`.

The “final destination” is that last `.rider` row. Chaining in §1 runs inside
each rider-to-rider span, including the return span. Initial refuel does not
replace the return pin (§2).

#### 5. Multi-waypoint Plan

Chaining is per span: for each consecutive `.rider` pair `(A, B)`, while the
personality search toward B exceeds the leg budget, insert `.fuelStop` or
`.distanceBreak` **between** A and B. Then continue from the new point toward
the same B.

A rider-placed waypoint is never skipped, merged, reordered, or converted to
`.fuelStop`. Fuel/distance points never jump into another span.

From Here is the two-`.rider` case of the same list (origin, destination).

#### Leg budget and prepare (Stage 1)

- Superseded by the §5 owner contract (15 Sep). First pump: nearest reachable
  pump by the most direct legal route (rule 8). After that: the sweep and fan
  choose pumps (rules 9 to 11); shortest distance and `nearestReachable` never
  pick a pump after the first one; no `planTank` slack factor. Fuel off:
  distance breaks at 350 to 400 km (rule 13).
- Fuel on: `legBudgetMeters = FuelRangePrefs.snapshot.usableMeters` after a
  refill; at trip start do **not** invent a remaining-fuel UX (see Backlog).
- Hard cutoff: do not expand a `PathSearch` label whose accumulated meters
  exceed `legBudgetMeters`. Dominance under that cutoff must respect meters
  (a cheaper but longer label may not discard a shorter one).
- **Window size.** Pack/combined fuel planning sizes `windowMaxStops` from
  remaining straight-line distance / (0.75 × tank), capped at 12 — including
  cross-province joined packs and hop-override replans. Do not force
  `windowStops=1` merely because endpoints cross a province boundary (that
  aborted after the first pump via `maximumStops`). A full window with
  `allowPartialResult` returns status `window` (not `gap`) so the client
  continues from the last proven pump.
- **Frontier → station (named mapping).** For `.fuelStop`, the frontier label’s
  coordinate is snapped to a packed station with
  `FuelPlanner.fuelStationSnapMeters` (= 150, same contract as
  `ItineraryRangeArithmetic.fuelWaypointSnapMeters`). Try on-heading frontier
  labels near the cutoff until one snaps. A Stage 1 `.fuelStop` always has a
  non-nil `stationID`. `stationID == nil` is reserved for Stage 2 after the
  rider drags a fuel pin off a pump.
- **Meaningful dirt floor (Stage 1 phone fix).** Dirt/Balanced tax contiguous
  dirt shorter than `ProfilePolicy.minimumMeaningfulDirtMeters` (1 km) at
  paved rates during expansion (`shortDirtClawback`), so 200–300 m nibble
  detours lose to the direct alternative. Each paved→dirt entry also pays
  `dirtEnterTransitionCost` so many separate >1 km grabs lose to fewer,
  longer connected runs. That enter tax dilutes past
  `dirtEnterTransitionReferenceMeters` (50 km) using the hop's
  `maximumMeters` or geodesic span, so a flat per-transition constant cannot
  starve dirt preference on 200 km+ fuel/A→B legs. Prior-edge
  `backtrackFactor` still applies across hops (FuelPlanner unions every prior
  hop's edge IDs into `priorEdges`); within a hop, wander-band corridor +
  progress regression block out-and-back.
- **Balanced mix continuity across chained sub-legs.** A rider-to-rider span
  owns one 50/50 target. Carry `precedingDirtMeters` / `precedingMeters` across
  every sub-leg of that span (already on `SearchOptions`). Before each Balanced
  sub-leg search, set `ProfilePolicy.balancedDirtPreference` so the sub-leg
  corrects the running span ratio toward 0.5 (for example if the span so far is
  70% dirt, prefer paved; if 30% dirt, prefer dirt). Do not reset the mix at
  each fuel/distance waypoint.
- `IndexedGraph` + `RoadCompass` toward the **span’s rider destination** once
  per span (or once per trip if the destination is unchanged). Do not reopen
  packs per hop.
- Failure: explicit, no advisory A→B / `fuel-foundation` / `fuel advisory
  fallback`.

#### Backlog

Do not handle these inside Stages 0–3. After Stages 0–3 are phone-tested,
resume §8 tasks 6, 7, 8 in order, then this list one item at a time:

- Stage 1 fuel/dirt residual (15 Sep): first-pump approaches remain short
  distance legs (rule 8). Later `planTank` / `distanceFallback` / dest-closeness
  picks are removed in Step B (sweep + fan). Do not reopen fuelGoalPull /
  transition tuning. Step C (wander vs road progress) and Step D (fuel-off
  350–400 km breaks) wait on phone tests. Still deferred: loops/W at waypoints
  (rule 3), 1 km dirt rule (rule 4), movable fuel/distance-break save/restore
  (rule 14), legs appearing as they build (rule 15). `preferredStationIDs` is
  unused. Clean fuel sweeps turn `pavedOnly` off so they can leave an unpaved
  first pump; Clean cost still prefers pavement. Contract probes (180 km
  usable): Yarmouth Dirt/Balanced and north-NB Dirt/Balanced empty-fan gaps;
  Cape Breton Balanced gap near the dest. Do not put shortest back.
- Wander slider: needs a real, monotonic, visibly-scaling effect anchored
  around a sensible median default, not the current near-flat 0%–100%
  behavior. Do not tweak weights ad hoc until that design is settled.
- Avoid-highways / avoid-cities (audit 15 Sep Stage 1 phone): both toggles
  are wired into `ProfilePolicy` / `SearchOptions.cityWall` via
  `RidePreferences`. Dirt’s displayed default for avoid-highways is **off**.
  Fuel hops inherit `cityWall` and `avoidMajorHighways` from the rider
  request (no `cityWall = false` override in `FuelPlanner`). Soft urban ×120
  still applies when a search enters a core. If highways still look unchanged
  with the toggle on, raise the Dirt/Balanced motorway/trunk/arterial
  multipliers (currently ×40/×18/×8).
- Remaining fuel now: no rider input exists (`FuelRangePrefs` is tank + reserve
  only). Add a control later; until then Stage 1 uses `usableMeters` for leg 0
  and does not guess a “current level” UI.
- Stage 1 phone-fuel-yarmouth-window: after the nearest first pump (~16 km),
  onward hops within a 270 km tank still fail to prove a second stop (explicit
  `no fuel stop found within range near …`). Canso and owner St Stephen chains
  complete. Investigate departure rematch / progressing selection before Stage 2.
- App `fuel advisory fallback` in `ItineraryBuilder` still exists; engine no
  longer returns a foundation. Remove/replace the advisory path when Stage 2
  wires the waypoint list so a failed chain cannot draw a fuel-ignorant A→B.
- Task 4 Clean still highway-heavy / loop-prone on some pins.
- Dirt wander still weaker than the owner goal on some corridors.
- Balanced still not reliably nearest-50% on every pin.
- Cape Breton unknown-access exclusions.
- Dirt recovery-search cost (partially bounded in Task 6; still on the phone
  budget when it runs).
- Matcher opposite-carriageway suppression.
- GPX `<wpt>` export for saved fuel / distance-break pins.
- §2 sentence “generated fuel points remain bound to mapped stations rather
  than freely draggable locations” — delete or rewrite when Stage 2 ships.

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
