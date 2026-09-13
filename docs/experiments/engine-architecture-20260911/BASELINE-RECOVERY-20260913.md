# Baseline recovery — September 13, 2026

Status: **DEV 40 remains the owner-accepted production app foundation. DEV 41 local computation checkpoint is unqualified: final serial replay has eight failed assertions. No new phone installation.**
 
## Superseding owner direction: production app foundation

The owner clarified that DEV must start from the production/TestFlight app code,
preserving its onboarding, UI, and launch-ready functionality while adding
installed offline-pack computation. Restoring the older app shell was the wrong
foundation. The investigation below records an unqualified historical experiment;
it does not establish the approved product UI or a usable DEV candidate.

The production 2 (19) release record in the main worktree identifies release
source `582fcb1` and archive `DIRT-Production-2-19-Final.xcarchive`, with additional
workspace changes recorded at archive time. The later `91cc3cc` app checkpoint
must be reconciled with that release evidence before selecting the exact source.
Historical native revision `71aa7fd` remains routing comparison evidence only.

The obsolete simulator replay was interrupted following this clarification;
its build and test-app processes have exited. The suite did not complete or pass.
No phone installation or production modification occurred. Product parity must
be established on the production-derived DEV candidate before route qualification
and any owner review on the phone.

## Production-derived DEV foundation — build 40

Owner explicitly authorized installing DEV on September 13 to verify the current
production app foundation, before completion of the on-device migration. This
supersedes the earlier no-install boundary for this foundation build only; it
is not route acceptance or permission to modify production.

- App, resources, configuration, Xcode project, and test sources restored from
  `91cc3ccdd9f51fa6ff503f3f06e7cab59b00393e`, the current production app workspace
  checkpoint immediately before graph-loading experiments. Every file in `Dirt/`
  matches that revision. This includes onboarding, Loop, preferences, pin
  confirmation, navigation, profile, Groups, audio, and launch-preparation fixes.
- This is the current production-line source, not a claim of binary identity
  with uploaded TestFlight 2 (19). That archive predates the later workspace
  checkpoint; its release record identifies `582fcb1` plus workspace changes.
- DEV identity remains `com.mayday.dirt.dev`, development accounts/services, with
  the source's immutable `fabric-v4-20260909-02` pack catalog. Production identity
  and release build 19 remain unchanged. DEV build number is 40.
- Only foundation adjustments relative to the source: DEV build number and
  disabling parallel testing. No app routing, fuel, or UI edits are included.
- Foundation planning therefore still follows the production source's existing
  online policy. Build 40 does **not** claim completed local-only routing.
- Historical experiment and replay source are preserved in `4d467b7`; original
  hybrid checkpoint remains `165eac4`. They are not merged into this app baseline.
- Next enhancement must move route and fuel computation to installed graphs,
  preserving the production app and accepted routing contract. Border seams,
  fuel progress, repeated roads, profile semantics, limits/cancellation, and
  full requested/reached destination reporting require replay and phone review.
- Target: White iPhone only. Red and `com.mayday.dirt` are untouched.

### Foundation installation and owner acceptance

- Xcode device build succeeded; development environment verification and code
  signing verification passed. The matching production verification scripts
  were restored because the experiment script still expected the obsolete
  StoreKit relative path.
- Xcode CoreDevice installed and launched `com.mayday.dirt.dev` on White.
  Device inventory independently confirms version 2, build 40.
- Owner explicitly accepted the foundation: “Yes this is the right foundational
  build.” The owner initially questioned the motorcycle animation, then confirmed
  “There it is. Yeah we're good.” This accepts the app foundation, not local-route
  parity or a completed scalability migration.
- App rollback checkpoint: `53b7105`. No subsequent computation changes belong
  to that installed artifact.
- Serial simulator suite passed: **312 tests in 38 suites**, 38.835 seconds of
  test execution, using only the authorized existing simulator. Initial run
  exposed three stale release01 assertions in one configuration test; corrected
  expectations match documented release02 URLs. A method-filtered attempt ran
  zero tests and is not counted; the subsequent full suite passed. App
  configuration is unchanged. Result: `/tmp/Dirt-Production-Foundation-40-verified.xcresult`.

### Confirmed migration gaps in the production source

`PackRoutingSource` rejects non-nil ride preferences for both route and fuel
requests. `RoutingSourcePolicy` selects live whenever online; navigation recovery
also falls back to live. Typed local failures are collapsed into a generic
no-route message. These are concrete remaining migration boundaries, not
permission to simplify features or change route rules.

The pre-experiment app checkpoint records accepted DEV service `139a173`.
That service contains ride-preference behavior absent from this worktree's older
JavaScript sources, including continuous wander distance cost and highway/city
preferences. Comparisons must explicitly identify the service revision; testing
against whichever JavaScript happens to be checked out would repeat the earlier
baseline mistake. No preference formula has been ported or changed yet.


## Local computation work after foundation acceptance

DEV 41 recovery checkpoint; **not installed or qualified**. Build 40 remains
the accepted phone foundation and rollback. Its signed app is preserved at
`.build/accepted-foundation-40/Dirt.app` with an identity record.

### Execution/performance changes

- DEV-only `DIRT_LOCAL_ROUTING` selects installed-pack computation regardless of
  connectivity, including navigation recovery and replacement fuel lookup. This
  does not authorize live fallback when a pack is missing. Release configuration
  is unchanged. The local replacement lookup preserves the existing radius and
  distance ordering. Custom ride preferences remain an explicit migration gap.
- App-target compiler optimization is enabled for this DEV candidate. The first
  optimized replay reduced short Clean from 39.609 to 6.974 seconds with the same
  7,639.971 m distance and 11% dirt. Short Balanced retained 7,520.972 m/17% dirt
  and completed refinement in 3.560 seconds instead of timing out at 19.850.
  Deadline-limited routes can change when more of the existing search completes;
  this is not proof of route parity.
- Remaining geometry reads use unaligned-safe access. Pack bytes are unchanged.
- A small evictable decoded-pack cache reuses graphs when switching regions;
  file path, byte count and modification time identify entries. It is an
  execution cache, not a coverage or border policy. The 128 MiB cost limit counts
  serialized inputs, not actual resident memory. Real NS/NB reuse and invalidation
  checks are included in the next simulator run.
- Range-query station matches are cached by exact coordinate, effective access
  policy, live pack object and geometry object. Legal V4 matching has no profile
  distinction beyond unknown access; legacy packs retain profile in the key. Only matches are reused; range
  distances are recomputed for every request. The cache retains at most 8,192
  matches for one pack. The station loop checks cancellation/deadlines.
- Route-response cache identity now reflects actual installed graph/geometry/seam
  file paths and stamps, rather than the latest downloadable catalog version.
  Replay had exposed a misleading September 9 catalog label on September 8 files.
- Existing caller fuel deadlines and cancellation now propagate into detached
  native searches. Incomplete work remains unknown rather than a proved fuel gap
  or no-route result. No larger search budget or new fuel threshold was added.
- Cyclic predecessor walks now detect the same existing rejection in constant
  space instead of reaching the ten-million-step safety guard. Acyclic partial
  edge overlap semantics remain unchanged; cycle/overlap checks accompany replay.
- Test pack roots isolate fixture storage and disable catalog refresh. All four
  accepted pack files are checked against manifest sizes and SHA-256 hashes.

### Destination geometry correction

The route-output audit found the existing `soft-stitch-end` connector reversed:
it ran from the requested destination back to the road. The rural oracle exposed
a 117.432 m join gap. The candidate reverses only this final connector so the
route joins the road and ends at the requested destination. Selected roads,
connector distance, snap limit and access classification remain unchanged. This
bug is present in `71aa7fd` as well; the correction follows the explicit destination
preservation requirement. Replay asserts connector continuity and actual arrival.

### Explicit route-selection restoration

The production-line source also raised the non-Clean settlement preference from
`5` in `71aa7fd` to `20`. The candidate restores exactly `5`; Clean overrides
remain unchanged. The corresponding regression assertion now names the recovered
value. This is an explicit routing restoration, not a tuned replacement value.

The production-line native implementation added `RoadCompass` road-distance
progress penalties after `71aa7fd`. The candidate removes those penalties and
restores that revision's geographic progress calculation. This is a behavior
restoration, **not** a performance-only change. Current legal turn-state and
customer-access handling remain; the whole router is not claimed byte-identical
or proven equivalent to `71aa7fd`. No new Dirt/Balanced definition or fuel ranking
has been introduced. Replay must establish the consequences before phone use.

### Rejected work and current evidence

- A proposed predecessor history index passed 20,000 isolated comparisons but
  worsened actual route replay. It was fully reverted; the rejected patch is
  preserved as `REJECTED-HISTORY-INDEX.patch`. It is not in the candidate.
- Unoptimized native replay retained 17 route JSON outputs in
  `/tmp/dirt-production-native-before-history-index`; it was interrupted and did
  not pass. Cape Breton Balanced hit its time cap after 136.832 seconds.
- Optimized pre-deadline replay retained 25 JSON outputs in
  `/tmp/dirt-optimized-before-fuel-budget`; long fuel searches ignored the caller
  deadline and the run was interrupted. It did not pass.
- Full serial deadline replay: **321 tests, 40 suites, 11 failures**, 602.204
  seconds. Ten oracle fuel workflows did not reach the requested endpoint; the
  short itinerary also failed its complete-status assertion. Original destinations
  and partial reached endpoints remain in the JSON evidence. Result bundle:
  `/tmp/Dirt-Local-Deadline-Replay-41b.xcresult`; preserved route JSON:
  `/tmp/dirt-deadline-before-progress-restoration`. This run precedes cycle detection,
  decoded-pack caching and geographic progress restoration.
- Service `139a173` on `fabric-v4-20260909-02` completed 36 standalone route/fuel
  requests: 26 complete, 10 unknown/incomplete. This uses the harness's explicit
  16-stop request shape, not the app's one-stop forward-window workflow, and is
  not a passing parity comparison.
- NS graph, geometry and fuel hashes match between September 8 accepted packs
  and September 9 production packs; seams differ. NB graph and seams differ;
  geometry/fuel match. Cross-province comparisons must use identical releases.
- Geographic progress/cycle/cache run completed **324 tests in 41 suites**, with
  12 issues: the same 11 replay failures plus an overlap-test assertion. Pack
  reuse/invalidation passed. Result: `/tmp/Dirt-Local-Recovered-Progress-41b.xcresult`.
- Station-match cache/endpoint run completed **325 tests in 41 suites**, with
  **8 issues**, 401.936 seconds. Eleven of 18 oracle fuel workflows reached the
  destination. Cross-province (3 profiles), multi-stop (3), and Canso Dirt remained
  incomplete; the short builder itinerary retained an unproved destination-fuel
  status. Clean Antigonish now completed 221,711.560 m with one pump, with hops
  206,665.172 m and 15,046.388 m. Canso Clean and Balanced also completed with one
  stop each. Request deadline exits were approximately 15 seconds rather than
  23–33 seconds. All overlap, cancellation, pack-reuse and repeated-reachability
  tests passed. The overlap test now evaluates its predicate before passing the
  Boolean to the assertion; no overlap threshold changed.
  Result: `/tmp/Dirt-Local-Station-Cache-41.xcresult`. Raw JSON is preserved under
  `.build/recovery-evidence/station-cache-41/`. This run precedes restoration of
  the settlement multiplier from 20 to the recorded value 5.
- Final combined checkpoint run (including settlement value 5): **325 tests in
  41 suites, eight failed assertions across two tests**, 403.588 seconds. Nineteen
  direct road requests completed (six short/rural profile requests, twelve
  September 13 NS requests, one NS/NB Dirt request). Eleven of eighteen oracle
  fuel workflows completed; the same seven workflows and the destination-fuel
  assertion remain unqualified. Result:
  `/tmp/Dirt-Local-Recovery-Checkpoint-41.xcresult`. Raw outputs:
  `.build/recovery-evidence/checkpoint-41/`.
- Build 41 retains the production-foundation DEV catalog `fabric-v4-20260909-02`;
  these historical replays explicitly use accepted `fabric-v4-20260908-02` files.
  They do not qualify the candidate's catalog release. A complete matched-release
  replay and resolution of the NS/NB data differences remain required before
  installation. No installed pack or published catalog was replaced.
- No new phone installation or production modification occurred. Build 40 remains
  the accepted app foundation and signed rollback artifact.

### Shape versus surface-reporting discrepancy

The pre-station-cache native comparison and service `139a173` standalone route
outputs use identical oracle coordinates, seed and profile flags. NS road,
geometry and fuel bytes match between the two releases; seam bytes do not.
These observations are specific to the intra-NS requests, not proof of complete
pack/release equivalence or fuel-workflow parity:

| Case/profile | Native metres / dirt | Service metres / dirt | Road edge order |
| --- | ---: | ---: | --- |
| Short Clean | 7,640 / 11% | 7,561 / 6% | Identical 70 road edges |
| Short Balanced | 7,521 / 17% | 7,445 / 6% | Different (63 shared edges) |
| Short Dirt | 7,521 / 17% | 7,445 / 6% | Different (63 shared edges) |
| Rural Clean | 57,179 / 0% | 56,903 / 0% | Different (82 shared edges) |
| Rural Balanced | 98,179 / 49% | 95,231 / 71% | Different (104 shared edges) |
| Rural Dirt | 95,495 / 71% | 95,231 / 71% | Identical 135 road edges |

The short Clean percentage discrepancy is concrete: service segments contain
439 m of known unpaved surface and about 414 m of unknown surface. Native
`SurfaceFamily.swift` explicitly includes unknown surface in displayed Dirt%;
service `adventure/surface.js` excludes it. The road sequence is identical in
this case, so this discrepancy is not evidence to retune search costs. Native
endpoint connectors also contribute distance that the service's road-only
geometry omits. Neither surface rule has been silently redefined in this work.

### Avoidance audit scope

`RECOVERY-STATION-CACHE-AVOIDANCE-AUDIT.json` measures the saved geometry against
all 3 city and 57 town rectangles embedded in the accepted NS pack. The only
city overlaps in those completed outputs occur on the Canso Clean/Balanced
arrivals into Sydney, where the requested destination is inside the city box.
Town overlaps are retained as measurements; the contract uses finite preferences,
so overlap alone does not establish a violation or prove an alternative exists.
The accepted NB pack has neither embedded list. Native static fallback data is
separate and is not covered by this rectangle-only audit; NB avoidance remains
unqualified. No boxes or location-specific exceptions were added.

### Final geometry and device-build checks

`RECOVERY-CHECKPOINT-GEOMETRY-AUDIT.json` records 30 completed native outputs
and the separately identified service comparison. Final native geometry joins
are contiguous under the audit's coordinate-segment method (maximum join gap
0.0 m). The earlier reversed endpoint connector is corrected.

**Completion is not quality acceptance.** Exact undirected coordinate-segment
repeats remain: Antigonish Clean fuel itinerary 2,396.33 m; long NS/NB Dirt
1,734.13 m; Canso Balanced 84.13 m; Canso Clean 53.44 m. This is a lower bound
and does not detect nearby or differently split duplicate roads. Fuel approaches
and border joins need segment-level qualification; native backtrack summaries
alone did not expose these physical overlaps. No acceptable repeat threshold
has been invented, and no passing route-quality claim is made.

The signed generic-iPhone DEV 41 build succeeded. Development environment checks,
StoreKit reference checks, and strict recursive code-signing verification passed;
Info.plist confirms build 41. Artifact:
`.build/production-foundation-device/Build/Products/Debug-iphoneos/Dirt.app`.
It has **not** been installed. Production/TestFlight and White's accepted build
40 remain unchanged. The signed rollback app is separately preserved.

### Owner contract clarification pending

The owner has been asked which existing surface-reporting rule to preserve:
the frozen/native unknown-inclusive calculation or current production's known-dirt
calculation. The short Clean case supplies a concrete same-road comparison
(11% versus 6%). This is not a proposed new profile definition; the sources
already disagree. No change to either definition has been made pending the
answer. Fuel completion, candidate pack parity and custom preferences remain
separate technical gates.

### Remaining release gates

Custom ride preferences/Loop cannot be silently discarded: the current native
source explicitly rejects preference-bearing requests. Accepted service behavior
must be migrated before this is a functionally equivalent product. Fuel windows,
full oracle route shapes, dirt contribution, repeated roads, forward pump progress,
city/town avoidance, access and border seams still need passing comparisons on
matched pack identities. A no-stop route fitting the tank is not by itself proof
that the intended Dirt route was preserved. No candidate is ready for installation.

## Historical investigation (superseded as an app foundation)

Worktree: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`.
Branch: `audit/baseline-recovery-20260913`. Production, published packs, physical
phone installation, and remote Git refs are untouched.

## 1. Recovered identities and approved presentation

| Boundary | Exact identity | What it establishes |
| --- | --- | --- |
| Frozen service | `94b467a11375e3ea3233c127b07af2ef039d0658`; tag `routing-rc1-2026-09-03`; `dirt-routing.r0.v1` | September 3 routing/fuel contract; accepted build 2 (13) |
| Native restoration source | `71aa7fd6d396bbf215bc1637ba1e3959f6fcdd6a` | September 6 legal routing, profile selection, fuel and itinerary implementation |
| Accepted physical NS/NB Dirt record | build 2 (23); `fabric-v4-20260908-02`; live `67425f53c32f26bf81911331931462389205bc2b` | Three rider-accepted NB route builds; 250 km tank, 10% reserve, unknown off, automatic fuel on |
| Accepted NS continuity record | build 2 (23); NS02; live `9c15324e6ace23df668c6061e2d4ba2a04b99bc8` | Rider's “Looks really good. Pass” at the recorded Cape Breton pin |
| Preserved experiment | `165eac4`; experimental `fabric-v4-20260909-01` | Rollback/reference for the hybrid work; **not** the accepted routing baseline |

These boundaries are not interchangeable. The physical build-23 records explicitly
identify **live** canary computation and leave offline parity unqualified. The
older numeric oracle is a historical measurement on different V3 bytes and an
older service build, not proof of expected exact V4 geometry. Its Clean multi-stop
row even contains repeated tiny Sydney-area stops; that observation does not
override the frozen forward-progress law.

The abandoned historical restoration matched the old `71aa7fd` / `9c15324`
app shell. The owner rejected that as the product foundation. Its
`RECOVERY-SOURCE-INVENTORY.json` describes only that abandoned state. Current
DEV instead preserves all production-line app files from `91cc3cc`, including
ride preferences and Loop; the owner accepted this foundation on White.

The abandoned replay configuration selected immutable candidate `fabric-v4-20260908-02`.
Current build 40 retains production-line release `fabric-v4-20260909-02`.
Production continues to use its public catalog and ordinary online source policy.
Installed-pack preference is explicitly limited to DEV. Replay checks every
accepted graph, geometry, fuel and seam file against its manifest byte count and
SHA-256. `RECOVERY-JS-CANARY-SUMMARY.json` records the full NS/NB identities.

## 2. Execution and compatibility changes

Relative to `71aa7fd`, the retained compatibility changes are:

- DEV source selection prefers installed coverage, without changing profile,
  fuel, access or route options. This is an execution location choice; it is
  not proof that live and native results already agree.
- Little-endian scalar/array decoding uses unaligned-safe reads.
- V4 compact edge IDs are derived from the pack's canonical OSM way and node
  endpoints when flag bit 4 is present. This restores existing checkpoint code,
  matching the JavaScript V4 decoder; no pack bytes or costs change.
- Accepted seam sidecars fill absent embedded seam metadata. No coordinate-near
  rescue connector or new seam ranking is added.
- The spatial-index cache retains the existing `3da6de4` live-pack identity
  safeguard explicitly required by the September 8 rollback notes. A recycled
  object address must not reuse another pack's spatial index.
- Pack-source failures use the existing typed failure mapping, so a search limit
  or cancellation is not rewritten to a blanket “no route”.
- Test-only injected cache roots and optional catalog refresh isolate replay
  storage. Ordinary construction keeps its existing defaults.
- Both DEV test targets are nonparallel. All test runs use only existing simulator
  `CC6035EE-9C03-48A2-ACBA-DDE3B068642A`, with `-parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1`.

The compact-ID omission was a real compatibility defect in the inherited recovery:
V4 omits the old string table, but the reader read it anyway. Empty IDs then made
postprocessing associate different roads with the same prior metadata. The rural
Dirt replay incorrectly reported zero known dirt. Restoring compact IDs changes
that result to approximately 71%, without altering route-selection code.
Whole-table JavaScript edge-ID digests are asserted in the real-pack replay;
a small legacy-versus-derived-ID fixture is also covered.

## 3. Behavioral changes and exclusions

The inherited recovery removes the hybrid fast-search envelope, forced early
pump qualification, destination-escape deferral, Balanced pump-approach fallback,
forecourt snap enlargement and later universal settlement wall. Those were
behavior changes, not performance-only changes. The recovered `FuelItinerary`,
`HopSearchPolicy`, `UrbanCore`, profile costs and `ItineraryBuilder` match
`71aa7fd` exactly. The sole difference inside `OnDeviceRouter` is the documented
spatial-index cache identity safeguard; route selection remains equivalent to
`71aa7fd` on the same correctly decoded graph.

The recovered contract keeps major urban cores as walls with labelled fallback,
and smaller settlements as finite costs. It does not turn every town into a
hard wall. Tests introduced for the later wall were restored to the accepted
`71aa7fd` expectations rather than changing the runtime to satisfy the experiment.

No new Dirt/Balanced definition, dirt percentage target, corridor width, station
ranking threshold, or location-specific repair is introduced.

## 4. Replay protocol and evidence

The September 13 matrix now includes all four NS endpoints and all three profiles;
the temporary first-endpoint/Dirt-only restriction is removed. The NS→NB replay
and real itinerary check remain enabled. The full historical oracle matrix reads
all six cases directly from `scripts/pack-fabric/bench/routing-oracle-cases.json`.

Native oracle replay ports the original forward workflow: 230 km tank, 207 km
usable, unknown off, Clean motorway avoidance on, seed 3511091208, a one-stop
15-second fuel window, inherited road history, excluded committed/rejected pumps,
and at most 16 forward attempts. Every route, fuel request/response, reached
endpoint, original destination and failure is preserved as JSON. Reaching a
bounded prefix is not counted as reaching the destination.

JavaScript comparisons have two explicitly separate protocols:

1. `replay-recovered-v4.js`: historical `9c15324` canary with road-only and
   integrated-fuel requests, accepted V4 bytes and the oracle's coordinates,
   profiles and 207 km usable range. The integrated request permits 16 stops and
   a 20-second canary window; it is not the old one-stop oracle workflow.
2. `replay-recovered-oracle-local.js`: the unchanged `run-routing-oracle.js`
   request workflow against exported historical API handlers. Pack reads are
   served locally; no hosted routing service is invoked. Each case's actual
   request and response are saved, including failures.

Initial findings (not acceptance):

- Historical canary road results return the same 7.445 km/6% known-dirt shape
  for all three short profiles, and the same 95.231 km/~71% shape for rural
  Dirt and Balanced. This is present in the accepted service source, not just
  Swift. The older oracle expects different results on its older bytes.
- Corrected native rural Dirt is about 95.217 km/71%; Balanced about
  92.965 km/66%. Exact geometry parity is not established by these similar totals.
- The September 13 short Dirt request returns a usable result with `popCap`
  refinement diagnostics. It must not be labelled as exhaustive route quality
  or proof that no better Dirt route exists.
- Historical canary fuel requests at 207 km usable include `label_limit`/
  incomplete proofs. A road response retained inside an unknown fuel result is
  not a fuel-complete itinerary. Do not substitute the physical 225 km usable
  setting to make this oracle pass.

Final serial suite totals, output audits and comparison tables are appended below
when execution completes. Earlier diagnostic runs were interrupted after the
compact-ID and cache-identity defects were established; they are not passing
verification evidence.

## 5. Unresolved decisions and acceptance gates

- `71aa7fd` native behavior and build-23 live canary behavior are different
  algorithms. Shared pack identity does not make them exact behavioral twins.
  Where results disagree, preserve evidence and obtain a baseline decision;
  do not retune one algorithm to mimic a percentage.
- Some physical acceptance fixtures named in the September 8 documents are
  absent from both this checkout and the inspected accepted revision's tree.
  The documents preserve coordinates/settings and observed acceptance, but do
  not contain full geometry. This limits reconstruction of exact phone shapes.
- Dirt must retain its requested profile. An equal result can arise from an
  explicitly shared accepted candidate pool; it is not blanket permission for
  a silent Balanced substitute in the native fuel path.
- Fuel progress, repeated roads, tiny stops, partial destination preservation,
  city/town avoidance, legal access and seams require the complete output audit;
  a passing route-count or timing assertion is insufficient.
- The installed-pack lookup still supports previously installed revisions.
  Before any phone qualification, actual installed manifest and file hashes
  must match the accepted candidate; an AppConfig URL alone is not proof.
- All requested comparisons and physical phone acceptance remain gates.
  No phone install is authorized by this report and none has been performed.

## 6. DEV recovery checkpoint and rollback

This branch is the isolated DEV recovery candidate. It preserves the accepted UI,
native routing/fuel source and immutable accepted pack configuration, with the
compatibility corrections above. It is a coherent **recovery checkpoint**, not an
accepted replacement for the live canary.

`165eac4` preserves the original hybrid work. `71aa7fd` remains the native behavior
comparison point, and the September 3 tag remains the frozen service boundary.
Do not reset the primary worktree, publish packs, push remote refs or install on
the phone as part of rollback. The recovery commit containing this report provides
the local return point for subsequent comparison work.

Android outcome requirements remain unchanged: preserve profile and access intent,
prove useful fuel progress, distinguish incomplete calculation from no-path/gap,
and retain destination intent for partial output. Compact-ID decoding and cache
identity are platform implementation requirements; no Android parity pass is
claimed by native simulator results.


## September 13 owner clarification: forward rides and geographic barriers

The owner explicitly authorized forward fuel legs and fresh-ride variety while
preserving the production-based UI and profile definitions. Fuel is part of the
ride. Progress must follow connected roads around obstacles, not geographic
closeness to the destination. The same rules must apply across regional borders;
Halifax-area–St. Stephen is a regression case, not a location-specific exception.

Current unqualified DEV changes after dfd9cbb:

- Native fuel selection uses directed road-distance guidance across the existing
  regional path and reciprocal recorded seams. Forward fuel discovery and the
  destination distance check use the same cross-pack view. These distances are
  lower bounds; exact riding legs still prove profile, turn, access and range.
- A requested partial window returns its proven fuel leg immediately. The
  itinerary builder reuses that route. It remains explicitly incomplete until
  the requested destination is reached. Fuel planning no longer solves a full
  destination ride for every distant pump candidate.
- The first suitable non-urban leg in the existing fuel search zone can be
  selected without comparing six complete itineraries. Explicit pump selection
  precedes the automatic candidate limit. Existing range/forward/retrace limits
  remain; no new location or percentage thresholds were added.
- Actual replay exposed long fuel-station exit spurs. For a pump within a tank's
  road distance of the destination, the final exit is checked against the
  existing retrace limit before selecting that pump. This is bounded exit
  validation, not a claim that an unbuilt continuation is complete.
- Customer endpoint intent is carried when a new window departs a selected
  fuel station. Ordinary rider pins retain their original endpoint intent.
- Station matches retain two pack/geometry identities within 8192 total entries.
  Spatial lookup retains two indexes, invalidates changed geometry, and uses
  conservative full-geometry bounds to skip impossible snap candidates before
  exact projection. Profile costs, snap radius and final matching remain intact.

Evidence is incremental and the candidate remains unqualified:

- Full serial simulator run `Dirt-Forward-Fuel-Integrated-20260913.xcresult`:
  338 tests, 335 passed, three failing tests (fuel oracle and two UI tests).
  All 19 direct-route shapes and dirt percentages matched `dfd9cbb`; distance
  differences were under one centimetre. The previously failing short itinerary
  destination/fuel-status test passed.
- Cold connected-road guidance improved from 52.66 seconds to 39.02 seconds
  with retained indexes, then 1.658 seconds with conservative geometry bounds.
  Forward and reverse cross-pack distances agree. These are simulator timings.
- Fuel selection now avoids retrying duplicate physical stations before other
  candidates. Osmium area IDs identify the same source way/relation; both mapped
  access records remain available, and an explicitly selected record is retained.
- Cross-pack search translates prior roads through V4 global OSM node IDs instead
  of interpreting one region's local node indices in the next region. Public
  edge IDs remain unchanged. Per-hop backtrack metadata is retained when joining
  regional results. Cross-window history identity still needs a complete audit.
- `Dirt-Fuel-Alias-Oracle-20260913.xcresult`: 17/21 fuel cases complete. Cross-border
  Dirt and all three Fundy profiles remain incomplete because of search budgets.
  All within-NS cases complete, including three-stop rides of 723–766 km. Exact
  repeated-segment audit of completed routes ranges from 0 to 708 metres; this
  remains a lower bound, not proof of all access/turn/surface requirements.
  Earlier 4 km and 8 km fuel repeats are absent in this iteration.
- The Profile UI test now asserts the accepted persistent dock instead of the
  old full-screen expectation. Its Route tap still fails to switch panels.
  The paywall test still shows “Plans unavailable”, including with an explicit
  local StoreKit test session. Failure screenshots and accessibility hierarchies
  are preserved in `Dirt-Fuel-Aliases-UI-20260913.xcresult`. No app UI source was
  changed to conceal either failure. Both remain open qualification findings.
- A further execution-only optimization is under replay: synchronous immutable
  predecessor-array views avoid repeated Swift exclusivity checks while retaining
  the existing retrace walk and cycle rules. Fuel selection also avoids onward
  work for an incoming leg already rejected by the existing retrace allowance.
  These last changes are not yet qualified.

The added Fundy case uses Porters Lake (44.764919, -63.340350) to the accepted
sidecar's St. Stephen station osm:w682170844 (45.177074, -67.296103), with the
historical oracle's profiles, seed, tank and reserve settings. The historical
oracle file and its coordinates remain unchanged. Evidence is retained under
.build/recovery-evidence; audit-native-fuel-replay.py reports exact repeated
segments as a lower bound, endpoint gaps, hop lengths and completion separately.

Fresh-ride seed plumbing, custom ride preferences, full route quality, candidate
pack qualification and phone route acceptance remain open. The current regional
path chooser is unchanged; arbitrary worldwide coverage has not been qualified.
The live service remains a comparison reference, not the normal computation path.
Production deployments, phone installation and approved UI are untouched. Android
must implement the clarified outcomes; no Android qualification is claimed.

### Subsequent work in progress: initial fill and ride identity

The owner explicitly reaffirmed that **every fuel-enabled ride first visits the
closest reachable fuel station**, including a 500 m stop. The current forward
builder did not enforce this at arbitrary starting points; it could accept a
direct ride based on a full-tank assumption. A new `fuel.initialFillUp` request
phase now separates the initial refill from later forward-progress/search-zone
rules. It preserves the original destination, returns the actual approach leg,
and does not claim the ride is finished at the pump. Starting on a mapped pump
is recognized separately. Tests are running; no device qualification is claimed.

Rider-leg identity now supplies a stable, JavaScript-safe nonzero variety seed to
route and fuel requests. Saving, retrying, changing profile and replacing fuel
stops keep that seed; fresh rider pin identities change it. Existing native
variety rules remain unchanged. This is newly wired behavior, not a claim that
every road network can produce a distinct feasible alternative.

The immutable predecessor-view optimization preserved all 19 actual direct-route
geometries and dirt percentages. A subsequent experiment removing speculative
final fuel exits completed only 14/21 cases and was rejected: it chose initial
forward pumps whose exits then exhausted the search budget. Its source is saved
in local recovery evidence. The 17/21 variant's exit validation is restored,
with an additional final-leg retrace check. Remaining first-pump exit constraints
need resolution without costly repeated full-route searches.

### Full serial verification of the initial-refill candidate

`/tmp/Dirt-Forward-Initial-Full-20260913.xcresult` reports 342 unique tests: 338
passed and four failed (345 executions including dynamic parameter runs). The
failing tests are the historical fuel oracle (four incomplete long requests),
one incremental fixture with an obsolete arbitrary-origin/full-tank assumption,
and the two previously recorded UI tests. The incremental fixture now explicitly
starts at a mapped station; focused itinerary, incremental-rebuild and saved-identity verification passed in `Dirt-Initial-Fill-Integration-20260913.xcresult`.

All 19 direct-route geometries and dirt percentages still match the pre-work
checkpoint. The historical fuel replay remains 17/21 complete. The additional
real-pack initial-refill checks pass for Clean, Balanced and Dirt, each selecting
accepted station `osm:w183099842` from the recorded Porters Lake start, with an
approach of approximately 7.16 km. The whole short itinerary now correctly
contains that initial refill followed by the original rider destination. A
separate 500 m builder regression and the fuel-off regression pass. Historical
oracle requests retain their exact original settings; their new initial-refill
flag is absent. Owner-directed initial-refill tests are separate, not silently
substituted for those baseline comparisons. Evidence: `.build/recovery-evidence/forward-initial-full`.

No AppGate, RootView, onboarding or subscription view source differs from
production foundation `91cc3cc`. UI failure screenshots show unavailable StoreKit
plans and a Profile dock tap that does not switch to Route. No app UI rewrite is
included. Production, R2, live deployments, GitHub and White remain untouched.

Remaining qualification includes: the four long fuel requests; complete initial-
refill-plus-long-ride replay; global history identity across separate fuel
windows; selected-stop replacement; UI failures; custom ride settings; candidate
`fabric-v4-20260909-02`; and White route acceptance. Seed plumbing is present,
but bounded native fuel searches currently disable the old predecessor-variety
mechanism, so varied output is not yet qualified. The pre-change code rollback
point remains `dfd9cbb`; the accepted phone foundation remains DEV 2 (40).

### Initial approach is a separate phase (owner follow-up)

The first complete owner-refill replay exposed a 129 km recreational approach to
the nearest station and approach-road history blocking the subsequent ride. The
initial approach now uses the existing distance objective with legal graph
connections, retains the selected profile's access/snap constraints, and records
`initial-fuel-approach` in search metadata. Ordinary ride objectives are unchanged.
This is a route-selection change for the owner-required initial phase, not merely
a performance optimization. After refuelling, recent recreational road history
starts afresh; the incoming edge remains available for legal departure turns.
The full initial approach stays visible in the itinerary. Reused prefixes retain
the initial-fill marker. Starting at a mapped station counts as the initial fill.

`Dirt-Initial-Approach-20260913.xcresult` exercised 21 owner requests: 15 complete,
six incomplete (all three cross-province and all three Fundy profiles). Their
failures explicitly report an exhausted planning budget, not a proven fuel gap.
Short, rural, one-stop, multi-stop and Canso requests complete in all profiles.
The rural initial approach is now 13.24 km instead of 129 km. Multi-stop initial
approaches are 931 m; short/Porters Lake approaches are 7.155 km. All recorded
joins are continuous. Exact repeated-segment lower bounds across entire completed
itineraries range from 2 m to 1.814 km, including permitted overlap with the
initial approach; this is not a claim of no repeated roads. Evidence is retained
in `.build/recovery-evidence/owner-initial-approach`, including actual geometries
and an audit. Historical oracle settings remain separate and unchanged.

The run also exposed a test fixture with no edge segments despite an assertion
about arrival-edge preservation. The fixture now supplies explicit segments and
checks the exact retained arrival edge. Focused itinerary and incremental tests
and all 19 direct replays passed in
`Dirt-Initial-Approach-Regression-20260913.xcresult`. Actual geometry and dirt
percentages match all 19 saved direct routes; comparison evidence is retained
in `.build/recovery-evidence/initial-approach-regression`.
The cross-province failures, UI failures and remaining qualification list above
remain open. This remains an unqualified DEV recovery checkpoint.
