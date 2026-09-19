# DIRT routing — source of truth

Updated: 2026-09-19. Owner: Richard Smith.

## 1. Authority and purpose

This is the single maintained document for DIRT routing: product intent,
architecture, routing data, fuel, regional continuity, acceptance, and current
work. Change this document in place when a decision changes. Remove the replaced
rule; do not append a competing rule, create another routing specification, or
use an old experiment as current instructions. Git history retains old decisions.
Richard's current instructions take precedence over this document.

The current native engine is the implementation being improved. Existing code,
packs, tests, and measured experiments are assets to evaluate, not obligations
to preserve unsuccessful behavior. The earlier engine replacement is historical;
the active task does not authorize another engine rewrite, reverting the app,
or changing its interface beyond the owner-requested progress
notice, matching Your ride to the existing Fuel Range panel, and the requested
pack download/update progress window.

### Fresh regional build qualification (owner authorization, September 19)

Build and qualify seven fresh packs first: `ns`, `nb`, `pe`, `nl-island`,
`nl-lab`, `qc-s`, `qc-n`. Preserve the split geography concept, not old pack
bytes. Derive all seven from one dated OSM source with a recorded hash; never
relabel older regional data as the new source epoch. The candidate is explicitly
limited to these seven regions, not a complete continental fabric. Do not mix
old regions into it to make a full catalog. Other regions follow only after this
process is qualified.

Every region, including small provinces, receives the same source, feature,
connectivity, actual-route and memory checks. Test legal road crossings in both
permitted directions, internal split crossings, ferries, and the Confederation
Bridge between NB and PEI. A ferry-only PEI result does not qualify the bridge.
Preserve ramps, overpasses/grade separation, tunnels, surfaces, directed access,
barriers and turn restrictions. Never fabricate connectivity where source data
does not establish it; missing data and defects must be diagnosed and repaired.

Fuel remains `fuel.v1.json` in each routing-pack download for offline advisory,
map and notification use; it does not steer route generation. Fresh campground,
lodging and liquor data remain in the independent Rider Services catalog and
cannot block navigation. Map presentation layers remain separate.

The owner authorizes autonomous implementation, fresh source acquisition,
building, documenting evidence, testing, repair and publication to an immutable
DEV candidate. Preserve the existing release for rollback and leave production
unchanged. Qualify the seven-region catalog and app acquisition path before
pointing DEV to it. Tell the owner when to build DIRT Dev in Xcode; the owner
performs physical-device acceptance. Initial work/evidence directory:
`.build/fresh-fabric-20260919`. No fresh candidate is qualified or published yet.

The fresh inputs come from `canada-260918.osm.pbf`, OSM timestamp
`2026-09-18T20:21:10Z`, SHA-256
`8190d82b9f4872504581006345663b6323bb8f4deba50fab84c2f6fd4ad4a08b`.
The old Newfoundland longitude split put western island towns in Labrador.
Its replacement uses Labrador's OSM administrative relation `9610205` within
province relation `391196`; the island is the remaining province geometry.
The generation recipe records the boundary input hash separately from the road
source hash. Known-place checks cover both sides, including Port aux Basques,
Corner Brook, St Anthony, Red Bay and Happy Valley–Goose Bay.

PEI diagnosis: the old packs already contain Confederation Bridge way
`646650186`. Fewest-region acquisition and staged chain selection could exclude
NB and retain only NS–PE ferry travel. New candidates carry verified road-neighbor
metadata so acquisition retains both road/bridge and ferry alternatives. Staged
alternatives share a bounded comparison window and are compared using riding
style; neither pack count nor a blanket bridge-first rule selects the result.
This is a deliberate regional route-selection correction. It still requires
actual fresh-pack bridge/ferry replays before qualification. It is not an
exhaustive search of every possible administrative chain.

Focused evidence in the directory above: `engine-connection-selection-tests.log`
(119 passing), `acquisition-tests-2.xcresult` (33 passing on the single existing
simulator), and `seam-geography-tests.log` (30 passing). These do not establish
fresh-pack ride quality or physical-device acceptance. An exact membership index
replaces repeated seam-proof scans; the 24,000-proof synthetic check changed from
1,148 ms to 22 ms (`seam-proof-before.json` / `seam-proof-after.json`). This is a
build-tool measurement, not a phone-routing speed claim.

Pack preparation should also reduce repeated phone work where exact reusable
information can be calculated once by the factory. The current candidate adds
eight bytes per road to GEOM v1 for the exact matching-grid bounds of its stored
coordinates. The factory verifies every row; the graph's paired geometry hash
covers the table. Readers without this extension still read the original shapes.
This does not select routes, simplify shapes, prune dirt alternatives or weaken
legal checks. New and legacy matching agree in focused tests; measured route
preparation, memory and download costs remain required before qualification.

The initial NS host comparison on Apple M1/16 GiB used identical private pack
bytes for both readers and three process starts per variant: median preparation
0.209→0.165 s, total 2.317→2.275 s, identical road-sequence hash and 584.665 km
distance. The table adds 1,766,160 bytes for NS. This is modest preparation
evidence, not fresh-pack or phone acceptance. QC-s timings were highly variable
while source extraction ran; they do not establish a performance gain. Raw
before/after results are in `grid-comparison/` under the evidence directory.

A separate runtime legality correction removes coordinate-only node transfers.
The former index joined distinct source nodes inside a 2 m coordinate bucket,
contradicting the source-topology requirement below. A regression test reproduced
a route over two unconnected roads at one map position before the repair.
`RegionalGraph` continues to join verified source identities; ordinary indexes
no longer invent proximity junctions or allocate the whole-network proximity
table. This can change new route results and must be qualified as a correctness
change. Two older tests that expected the unsupported transfer now require
disconnection. The stronger source-identity/seam/turn tests remain passing:
`engine-verified-junction-tests.log` records 121 passing; the reproducer is
`unverified-junction-before.log`. Fresh-region route qualification remains open.

The fresh NB input contains 13 footway/cycleway source ways with explicit
motor-vehicle permission that the former highway-class filter discarded.
Supplemental footway, cycleway, bridleway and pedestrian ways are now retained
only when applicable explicit motor permission allows a direction; original
class, surface and legal access remain separate. Ordinary walking/cycling ways,
ATV-only permission and explicit motorcycle prohibitions do not become legal
motorcycle routes. This is a source-coverage correction, not a speed-only change.
Evidence: `nb-other-paths.opl` and `explicit-motor-path-tests.log` (20 passing).

There is no requirement to use live server routing, keep complete regional
graphs in a persistent service, publish every experiment, maintain identical
JavaScript and Swift implementations, or use a particular third-party engine.
There is no distance or province-boundary rule that automatically selects the
server or changes the rider's requested style.

New agents start with `docs/TAKE-THE-LEAD.md`: the product vision, how Richard
works, the tools, what has and has not worked, and where everything lives. It is
a handbook, subordinate to this document, and it never carries a routing rule of
its own.

Other product documents may cover navigation presentation, maps, accounts,
subscriptions, privacy, and release operations. They must link here for routing
requirements rather than maintain their own versions. Routing requirements for
future Android work also live here; implementation or parity is not implied.

## 2. The rider's result

DIRT helps motorcycle riders create useful adventures over connected roads and
trails, through their chosen places, with understandable surface choices and
fuel awareness. Short rides, long rides, and province/state crossings are all
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
| Wander | Default to 50%. Continuously adjust willingness to meander and travel farther within the selected style. Full Wander deliberately leans toward broad, substantial coherent dirt detours; the rider can rein it in with the slider. Decreasing Wander limits detour appetite without silently converting Dirt to Balanced or Clean. It is not a guarantee that arbitrary endpoints have a 100% dirt connection. Adjacent Wander values may select the same roads; Wander granularity need not make every tick differ. Route-to-route variety across separate generations is a distinct requirement (see "A different ride every time"). |
| Allow Unknown | For Dirt and Balanced, off permits only short mapped unknown-motorcycle-access connectors: at most 100 m for an entire continuous uncertain stretch, between through-permitted roads. On also permits longer supported uncertain-access sections. Neither setting overrides known motorcycle prohibitions, barriers, or closures. Clean excludes uncertain motor access. Unknown surface and uncertain motor access remain distinct facts; a short uncertain connector is not proof of permission. |

DIRT is a back-roads product. Avoid highways, divided highways, and major
thoroughfares in every style — Clean included — unless a short unavoidable
connector or legal endpoint access requires one. Small rural towns remain usable
and are often necessary: they carry the fuel. An unnecessary trip through a large
city or built-up area is avoided; passing through a small town is not.

Avoid highways and Avoid cities both default to on in every riding style.
Explicit saved ride preferences retain the rider’s chosen values.
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
- Rider-selected stations remain rider points with stable identities. Automatic
  fuel stops are not generated. Internal regional boundaries are not extra rider
  waypoints. Moving a rider-selected station rebuilds its affected route legs
  with legal incoming and onward access and rejects stale results.
- A selected rider waypoint highlights and can be dragged. After movement and
  release, ask the rider to confirm placement. Yes initiates rebuilding; No
  permits further refinement. Inserting a draft into a leg alone does not show
  that confirmation or start routing before the movement/confirmation flow.
- Match placement to a nearby legally usable road. Show the matched position;
  do not secretly move a point across water, a barrier, or onto an unrelated
  distant road to force success. Preserve requested and matched coordinates.
- Edits preserve unaffected stages and settings. Refresh advisory fuel information
  after the roads change. Cancelled or older results cannot overwrite newer rider
  intent.
- Save, reopen, and start preserve the chosen route, points, settings, fuel
  identities, and generation identity. New rides or relevant edits may choose
  different qualified roads. A performance-only change should preserve results
  where equivalent behavior is expected; a deliberate routing correction can
  change newly generated geometry with explicit comparison and evidence.

### Loop and navigation handoff

A loop is two pins: the rider's start, and one far pin they drop where they want
the ride to reach. There is no compass heading and no distance slider. The far pin
is the distance and the direction — the rider may drop it as near or as far as
they like, including another province. The pin is honoured: it is a hard extent,
the outer edge of the day's ride, not merely what the circuit aims at (owner
decision, 16 Sep, §5). Outbound and return may wander widely side to side —
lateral width is not limited by this — but neither leg may travel farther from
the start than the far pin itself. This is the rider's contract: "this is how
far I ride today."

The far pin is an ordinary rider waypoint. It is dropped with the same gesture as
a Plan waypoint, and it can be tapped, dragged, and dropped somewhere else, which
rebuilds the loop. That is the rider's control: if they do not like the loop, they
move the pin.

A loop is one ride: one style and one Allow Unknown setting for the whole
circuit, never per leg. Shared access roads may be necessary and a perfect circle
is not promised. Make a true loop wherever the network allows one; where space is
confined — a peninsula, a dead-end valley, one road in and out — an out-and-back
is an acceptable result, but it is reported as what it is, with the repeated
distance named. Never pass a folded circuit off as a loop.

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
intermediate regions when needed. Present missing packs in a download window and
outdated packs in the same window labelled Update packs. List every required
pack with its own orange progress bar. After all required packs are installed and
verified, enable **Begin Route Search**; that explicit action closes the window
and begins calculation. Do not start the route timer or search while acquiring
packs. Preserve the existing informed choice to keep compatible installed packs.
This panel is owner-requested and not yet implemented/qualified. Support decline,
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
2. Every leg is selectable. Each leg has its own style and is held to that
   style's target:
   - Dirt: strive for 100% dirt.
   - Balanced: strive for 50% dirt and 50% pavement on that leg.
   - Clean: strive for 100% pavement on back roads, no highways.
   A route may mix styles leg by leg (for example leg 1 Dirt, leg 2 Balanced).
3. Leg shape. S-curves and wide swings are good. No loops. No out-and-back or W
   shape into or out of any waypoint on the same road. Re-ride a road only when
   absolutely necessary. Repetition is priced, never simply forbidden: a search
   that can only finish by repeating road returns the least repetition the
   network allows, and reports the metres. A hard ban gives either a ride with
   no repetition or no ride at all, and on a real network the rider mostly gets
   the second.
4. Dirt means real riding. Dirt runs under 1 km do not count and are not worth a
   detour.
5. Direction of travel follows the roads, not the straight line. "Ahead" means
   closer to the next waypoint by road, so a lake or bay is ridden around, not
   treated as a wall.
6. Wander sets how far the ride may roam: tight and direct at low wander, big
   S-curves and wide swings at high wander. It sets how much of each leg's ridden
   distance may go sideways instead of toward the next rider waypoint.

Loops are rides (owner decision, 16 Sep). Build Loop uses the rider's start pin
and one far pin the rider drops where they want the ride to reach. Compass
headings — north, south, east, west — are removed. A heading asks the rider to
name a direction they cannot see from a map (which coast, which way around the
water), and it forced the engine to invent a far point, which produced tangles
instead of loops. The far pin is a fact, and it is a hard extent (owner
decision, 16 Sep): no explored road, outbound or return, may sit farther from
the start than the far pin itself. Lateral wander — side-to-side meander while
staying within that radius — is unaffected; only radially passing the pin is
rejected. This is the rider's contract: "this is how far I ride today," and
past the pin breaks it. The distance target still shapes how much the ride
wanders getting out to the pin and home again; it no longer sets the boundary
itself, and it never lets the ride go past the pin to hit a number.

Engine enforcement: `SearchOptions.extentCenter`/`maxExtentMeters` (opt-in, nil
by default) reject any explored road farther than `maxExtentMeters` from
`extentCenter`, with a small fixed `LoopPlanner.extentToleranceMeters` (2 km)
for the pin's own graph edge, which may run a short distance past the pin's
exact coordinate before turning onto it. `LoopPlanner` is the only caller that
sets these fields, both legs sharing one centre (the start) and radius (start
to far), so From Here and Plan searches — which never set them — are
unaffected; the 16 Sep matrix (§8 STEP 6) proves this exactly.

The far pin is a rider waypoint and uses the existing waypoint path — dropped
with the same gesture, tapped, moved, and dropped again to rebuild the loop.

Outbound and return are ordinary styled legs (rule 2) and obey leg shape
(rule 3), so the return re-rides as little of the outbound as the network allows.
The whole circuit carries one style and one Allow Unknown setting; the app never
changes a loop leg's style, and a loop has no per-leg settings that can disagree
with each other. Where the network is confined, an out-and-back is an acceptable
answer, declared as one with its repeated distance. Reserve failure for a pin
that cannot be reached at all, and say it in terms of the pin, because the
rider's move is to drop it somewhere else.

**Waypoints and experience**

7. Waypoint kinds are rider-placed. Long trips stay one rider-to-rider leg until
   the rider drops their own waypoints on the route to reshape it.
8. Legs appear one after another as they are built. A long trip may take longer
   to finish; the rider watches it grow.

**Fuel is not part of route building (owner decision, 15 Sep evening)**

9. Route building never consults fuel range, reserve, or pumps, and never places
   a fuel stop. No fuel windows, sweeps, fans, progress shares, or fuel gap
   cards take part in building a route. Hunting for fuel while composing the
   ride produced paved legs and wrong-way detours; the ride comes first.
10. Fuel becomes an advisory layer in a later phase (below). Until it ships,
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
fresh bounded windows after a valid committed rider or internal road stage. Do not
impose one short immutable deadline over an arbitrarily long trip or count
successful stages toward a failed-retry limit. Bound failed/no-progress repetition;
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

### Active owner-directed sequence — September 19

**Current priority:** qualify the seven fresh Atlantic/Quebec packs described
in section 1, including bridges, ferries, split-region continuity and measured
phone preparation costs. Apply the resulting repeatable process to other
regions only after this set passes. The earlier Texas–Moab failure and broader
US qualification remain open; the accepted trans-Canada planner ride does not
establish US coverage.


Work in `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`. The current task began at
`5383862` on `cursor/stub-island-seam-rank-f339`. Implement and qualify reduced
memory, faster route generation, broader Wander and meaningful route variety,
prioritizing everyday one/two-region rides. Prepare a reviewed candidate on main
for Richard's Xcode Play build; do not install a phone build or deploy production
as a side effect. Preserve the accepted app foundation and current main fixes.
Fuel remains advisory only, outside route generation. Historical fuel-chain
measurements below do not authorize restoring that planner.

For the September 19 rebuild, use the seven fresh regions authorized in section
1 for candidate qualification. Immutable `fabric-v4-20260917-02` remains the
comparison and rollback release; its mixed source dates do not qualify fresh
data. The existing Swift routing engine remains in place; do not restart it or
restore an older app.

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
  values. Fuel notifications on/off must not change calculated roads or add stops.
- Legal arrival-direction restrictions, regional tails, and preserved rider points.
  Earlier automatic fuel-continuation tests are historical, not active requirements.
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

### Git: where the work lives

These are facts about this project's repositories. Keep them accurate; an agent
that guesses here can lose work or bloat the checkout.

- **Working checkout, the only one:** `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`, on
  the SIDECAR volume. Richard builds DIRT Dev from this checkout. Do not create a
  second worktree, clone, or copy of the project. Probe and experiment builds go
  to the session scratch directory, never to another checkout.
- **Working branch for the owner's next Xcode Play:** `main`, advanced to the
  September 19 qualified development candidate. The prior working branch
  `cursor/stub-island-seam-rank-f339` retains the implementation checkpoints.
- **Remotes:** `github` → `https://github.com/HellaCreative/ProjectMayday`
  (public). There is no `origin`. The old internal-disk clone at
  `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` is gone; do not recreate it.
- **Publishing:** `git push github HEAD:main`, normal fast-forward only. Main
  `a3824c5` was merged before this candidate, preserving its settings and
  navigation fixes. The earlier GitHub main (August) remains preserved as
  `archive/main-2026-08-13`. Local main is now used for the owner's build.
- **Never fetch ProjectMayday into this checkout.** Doing it once pulled every
  unrelated experiment branch and grew `.git` from 95 MB to 7 GB. This checkout
  pushes; it does not fetch. `.git` is about 100 MB after `git gc`.
- **Never stage** `Dirt/Features/Groups/GroupsSheet.swift` or
  `Dirt/Routing/RoutingModels.swift`. They carry Richard's own local changes and
  stay uncommitted. Stage named paths, never `git add -A` or `git add .`.
- **Never commit** build output, packs, or evidence directories. `.build/`,
  `.impeccable/`, `.wrangler/`, and `*.o` are ignored; keep it that way.
- **Commit rhythm:** one commit per step, with a message saying what changed and
  why. Commit and push at the end of every piece of work, so that what is on
  Richard's phone and what is on GitHub are the same thing. He should never have
  to ask whether his work is saved.
- **Nothing destructive without a specific instruction for that action:** no
  force push, no `reset --hard`, no branch deletion, no history rewrite. Richard
  does not read Git; explain in plain language what a command will do before
  proposing it.

## 8. Current implementation and evidence

### Current implementation and qualification — September 19

US qualification is **in progress, not accepted**. The owner Texas–Moab request
in `dirt-app-debug-2026-09-19T183900Z.txt` used Balanced, Unknown off,
`[-99.013625,30.528910]` → `[-109.528104,38.615266]`, packs tx/nm/az/ut.
Its 111-second acquisition finished before calculation began. The phone then
failed preparing the road index, with zero searches. Seed and Wander were not
recorded; host replays explicitly use seed 1 and Wander 50%, not an invented
exact seed match.

Current repairs omit roads unmatchable in both directions from the endpoint
lookup index (underlying legal topology remains intact), and compare numeric
source-node identities before allocating strings during regional joining.
Necessary city connections retry after an actual no-path result using the
existing urban penalty and the same time/memory budget; explicit access rules
remain enforced. Time/label limits never trigger that fallback or become proof
of disconnection. New tests cover required city crossings, a usable bypass,
prohibited access, and spatial-index matching parity across access modes.

The local probe now uses the app's 1.6-million-label limit, renews a window only
after a committed stage, and enables the app's non-staged ride composition.
Preparation phase totals remain visible on failure. The serial matrix scripts
retain settings, source/executable identity, immutable pack manifests, route
quality fields and process memory measurements. These are host tests, not device
acceptance. Xcode background work affected cold timings and prevents describing
this batch as an isolated performance qualification.

Evidence: `.build/us-routing-20260919/`. Initial tx↔nm, az↔ut and nb↔me host
Balanced smoke tests completed. Corrected me↔nh endpoints also completed;
original arbitrary points included isolated source roads. The owner Texas replay
gets past the old road-index-capacity error but still times out in preparation.
Vancouver→Bellingham completes after necessary-city recovery, but its 435.7 km /
37.1% dirt result is not quality-qualified. The reverse still exceeds the label
limit. Do not report either pair as fully fixed. The generated border inventory
contains 248 directional requests across 124 paired connections, with de–nj and
ny–on-s fixture selection unresolved. Generating requests is not running them.
The first broad Balanced pass is running serially. It exposed Mississippi→Arkansas
arriving at a shared bridge's entry junction on an incoming local road absent
from the Arkansas pack. A generated cut now uses the interior of geometry
represented by both packs, with a real shared incoming-road traversal (a zero-
metre terminal arc cannot substitute for one). The existing candidate count,
window budgets, access rules and turn-state safeguards remain in force; rider
points are unchanged. On the exact matrix endpoints, the repaired direction
completed in 3.474 s / 229.5 km / 10.6% dirt with zero repeated metres. Reverse
still completed (269.6 km / 12.3% dirt, zero repeated metres). These results prove
road continuity only; they do not qualify the Balanced mix. Evidence is
`.build/us-routing-20260919/shared-interior-after/`; 115 engine tests pass,
including actual shared-road arrival, conservation of distance across a cut,
zero repeated road, and retained active-turn safeguards. Retreating the cut alone
was tested, did not repair this failure, and was removed before this candidate.
Alaska→BC and reverse BC–Washington limitations remain unresolved.

The same sweep exposed Montana→BC failing after only 32 label pops. The endpoint
filter mistook roads meeting at a source junction for opposite carriageways and
removed the legal departure that initially headed away from the destination.
Source-connected junction alternatives now remain eligible; destination bearing
still ranks them, and the existing separate-carriageway check remains. A focused
test failed before the repair and passes afterward. On the exact matrix points,
Montana→BC now completes in 3.682 s / 192.7 km / 46.7% known dirt with zero
repeated metres. Reverse retains the identical road hash. With the combined
handover and matching repairs, Iowa→Illinois also completes (21.525 s / 214.7 km /
53.3% known dirt), and reverse completes (255.2 km / 62.9% known dirt); both have
zero repeated metres. These are host continuity results, not full style or phone
qualification. Unknown surface remains substantial (47.3% Montana–BC; 41.9%
Iowa→Illinois) and is not counted as known dirt. Evidence:
`.build/us-routing-20260919/junction-after/`; 117 engine tests pass.

California↔Nevada currently rejects incompatible shared road data in both
directions and with both California packs. Direct inspection of unchanged
`fabric-v4-20260917-02` bytes found two conflicting shared roads for ca-n/nv and
21 for ca-s/nv. For example, way 723270369, nodes 9327727868→89784397, is recorded
as 183 m in ca-n and 164 m in nv, with the same final source node about 19 m apart.
Way 14289893, nodes 137180897→7924156554, differs by about 5 m at its first node.
This is actual source-pack disagreement, not merely a runtime index mismatch.
The join still rejects it; diagnostics now name both regions and the exact road
and node identities. No tolerance was increased, connector fabricated, or pack
changed. Detailed comparisons are in `.build/us-routing-20260919/ca-*-nv-geometry.json`.
Resolving those pack conflicts remains outstanding and does not justify relaxing
legal/topological validation for other regions.
Provenance inspection explains the mismatch: ca-n/ca-s use OSM timestamp
2026-09-16T20:21:21Z, while nv uses 2026-09-06T20:21:35Z despite the shared
September 17 sourceEpoch. Across the installed fabric, 59 regions contain
September 6 source data and eight split regions contain September 16 data
(ca-n/ca-s, nl-island/nl-lab, on-n/on-s, qc-n/qc-s). Different dates alone do not
prove every connection broken; the conflicting road bytes above do prove these
California–Nevada failures. `.build/us-routing-20260919/pack-source-dates.json`
records timestamps and source/graph/geometry hashes for every region. No source
data or distributed artifacts were rebuilt or replaced.
The same read-only shared-road audit found conflicts for me–qc-s (one road),
mi–on-n (three), mi–on-s (two), mn–on-n (one), and ny–qc-s (one). Some differences
are internal geometry with unchanged endpoint identity/rounded distance; they
still fail the current exact alias contract and are not silently ignored. Five
other mixed-date US boundary pairs had no conflicts in this audit, reinforcing
that a timestamp difference alone is not proof of failure.

All eight September 16 split packs also omit `urbanCores` and `settlements` in
their graph metadata. In particular, California has no applicable entries in
the engine's existing Canadian-only fallback city list, so route completion
cannot qualify Avoid cities there. Canadian fallback coverage is only the
existing named cities, not a substitute for complete metadata. Evidence:
`.build/us-routing-20260919/pack-city-metadata.json`. Do not add location-specific
rescue boxes to conceal this missing pack information.

Intrastate cardinal/diagonal tests, Hawaii, longer multistate runs, all-style
qualification, physical-device performance and the secondary acquisition UI
remain outstanding.


Owner authorization: implement and qualify speed, memory and useful ride variety,
then prepare main for the owner's Xcode Play build. Everyday one/two-region rides
(Kitchener–Barrie and NS–NB) take priority; Halifax–Squamish through Canada is a
stress case. Fuel is advisory only, outside route generation. Preserve the app
foundation and Loop. No phone install, production deployment or pack publication
is authorized by this work.

Work began at `5383862`; it remains the recoverable pre-change checkpoint.
Implementation checkpoint `df919b9` includes the native app qualification tests.
Main `a3824c5` was integrated while retaining the later
app refinements from the working branch. Exact performance changes include compact
shared outgoing/reverse connections, indexed seam/restriction proofs, two-window
preparation retention, removal of duplicate app preparation, weak reuse of mapped
packs, two-entry sidecar reuse, small verified region envelopes, and shared scoring
tables. Road-compass reuse is bound to the exact prepared graph; changed artifact
identities require verification. Full region indexes still exist: this is **not**
selective neighborhood loading.

A completed internal stage may start a fresh 60-second window. Preparation and
failed attempts share each window's absolute deadline; label limits remain
1.6 million. Cancellation is shared with preparation workers. A search limit stays
an incomplete calculation even if later alternatives return no path. Cross-window
incoming roads use original topology identity. An active multi-road turn sequence
that cannot yet be carried across windows fails explicitly rather than being dropped;
full cross-window sequence remapping remains an open limitation.

September 19 follow-up: Richard explicitly requested a more extreme upper Wander
range, then approved **100 m continuous unknown-motorcycle-access connectors
with Allow Unknown off**. Allow Unknown on keeps longer uncertain sections
available. This supersedes the earlier off-means-no-code-1 interpretation.
Known prohibitions and closures remain excluded. Clean still excludes uncertain
motor access. Source packs and their access classifications are unchanged.

Full Dirt Wander now uses 2.5 times the previous corridor, extra-distance and
backward-progress allowance, with progressively less extra freedom toward zero.
Zero Wander retains its earlier geometry/progress settings. Candidate discovery
tries wider dirt areas while retaining nearer alternatives, ordered by nearby
permitted known dirt as a discovery hint; actual road search proves the ride.
Non-staged composition rejects repeated roads, closed source-junction circuits
and short dirt scraps. Passing near an earlier part of the ride on a different
road is no longer automatically rejected by the old two-kilometre proximity
check. Loop's far-pin extent and ordinary legal turn-around behavior are retained.
Saved route geometry is not regenerated. Fixed roughly-800 km cuts remain rejected.

Long-route stages now retain traversed original road identities before releasing
their graphs. Dirt continuations first try unused roads, with the ordinary
repeat-penalty fallback only if exclusion returns no path; attempts share the
existing deadline. A first widened country replay exposed 506 km of repeated
roads, so that result was rejected. Carrying the previous-road penalty alone
reduced it to 22 km but was also rejected as a regression. The final repair also
preserves the exact incoming road and direction at generated cuts, keeps all
clipped road pieces when joining stages, and can move an internal cut back to a
verified shared junction with an onward exit. Trimming cannot erase an active
turn sequence. Nearby border alternatives remain available within the existing
12-candidate bound when geographic spacing would otherwise leave only one.
These are deliberate route-selection/continuity corrections, not performance-only
changes. No search deadlines or label budgets were enlarged.

Unknown-off connectors accumulate actual routed length across consecutive code-1
pieces. Their search labels retain the accumulated length, including zero-length
junction transfers, and reject runs over 100 m. Entry and exit must be on
through-permitted roads; internal stages cannot end inside an unfinished uncertain
connector. Matching still excludes uncertain-access pins with the switch off.
Weak connectivity includes uncertain roads only as optimistic discovery, never as
proof that the connector cap or access requirement has passed. Returned segments
retain `motorized_unknown`; uncertainty is not relabeled as proven permission.

Qualification evidence lives in ignored `.build/routing-experiments-20260919`.
Host: Apple M1 MacBookPro17,1, 16 GB, macOS 26.6.2. Immutable packs remain
`fabric-v4-20260917-02` with seams v2. Each replay records pack manifests/hashes,
source hashes, binary hash, seed, settings and actual segments. Dirt, Wander 100%,
Unknown off, city/highway avoidance on, seed 1 and no fuel computation unless
explicitly stated. Disk cache and unrelated host activity are uncontrolled;
process-cold means preparation stores were fresh, not an emptied OS cache.

| Workload | Earlier candidate | Broader Wander / short-connector candidate |
| --- | --- | --- |
| Kitchener–Barrie full Wander, seeds 1/2/3 | 265/285/293 km; 77.8/78.6/79.1% dirt; 1.73–1.87 s warm | 360/317/362 km; 83.5/80.6/81.5% dirt; 9.85 s first preparation, 2.81/3.56 s warm; zero repeated roads |
| Kitchener–Barrie Wander 0/50/100, seed 1 | 177/261/265 km | 177/303/360 km; 62.9/80.3/83.5% dirt; half-Wander still costs 15.65 s warm |
| Owner Halifax–St Stephen, exact Sept 19 coordinates, Unknown off | about 902 km / 58.3% dirt | about 902.2 km / 56.3% dirt, 7.25 s first preparation; two uncertain connectors of 100 m and 45 m; **does not meet Dirt quality target** |
| Same owner route, Unknown on | about 930 km / 66.3% dirt | about 1,013.4 km / 65.4% dirt, 4.23 s warm; long uncertain access remains available; **does not meet Dirt quality target** |

| Halifax–Squamish through Canada, seed 1, cold/warm | narrower candidate 9,673.9 km / 76.9% dirt, about 68/61 s host | 12,247.9 km / 81.5% dirt, 87.85/82.52 s host; zero repeated roads; broader ride costs more time |

The country host replay reports 56.93/57.10 s search, peak 929,233 labels,
877,269,440 bytes peak physical footprint and 966,770,688 bytes maximum RSS.
Cold/warm road hashes match (`c1d9441131d489d393a224601c9ba417238fa1ec87c0aa1e2b8ae774e99f4c9b`).
An independent returned-segment audit finds five uncertain connectors totalling
220 m (longest 58 m), no explicit prohibited/closed road, and a maximum 1.19 m
geometry join offset across recorded regional connections. The owner NS–NB
routes have zero geometry join gaps and zero repeated roads; Unknown on uses
149,058 m of uncertain access, which remains distinct from known dirt.

The owner coordinates above are `(44.696743,-63.485973)` to
`(45.213841,-67.296321)`. Qualifying host evidence: Ontario in
`candidate-wander-connectors`, owner NS–NB in `candidate-nearby-handoffs`, and
country in `candidate-live-handoffs`. The last country host replay predates the
nearby-border candidate-list repair; final app qualification covers that repair.
Intermediate country outputs with repeated roads, hidden tails, or failed
continuations are rejected experiments, not qualifying routes.

110 engine tests pass, including continuous 100/101 m boundaries, segmented
unknown stretches, zero-length transfers, explicit denials, long Unknown-on
sections, unknown endpoint exclusion, source-junction circuits versus nearby
roads, unused-road continuation with a necessary-access fallback, exact incoming
road/direction, clipped-stage distance, active turn sequence preservation, and
shared-road stubs/forbidden exits. Release engine-suite evidence:
`wander-engine-tests.log`. Final app qualification uses the existing iPhone17 /
iOS26.5 simulator on the same M1 host, DIRT Dev Debug, serial testing, through
`NativeRoutingSession` and `NativeRoutingAdapter`. Ontario seeds 1/2/3 return
83.5/80.6/81.5% dirt in 23.52/9.04/10.57 s (first preparation then warm);
repeating seed 1 takes 9.72 s and returns identical roads. Peak process footprint
reaches 327 MiB. First Ontario preparation is 12.76 s; search is 4.15–5.63 s.
Save/JSON-reopen and surface-display consistency checks pass. These timings include
response validation and are development-simulator measurements, not phone timings.
The country cold/warm app runs pass at 143.62/120.89 s, 12,247.9 km,
81.5% known dirt and zero repeated roads, with identical selected-road hashes.
Country preparation windows take 13.31/8.19 s and search 83.21/82.75 s; remaining
time includes matching/guidance, retries, graph access, geometry and validation.
Peak process footprint is 562 MiB (process-wide high-water mark; not an allocator
peak). The final app country replay includes the nearby-border alternative repair.
Evidence: `wander-app-final.log`, `wander-app-final.xcresult`, and
`wander-app-final-identity.json` (source/binary identity and pack manifests).
Owner NS–NB app runs also pass the endpoint, access and connector assertions:
14.49 s Unknown off, 9.91 s on, with the same 56.3/65.4% dirt as the host replay.
These run after country preparation and are not isolated cold-start measurements;
562 MiB is the inherited process high-water mark, not NS–NB-specific memory.
All three integrated tests pass (341.98 s suite). This establishes the tested
behavior and safeguards, not Maritimes Dirt-quality acceptance or full product
qualification.
Candidate stamp: `broad-wander-connectors-20260919b`; a new DIRT Dev Xcode Play
build is required. Recoverable pre-change main: `b24c502`.

Remaining limitations: Maritimes dirt percentages above are still below the
owner's target; broader Wander and short connectors do not guarantee improvement
on every corridor. Full-region preparation remains; true selective neighborhood
loading is unfinished. Half-Wander latency is not uniformly low. Physical-phone
acceptance and allocation-peak instrumentation are not established by host or
simulator checks. No phone build, pack publication, server deployment or archive
has been performed by this follow-up.

September 19 waypoint-editing repair (owner phone log exported at 18:13:44Z):
a confirmed insertion correctly created one intermediate rider point, but the
next rider leg sent its unsnapped coordinate alongside the previous leg's exact
incoming road. The stricter continuation matcher rejected that mismatch. The
planner then mistook the completed prefix for the final destination and moved
the destination onto the intermediate point. This produced the apparent duplicate
and lost destination visible in the owner log.

The builder now carries the actual reached coordinate together with the incoming
road/restriction state; rider waypoint identity and requested coordinates remain
unchanged. Missing arrival metadata clears the previous leg's metadata instead
of leaking it forward. Destination pin synchronization requires the current
final rider leg to be built and to end at that destination, never a partial
prefix or generated stop. No matching tolerance, routing preferences, pack data,
or map gesture design changed.

Verification: 60 planner/builder/reducer tests pass, including repeated placement
confirmation, insert/move/delete, continuous snapped departures, and preserving
the final destination after an onward failure. A separate native app-path test
replays both owner insertions through `ItineraryBuilder`, `NativeRoutingAdapter`
and `NativeRoutingSession` on immutable fabric-02 NS data: both complete, and each
incoming route endpoint equals the onward route start. Exact coordinates live in
`ownerCapeBretonInsertedWaypointsContinueAtMatchedRoad`; replay seed is 1 (the
phone log does not record its seed), Wander 100%, Unknown off, city/highway
avoidance on, fuel excluded, map zoom 8.1/8.2. That test passes in 46.62 s total
on the existing serial iPhone17/iOS26.5 simulator on the M1 host. Evidence:
`.build/waypoint-repair-20260919.xcresult` and
`.build/waypoint-native-replay-20260919.xcresult` with matching build/test logs.
These verify planner actions and real routing, not physical touch gestures on
the phone. Final DIRT Dev build succeeds. New native build required; stamp
`waypoint-continuity-20260919c`.
Pre-repair checkpoint: `87f9ba5`. The owner subsequently reported that planning
with their own waypoints worked from Nova Scotia to BC on the phone, and approved
the Wander experience and yellow long-planning notice. This is acceptance of that
reported journey, not qualification of every corridor or gesture case.

The owner requested new-ride defaults of 50% Wander, Avoid highways on, and Avoid
cities on. The settings display and native request adapter now share those
fallback defaults; explicit saved preferences remain unchanged. The broad 100%
Wander setting and yellow progress notice are unchanged. A new native build is
required for these default changes. The DIRT Dev build and all five focused
`RidePreferencesTests` pass on the existing serial iPhone17/iOS26.5 simulator,
including native defaults for all three styles and explicit saved-setting
overrides. Evidence: `.build/ride-defaults-20260919b.xcresult`.

The owner also requested that **Your ride** use the existing **Fuel Range**
floating map panel presentation: same top entrance, placement, material, rounded
border, shadow, compact header and Done action. The two panels now share their
surface styling and presentation host; opening either closes the other. Your
ride groups Wander and the two avoidance switches without nested cards. Done
applies the draft once; closing via the settings button or switching to Fuel
Range discards uncommitted edits. Removed the obsolete waypoint/fuel-road caveat
and the obsolete online-planning/fuel-stages introduction. Reduced Motion uses a
fade instead of the slide. Routing selection and defaults are unchanged.

Verification: DIRT Dev simulator build succeeds (`.build/ride-panel-20260919.log`).
On the existing iPhone17/iOS26.5 simulator, inspected both panels in portrait,
opened/switched/closed them, changed a switch, applied with Done, reopened and
verified the value, then restored it. The default 50% Wander and both avoidance
switches on are visible. No obsolete copy remains. Landscape reflow could not be
verified: the simulator rotated its display but the app stayed in its portrait
layout. Large Dynamic Type and VoiceOver interaction remain unverified. A new
native build is required; no physical-device installation was performed.

The owner requested a caveat inside the existing progress animation only after
a route has been building for 20 seconds, including with Reduce Motion enabled.
There is no early display based on route distance or pack count. Exact copy:
“Longer rides can take 10 seconds to over a minute to plan.” Pack information
belongs to the existing download notification and is omitted from this caveat.
This is a waiting-time explanation, not a precise forecast or one-minute limit.
At the same 20-second threshold, the existing progress card gains a yellow border
and a subtle yellow surface tint to draw attention to the added text. Earlier
progress keeps its normal appearance. The transition respects Reduce Motion;
the text continues to communicate the state without relying on color alone.

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

Waypoints are the only mechanism. Rider taps and (later) fuel stops are points
the route passes through. Distance-break waypoints were removed: a long trip
stays one rider-to-rider leg until the rider drops their own waypoints on the
route to reshape it. Some points are rider-movable; all are built with the same
bounded, personality-aware per-leg search. This replaces “solve fuel as a
separate reachability problem.”

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
| Loop (Build) | start + rider-dropped far pin + target distance → `LoopPlanner` → `[start, far, start]` | Two rider waypoints plus a return pin at the start. Far is the rider's own pin (§5, 16 Sep) and a hard extent — outbound/return never travel farther from start than the pin — moved with the ordinary waypoint drag to rebuild; no heading. The distance target shapes wander inside that extent rather than placing the far point or setting the boundary. One style and one Allow Unknown for the whole circuit. Fuel is not consulted while building. |
| Loop (Plan close) | `closeLoop()` → `.append(coordinate: start)` | Same: extra rider waypoint at the start pin, not a special route type. |
| Saved library | `SavedRoute` (`SwiftData`) | `coordinatesData` (full polyline), `segmentsData?`, `profileRawValue` (one profile for the whole record), `ridePreferencesData?`, `routeSeedsData?`, stats. **No `RiderItinerary`.** |
| Reopen | `loadSavedRoute` → `applyStoredRouteGeometry` | Frozen `.saved` track with pins `start`/`dest`. Does not restore waypoints or fuel stops. Re-planning requires a new From Here / Plan. |
| Current fuel | `FuelRangePrefs` | `kilometers` (tank), `reservePercent` (default 10), `automaticPlanningEnabled`. Snapshot: `tankMeters`, `usableMeters = tank * (1 - reserve/100)`. **No remaining-fuel-now field.** Trip-start `firstLegMaxMeters` is `usableMeters` (full usable tank). |

§2 still says generated fuel points stay bound to mapped stations and are not
freely draggable. This redesign **supersedes that sentence** if approved: fuel
pins use the same drag/confirm path as rider pins. A fuel stop should still
prefer a mapped `stationID` when the drop is on a pump.

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

No loop-specific fuel type. Build Loop materializes rider waypoints
`[start, far, start]`, where `far` is the pin the rider dropped. Plan “close
loop” already `.append`s the start coordinate as a new `.rider` with a new `id`.

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
  `maximumMeters` or geodesic span, but never below half the base — long
  From-Here legs were otherwise letting on-path 1–2 km scraps win. Leaving a
  run shorter than `minimumUsefulDirtMeters` (2.5 km) pays
  `shortDirtLeaveAbortCost` (full undiluted enter below 1 km; tapered to
  zero by 2.5 km). Dirt also accrues `deferredDirtEntryCost` after
  `deferredDirtEntryAfterMeters` (3 km) of pavement without a meaningful
  dirt completion, so the first proper dirt turn beats a long paved dip that
  only harvests scraps later. Before the first meaningful dirt run, paved arcs
  inside `earlyOpeningWindowMeters` (12 km) that increase geodesic distance to
  the pin pay `earlyOpeningAwayCost` — road-compass `approachAway` alone missed
  U-shaped black opening dips that keep remaining-to-B flat; dirt arcs stay
  exempt so dipping for dirt remains intentional. In that same opening window,
  Dirt also suspends arterial/trunk `avoidMajorHighways` multipliers (motorway
  stays taxed) and prices profile-mode arterial/trunk like collector — otherwise
  the ×8 arterial flee turns Trunk/Hwy 7 into a paved collector U with no dirt
  payoff (Porters Lake). After meaningful dirt, full highway avoidance returns.
  Post-search
  `shortDirtExcursions` (useful-run floor) and `RouteQuality.prefersDirt`
  (scrap metres / leading paved before percent) reinforce the scrap rule.
  Prior-edge `backtrackFactor` still applies across hops (FuelPlanner unions
  every prior hop's edge IDs into `priorEdges`); within a hop, wander-band
  corridor + progress regression block out-and-back.
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
  distance legs. Later `planTank` / `distanceFallback` / dest-closeness
  picks are removed in Step B (sweep + fan). Do not reopen fuelGoalPull /
  transition tuning. Step C (wander vs road progress) waits on phone tests.
  Distance-break waypoints were removed: the rider drops their own waypoints
  to reshape a long trip (rule 7). Still deferred: loops/W at waypoints
  (rule 3), 1 km dirt rule (rule 4), movable fuel save/restore, legs appearing
  as they build (rule 8). `preferredStationIDs` is
  unused. Clean fuel sweeps turn `pavedOnly` off so they can leave an unpaved
  first pump; Clean cost still prefers pavement. Contract probes (180 km
  usable): Yarmouth Dirt/Balanced and north-NB Dirt/Balanced empty-fan gaps;
  Cape Breton Balanced gap near the dest. Do not put shortest back.
- Wander slider: needs a real, monotonic, visibly-scaling effect anchored
  around a sensible median default, not the current near-flat 0%–100%
  behavior. Do not tweak weights ad hoc until that design is settled.
- Avoid-highways / avoid-cities (audit 15 Sep Stage 1 phone): both toggles
  are wired into `ProfilePolicy` / `SearchOptions.cityWall` via
  `RidePreferences`. Both avoidance switches now default to **on** in every style.
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
- Overnight 15–16 Sep (do not fix inline): north-NB Dirt wander 50 and 100 are
  the same ride (edge hash `4a4d525e1c5c`). Cape Breton and Yarmouth do differ.
- Overnight 15–16 Sep: contract Dirt is still 57–66%, not 70–80%. Yarmouth is
  the weakest (57.1%). Clean on all three corridors is 0% dirt, so a paved
  spine exists; the connected legal dirt is what is missing, not a paved-only
  search. Profile candidate + away×1 did not reach 70% on any of the three.
- Overnight 15–16 Sep: the rule-3 shape checker reported `shape:0->0` on every
  Dirt/Balanced contract ride. It is unproven on a real loop / out-and-back / W.
- Overnight 15–16 Sep: staged Gaspé (Porters Lake → 48.922934,−64.273363) is
  1,281 km / 69.3% dirt / 16.8 s / 308 MB. Memory and dirt-vs-68% met; 8 s
  missed. Stage `nb+qc` spends ~10 s indexing all of Québec. Need a subgraph
  or a cheaper index, not another corridor tweak. Staged ride is ~25 km longer
  than the old single 3-pack search (1,256 km) because the handover is the
  nb–qc seam closest to the pin, not a globally optimal split.
- `debugBuildUsesIsolatedDevelopmentBackends` still expects fabric-01 against
  the app’s fabric-02. Pre-existing; left unstaged.
- `Dirt/Features/Groups/GroupsSheet.swift` and `Dirt/Routing/RoutingModels.swift`
  remain dirty and must not be staged with routing work.

### Overnight report — 16 Sep 2026

Probe-only overnight on `cursor/on-device-routing-speed-37c5`. No phone tests.
Fuel off. Contract: Porters Lake → Cape Breton (−60.477673 46.931127), →
Yarmouth (−66.09856 43.84097), → north NB (ns,nb −67.02568 47.31730), each
Dirt / Balanced / Clean. Style targets 100 / 50 / 0. §5 was not edited;
internal staging does not add waypoints (rule 7). Engine tests passed before
every commit. `GroupsSheet.swift` and `RoutingModels.swift` were never staged.

#### STEP 1 — finish distance-break removal — `c457e92`

What changed: long legs stay one rider-to-rider search. No D pins. Routes
paint from real surfaces (brown/black). Card dirt matches logged dirt %.
12 non-fuel matrix cases IDENTICAL to the then-baseline (`step1-matrix`).

| Route | Style | km | dirt % | target | s | peak MB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Cape Breton | Dirt | 603.9 | 59.7 | 100 | 2.35 | 79 |
| Cape Breton | Balanced | 563.7 | 50.9 | 50 | 1.77 | 79 |
| Cape Breton | Clean | 536.2 | 0 | 0 | 0.64 | 74 |
| Yarmouth | Dirt | 581.9 | 53.8 | 100 | 1.18 | 85 |
| Yarmouth | Balanced | 514.8 | 41.1 | 50 | 2.73 | 86 |
| Yarmouth | Clean | 457.7 | 0 | 0 | 0.69 | 81 |
| north NB | Dirt | 764.1 | 64.3 | 100 | 3.67 | 165 |
| north NB | Balanced | 713.7 | 55.4 | 50 | 3.39 | 140 |
| north NB | Clean | 739.3 | 0 | 0 | 1.56 | 137 |

Unfinished: none for this step.

#### STEP 2 — wander vs road progress — `782914f`

What changed: corridor width now uses the straight-line span; extra and
backward allowances are metres of road remaining toward the next waypoint,
scaled by wander. Dirt noPath retries once with the progress gate relaxed.
Default-wander contract (below) kept Cape Breton Dirt/Clean; Yarmouth and
north-NB Balanced moved.

Wander 0 / 50 / 100 on Dirt (must be different rides):

| Route | wander 0 km / dirt % | 50 | 100 |
| --- | --- | --- | --- |
| Cape Breton | 577.5 / 58.3 | 602.7 / 59.6 | 603.9 / 59.7 |
| Yarmouth | 510.8 / 48.9 | 519.0 / 50.6 | 581.9 / 53.8 |
| north NB | 750.0 / 63.6 | 764.1 / 64.3 | 764.1 / 64.3 |

Cape Breton and Yarmouth hashes differ at all three ticks. North NB 50 = 100
(hash `4a4d525e1c5c`).

| Route | Style | km | dirt % | target | s | peak MB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Cape Breton | Dirt | 603.9 | 59.7 | 100 | 1.65 | 101 |
| Cape Breton | Balanced | 563.7 | 50.9 | 50 | 1.86 | 104 |
| Cape Breton | Clean | 536.2 | 0 | 0 | 0.62 | 74 |
| Yarmouth | Dirt | 581.9 | 53.8 | 100 | 1.60 | 106 |
| Yarmouth | Balanced | 546.4 | 47.9 | 50 | 1.78 | 107 |
| Yarmouth | Clean | 457.7 | 0 | 0 | 0.62 | 81 |
| north NB | Dirt | 764.1 | 64.3 | 100 | 2.55 | 163 |
| north NB | Balanced | 719.3 | 55.7 | 50 | 3.14 | 166 |
| north NB | Clean | 739.3 | 0 | 0 | 1.50 | 136 |

Unfinished: north-NB wander saturates by 50. Listed in Backlog.

#### STEP 3 — Dirt toward 70–80% — `b2ceb77`

What changed: `dirtPavementAwayAtFullWander = 1.0`; if Dirt is under 70%, run
a `.profile` candidate and keep the dirtier legal ride. Balanced resource
recovery restored to the 40–50% band only. Balanced and Clean unchanged vs
STEP 2.

| Route | Dirt before (STEP 2) | Dirt after | Balanced | Clean |
| --- | --- | --- | --- | --- |
| Cape Breton | 603.9 km / 59.7% | 667.8 km / 65.6% | 563.7 / 50.9 | 536.2 / 0 |
| Yarmouth | 581.9 km / 53.8% | 620.8 km / 57.1% | 546.4 / 47.9 | 457.7 / 0 |
| north NB | 764.1 km / 64.3% | 781.7 km / 65.5% | 719.3 / 55.7 | 739.3 / 0 |

None of these tested candidates reached 70%. These measurements do not prove
an upper bound on the dirt available in the connected legal network. They record
what the then-current search found, not that a better ride is impossible.

| Route | Style | km | dirt % | target | s | peak MB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Cape Breton | Dirt | 667.8 | 65.6 | 100 | 2.46 | 103 |
| Cape Breton | Balanced | 563.7 | 50.9 | 50 | 1.87 | 104 |
| Cape Breton | Clean | 536.2 | 0 | 0 | 0.60 | 74 |
| Yarmouth | Dirt | 620.8 | 57.1 | 100 | 1.99 | 108 |
| Yarmouth | Balanced | 546.4 | 47.9 | 50 | 1.81 | 107 |
| Yarmouth | Clean | 457.7 | 0 | 0 | 0.60 | 81 |
| north NB | Dirt | 781.7 | 65.5 | 100 | 3.33 | 167 |
| north NB | Balanced | 719.3 | 55.7 | 50 | 2.89 | 166 |
| north NB | Clean | 739.3 | 0 | 0 | 1.47 | 137 |

Unfinished: 70% Dirt on these three OD pairs. Evidence above; Backlog.

#### STEP 4 — leg shape — `3f12746`

What changed: `RouteQuality.shapeFaults` flags reused edge IDs (≥2 runs >80 m)
and a W in the first/last 2.5 km of a pin. One avoid-edge re-search when a
fault is found. Probe summary `shape:before->after`.

Caught on the nine contract rides: **0 before, 0 after** (every Dirt/Balanced
`shape:0->0`; Clean has no shape field). Nothing to repair on these pins.

| Route | Style | km | dirt % | target | s | peak MB | shape |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Cape Breton | Dirt | 667.8 | 65.6 | 100 | 3.23 | 102 | 0→0 |
| Cape Breton | Balanced | 563.7 | 50.9 | 50 | 2.05 | 105 | 0→0 |
| Cape Breton | Clean | 536.2 | 0 | 0 | 0.63 | 76 | — |
| Yarmouth | Dirt | 620.8 | 57.1 | 100 | 2.02 | 107 | 0→0 |
| Yarmouth | Balanced | 546.4 | 47.9 | 50 | 1.75 | 107 | 0→0 |
| Yarmouth | Clean | 457.7 | 0 | 0 | 0.63 | 81 | — |
| north NB | Dirt | 781.7 | 65.5 | 100 | 4.29 | 167 | 0→0 |
| north NB | Balanced | 719.3 | 55.7 | 50 | 3.13 | 166 | 0→0 |
| north NB | Clean | 739.3 | 0 | 0 | 1.53 | 137 | — |

Unfinished: checker unproven on a real loop. Backlog.

#### STEP 5 — long-route internal stages — `57d57be`

What changed: `StagedRouter` runs only when ≥3 packs and geodesic >400 km.
Overlapping two-pack windows (ns+nb, then nb+qc), handover at the seam
closest to the destination, stitch into one rider leg. Compass
`maxRemaining` is capped per hop. 1–2 pack searches are unchanged.

Porters Lake → 48.922934,−64.273363 (Dirt, seed 1, zoom 12.5, ns,nb,qc):
1,280.7 km, 69.3% dirt (within 3 of 68%), **16.8 s**, **308 MB**. Stages
`ns+nb` 3.8 s then `nb+qc` 10.1 s. No D pins. Dirt % met; 400 MB met; 8 s
not met (Québec `IndexedGraph` of the whole pack).

Nine-route contract vs STEP 4: all nine **IDENTICAL** (km, dirt %, edge hash,
searches, pops). 12-case matrix 1–2 pack routes do not enter staging. Clean
matrix cases remain IDENTICAL to `step2-matrix`; Dirt/Balanced matrix cases
already differed from that snapshot after STEPs 2–4.

| Route | Style | km | dirt % | target | s | peak MB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Cape Breton | Dirt | 667.8 | 65.6 | 100 | 3.32 | 102 |
| Cape Breton | Balanced | 563.7 | 50.9 | 50 | 1.85 | 104 |
| Cape Breton | Clean | 536.2 | 0 | 0 | 0.60 | 74 |
| Yarmouth | Dirt | 620.8 | 57.1 | 100 | 2.05 | 108 |
| Yarmouth | Balanced | 546.4 | 47.9 | 50 | 1.68 | 107 |
| Yarmouth | Clean | 457.7 | 0 | 0 | 0.61 | 81 |
| north NB | Dirt | 781.7 | 65.5 | 100 | 4.36 | 167 |
| north NB | Balanced | 719.3 | 55.7 | 50 | 2.98 | 165 |
| north NB | Clean | 739.3 | 0 | 0 | 1.50 | 137 |

Unfinished: Gaspé 16.8 s vs 8 s. Stopped rather than extract a Québec
subgraph overnight. Backlog.

#### STEP 6 — Loop far pin is a hard extent — `f5bd9ef`

What changed: the far pin is now the outer edge of the ride (§2, §5), not
merely what the distance target aimed at. `SearchOptions.extentCenter` /
`maxExtentMeters` (opt-in, nil by default) reject any explored road farther
than `maxExtentMeters` from `extentCenter`, exempting only the endpoint's own
attached edge. `LoopPlanner` sets `extentCenter = start`,
`maxExtentMeters = start.distance(to: far) + 2 km`, for outbound and the
derived inbound request, so both legs share one centre and radius. No other
caller sets these fields, so From Here and Plan are unaffected: the 12-case
non-fuel matrix is byte-identical before/after (edge hash, km, dirt%, pops,
searches — `step5-matrix` vs `step6-matrix`).

Probe: Porters Lake → (−62.89594,45.11837), the pin family from the owner's
last device test, `ns` pack, Dirt, Allow Unknown **off** (product default).
Before this step the combined loop reached 81.6 km from start against a
52.6 km straight-line pin distance (+29.0 km, on the inbound leg — outbound
alone was already close, +1.6 km). After, across three target distances:

| Target | Outbound km | Inbound km | Total km | Dirt % | Outbound max-from-start | Inbound max-from-start |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 km | 112.7 | 114.5 | 227.2 | 34.0 | 52.75 km (+0.14 km) | 52.75 km (+0.14 km) |
| 140 km | 105.6 | 136.1 | 241.7 | 36.7 | 52.75 km (+0.14 km) | 52.75 km (+0.14 km) |
| 250 km | 113.3 | 132.2 | 245.5 | 35.7 | 52.75 km (+0.14 km) | 54.18 km (+1.57 km) |

Every case stays inside the 2 km snap tolerance; none goes meaningfully past
the pin. Combined distance dropped materially at the 140 km target (395.2 km
→ 241.7 km) because the untaxed detour that previously ran outbound edges'
`repeatFactor` tax out past the pin to avoid re-riding them is now blocked,
so the return retraces more of the outbound at a real, bounded cost instead
of ballooning past the extent. Engine tests: 64/64 (62 existing + 2 new)
passed before this commit.

Unfinished: short-dirt clawback / 1 km rule, global return `repeatFactor`,
per-leg Allow Unknown, fuel, map freeze, and JS decommission are untouched —
out of scope for this step. On the fixture pin, blocking the untaxed detour
past the pin leaves the return re-riding 24–33% of its own distance
(`reriddenMeters`/inbound km across the three targets above) at the taxed
`repeatFactor` rate. Retuning that factor or the clawback is a separate,
deliberately deferred question — not this step's job.

## 9. Existing V4 data format reference

This describes the existing data that must remain readable during the repair;
it is not a requirement to rebuild or publish packs. Check encoder/reader tests
when changing implementation. Legacy V2/V3 decoding is not V4 legal-topology
qualification. Every participating region must satisfy the required schema,
capabilities, paired identities, and compatible source epoch.

Objects: `graph.v4.bin` (DRT4, little-endian magic `0x34545244`, version 4),
paired `geometry.v1.bin` (GEOM v1), `fuel.v1.json`, and `pack-manifest.v2.json`.
GEOM v1 flag bit 0 denotes Float64 coordinates (otherwise Float32). Optional
flag bit 1 adds an exact matching-grid table immediately after the coordinate
array: four little-endian Int16 values per edge, `xMin,xMax,yMin,yMax`, using
`floor(storedCoordinate / 0.05)` for longitude/latitude cells. Empty shapes use
`32767,-32768,32767,-32768`. This version fixes the cell width at 0.05 degrees;
changing that convention requires a new format identifier. The table and original
shape bytes share the paired geometry hash. The factory validates every bound
against the stored coordinates; old readers may ignore the optional table.
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
For Dirt/Balanced, code 1 is allowed with Allow Unknown on, or as a continuous mapped connector of at most 100 m between through-permitted roads with it off (owner decision, September 19). The cap is cumulative across segmented roads and cannot reset at a zero-length connector or internal stage. Codes 2–5 never become through permission. Clean continues to exclude code 1.

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
