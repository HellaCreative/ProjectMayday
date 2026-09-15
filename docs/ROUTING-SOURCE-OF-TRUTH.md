# DIRT routing — source of truth

Updated: 2026-09-14. Owner: Richard Smith.

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
selected riding style. Among the reachable legal stations, prefer the one whose
approach best expresses the selected style — the pump is a pivot of the ride, a
reason to ride out to it, not the nearest convenient interruption of it —
provided it still supports useful onward progress. Earlier refuelling is valid
where needed. Do not impose
historical 75-percent barriers, fixed candidate counts, or a global minimum-stop
objective that overrides the ride. Do not exclude a necessary refill by an
absolute minimum stage distance or a fixed exclusion zone around the destination.
Avoid needless repetitive stops and preserve
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

## 8. Current state and Cursor handoff — September 14

### Read this before changing code

Richard requested this handoff because he may need to continue in Cursor. The
replacement is **unfinished and not qualified for a phone release**. Continue
from the actual working tree; do not restart the rewrite or restore the old
Swift engine. The owner's instruction is to delete the old native routing and
rebuild greenfield from the successful JavaScript. Improve justified defects,
but do not claim exact parity, full feature coverage, perfection, or device
acceptance without evidence.

- Checkout: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`.
- Branch: `cursor/on-device-routing-speed-37c5`.
- Starting/current HEAD: `5f7cb8df465310e7690369457c4e27fbf2a74157`.
- All work from this task is **uncommitted**, including important **untracked**
  package and adapter files. A clean checkout of HEAD will lose this work.
- Read `AGENTS.md` and this document. This remains the sole routing authority.
  Do not resume `.build/engine-architecture` or another historical worktree.
- Preserve other work. `.build/`, `.impeccable/`, `.wrangler/`, `internal/`, and
  `scripts/pack-fabric/bench/results/71aa7fd-20260907T005634Z.json` pre-existed.
  Changes appeared in `docs/CARPLAY-FOUNDATION-2026-09-10.md` and
  `docs/LAUNCH-PREPARATION-2026-09-10.md` during this task but were not made by this
  routing agent. Leave them alone. Xcode also changed the user scheme-management
  plist during package resolution; inspect that separately from source changes.
- No device/simulator was created or cloned. The existing iPhone 17 simulator
  `CC6035EE-9C03-48A2-ACBA-DDE3B068642A` is reused for focused app tests, with
  parallel testing disabled and shutdown arranged after the run. No physical
  device installation, production deployment or pack rebuild occurred. Two
  existing published packs were downloaded for desktop verification.

### What is implemented and where

`Packages/DirtRoutingEngine` is an independent Swift 6 package, linked as a local
package in `Dirt.xcodeproj`. It contains no HTTP client, download callback,
JavaScript execution, or wrapper around the deleted native engine.

| New code | Current responsibility |
| --- | --- |
| `BinaryFile.swift`, `GraphPack.swift` | Local mapped V4/geometry decoder, graph/geometry SHA pairing, bounds/access/restriction validation. |
| `PackRepository.swift` | Local manifest/artifact verification and missing-region demand; simple regional download-chain helper. |
| `RoadGraph.swift`, `RegionalGraph.swift` | Search graph abstraction; independently reprove reciprocal OSM seams against both graphs; carry one search and restriction state through regions. |
| `Restrictions.swift`, `PathSearch.swift` | Directed legal search, endpoint fragments, destination/customer access, turn/via-way state, distance caps, profile/resource labels, deadline/cancellation. |
| `Matching.swift`, `IndexedGraph.swift` | Directed road matching and a reusable geometry-bounds index. The index is in memory, not the old private disk index. |
| `ProfilePolicy.swift`, `RoutingEngine.swift`, `RouteQuality.swift` | Initial profile costs, staged candidate search/selection, known/unknown surface reporting, corrected weakest-section comparison. Full policy coverage is NOT finished. |
| `FuelPlanner.swift` | Initial bounded fuel-chain search over the same graph, road-proven approaches, tank limits and destination escape. This is a provisional implementation, NOT a complete port of `fuel-chain.js`. |
| `NavigationCues.swift` | Initial graph-junction cues and arrival cues. Full navigation acceptance is outstanding. |
| `Sources/RoutingProbe/main.swift` | Desktop local-file CLI for real-pack checks. |

App integration:

- `Dirt/Routing/NativeRoutingAdapter.swift`: new app request/response bridge,
  shared presentation mapping, and `NativeRoutingSession` actor. It opens local
  verified packs and reuses one prepared graph/index/fuel set.
- `Dirt/Features/RoutePlanning/Itinerary/RoutingSource.swift`: old native
  `PackRoutingSource` was removed and replaced. Production source selection now
  always selects the pack source. `LiveRoutingSource`/live client infrastructure
  remains available as the owner requested, but is not the automatic fallback.
- `GraphPackStore.swift`: removed old routing, decoding and seam-hop chaining;
  retained acquisition/UI infrastructure. Routing no longer silently tops up
  geometry/fuel/seams. Explicit installation now downloads and checks the small
  per-region `pack-manifest.v2.json` alongside catalog-verified artifacts.
  Previously installed files without a complete manifest need installation
  migration. This acquisition path still needs end-to-end testing.
- `RoutePlannerModel.swift` and `PackAcquisition.swift`: restore the existing
  consent flow, include intermediate regions, preserve pins on unavailable or
  declined downloads, route navigation recovery locally, and use local fuel
  data for replacement candidates. Removed silent server routing fallback.
- `ItineraryRangeArithmetic.swift` retains the two arithmetic helpers needed by
  the shared/live itinerary builder. `SurfacePresentation.swift` retains shared
  display models; unknown is no longer counted as proven Dirt. Pack overlays
  now read the new decoder. These are app-support functions, not preserved old
  pathfinding.
- `ReferenceIdentity.json` lists deleted native implementation/test files and
  hashes all 124 checked-in JavaScript routing reference files. The hashes were
  rechecked unchanged at handoff. Do not modify JS to make Swift tests pass.

### Verified results and exact limits of the evidence

1. `swift test --package-path Packages/DirtRoutingEngine --jobs 2` passed **24
   Swift tests in five suites**. Internally these include **312 turn checks and
   1,216 executed-JavaScript inner-search route comparisons** over four existing
   legal-topology binary fixtures. These are NOT 1,216 independent Swift tests
   and do NOT establish full matching/orchestration/fuel/large-pack parity.
2. Other package checks cover cancelled/expired computation, malformed headers,
   paired-file mismatch, rejecting remote URLs, missing intermediate data,
   weakest-section selection, synthetic two-pack restriction preservation,
   indexed matching equivalence on a fixture, and synthetic fuel-chain/tank/
   destination-escape outcomes.
3. The unsigned **app build succeeds** for generic iOS. Command and latest log:

   ```sh
   xcodebuild -project Dirt.xcodeproj -scheme 'DIRT Dev' -configuration Debug -destination 'generic/platform=iOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
   ```

   Log: `.build/greenfield-routing-evidence/app-build.log`.
4. **App test compilation now succeeds** for generic iOS (`build-for-testing`,
   `-parallel-testing-enabled NO`, unsigned). Log:
   `.build/greenfield-routing-evidence/app-tests-build.log`. The two old-API
   compilation failures have been migrated without restoring deleted routing.
   `Phase1OwnerFuelOffReplayTests` reads explicit local files using opt-in
   `DIRT_OWNER_REPLAY_PACK_ROOT`; optional `DIRT_OWNER_REPLAY_OUTPUT` chooses its
   evidence file. It never overwrites the rider's cache. It now asserts at least
   70% known dirt and no incomplete comparison, so the current owner result
   below FAILS its acceptance requirements. The ordinary suite skips this large
   external-data replay unless its pack root is explicitly supplied.
   Focused simulator testing passed **38 tests in three suites**:
   `PackFirstRoutingTests`, `RoutePlannerModelItineraryTests`, and
   `PackDebugPaintTests` (10.977 s test execution). Log:
   `.build/greenfield-routing-evidence/app-offline-tests.log`. This uses fake
   routing sources for app orchestration; it is not physical-device routing or
   a network-denied full native-app replay. The existing simulator was shut down
   afterward and its shutdown state verified. No clones were created.
5. Current release `fabric-v4-20260909-02` NS/NB graph, geometry, fuel, seams and
   manifests were downloaded from the public pack CDN and all artifact hashes
   verified. Files: `.build/greenfield-routing-evidence/packs/{ns,nb}`. These
   are test inputs, not a modified or republished pack. Do not commit them.

Desktop release-probe results below include preparation, use local files only,
and have **no phone-performance or riding-quality acceptance**:

| Evidence JSON under `.build/greenfield-routing-evidence/` | Result |
| --- | --- |
| `ns-clean-current.json` | A `(-63.340265,44.764830)` to B `(-63.574,44.666)`, Clean, seed 1: 39,697.915 m, 0% known dirt, 0% unknown surface, 9,125 pops, 1.183 s preparation, 2.829 s total, no reported limit. |
| `ns-nb-clean-current.json` | Same A to B `(-67.29131337653283,45.262939746458734)`, Clean, seed 1: 770,948.368 m, 0% known dirt, 3% unknown, 116,899 pops, 0.826 s preparation, 8.871 s total, no reported limit. Connectivity demonstrated; the long chosen route still needs quality comparison. |
| `ns-dirt-current.json` | Same short NS endpoints, Dirt, seed 1: 59,915.915 m, **10.1% known dirt**, 0.4% unknown, 229,404 pops, 0.181 s preparation, 2.401 s total, no reported limit. This is **not qualified Dirt behavior**. Compare the identical JS request before claiming either parity or a regression; do not assume the available dirt was exhausted. |

An earlier arbitrary B `(-63.3,44.8)` produced `noMatch`; the JS matcher also
found no candidate within 2 km there. That was not a useful route acceptance
case. The old checked-in NS sample pack has a different epoch from the current
published pack; do not mix their receipts.

Additional evidence from continued work after the first handoff:

- `scripts/native-routing-full-reference.cjs` executes actual JS `routeOnRuntime`
  on a single local V4 pack, verifies graph/geometry hashes, and rejects HTTP
  before loading reference modules. It accepts `PACK_DIRECTORY REQUEST_JSON
  [SECONDS]`. This adds full single-pack orchestration comparison; multi-pack
  JS and full fuel comparison are still outstanding. Preserve the untouched JS.
- `ns-short-request.json` → `ns-dirt-full-js.json`: same short NS points, seed 1,
  250 m match limit, Allow Unknown off, current NS pack. JS returned 34,486 m,
  **4.3% known dirt**, degraded quality, 2.999 s total (1.201 s preparation), zero
  network attempts. Its endpoint road is `w364195767:62537:126846`.
- `ns-dirt-full-swift.json` is the pre-variety Swift comparison: 59,915.915 m,
  **10.1% known dirt**, 2.445 s total, endpoint road
  `w159933737:62537:105303`. Start edge agrees with JS. Both fail Dirt acceptance;
  endpoint selection already differs, so this is not a search-only comparison.
  The new matcher scores arriving travel direction toward B, whereas the JS
  outer router supplies reversed intent for its destination match. Investigate
  directed matching explicitly before changing either behavior.
- `owner-dirt-seeded-swift.json` uses the EXACT owner coordinates, seed and zoom
  with the new variety implementation: **968,578.496 m, 53.8% known dirt, 0.7%
  unknown**, 250,438 selected-search pops, 60.006 s total, 2.244 s preparation.
  It reaches B but reports `comparison incomplete: resourceLimit("time")`.
  This FAILS owner Dirt and performance acceptance. No fuel proof was run in
  this replay. The probe's `status: complete` means road connectivity only.

- CPU sampling (`owner-cpu-sample.txt`, first eight seconds of a separate
  30-second diagnostic run) identified repeated regional edge canonicalization
  inside ancestor overlap checks as the dominant cost. `PathSearch` now computes
  the candidate's canonical edge once and reads each ancestor's already-stored
  canonical incoming edge. The overlap predicate and search costs are unchanged;
  this requires no new retained cache or working-set allocation.
- `owner-dirt-hotloop-swift.json`: same exact owner replay after that change,
  **17.663 s total, 0.499 s preparation**, with the **identical selected geometry,
  road-ID sequence, distance, dirt percentage and 250,438 pops** as the 60-second
  run. Preparation is warmer, so do not attribute the entire end-to-end delta
  to the inner-loop change; nevertheless search drops from approximately 57.8 s
  to 17.2 s and completes the attempted recovery instead of exhausting time.
  Dirt quality still FAILS. Its saved diagnostic says `comparison incomplete:
  noPath`; a subsequent classification fix now treats an exhausted no-path
  recovery as no candidate, not a timed-out comparison. Final verified replay `owner-dirt-final-swift.json` is **19.531 s total,
  2.248 s preparation**, identical selected geometry/IDs/250,438 pops, and no
  limit. The approximately 17.28 s search compares with the original 57.76 s
  search window. **53.8% known dirt still fails acceptance**. This is desktop
  evidence, not a phone timing claim.
- Fuel request policy now preserves explicit highway and city preferences as
  well as Wander when converting to native road/fuel requests. Low-dirt native
  responses carry an explicit `low_dirt` warning instead of silently presenting
  a sub-70% candidate as satisfying the Dirt target. This does not qualify them.

Final verification before pausing for credits:

- Package: **24 tests / five suites passed** after the final engine changes.
- Generic-iOS **test build succeeded** after the final app preference/warning
  changes. The 38 simulator tests passed earlier in this continuation; they
  were not rerun after those last adapter changes.
- `ns-dirt-final-swift.json`: seeded short NS route, 59,933.915 m, 10.1% known
  dirt, 1.910 s total, no limit. Still below Dirt acceptance.
- All **124 JavaScript source hashes remain unchanged**. Local
  `.build/greenfield-routing-evidence/greenfield-receipt.json` records source
  hashes, pack identities, final owner metrics and exact before/after geometry
  equality. Keep this local evidence; do not stage all of `.build`.
- No active simulator remains. The existing simulator was shut down and verified.
  All work remains uncommitted, including important untracked files. Nothing was
  deployed or installed to a physical phone.

- Additional memory repeat: `owner-dirt-memory-swift.json` and
  `owner-memory.txt` retain the desktop timing and process memory measurement.
  They are not physical-device acceptance.

### Cursor: do these steps in this order

**1. Preserve and recheck the current baseline.** Inspect `git status`, the
untracked package and both reference runners. The two app test compilation
migrations are complete. Re-run the package and relevant app tests when code
changes. Keep the owner replay's original settings and stronger qualification
assertions; do not remove the test or weaken its assertions to accept 53.8% dirt.

**2. Audit missing policy before adding optimization.** This is the highest
priority substantive work. Known gaps in the current new code:

- Seed variety is now implemented in `RouteVariety.swift` as a deterministic
  per-edge cost multiplier in [0.96, 1.04), using all 64 seed bits. It preserves
  nonnegative static costs instead of JS's history-dependent near-cost label
  stealing. Exact-distance probes exclude it. Four tests verify repeatability,
  both legal fork alternatives, prohibited-road exclusion, and unchanged exact
  distance probes. This is an intentional algorithm difference, not JS parity.
  Clean also receives variety. Its quality on real alternative routes remains
  unqualified; IDs still differ across single/regional runtimes. The inner JS
  oracle explicitly disables variety on both sides.
- `ProfilePolicy.wander` is still stored but unused. Implement actual continuous
  detour appetite, with controlled route tests, without silently changing style.
  Do not claim Wander works until it changes behavior.
- `ProfilePolicy.step`/`RoutingEngine.route` are incomplete translations of
  `profile-costs.js`, `hop-search.js`, `road-tier.js`, `find-path-v2.js`, and outer
  `router.js` orchestration. Compare all actual cost factors, profile fallback
  stages, direct-distance caps, urban/settlement policy, meaningful dirt runs,
  highway endpoint exemptions/entry costs, directional guidance, and recovery
  selection. Current major-road multipliers/defaults differ from JS; some are
  intentional owner preferences, others are unqualified drift. The present
  steep away/quadratic-chord costs also need reconciliation with section 2's
  soft waypoint preference. Record each deliberate correction separately.
- No reverse-road compass/feasibility bounds have been implemented. Avoid
  blindly restoring the old eager province-wide preparation. Measure a correct
  baseline, then add tested bounds/preparation reuse where justified.
- Matching has no JS median/opposite-carriageway suppression or weak-component
  pair pruning. It uses latitude-scaled projection and honors directed matches;
  JS's projection and later direction handling differ. Test one-way arrival,
  divided highways, customer access, endpoints on the same edge, and exact
  requested-versus-matched positions before declaring these improvements.
- `NativeRoutingAdapter.request` currently **ignores `arrivalEdgeId`**. The new
  `SearchArrival` preserves state within `FuelPlanner`, but independent app
  rider-stage requests do not yet pass complete legal arrival state. Fix this
  end-to-end; an edge ID alone is insufficient for active via-way restrictions.
  Regional and single-pack edge-ID formats also differ today, which can weaken
  prior-road/history matching when the prepared pack set changes.
- New fuel planning is a first implementation. Audit `fuel-chain.js` against
  `FuelPlanner` and the app adapter: partial-tank initial fuel, nearest reachable
  probe, required/excluded/preferred stations, minimum stops, windows/partial
  continuation, onward proof, destination escape, route-first reuse, avoiding
  unnecessary retrace/urban entry, and total rider-leg Balanced composition.
  Several JS request controls are currently ignored. Many candidates trigger
  separate route searches and the frontier has no strong dominance pruning;
  this is not proven fast or complete for real fuel cases. The new planner now retains a
  completed foundation when its fuel frontier hits a time/label limit; its
  regression test exercises actual frontier exhaustion. Cancellation still
  propagates. The absolute 800 m refill-spacing exclusion has been removed and
  a necessary-nearby-refill regression passes. Verify foundation retention through
  the app as well; neither correction proves complete fuel policy.
- Navigation cues are initial graph-based output, not yet a full tested port.
  Honor `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md`; do not change the accepted HUD,
  speech or Loop experience while repairing the engine.

**3. Execute JS-versus-Swift comparisons over the same immutable inputs.** Extend
`scripts/native-routing-reference.cjs` or add test-only runners that execute the
real JS `routeOnRuntime`/fuel pipeline on local packs. Keep JS out of the app.
The inner fixture runner intentionally disables several policies; copying more
constants into tests is not parity proof. Record request, settings, seed, pack
hashes, requested/matched endpoints, directed physical roads, restrictions,
geometry, actual surface composition, limits, timing, and memory. Diagnose the
first decision that differs rather than tuning until percentages look similar.
Compare known-surface statistics separately from JS's old unknown-as-dirt bug.

The owner replay is A `(lon=-63.34024797349485, lat=44.764804567541226)` to
B `(lon=-67.29131337653283, lat=45.262939746458734)`, seed
`3806057305948982`, Dirt, Allow Unknown off, map zoom 12.5, and then fuel on at
200 km / 10% reserve. Include short NS, real NS–NB, intermediate NS–QC/ON,
Canada–US, dense Ontario, all three styles, meaningful Wander/seed cases, and
fuel regressions. The short near-Dartmouth test above is not this owner replay.

**4. Verify the offline application boundary.** With valid installed files,
reject all routing HTTP requests in the test harness and exercise create,
reroute, fuel replacement, edit/cancel, save/resume, and navigation handoff.
Verify missing/corrupt/stale/incompatible packs and installation migration.
Only explicit acquisition may download pack files/metadata. Missing data must
preserve pins and request data, never invoke live routing or become `noPath`.
The new `hasCompleteNativePack`/cache checks are not a substitute for corruption,
atomic replacement and stale-cache tests. The app still contains the preserved
live client; prove it is unreachable from ordinary device-routing paths.

**5. Optimize measured bottlenecks while preserving the corrected route.** Start
with matching/index reuse, duplicate preparation, candidate/continuation reuse,
restriction-relevant state compaction, and justified graph-distance bounds.
Ancestor canonicalization has already been optimized with measured evidence.
  Do not redo it. Further dominance/pruning requires care: labels currently
  merge histories by node/incoming/restriction/bucket even though the overlap
  rule depends on earlier traversed spans, and length bounds can make a shorter
  higher-cost arrival useful. Audit completeness before aggressive pruning.
  Current label limits and mapped full files are not a demonstrated bounded
working-set solution for dense Ontario. Measure memory as well as time. Do not
shorten the ride, omit packs/stops, lower qualification, or hide a comparison
limit to meet a latency target. Keep the single total monotonic deadline and
cancellation behavior. The route-quality comparator correction must stay tested.

**6. Report and release honestly.** Once package/app suites and the acceptance
matrix pass, prepare a coherent reviewable diff and update this section. Do not
stage the entire `.build` directory or unrelated owner work. Physical-device
installation/production promotion still need current owner authorization.
For simulator tests, reuse one existing suitable UDID and use
`-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`;
never create clones or boot an additional device concurrently without explicit
authorization. Do not call this done solely because the app compiles.

Useful local-only commands (run from the checkout above):

```sh
node scripts/native-routing-reference.cjs
swift test --package-path Packages/DirtRoutingEngine --jobs 2
swift build --package-path Packages/DirtRoutingEngine -c release --jobs 2
Packages/DirtRoutingEngine/.build/release/dirt-routing-probe .build/greenfield-routing-evidence/packs ns -63.340265 44.764830 -63.574 44.666 cleanest 45
Packages/DirtRoutingEngine/.build/release/dirt-routing-probe .build/greenfield-routing-evidence/packs ns,nb -63.340265 44.764830 -67.29131337653283 45.262939746458734 cleanest 60
```

The probe accepts optional `[SEED [MAP_ZOOM]]` after seconds (default seed 1).
It now records requested/matched points and matched road IDs. It prints potentially large
geometry/road JSON, so redirect to an evidence file when benchmarking. Avoid
concurrent timing runs. Existing evidence is local and untracked; record the
source state alongside any new measurements.

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
