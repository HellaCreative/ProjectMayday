# Routing rebuild implementation progress

8 September 2026. Branch `routing/rebuild-20260908`, isolated at `.build/routing-rebuild` from verified live `b3cb2fa2a9ef32f1f8f3b47ed860eb30ab792fdc`. Local implementation only; no deployment, factory change, mobile installation or production change.

## Implemented

Code lives in `scripts/pack-fabric/routing/lib/adventure/`.

- Immutable mode/anchor/primary-leg request contract, preserving generated fuel versus fixed rider ownership. Loop records its original return anchor, approximate target and first-fuel requirement.
- One known-surface calculation shared by candidate ranking/reporting. Unknown remains unknown. Balanced chooses 48% over 65% and prefers the dirt side at equivalent balance error.
- One request-owned deadline/cancellation/work budget across core operations.
- Fuel proof for exact candidate geometry, early stops, planned station refills, ordinary anchors, destination escape and honest incomplete results. A candidate fuel gap is never advertised as geographic scarcity.
- Shared candidate selection preserving a complete road ride when fuel verification fails. Candidate admissibility and legal proof remain upstream obligations, not inferred by this selector.
- Experimental fuel-aware label-setting search. Multiple arrivals to a road state retain cost/fuel tradeoffs; an inexpensive low-fuel arrival cannot erase a more expensive feasible continuation. Refills are search actions, not post-hoc route insertion.
- V4 graph adapter preserving directed access and node/via-way turn history without fabricated connections.
- Reverse road-cost bounds for the same graph/cost model. They guide search without a crow-line wall or shortest-derived ride-length cap. Partial bounds cannot masquerade as a no-path proof.
- Indexed station-to-road candidate discovery with explicit per-station evidence, reusing existing legal projection. Candidates are not automatically declared physical station visits or a verified fuel plan.

## Baseline replays

Reproducible runner: `scripts/pack-fabric/bench/run-rebuild-baseline.js`. Manifest and results in `scripts/pack-fabric/routing/candidates/rebuild-baseline/` within this worktree. These are local observations, not live-service latency percentiles. Fresh process then immediate warm request per case; OS cache is not cleared.

| Existing engine case | Cold process | Warm process | Outcome |
| --- | ---: | ---: | --- |
| Southwest NS Dirt | 2,185 ms | 1,836 ms | Complete, 48.9% known dirt |
| Same NS Balanced | 4,383 ms | 3,931 ms | Complete, 14.8% known dirt |
| Same NS Clean | 705 ms | 487 ms | Complete, 0% known dirt |
| Montreal fuel handoff | 3,663 ms | 2,654 ms | `match_failed` both times |

The legacy displayed dirt statistics include unknown surface while its journey-quality calculation does not. The new core makes that distinction explicit and consistent. Existing end-to-end fuel failure is preserved as a comparison case, not fixed by this foundation commit.

## Kernel experiment

`scripts/pack-fabric/bench/run-resource-probe.js`, NS accepted V4: 187,354 nodes, 220,770 edges. Explicit graph-node endpoints near the baseline; this is NOT the identical rider request. Urban policy, full endpoint projection, pump visits and destination escape are not integrated into the experiment.

Second local run:

- Experimental positive dirt-weighted search: 644 ms; 140,975 expanded states.
- Same graph, endpoints and cost with a complete reverse bound: 188 ms including 173 ms bound construction; 4,226 forward expanded states. Same 422,231 m route statistics, 53.86% known dirt.
- Reverse preparation adds its own graph work: total budget operations are higher even though wall time and forward labels fall. Reuse and memory must be measured across dense regions; do not extrapolate this single case into a universal speedup.
- Fuel-state search with only exact OSM-node station joins reaches the work limit, reported incomplete. That join produces zero stations because these POIs are not identical road nodes. This deliberately restricted probe cannot establish geographic scarcity or an end-to-end fuel result.
- Indexed legal projection at an experimental 150 m radius: all 671 POIs have eligible road candidates; 207 ms index + 294 ms matching. This does not verify service access, operation or continuation. Station association and split-edge access are the next integration work.
- Reported process memory is cumulative across sequential experiments and not per-search peak memory. This run reached roughly 680 MiB RSS; memory isolation and dense-region behaviour remain unqualified.

Evidence files: `rebuild-resource-probe-02.json` and `rebuild-resource-probe-02-stations.json` under the local candidate directory. Experiment weights are not accepted final Dirt/Balanced objectives.

## Verification

- 39 new focused tests passed before final report preparation.
- Expanded legal/pack checks: one existing fixture failure, `pack-manifest.v2 missing timezone`, reproduced unchanged on the untouched `atlantic-live-fuel` baseline. Do not conceal it as a green full suite or fix unrelated factory fixtures during this step.
- `npm run test:adventure` runs the replacement-core tests; they are also included in the default test command.
- These tests validate individual invariants and a search experiment. They do not mean the 23 full acceptance scenarios, live service or physical-device acceptance are complete.

## Architectural decision so far

Keep the replacement separate from the active engine. The resource-state experiment is promising for integrated fuel, and reusable reverse bounds deserve further comparison. Its additive positive costs do not solve global maximum dirt share, Balanced mix or meaningful variety. No final algorithm winner is declared.

GraphHopper's [custom-model documentation](https://github.com/graphhopper/graphhopper/blob/master/docs/core/custom-models.md) separates route preference from travel-time estimation. We apply that distinction; experimental search weights do not become displayed ETA speeds. This source does not validate DIRT's full adventure objective or the local prototype.

## Next work, in order

1. Integrate endpoint/station projections into exact directed road segments, carrying turn history and original geometry; verify matched pump access and onward departure rather than treating proximity as a refill.
2. Compare integrated fuel-state search with reusable multi-candidate search on identical requests, including a dense-region case and separate memory measurements.
3. Implement settled urban/rural/necessary-connector policy with evidence-based settlement classification; choose final profile candidate objectives against rider scenarios.
4. Add multi-primary-leg ownership, fuel-preserving edits, Loop generation and stable/varied route persistence; adapt the live API only once the replacement produces qualified results.
5. Run complete regression and DEV rider acceptance before replacing/removing the old orchestrator. App navigation/HUD and offline parity remain later stages.

No user decision is currently required to continue the engineering experiments. Unresolved policy choices remain in the specification and will be raised only with concrete route comparisons.

## Second implementation step — exact projected road positions

Added `projected-graph.js` and `route-geometry.js`, plus their regression tests and `bench/run-projected-probe.js`.

- Endpoint and station positions split an existing road edge in memory, retaining its original identity and distance. No connection is created between close or coincident but disconnected roads.
- Partial traversal preserves legal direction and node/via-way restrictions through every split piece. An interior projection cannot invent a U-turn; a genuine mapped junction or dead end retains its legal movements.
- Refilling at a supplied verified station binding does not clear direction or restriction history. Unverified station candidates cannot be supplied as a refill binding.
- Geometry is reconstructed from exact source polylines, in travel order, including curved and partial sections. Disconnected arcs or nonjoining geometry are rejected instead of drawing a straight connector.
- Snap distances are normalised against actual polyline length, avoiding rounding drift at endpoints. The search retains authoritative pack lengths for range accounting.
- Search results retain arrival turn state for subsequent-leg/escape integration.

The Southwest NS probe now uses the original requested coordinates, with eligible connected endpoint matching, and reconstructs the resulting full road geometry. Both directions matched their geometry endpoints exactly to the selected projections:

| Direction | Index/matching | Reverse bound | Search | Geometry | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Forward | 219 ms | 205 ms | 22 ms | 22 ms | 469 ms |
| Reverse | 206 ms | 163 ms | 17 ms | 21 ms | 407 ms |

Graph decoding occurs before this measured interval. These are single local observations, not latency percentiles or an equivalent full comparison with the live service. Forward: 422.66 km, 53.81% known dirt; reverse: 419.66 km, 53.16% known dirt. Urban avoidance and fuel are **not** applied, and the weight is still experimental. This is not a Dirt-quality acceptance result or a deployed route.

Evidence: `scripts/pack-fabric/routing/candidates/rebuild-projected-probe/{forward,reverse}.json`. Replay with the same `REBUILD_PACK_ROOT` and `npm run bench:projected-probe`.

52 replacement-core tests pass. Added cases cover same-edge endpoints, one-way reversal prevention, station refilling on an existing directed edge, no invented midpoint turnaround, coincident disconnected roads, full via-way restriction history, partial/curved geometry and actual endpoint projection.

Next integration boundary: the graph can now represent a verified station visit, but the current POI-to-road candidates do not themselves prove the station's physical entrance/exit. Preserve their offsets and alternatives as evidence; select/validate real road access before enabling those refills in rider-facing fuel plans. Multi-leg continuation, destination escape, urban classification and final candidate selection remain unfinished.

### Destination escape integration on supplied station access

Added `fuel-ride.js`. It preserves a low-cost road candidate for advisory display, then searches with fuel state and planned refills integrated into the search. This is not the old repeated pump-insertion/profile-reroute loop. Both phases share graph data, optional reverse bounds and the same work budget; this orchestration is still experimental and its duplicated road/fuel work needs comparison against the other planned search design.

At a candidate destination arrival, it verifies a legal road path to a station using the actual incoming turn state. Escape results are cached by that state. The fuel search rejects an arrival that cannot support this exit, permitting an upstream refill/alternative arrival instead. A destination that is a supplied station explicitly receives a planned refill; arrival range and post-refill departure range are separate.

If no feasible chain is found in the supplied matched graph, or its work budget expires, the complete advisory road route remains available. The result does not claim the region has no fuel. Unknown initial fuel remains explicit. These capabilities are tested on constructed legal graphs with supplied station associations; real-world station access proof and full multi-primary-leg integration are still pending.

58 replacement-core tests now pass, with eight existing V4 snap/pack checks also exercised in the final focused run. The known unrelated legacy timezone-fixture failure is unchanged. No live or physical-device qualification is claimed.

## Third implementation step — urban exposure separate from ride cost

Added `urban-exposure.js` and extended the experimental resource search with a
lexicographic objective: minimize metres inside supplied urban areas first,
then the existing experimental positive ride cost. This is not an arbitrary
finite city penalty that a sufficiently cheap shortcut can overcome. Fuel
feasibility still participates in label dominance: a rural arrival without
enough fuel cannot erase a necessary urban fuel alternative. Required urban
passage remains traversable, without restarting search or prompting the rider.
An interrupted search remains incomplete; it does not prove urban necessity.

Urban exposure uses complete source polylines, including exact partial-edge
positions. Roads whose endpoints are outside but whose geometry crosses a core
are detected. Overlapping Halifax/Dartmouth boxes count each metre once.
Curved roads that actually skirt the box are not charged for their endpoint
chord. Existing mapped major-core boxes are used explicitly; the 57 NS
settlement records are **not** silently converted into exclusions. They include
rural towns that the rider welcomes. Larger-town classification and suitable
berths still require review; the result carries `classificationComplete:false`.

The first full geometry scan exhausted the existing 6-million-operation shared
budget. Reusing the road index already built for matching reduced detailed
urban examination to 43,873 of 220,770 NS edges. The final runs used the original
budget without increasing it. This is reusable geometry work, not an extra
profile-dependent settlement scan.

Single local replay results, decoding excluded, fuel not requested:

| Case | Total | Urban indexing | Known dirt | Urban metres |
| --- | ---: | ---: | ---: | ---: |
| Southwest NS forward | 593 ms | 97 ms | 49.57% | 0 |
| Southwest NS reverse | 719 ms | 98 ms | 49.69% | 0 |
| Halifax rider anchor → Porters Lake | 741 ms | 96 ms | 12.56% | 11,519 |
| Porters Lake → Halifax rider anchor | 1,222 ms | 98 ms | 11.88% | 11,313 |

The urban-anchor runs demonstrate automatic urban entry/exit, **not** acceptable
ride quality. They produce approximately 143 km rides with little known dirt.
Strictly minimizing every metre of unavoidable urban passage before considering
ride character may be too aggressive around a rider's urban anchor. This is a
concrete comparison to address in candidate selection; do not adopt it as final
product tuning. The southwest runs also show the experimental additive weights
are not yet meeting the Dirt objective. Neither speed nor the presence of a
complete road route constitutes quality acceptance.

Evidence in `routing/candidates/rebuild-urban-probe/` and
`routing/candidates/rebuild-urban-anchor-probe/`. Replay the existing projected
probe with `REBUILD_URBAN=1`; add `REBUILD_PROBE_CASE=urban-anchor` for the second
case, with an explicit `REBUILD_PROBE_OUTPUT` to preserve prior results.

73 replacement tests and eight existing V4 snap/pack checks pass. New regressions
cover rural detours versus urban shortcuts, necessary urban passage, urban fuel
needed for onward continuation, preferred rural pumps, exact geometry exposure,
index/full-scan agreement, budget interruption and lower-bound compatibility.

Real station entrance/exit association remains unfinished: no proximity match
has been promoted to a verified physical refill. This step improves orchestration
with supplied station bindings only. Final profile candidate objectives, wider
settlement classification, multi-leg/Loop integration and live qualification
remain open. No deployment or pack mutation was performed.

## Fourth step — repeated real-map tests and independent search verification

Added `bench/run-rebuild-matrix.js` (`npm run bench:rebuild-matrix`). Three fresh
processes per case each search forward and reverse, using the same sealed NS/NB
pack root, urban exposure enabled, and unchanged 15-second / 6-million-operation
budgets. All 18 requests completed and all six directional requests reproduced
the same exact edge/fraction geometry across their three runs.

| Request | Minimum | Median of 3 | Maximum |
| --- | ---: | ---: | ---: |
| Southwest NS forward | 637 ms | 663 ms | 687 ms |
| Southwest NS reverse | 817 ms | 846 ms | 861 ms |
| Halifax → Porters Lake | 815 ms | 853 ms | 855 ms |
| Porters Lake → Halifax | 1,308 ms | 1,326 ms | 1,504 ms |
| Moncton → Shediac | 345 ms | 357 ms | 361 ms |
| Shediac → Moncton | 322 ms | 326 ms | 326 ms |

These timings include rebuilding matching and urban indexes, but exclude pack
loading and physical fuel-access integration. OS file caches were not cleared.
Three samples are not service latency percentiles. Process high-water RSS ranged
from 159 to 354 MiB across the groups; reverse runs share a process with forward
runs, so these are not isolated per-search memory measurements. Dense Quebec/
Ontario behaviour and service concurrency remain untested.

**Coverage finding:** this NB V4 pack has no embedded urban cores or settlement
records. Its roughly 25 km Moncton/Shediac routes are paved and are not evidence
of either urban avoidance or acceptable Dirt quality. The explicit incomplete
classification diagnostics caught this omission. Do not silently treat zero
recorded urban metres as proof that a route avoids cities. No pack bytes were
changed. NS route-quality concerns from the prior step persist unchanged.

Added an independent exhaustive finite-state oracle test over 250 reproducible
generated directed networks. It enumerates exact incoming-edge and fuel states
without the engine's Pareto pruning, heap or reverse heuristic. Each network is
compared with both plain and accelerated search: 500 result comparisons covering
fuel shortages, refill opportunities, turn restrictions, urban exposure and
destination escape reserves. Feasibility and the ordered objective agree in all
cases. Successful returned routes are also replayed for legal turns and fuel
consumption. These constructed tests do not verify real-world station access.

74 replacement tests plus eight existing V4 snap/pack checks pass (82 total).
The matrix's success exit is a road-completion/repeatability gate, not a profile,
urban-data, fuel or release-acceptance gate. It reports urban data coverage
separately. Evidence: `routing/candidates/rebuild-test-matrix/summary.json` with
individual geometry artifacts, pack hashes and process logs. Run the matrix with
an explicit `REBUILD_PACK_ROOT`; optional `REBUILD_MATRIX_OUTPUT` preserves
separate experiment sets. No runtime policy tuning, deployment or device change
was made during this testing step.

## Fifth step — Quebec scale and explicit failure reporting

Added the `qc-urban-anchor` projected probe (Montreal coordinate to an eastern
Quebec coordinate). The supplied sealed QC graph contains 1,203,111 nodes and
1,469,141 edges. Both directional attempts exhausted the unchanged 6-million
work budget during road-index construction, before route search. Times to this
incomplete result were 444 and 441 ms; those are **not route-return timings**.
Pack loading took 113 ms. Evidence: `routing/candidates/rebuild-qc-probe/`.

A separate diagnostic raised only the benchmark's work allowance to 50 million,
retaining its 15-second deadline. It passed indexing but stopped while creating
the graph, after 11,221,987 operations and 857/845 ms respectively. This is not a
passing enlarged-budget route. Peak process RSS was about 368 MiB across those
two failed attempts; later search memory remains unmeasured. The default work
allowance is unchanged. Evidence: `routing/candidates/rebuild-qc-diagnostic/`.

The restriction audit found one ambiguous entry among 16,474 QC restrictions:
OSM relation `7111448` resolves both `fromEdge` and the first `viaEdges` entry to
edge `318695` (endpoints `1113889` and `164`), with `toEdge:547118`. The adapter
cannot determine its directed entry from that representation and intentionally
rejects it. No claim is made yet that the original OSM relation is wrong; source
resolution versus adapter interpretation needs investigation. No restriction
was dropped, no permissions relaxed, and no factory bytes changed.

Added a regression preserving this failure and returning the exact relation,
edge and shared-node identifiers in structured diagnostics. The benchmark now
writes stage-specific artifacts for interrupted or failed preparation, exits
nonzero for incomplete routes, and supports an explicit diagnostic-only
`REBUILD_MAX_WORK` override. Matrix parsing handles these artifacts without
mistaking them for complete routes or crashing on absent geometry.

Verification: 75 replacement tests plus eight existing V4 snap/pack checks pass
(83 total). A forced-interruption matrix (`REBUILD_MAX_WORK=1`, separate output
`rebuild-forced-interruption`) exercised all 18 attempts: all reported incomplete
preparation, zero completed routes, and the matrix correctly exited nonzero.
This is a test of honest failure reporting, not 18 new successful rides.

Next: separate reusable graph preparation from per-request work without hiding
its time/memory cost; investigate the exact QC restriction against source and
packed representation. The existing city-anchor ride-quality concern, missing
NB urban definitions and real fuel-access qualification remain open. No service
or device deployment occurred.

## Sixth step — reusable preparation, unchanged routes, upstream restriction evidence

Added `adventure/preparation-cache.js`. It retains only completed spatial/urban
indexes and requires the same graph instance, geometry instance, immutable byte
revision identity and urban bounds. Default capacity is one prepared graph;
completed new entries evict old references, and explicit unloading clears them.
Interrupted builds cannot become cache hits or evict the working entry. Cached
work cannot override cancellation. Route-specific endpoints, style costs, fuel
state, turn history and reverse bounds are not cached. This is a bounded entry
count, not a verified byte-memory limit or a deployed service cache.

The benchmark enables this with `REBUILD_PREPARED=1`. Cold request preparation
still consumes its existing shared budget. An explicit optional
`REBUILD_PREWARM_WORK` prepares before requests and records that separate time,
work and memory in `preparation.json`; it must not conceal cold-start cost.
Production lifecycle/concurrency and shared asynchronous preparation remain
unfinished. No request deadline or default work limit was raised.

Three-process NS/NB matrix, 18 complete routes:

| Directional request | Median with reusable preparation | Earlier median without reuse |
| --- | ---: | ---: |
| Southwest NS forward (cold preparation) | 583 ms | 663 ms |
| Southwest NS reverse (reused preparation) | 428 ms | 846 ms |
| Halifax → Porters Lake (cold preparation) | 775 ms | 853 ms |
| Porters Lake → Halifax (reused preparation) | 836 ms | 1,326 ms |
| Moncton → Shediac (cold preparation) | 299 ms | 357 ms |
| Shediac → Moncton (reused preparation) | 186 ms | 326 ms |

All 18 exact edge/fraction fingerprints match the earlier matrix, and all nine
reverse requests report a preparation cache hit. Changes in cold-run timing are
not attributed to caching; these are separate local batches, not controlled
service percentiles. Timings exclude pack loading and physical fuel integration.
Peak process RSS across groups reached 363 MiB. Existing urban-data and ride-
quality limitations are unchanged. Evidence: `rebuild-prepared-matrix/`.

QC explicit prewarming completed in 808 ms with 11,221,354 operations, using a
separate 50-million diagnostic allowance. Its normal 6-million-budget requests
then used only 633 operations before the same restriction error, in 77/36 ms.
These are **failure timings**, not successful Quebec routes. Preparation is
reusable; first-use preparation under the original 6-million allowance remains
insufficient. Later QC bounds/search time and memory still cannot be measured.
Evidence: `rebuild-prepared-qc/`, including separate preparation accounting.

### Quebec restriction source check

The [current OSM source relation](https://api.openstreetmap.org/api/0.6/relation/7111448.json),
retrieved in this step, is version 2, timestamp `2025-08-17T13:26:18Z`. It declares:

- `restriction=only_straight_on`;
- from way `111771059`;
- via way `111771059` (the same way);
- to way `465413249`.

The repeated approach/via identity exists in the upstream record; it is not
solely introduced by assigning packed edge indices. This does **not** establish
a safe interpretation, absolve all source-resolution issues, or justify dropping
it. The source snapshot is preserved in the QC evidence directory. The original
reader rejection remains; factory/source investigation can proceed independently
without changing sealed packs during these experiments.

80 replacement tests plus eight existing V4 snap/pack checks pass (88 total),
including five new cache invalidation, eviction, interruption and cancellation
regressions. No live API, pack or phone change was made.

## Seventh step — quick boundary checks; Quebec investigation parked

Owner explicitly asked to park the restriction investigation and pursue smaller
checks. No further Quebec source/pack investigation was performed this step.

Added nine focused boundary tests. Four initially failed, exposing two issues:

1. Final fuel proof already tolerated one micrometre of floating-point distance
   rounding, but road search and destination escape used strict comparisons.
   Decimal segments could therefore be verified by proof but rejected by search.
   `fuel-math.js` now supplies the existing tolerance consistently across those
   phases, and subtraction clamps rounding-only negatives to zero. A genuine
   one-millimetre shortfall remains rejected. Rider reserve settings are unchanged.
2. A cancelled request could return `exhausted` when reverse bounds skipped an
   unreachable start, or cancellation occurred at the final outgoing-road check.
   Search now checks cancellation/deadline both before starting and before
   declaring exhaustion. It returns incomplete/cancelled instead of no path.

Other checks passed without policy changes: zero usable fuel permits a refill
only when already at a supplied station; candidate ordering cannot alter the
Dirt/Balanced/Clean choice or mutate its pool; changing a primary-leg input does
not mutate prior normalized legs or fixed anchors; all eight Loop directions and
both target kinds preserve first-fuel and unknown-starting-fuel intent through
JSON serialization. These are core input/storage-shape checks, **not** app save/
reopen, Loop generation, navigation or physical station acceptance.

Final verification: 89 replacement tests plus eight existing V4 snap/pack checks
pass (97 total), including the independent 250-network / 500-comparison fuel
oracle. No new speed claims are made from this correctness round. The restriction,
city-anchor ride quality, missing urban definitions and physical fuel-access
qualification remain open. No deployment, pack mutation or phone change.

## Eighth step — fuel-stop and waypoint handoff checks

Added ten focused tests in `adventure/fuel-stops.test.js`. Two initial failures
identified the same reporting inconsistency: final fuel proof called the
post-refill amount `arrivalUsableMeters` when the destination was a fuel stop.
The route search already distinguished arrival and departure correctly.

Final proof now captures the destination arrival before its planned refill and
returns separate `arrivalUsableMeters` and `departureUsableMeters`. Escape proof
uses the planned departure amount. The distinction remains explicit when escape
is unproved or exceeds usable range, including a zero-distance station endpoint.
This changes reporting, not route geometry, station selection or reserve policy.

Passing tests also cover a necessary generated pump shortly before a fixed fuel
destination (both planned refills retained); fuel carried through an ordinary
waypoint; a fixed station waypoint providing a full planned tank to the following
search; a station marker without a planned refill not resetting proof; explicit
refill at a zero-distance full-tank destination; and incoming turn history carried
through a waypoint into a separate search.

These are constructed-graph tests with explicit supplied station bindings.
Manually carrying state between two searches is not a completed multi-primary-leg
planner or a proof that future-leg feasibility back-propagates to earlier choices.
Neither passing a map marker in these proofs nor a planned refill confirms that
a navigating rider physically obtained fuel.

Final verification: 99 replacement tests plus eight existing V4 snap/pack checks
pass (107 total). The independent fuel-search oracle remains green. Quebec
restriction investigation stayed parked. Real station access, full multi-leg/
Loop orchestration, ride quality, app navigation and live/device acceptance
remain unfinished. No deployment or pack changes were made.

## Ninth step — invalid inputs and incomplete-result behavior

Added twelve tests in `adventure/input-outcomes.test.js`. Five initial test groups
exposed input-boundary gaps: sparse waypoint/leg arrays could omit entries;
station objects could become invented string IDs; generation objects could stay
mutable inside an otherwise frozen request; falsy malformed fuel settings could
be treated as no request; nonfinite initial fuel could be treated as merely
unknown; and summed distances could overflow into nonfinite reports.

Request normalization now rejects missing records and malformed identities/fuel
settings, retaining valid string or numeric station IDs and fixed coordinates.
Shared `validateFuel` supplies consistent validation to search, single-leg fuel
orchestration, candidate selection and final proof. Only absent/null initial fuel
means unknown. Invalid settings are rejected before search work starts, including
when no candidates are available. Surface summaries and proof reject aggregate
distance overflow as invalid data. These are internal typed errors; API/UI error
translation remains part of the still-unimplemented replacement adapter.

Incomplete-result tests passed without selection-policy changes: partially
assessed pools keep a completed road candidate while marking search incomplete;
interrupted fuel proof retains that road with fuel unverified; empty/unproved
pools do not claim geographic disconnection; cancellation selects no unexamined
candidate. This does not establish geographic fuel gaps or validate real POIs.

Final verification: 111 replacement tests plus eight existing V4 snap/pack checks
pass (119 total), including the 500 independent search/oracle comparisons. No
performance claim or full-app qualification follows from this correctness round.
Quebec remains parked. Pack bytes, service deployment and phone state are
unchanged. All original integration and rider-acceptance gaps remain tracked.

## Tenth step — batched From Here integration milestone

The individual core pieces now run through `adventure/from-here.js` against real
NS roads and the canonical 671-record station file. See
[the integration checkpoint](ROUTING-FROM-HERE-INTEGRATION.md) for the full results,
qualification boundaries and exact replay artifacts.

Three six-case runs produced 18 complete road results with the expected fuel
states and stable geometry/stops. Standard long ride median: 959 ms with one
planned refill; shorter tank range: 629 ms with three; removed original station
record: 633 ms with two alternative stops. Empty data and unknown initial fuel
retain roads with unverified fuel. The failed empty-data experiment (18 seconds,
~1.2 GiB) is preserved; the final empty-data case returned in 233 ms median. Final
batch process RSS peaked at 382 MiB. Timings exclude loading; no live-service
percentiles or concurrency qualification are claimed.

New search behavior uses fewer refills only after equal urban exposure and equal
experimental road cost, preserving early refills when needed. The independent
250-network oracle also verifies this third objective. A supplied-station count
of zero skips futile fuel search, and the integrated experiment caps admitted fuel
labels at 100,000 with explicit incomplete results and retained advisory geometry.
The road candidate is materialized before fuel work can consume the remaining
budget. Pack/projection restrictions and fixed anchors remain intact.

The graph and proof accept road-only station associations only through explicit
experimental opt-in. Evidence survives visits, fixed-destination refills and
escape; provisional access cannot produce a verified fuel result. Coincident road
matches remain alternatives, not asserted duplicate facilities. These changes
allow honest integration testing without fabricating station entrance proof.

A separate stronger preference experiment improved the long ride from 49.6% to
60.6% known dirt (596.8 km, three stops). Audited routes had zero repeated road
intervals/revisited graph nodes. Nearby Dirt quality remains poor. Preference
weights, coherent candidate selection and station access are still unqualified;
this is not a completed production routing replacement.

135 focused checks pass (127 replacement plus eight existing V4 snap/pack checks).
No service, pack or device changes; Quebec remains parked. The build plan's
immediate execution section now reflects this milestone rather than the obsolete
instruction to start the baseline.


## Large-region diagnostic batch — September 8, 2026

Owner explicitly requested a separate Quebec agent. Its bounded read-only audit
covered Quebec, Ontario and California. See ROUTING-LARGE-GRAPH-AUDIT.md for
measurements, source-history evidence and the pack-agent handoff. Cold preparation
exceeds the current request work allowance in all three regions; Ontario also
exceeds it during per-destination reverse bounds after preparation reuse.
California reached 1,071 MiB process peak before route search. These are single
process diagnostics, not successful rider-route benchmarks.

Quebec's ambiguous source relation remains enforced. California has different
ambiguities requiring independent resolution. No blanket restriction workaround,
pack rebuild or deployment was made. The next scale implementation priority is
bounded revision-owned preparation, then compact/reusable reverse topology.

In parallel, inspected current OSM around the selected Mahone Bay Irving
(node 5296522350). The downloaded bbox includes the station marker and matched
Edgewater Street way 1528881625, but no returned way contains the station node.
This does not prove physical inaccessibility: a standalone POI is normal map
data. It does mean that snapping it to the street still cannot certify a mapped
entrance/exit. Retain provisional station evidence; do not invent a connector.
Snapshot: routing/candidates/rebuild-station-access-audit/mahone-bay.osm; source:
https://api.openstreetmap.org/api/0.6/map?bbox=-64.382,44.448,-64.379,44.452
Current source is diagnostic evidence, not an assertion of pack-snapshot identity.
No Dirt cost settings were changed in this batch.

Verification: all 135 focused replacement/pack tests passed again. The new audit
script passes syntax checking. No runtime behavior or Android counterpart changed;
existing deferred parity requirements remain.

## Compact reverse preparation — September 8, 2026

Replaced temporary per-node arrays/per-arc objects in reverse-bound construction
with chunked typed storage. The default 256 MiB storage cap covers heads and
allocated arc chunks; exhaustion returns `reverse_storage_limit` as incomplete,
not geographic no-path. This cap does not cover pack/index residency, forward
labels, the bounds heap or total process RSS. No search corridor was introduced.

`prepareReverseCosts` now exposes caller-owned target-independent preparation.
Reuse requires the same immutable graph, node count and cost-function identity.
No global cache was added. From Here automatically uses compact storage but still
prepares it per request: its projected graph changes with station/anchor positions.
Cross-request reuse needs that graph lifecycle designed explicitly; benchmark
reuse must not be represented as already integrated into From Here.

Fresh-process Ontario comparison, same candidate03 bytes, three identical targets:

| Measurement | Previous objects | Compact/reused |
| --- | ---: | ---: |
| Process peak RSS | 722 MiB | 384 MiB |
| Separate reverse preparation | Included per target | 409 ms / 52.9 MiB storage |
| Large target 753966 | 1,490 ms | 406 ms after preparation |
| Small reachable component target 293902 | 859 ms | 1 ms after preparation |
| Large target 587 | 1,468 ms | 407 ms after preparation |

All three complete distance-array hashes match. The large target uses 4.23 M
operations after reusable preparation, versus 8.85 M combined before. Cold compact
preparation plus bounds still uses 8.85 M; this change does not make cold Ontario
fit the six-million request allowance. Each implementation ran in a separate
process, with explicit GC between targets, no cleared OS cache, no spatial index,
no fuel search. These are single-run diagnostics, not end-to-end route timings.
Replay: bench/run-reverse-cost-audit.js; evidence: routing/candidates/rebuild-reverse-costs/.

The full NS six-case matrix ran three times: all 18 expected outcomes pass and
all route/stop fingerprints match the preceding implementation. Normal long-route
median 872 ms; short-range 559 ms; nearby 409 ms; station-removed 569 ms; empty
catalog 178 ms; unknown initial fuel 445 ms. Pack loading excluded. Batch maximum
RSS 320 MiB versus previous 382 MiB. Station access remains provisional and Dirt
quality remains unchanged. Evidence: routing/candidates/rebuild-compact-reverse-matrix/.

138 focused checks pass, including the independent fuel/turn/cost oracle and new
cross-chunk reuse, storage cap, cancellation and stale-identity checks. No pack,
restriction, live API or phone change. Next: integrate bounded revision-owned
preparation before claiming large-region request readiness; resolve source turn
ambiguities independently and continue station access / Dirt candidate work.

## Exact projected preparation reuse — September 8, 2026

From Here now accepts a caller-owned reverse-cost cache, with one entry and a
64 MiB cap on typed reverse storage. The previous entry is released before its
replacement is built. Reuse requires the same pack instance, explicit immutable
revision, cost-function identity and exact ordered projected topology, including
endpoint permissions and unknown-road policy. Each request still builds its own
turn-state graph and fuel plan: the cache does not retain request graph state.
The caller must treat pack/cost inputs as immutable and must not retain old cache
results if it relies on the cache's residency bound. This is not a total RSS cap.

The probe now holds stable cost/preparation objects so the short-tank case can
reuse the preceding route's reverse preparation. All 18 NS matrix cases pass;
all geometry/stop fingerprints match the prior implementation. Medians: normal
886 ms, short tank 505 ms, nearby 427 ms, station removed 589 ms, no stations
173 ms, initial fuel unknown 441 ms. Maximum batch RSS 307 MiB. Three samples,
pack loading excluded, no cleared OS cache; these are not service percentiles.
Evidence: routing/candidates/rebuild-reverse-cache-matrix/.

A new integrated Ontario probe used candidate03, all 5,369 canonical stations,
start (45.055,-77.855), destination (45.13,-77.83), explicit 300 km full range /
270 km initial usable fuel, and the experimental Dirt weight 10. Spatial/urban
preparation was explicitly prewarmed with 50 M work: 951 ms / 12.14 M operations.
The first normal 6 M request remained incomplete during reverse bounds after
4,809 ms; its completed reverse preparation was retained. The next two requests
completed at 4,265 and 4,758 ms, each using 4.405 M operations and reporting a
reverse cache hit. Both returned the same 16.28 km road, 71.1% known dirt and a
provisional destination-fuel escape. No refill was needed on this short ride;
this does not qualify long-distance Ontario fueling.

Station matching dominated at 3.75–3.86 seconds per request. Process peak rose to
821 MiB across the three attempts, including full station diagnostics and no
explicit GC. This measurement is not comparable to the earlier reverse-only
benchmark as a memory regression: it includes the spatial index, all station
matching and full route pipeline. It is nevertheless an unresolved service
memory concern. The probe exits nonzero because its first attempt is incomplete;
that failure is preserved, not relabeled as success. Evidence:
routing/candidates/rebuild-on-integrated-cache/.

141 focused checks pass. New integration coverage exercises reuse, station
removal, moved pins, changed revision/cost/unknown-road settings, cancellation,
and capacity exhaustion. Next priority is bounded reuse of completed station
matching and an explicit cold-preparation lifecycle. No Quebec/California
restriction workaround, pack change, deployment or native change was made.

## Reuse canonical station matching — September 8, 2026

From Here now accepts a caller-owned station-match cache. One completed result
can be retained for at most 10,000 source records (at most 120,000 candidate
records). This is a record-count bound, not a heap-byte bound. Larger catalogs
still match fully without caching; no station is silently dropped. Cached
projection evidence is deeply frozen before reuse. Partial matching, interrupted
publication and cancelled reads never become a cached success.

Reuse requires identical pack/geometry instances, explicit immutable revision,
radius, unknown-road policy and ordered station IDs/coordinates. Removing,
relocating or reordering station records invalidates it. Current station names
and metadata remain outside the cached evidence, so a metadata update is visible
in the new fuel plan. Every request still performs its own fuel/turn search.
The shared deadline includes key comparison and evidence publication work.

144 focused checks pass. New tests cover evidence mutation, station deletion,
relocation, reordering, metadata refresh, source/policy/radius changes, capacity
bypass and cancellation/incomplete publication. All 18 NS matrix cases pass with
geometry/stop fingerprints identical to the preceding implementation. Medians:
normal 879 ms, short tank 226 ms, nearby 156 ms, station removed 574 ms, empty
catalog 172 ms, unknown initial fuel 447 ms. Maximum batch RSS 316 MiB. Evidence:
routing/candidates/rebuild-station-cache-matrix/. Three samples; pack loading
excluded, no cleared OS cache, not service percentiles.

Ontario used the same candidate03 bytes, two fixed pins, all 5,369 stations and
explicit fuel assumptions as the previous probe. Spatial preparation separately
prewarmed in 1,010 ms / 12.14 M operations. First normal request still failed at
6 M work during reverse bounds (4,873 ms); retained completed preparation then
allowed the two warm requests to finish in 563 and 500 ms. Station matching took
12 and 8 ms instead of 3.75–3.86 seconds. Both route geometries exactly match the
previous 16.28 km test and retain provisional destination escape. No refills are
needed on this short ride; long-distance Ontario fueling remains unqualified.
Process peak RSS was still 804 MiB. Evidence: rebuild-on-station-cache/.

A separate eight-attempt residency diagnostic explicitly invoked GC after each
attempt; this is measurement only, not a production fix. The first attempt still
failed; all seven warm routes completed with unchanged geometry and fuel escape.
After GC, heap use stayed about 74 MiB and array-buffer use 269 MiB; RSS settled
around 649–650 MiB across attempts 3–8. There was no growing retained heap in this
small sample, but residency remains high and concurrency is unqualified. Warm
request times in this separate run were 518–831 ms; forced collection changes
runtime behavior, so do not merge those timings with the ordinary probe. Evidence:
rebuild-on-station-residency/. Both Ontario probe processes intentionally exit
nonzero because the cold attempt remains incomplete.

Next: address cold preparation as an explicit lifecycle and whole-region bounds
work for new pins, then qualify longer Ontario routes. Reusing identical pins
must not be advertised as eliminating new-destination preparation. No pack,
restriction, live API or native changes; provisional station access and unfinished
Dirt candidate quality remain outstanding.

## First-attempt Ontario builds and new destinations — September 8, 2026

Reverse guidance can now stop when the request start is settled. If its settled
cost is L, every remaining distance is at least L, so the returned heuristic is
min(exact relaxed distance, L). Unreachable-but-unexplored nodes receive L, not
Infinity. This preserves admissibility/consistency without excluding roads or
limiting ride length. The forward fuel/turn search is unchanged. Saturation checks
the shared budget every 4,096 array entries. Results distinguish capped guidance
from exact full-graph guidance; an unreachable start still requires exhaustion.
The independent 250-network oracle now compares plain, exact-guided and capped-
guided searches: 750 comparisons, including urban priority, fuel and turn rules.

From Here accepts an explicit preparation work budget, defaulting to its existing
shared budget. When provided, its deadline may not exceed the request deadline.
Cold regional index work is reported separately in provenance and included in
request wall time. No hidden clock reset or automatic unbounded allowance was
introduced. The Ontario experiment explicitly uses 20 M preparation work and
6 M route work under the same 20-second deadline; default callers retain their
existing allowance. This is phase accounting, not a claim that cold work vanished.

Five Ontario requests ran with separately prewarmed indexing, then the same five
ran in a fresh process without prewarming using the explicit preparation budget.
Both batches completed. In the latter batch the first request included 907 ms /
12.14 M regional preparation operations and finished in 5,683 ms. Its remaining
request work was 4.89 M, within the unchanged 6 M route allowance. Pack decoding
is excluded, but all preparation, station matching, routing, geometry and fuel
proof are included. Subsequent cases changed the destination pin, invalidating
reverse topology each time; they are not identical-request cache hits.

| Ontario case from Bancroft area | Distance | Refills | Total time | Route work |
| --- | ---: | ---: | ---: | ---: |
| Nearby, cold | 16.28 km | 0 | 5,683 ms | 4.89 M |
| New nearby pin | 21.18 km | 0 | 932 ms | 4.68 M |
| Pembroke, 120 km full range | 180.39 km | 1 | 997 ms | 4.75 M |
| Mattawa, 180 km full range | 424.39 km | 4 | 1,114 ms | 5.40 M |
| North Bay, 180 km full range | 364.45 km | 2 | 964 ms | 5.29 M |

All use a 10% protected reserve and explicitly supplied full starting tank; that
assumption is not a new product default. Independent arithmetic checked every
refill interval and destination escape. Both batches' road geometries and planned
stops match. North Bay retains 16.93 km usable range above reserve with a matched
onward station 0.84 km away by road. Access evidence remains provisional. Surface
unknowns remain reported separately, never counted as dirt. The longer routes
have 57–73% known dirt; this is not final Dirt-quality acceptance.

Evidence: routing/candidates/rebuild-on-capped/ and rebuild-on-cold-lifecycle/
(including validation.json). Reusable input fixture:
bench/fixtures/ontario-from-here.json. Probe flags: REBUILD_REGION=on,
REBUILD_START='{"lat":45.055,"lon":-77.855}', REBUILD_PREPARATION_WORK=20000000,
REBUILD_CASES_FILE=scripts/pack-fabric/bench/fixtures/ontario-from-here.json.
Use candidate03 REBUILD_PACK_ROOT; omit REBUILD_PREWARM for the cold measurement.
These are single-run engineering measurements, not service percentiles.
Peak process RSS in the integrated cold batch was 652 MiB; concurrency remains
unqualified and the regional index/reverse topology still dominate residency.

146 focused checks pass. The 18-case NS matrix also passes with unchanged route/
stop fingerprints. Medians: normal 907 ms, short tank 237 ms, nearby 102 ms,
station removed 586 ms, empty 157 ms, initial unknown 429 ms; peak RSS 314 MiB.
Evidence: rebuild-capped-matrix/. Overall this batch exercised 28 real-map
requests, including 10 Ontario requests and six longer Ontario fuel plans.
No pack, source restriction, deployment or native changes. Next priority is
station entrance/exit qualification and broader route-quality integration; Quebec
and California restriction resolution remains independently outstanding.

## Fuel access and ride-shape diagnostics — September 8, 2026

Inspected current OSM neighborhoods for all five unique fuel stations selected
by the longer Ontario fixtures. Three are represented by fuel-tagged buildings,
two by standalone markers; none of those records alone proves station entry,
forecourt travel and exit. Access remains provisional. This is a source-evidence
limitation, not proof of closure or geographic fuel scarcity. Concrete findings
and the required source-linked access contract are in
ROUTING-STATION-ACCESS-HANDOFF.md. Raw snapshots remain local read-only evidence.

Added `auditRideShape` to complete From Here results as diagnostics only. It
measures overlap of actual source-edge intervals, revisited graph nodes and
continuous known-dirt runs. Adjacent split pieces are not retracing; repeated
third traversals count only their actual overlap with the prior interval union.
Unknown surface breaks a known-dirt run. Diagnostic bins below 250 m / 1 km do
not create new routing thresholds or rejection rules. Interrupted audits report
incomplete, never partial metrics as a complete audit.

| Saved ride | Repeated road | Revisited nodes | Dirt runs under 1 km |
| --- | ---: | ---: | ---: |
| Pembroke | 924 m | 4 | 4 of 25 |
| Mattawa | 5,504 m | 9 | 13 of 48 |
| North Bay | 0 m | 0 | 15 of 41 |
| Southwest NS | 0 m | 0 | 22 of 42 |
| Nearby NS | 0 m | 0 | 8 of 8 |

Every revisit interval in the two retracing Ontario cases contains a planned
fuel stop. The largest enclosed spans are 1.848 km for the Killaloe fuel stop
and 11.008 km for the Rutherglen Esso. This supports fuel-spur context rather
than a dirt-percentage farming loop; it does not prove those stops or spurs are
the best available choices. A blanket retrace rejection would conflict with the
accepted fuel/waypoint access rule. Short dirt runs alone do not prove a needless
diversion either: they need comparison against a coherent alternative.

151 focused checks pass, including partial-edge overlap, repeat traversals,
continuous surface runs, cancellation and From Here audit integration. All 18
NS matrix cases pass with unchanged route/stop fingerprints. Timings remain
comparable: normal 878 ms, short tank 230 ms, nearby 101 ms, removed station
580 ms. Evidence: rebuild-quality-audit-matrix/. Audit evidence:
rebuild-on-access/ride-quality.json. Replay saved rides with
bench/audit-built-rides.js; this audit does not rebuild routes.

No access evidence was upgraded to verified, no scoring weights changed, and
nothing deployed. Next routing priority is coherent alternative generation and
comparison using these diagnostics, while pack/access evidence work addresses
station associations. A successful fuel arithmetic test is still not complete
station-access or rider-quality acceptance.

## Device-test canary integration — September 8, 2026

Owner approved continued work without batch permission until a physical-device
test is available, and requested Impeccable for UI changes. The current app can
already consume combined fuel-chain routes. This first canary therefore uses
existing From Here pins, profile and fuel controls; Loop, exploration controls,
per-fuel-leg overrides and navigation fuel-confirmation UI remain future work.
Impeccable was loaded for UI review; no UI replacement or native edit was made.

Added a shared three-candidate pool (paved, Dirt weight10, Dirt weight30), each
with integrated fuel search. Surface selection uses the same feasible pool for
Dirt/Balanced/Clean, preserving urban exposure priority. A common experimental
motorway factor8 favors backroads while permitting connectors. These are bounded
candidate generators, not global optimum claims or final tuning. Known surface
and unknown access remain separate in the app-compatible response.

The opt-in `DIRT_ADVENTURE_CANARY=ns-v1` adapter only handles two-pin single-region
NS requests on accepted candidate02. It preserves the existing service contract
and partitions the already-built road at fuel visits into app-consumable route
hops. It does not re-route each hop. API usable/initial fuel values are already
reserve-adjusted by the client; the adapter preserves them without subtracting
reserve twice. The adapter retains `provisional_station_access` and a DEV warning;
these tests concern route review, not physical fuel-station/navigation acceptance.

Required fuel replacements, mandatory stops, arrival-edge/recovery history,
impassable-edge exclusions, path caps, motorway prohibition, cross-region and
other unsupported cases stay on the existing engine. Station exclusions are
honored by filtering the canonical source before matching. Responses carry the
replacement engine identity only when it actually ran. Generated window prefixes
honor the requested maximum stops. Stable DEV and pack activation remain owned
in coordination with the pack-refinement task; isolated preview first.

Local real NS API-compatible calls all completed: Dirt597.35km/60.58%known dirt/
3stops in1.30s; Balanced500.74km/51.77%known dirt/2stops in0.74s;
Clean351.17km/98.51%known paved/1stop in0.68s. Pack loading excluded, three different
profile requests in one process. All candidates had zero measured embedded-major-
core exposure in this fixture. Unknown surface remains explicitly reported.
Evidence: routing/candidates/rebuild-live-canary/. 154 focused checks pass,
including candidate sharing and app-compatible fuel-hop partitioning.

## Verified live preview — September 8, 2026

Preview READY: https://pack-fabric-42ltrerz7-goricksmith-7678s-projects.vercel.app
Deployment dpl_6vK7hFKuwQbAs6HF6BYSMdrfFE2b; exact deployed source
 ecf746ef8497df49c996c0853fe84743de331f7f. Framework: Vercel Node functions;
reported build-output creation1s. Accepted02 five-region configuration and rider
services were explicitly preserved; connection revision empty; canary NS-only.
No national03 or production change. Local later commits may contain evidence
scripts/docs only; the deployment identity above identifies runtime bytes.

Actual app-compatible preview POSTs passed Dirt/Balanced/Clean. The cold Dirt
server request took6,132ms including data load, Balanced1,575ms and Clean1,464ms.
CLI/protection overhead is excluded from those server measurements. Exact output
geometry/surface matched the local canary; all returned hops are contiguous,
within270km usable range, and retain enough fuel for destination escape. A162km
usable-range request returned four stops over588.64km, all hops within range.
Plain /api/route also returns the replacement's61%dirt geometry. Fuel access
remains provisional; this is route review, not station or navigation acceptance.

Fallback/non-route comparisons against previous stable b3cb2fa passed:
NB→NS Clean route45.883,-64.305→45.828,-64.21 completes10,753m with identical
geometry and legacy chain engine. A supported-road NS Clean request with the
unsupported avoidMotorways control completes239,482m with identical legacy
geometry on both deployments. An initial alternate fallback fixture failed
matching on both, so it was not presented as a successful route test. Fuel data
contains the same671NS stations and identities; rider-services POI payloads match.
The preview error-log query for the preceding hour returned no entries.

Evidence: routing/candidates/rebuild-live-preview/{smoke,fallback,config.json,
errors.jsonl}. Replay API tests with bench/verify-adventure-live.js and
REBUILD_DEPLOYMENT set. The pack-refinement owner received the verified exact
preview/config/results for a coordinated stable DEV alias move. Publication
confirmation and public stable readback still required before device handoff.
Device scope, precise pins/settings and remaining UI gaps are documented in
ROUTING-DEVICE-CANARY.md. No UI edit required for this initial From Here comparison;
future UI changes use the requested Impeccable skill and incumbent DIRT tokens.

## Stable DEV ready for physical route review — September 8, 2026

The pack-refinement owner moved pack-fabric.vercel.app to the EXACT verified
preview dpl_6vK7hFKuwQbAs6HF6BYSMdrfFE2b / source
 ecf746ef8497df49c996c0853fe84743de331f7f. Accepted02 data, the five-region
configuration, rider-services base and empty connection revision were preserved.
No production, national03, phone installation or downloaded-pack change occurred.

Independent unauthenticated public checks then passed the address the installed
DIRT Dev app uses: health reports ecf746e/ns-v1; Dirt/Balanced/Clean fuel chains
complete with3/2/1stops, exactNS02 identity, contiguous geometry, usable-range
limits and destination escape. Public HTTP times were3.58/2.05/1.87s; server
processing1.48/1.47/1.37s with warm data. These are individual checks, not service
percentiles. Evidence: routing/candidates/rebuild-live-preview/stable/.

The first physical route-building review is now available. Follow
ROUTING-DEVICE-CANARY.md. No device acceptance or navigation qualification is
claimed until Richard tests. Fuel access remains provisional, Dirt quality is
still bounded by the current candidate pool, and newer UI flows remain unfinished.
The national pack owner was told that the explicitNS02 release guard will reject
NS03 from the canary; keepNS02 for this device review until03 is separately
qualified and the guard deliberately revised. Do not silently switch the phone
back to the old engine during national pack activation.

## Physical feedback — build 22, September 8

Richard confirms fast, good NS route creation including fuel. US and Quebec remain unacceptable on legacy cross-region routing. See ROUTING-PHYSICAL-FEEDBACK-2026-09-08.md for exact request IDs, timings, pack identities and reconstructed regression fixtures. National pack publication alone does not enable the replacement engine outside NS. Cross-region integrated fuel search is the next engine integration priority; NS02 remains pinned.

## Successful physical NS toggle sequence

Richard accepted the Porters Lake → Cape Breton Dirt / Allow Unknown / fuel-toggle sequence as a big win. Device HTTP times 5.532 s / 2.435 s / 4.101 s; final fuel response includes three pumps and destination on unchanged ecf746e/NS02. Screenshot captures the pre-fuel 593.5 km, 82% dirt route. Evidence and diagnostic mapping flag recorded in ROUTING-PHYSICAL-FEEDBACK-2026-09-08.md. Scope now NS + NB, including cross-region tests; QC/US deferred.

## NB and cross-region preparation — September 8

Added run-nb-adventure.js: 24 local cases over the recorded NB segment 46.646799,-64.87533 ↔ 47.762610,-65.856301, both directions, all three styles, Allow Unknown on/off (forced off for Clean), 333/162 km usable range. All complete with complete candidate pools and provisional station access. Individual engine times 363–924 ms exclude loading and network. Independent saved-route checks confirm every stop-to-stop distance is within usable range and destination escape fits remaining fuel. Existing 154 focused tests pass.

Quality flag: Balanced returns approximately 82.6% dirt at the longer range, 67% at shorter range. The limited candidate pool does not offer a near-50/50 alternative here; connectivity/speed passes do not constitute profile-quality acceptance. Dirt remains at least as dirt-rich as Balanced for equal access/fuel conditions; Clean is 0% known dirt.

Added audit-ns-nb-seams.js: all 232 NS02→NB02 seam records have reciprocal entries, matching OSM node/way/endpoints and exact node coordinates in both packs. Five records refer to restriction-bearing edges. This is identity evidence, not end-to-end crossing qualification. Runtime edgeId uses packed node indices while sidecar edge IDs use OSM node IDs, so audit reconstructs the canonical sidecar identity rather than comparing unlike IDs.

Next implementation: one cross-region graph/search with remaining fuel and turn history retained across shared boundary nodes; avoid independent provincial searches that erase state or pick fuel after the ride. Keep NS device baseline and current stable deployment unchanged during integration. No NB replacement deployment yet. Evidence: routing/candidates/rebuild-nb-adventure and rebuild-ns-nb-seams.json.

## NS/NB integrated preview candidate

Added an exact-source in-memory join, translating regional surface/road dictionaries, deduplicating geometry-identical overlapping edges and remapping node/via-way restrictions. Same-coordinate/different-OSM nodes never connect; source-epoch, duplicate attribute/geometry and shared-node coordinate conflicts reject the join. Same-region self-loop edge geometries stay distinct. Cross-region fuel search retains one ledger and turn state. Six focused join tests include restriction crossing and no boundary refuel.

The original exact search at 400k labels still exhausted short-range Dirt and peaked at ~1481 MiB. Experimental fuel-only weighted guidance (2x relaxed goal bound) at the original100k label cap completes all24 cross-region range/access/profile/direction cases, without relaxing fuel or road legality; it does not claim minimum additive cost. Six shared candidates are used only for NB or NS/NB, adding2/3/5 intermediate surface costs. NS-only retains original three candidates and exact guidance. Final expanded cross matrix passed all24 cases and stop-to-stop/destination-escape checks. Balanced remains dependent on available candidates, not guaranteed50/50.

New opt-in `ns-nb-v1` accepts NS02/NB02 and both together; existing ns-v1 scope unchanged. Joined preparation cache holds one immutable pair. Full identities are returned. Generic Allow Unknown diagnostics now reflect request intent. Native DEV NS/NB requests up to12 already-built legs and disables legacy forwardFeeler for that path; other regions and Release unchanged. Native test added and Android contract updated.

Existing NS local live-adapter comparison preserves597.353731/500.744731/351.170731km and3/2/1stops for Dirt/Balanced/Clean. 161 focused JS tests pass. Hosted preview, native test completion and physical acceptance remain pending.

## Hosted and public NS/NB verification — September 8

Exact acceptance preview/source94597816b960b3baeb33cf008340700d8a3589ae (stablebaseb9f263d plus2d4e394) published to stable DEV by the pack owner after error-log query returned no entries. Flag ns-nb-v1, allfiveexistingregions02, NS/NB02 preserved, no national03/production change.

Six hosted cross tests passed bothdirections/allprofiles at225kmusable, full12stopwindow, per-hop range, contiguousgeometry and destinationescape. Server times5.6–15.3s; forwardDirt1054.84km73.51%/6stops, Balanced630.41km46.68%/2stops, reverseBalanced609.89km44.60%/2stops. Additional UnknownDirt forward completes7stops6.665s; NB-onlyDirt2stops3.593s. Independent3styleNS exactbaseline holds.

Independent publicstable health confirms94597816/ns-nb-v1; real unauthenticated unknownDirtNSNB request completed7stops,9.85sHTTP/8.537sserver, fullwindow, expected02identities, range andescapechecks. Evidence in rebuild-atlantic-public, rebuild-atlantic-extra, rebuild-atlantic-ns-regression; owner's sixcase responses in maincandidate03/atlantic-acceptance-live.

All38native ItineraryBuilder tests pass (the addedtest initially expected literalfalse, butserializer correctlyomitsdisabled forwardFeeler; corrected assertion checks nottrue).162focusedJS tests pass. Signeddevice23 build andeightDEVbundlechecks pass. Install/launchverification follows.

Later source464864f adds diagnosticweight reporting and tests only; hosted94597816 intentionally stays the exactverified artifact. New NS/NB routebuilding remains a device acceptance candidate; offline reroute parity, physicalpumpaccess and longerthan12stopcontinuations are not qualified by these checks.

## Device23 installed and running

Xcode installed DIRT Dev2(23) on White; device inventory independently confirms bundlecom.mayday.dirt.dev/version2/build23. Initial Xcode launch terminated withsignal9 (cause not established). Direct devicectl launch then succeeded and device process inventory confirms Dirt running (PID5088). Public stable source945978/ns-nb-v1 and both02packs verified beforehand. No packs downloaded. Physical NS/NB route-building test is ready; rider acceptance remains pending.

## Evening physical feedback follow-up (local, not yet published)

168 focused JS checks pass. Added exact phone Clean avoidMotorways gate test,
synthetic alternate/mandatory motorway cases, fuel alternative safety/fixed-anchor
checks and full source geometry road-class reporting. Exact Dalhousie automated
replay replaces65.610km retrace with4.095km using Sunny Corner, still72.340%dirt,
all fuel intervals/final escape verified. NS/NB24-case expanded regression in
progress. Clean legacy fallback repaired locally; NB city classification missing
in original02 confirmed with pack owner and source-locked supplement under test.
Clean primary/trunk back-road preference remains open. No live/phone changes yet.

Hosted preview0e266910 replay confirmed corrected Dalhousie958.049km/72.340%dirt/
4.095km repeated and full fuel proof, plus Clean stays in replacement engine.
However cold Dalhousie exhausted20s while performing multiple optional quality
trials. Not published. Reduced expansion to ONE trial for the worst fuel circuit
across the common base pool (base candidates still completed first). Local exact
replay retains the same improvement.24cross plus8actualClean-preference cases and
3unchangedNS baseline cases passed before this narrowing; rerunning relevant
regression and hosted timing before stable publication.

## Stable DEV physical retest ready — final evening deployment

Stable pack-fabric.vercel.app now source6ace2323f6a6051a9f3761db55973d7548fc087e,
exact previewmpatek5gc, ns-nb-v1, NS/NB02 unchanged. Pack owner flipped only DEV
alias and updated national activation guard; production/phone untouched.
Independent PUBLIC Dalhousie request verifies source, replacement strategy,
full five-route/four-stop window, Sunny Corner, continuous geometry, all225km
intervals and destination escape.9.550s HTTP/8.579s server,958.048809km.
Exact hosted audit72.340%dirt/4.095km repeated; old65.610km repeated.
Cold exact preview15.456s remains a performance flag. Six hosted reference cases
both directions/allstyles pass7.337–8.403s. Final local24cases pass2.013–4.289s,
819MiBpeak;168focusedJS checks pass, three NS baseline distances unchanged.

Runtime commits a13f820/cd1dcd0 integrated on live945978 plus464864f diagnostics.
No new native changes: existing DIRT Dev build23 uses the updated service.
Device retest instructions at top of ROUTING-DEVICE-CANARY.md. Clean request
fallback and reviewed NBcity coverage corrected, but its primary/trunk-heavy
back-road quality remains explicitly OPEN. No broad Clean acceptance claimed.

## 21:20 moved-waypoint physical failure — acceptance reopened

User accepted the near-Dalhousie placement, then moved destination to
47.743529,-64.911236 and rejected the resulting two fuel spurs. Same source6ace232
and replacement engine confirmed, so this is not stale deployment or legacy
fallback. Public replay1124.508km/73.826%dirt/82.243km repeated. The bounded trial
found a fuel-valid894.565km/65.697%dirt/1.894km repeated alternative but rejected
it because fresh-dirt ratio was65.655% versus67.555% on original. Thus successful
fuel feasibility does not equal satisfactory route quality. Current final pool
also ranks raw dirt share, another opportunity to select a poor-shaped ride.

Previous Dalhousie improvement was too narrow; general fuel-detour acceptance
is reopened. Do not extend pump exclusions or increase trial count as the claimed
systemic fix. Shared search/selection must explicitly represent onward continuity
and necessary versus avoidable repeated access. Preserve coherent integrated
fuel search; no blanket direct-line corridor, no arbitrary destination-distance
cap, and no shorter-all-paved substitute presented as Dirt success.

Counterexample and measured fuel hops captured in
scripts/pack-fabric/bench/fixtures/moved-waypoint-20260908.json. Generic local
replay supports REBUILD_REQUEST_PATH. No runtime or live service changes made
in this diagnostic follow-up. Next acceptance must cover a range of moved
endpoints and audit whole rides, not only the one previously successful pin.

## Local onward-search candidate after moved-waypoint failure

Moved repeat82.243→1.621km,884.748km64.341%dirt,4pumps. Near-Dalhousie and actual
Dalhousie repeats1.413km, approximately828.6/797.1km. Eight-waypoint sweep (actual
three pins plus five road positions5–90km back from moved endpoint) each keeps
>=60%dirt and<=2km repeated; all fuel intervals/final escape pass. These are
case acceptance bounds, not new routing thresholds. Post-hoc pump exclusion
and fresh-dirt percentage veto removed in favor of integrated approach-retrace
priority. Outgoing legal connections from a pump compete during fuel search.

Initial100k labels limited two candidates on162km-range unknown reverse ride.
200k allows all six candidates there to finish, Balanced53.37%dirt, profile-only
matrix peak890MiB; same20s/30M caps, host2GiB. Attempted road-trace interning did
not resolve that limit and was removed. NS3baseline exact distances unchanged.
Full24final and hosted verification pending; no public update yet. Generic
history-dependent route quality remains bounded/heuristic; no global proof.

## Onward candidate verification complete; DEV alias requested

Private df0827e60e9c04a625fd3b3155fae87220c93113 passed4actualdevice requests and
critical162km reverseunknown Balanced case (allcandidatescomplete). Full24local
pass1.820–3.630s839MiBpeak,8pinsweep pass,166focusedchecks. Cold movedrequest
13.179s; followingactualcases4.927–5.070s; difficultshortreverse10.152s. NS3exact
baseline unchanged; CapeUnknown retrace improves5.670→4.962km at3stops. Clean
backroad preference stillopen. Stable switch requested only after thesechecks;
publicverification andphysicalhandoff recorded next. Runtime revision86f3c02;
service subtree matches private df0827. No Xcode/phone/packchanges.

## Onward rollout held and reverted for NB-only final check

Public df0827 moved replay passed884.748km/4stops/1.621kmrepeat,7.822sHTTP/
6.522sserver. However NB-only matrix, newly run with actual onboard policy,
found162kmunknownforward dirt-30 label_limit at200k (othercandidateDirt48.49%).
Restored stableDEV6ace232 via packowner before physicalhandoff; both02 preserved.
Owner publiclyverified rollback. Do not treat df0827 ascurrentstable.

400k cap allows every NBcandidate tofinish under same20s/30M caps. The completed
strong-Dirt candidate ALSO yields48.49%, so the initial assertion that the limit
caused the low surface share was not established. Short-range NB surface quality
remains a separate bounded-pool flag, not a proved geographic maximum. Full
24NBcases pass at400k (691–1864ms preliminaryrun). Added diagnostics correction:
poolComplete cannot be true when fuelcandidateverification fails. Added regression
forlabel_limit. All167focusedchecks pass. Finalmemory/hostedNBcriticalcase pending.

## Final400k candidate hosted checks pass

Private67425f53c32f26bf81911331931462389205bc2b =df0827+05eecb0.
NB-only critical162kmunknown firstrequest7.429sserver,256.158km48.491%dirt,
0.016kmrepeat,all6candidatescomplete. Subsequent actualmoved request13.164s,
nearDalhousie4.887s,Dalhousie4.689s,Clean4.423s,matching previously verified
shapes/fuelproof. NB24final400k691–1986ms525MiBpeak; previouscross24completed
below200k (thus unchanged by highercap)1.820–3.630s839MiBpeak.167focusedchecks.
Stable reactivation requested only after allthesechecks. Retestscope remains
225kmusable FromHere, with short-rangeNB48%dirt/Cleanbackroadquality flags open.

## Physical retest ready — final public67425 verification

StableDEV pack-fabric.vercel.app now source67425f53c32f26bf81911331931462389205bc2b,
exact5bnn5yit5 preview, ns-nb-v1/BOTHNS02NB02. Ownerverifiedpublichealth andupdated
nationalactivationguard. Independentpublic failedmoved-pin request passes:
5.690sHTTP/4.637sserver,884.748389km,4pumps,1.621km repeated. Everycandidatefuel
search finishes, all5legs within225km, destinationescape fits andgeometryjoins.
No Xcodeinstall/phonepackchange/productionchange. Runtime commits86f3c02/05eecb0.

Handoff: freshFromHere route to lastfailedNBdestination, Dirt/unknownOFF/fuelON,
samevehicle range, then moveendpoint again.167focusedchecks,24cross+24NB regional
cases and8pin sweep support this handoff; physicalride-qualityacceptance pending.
Cleanmajor-road preference, lowdirt48.49%on162kmNBcase andresidualNSunknownretrace
remain explicitqualityflags. No globaloptimality or offlinenavigationclaim.

## Physical acceptance — 22:11 UTC, build 23

The rider reported “Perfect!” after three new Porters Lake→NB Dirt builds.
All used live source `67425f53c32f26bf81911331931462389205bc2b`, NS02/NB02,
Allow Unknown OFF, automatic fuel ON, 250 km range with 10% reserve (225 km usable).

| Destination latitude, longitude | Request time | Fuel stops | Committed legs |
|---|---:|---:|---:|
| 47.752778, -64.870725 | 5.513 s | 4 | 5 |
| 48.042596, -66.476724 | 4.807 s | 3 | 4 |
| 45.270115, -67.383511 | 5.444 s | 4 | 5 |

These are three accepted physical route-building cases, including changed endpoints.
Exact inputs and log observations are preserved in
`scripts/pack-fabric/bench/fixtures/physical-dirt-acceptance-20260908-221107.json`.
The installed pack01 path in the policy line does not identify the live routing
pack: the response identity explicitly confirms both02 packs. No app reinstall
or new deployment was needed for this acceptance.

The pasted log does not include full geometry or fuel-hop distances; rider visual
acceptance and successful responses do not independently verify navigation,
station entrances/availability, or offline routing. Clean back-road quality is
the next integration priority. Short-range NB dirt share and residual NS unknown
retrace remain open. Preserve this accepted Dirt baseline while refining Clean.

## Follow-up correction — Nova Scotia short diversions, 22:14 UTC

The rider's close-up screenshot rejects short hooked diversions near Musquodoboit
Harbour on a NEW NS-only route to 46.214698,-59.965492. This is separate from the
three earlier NS→NB builds. The earlier positive feedback is not blanket routing
acceptance. Route quality remains open and takes priority over Clean refinement.

Exact public replay on source67425 confirms the diversions exist in returned
segments, not only the renderer. Gravel service runs of70m and179m occur in the
opening9km. The selected route reports zero repeated road metres: leaving and
rejoining through different edges escapes the retrace check. Current per-metre
surface costs reward short dirt without assessing continuous riding value.
A short-run threshold alone must not reject necessary fuel/waypoint access.

Device request16.488s; public replay13.677s server. Dirt-10 completes at561.496km,
68.981%dirt,3pumps; paved and dirt-30 candidates hit label_limit. This is a separate
search-completeness/performance failure, not evidence that dirt-10 is best possible.
Input and observations: bench fixture `ns-short-diversions-20260908.json`.
No scoring change or deployment made for this diagnostic capture. Next: compare
these short branches with legal onward alternatives and qualify continuity
handling beyond repeated-edge detection; preserve fuel and turn constraints.

## Dirt continuity candidate — local qualification

Short leave-and-rejoin branches are not repeated-edge problems. Added an explicit
nonnegative dirt-entry cost to resource search, once per continuous dirt run.
An onDirt bit participates in dominance; refill labels preserve it. The ordinary
edge-only reverse bound remains admissible because it omits this added cost.
Turn/access/fuel restrictions and destination escape are unchanged. The parameter
is candidate generation guidance, not a road ban or minimum permissible dirt run.

DEV candidate uses1000m continuity allowance scaled by each objective's dirt
saving, zero charge for the paved objective, and fuel heuristic1.5 for single
regions (cross-region remains2). No region-specific road exclusions or smoothing
of final geometry. Actual travelled dirt percentages remain honest. Search costs
are changed before fuel routing; no extra post-route fuel insertion pass.

Exact new NS case:559.326km,68.061%dirt,zero repeated road, no dirt branches in
opening20km; every candidate fuel search completes. Local~2.9s. Weight1 with the
same continuity cost hit label limits; weight2 caused a4.4km NBshort-range
regression and was rejected for single regions. Final1.5 NBmatrix all24pass;
worst added repeat167m (total183m); cross24pass with worst added16m (total304m).
These small repeats still require context, not an assertion every spur is removed.
Moved NB pin856.440km63.203%dirt471mrepeat (previous1621m), allcandidatefuelcomplete.
NS3reference styles allcomplete with zero repeats; geometry intentionally changes.
CapeUnknown still4962m repeated, unchanged unresolved quality flag.

172focused tests pass, including short-vs-long dirt choice, dominance arrival
surface, split roads/refills, necessary short pump access and legal restrictions.
Local bench `replay-ns-continuity.js` captures0/500/1000comparisons and optional
qualification assertions. Evidence is under /tmp/dirt-continuity-qualified,
/tmp/dirt-cross-continuity, /tmp/dirt-nb-continuity-weight15 and
/tmp/dirt-moved-continuity. Private hosted verification pending; no DEV switch.

## Continuity hosted qualification — source9c15324

Private r2w1bfpj7/source9c15324e6ace23df668c6061e2d4ba2a04b99bc8 =67425+d14a5a7.
Exact NS hooks559.326km68.061%dirt0repeat3stops,9.591sserver onfirstNSrequest.
Moved NB856.440km63.203%0.471kmrepeat4stops15.120s firstjoined; nearDalhousie
807.840km62.361%0.471repeat7.981s; Dalhousie776.358km64.101%0.471repeat7.542s.
Clean unchanged704.376km0repeat7.628s; criticalNB162unknown273.298km50.394%
0.183repeat4.881s. All six pass complete candidate pools, fuel intervals,
destination escape, geometry joins and response pack identities. Test-specific
NS assertion verifies no dirt runs in first20km and>65%dirt, not a global rule.

Final localcross24:2.449–4.916s1185MiBpeak; NB24:0.715–1.572s349MiBpeak.
Hosted joined latency increased; correctness improves but speed remains a flag.
Evidence summaries preserved in routing/candidates/rebuild-continuity-verification.
Requested stableDEV activation after checks; public confirmation recorded next.

## Stable continuity candidate ready for physical retest

Owner activated exact r2w1bfpj7/source9c15324, preserved both02/ns-nb-v1/allenv,
updated guard and publicly checked identity. Independent public NSrequest:
7.554sHTTP/6.978sserver,559.326km3stops0repeated, no dirt runs in opening20km.
Everycandidatefuelcomplete; all225km intervals, destinationescape andgeometryjoins
pass. No Xcode install, phonepack transfer, production publication or GitHubpush.
Physical handoff: fresh sameCapeBretonpin,Dirt,unknownOFF,fuelON250km/10%reserve;
inspect MusquodoboitHarbour hooks. Physical acceptance pending, not implied by
our automated checks. LargeNB latency/Cleanquality/CapeUnknownrepeat remainopen.

## Physical continuity pass — 22:36 UTC

Rider: “Looks really good. Pass”. App2(23), live9c15324, NS02, Dirt,
unknownOFF, automaticfuelON250km/10%reserve. Requestfuel-b6585486 completes in
5.793s with3pumps+destination (4committedlegs), selecteddirt-10. Origin44.764827,
-63.340263; destination46.980210,-60.472582, snapped46.98019,-60.47261.
This is a different CapeBreton pin from the original hooks failure, providing
another rider-accepted route build. Exact observations are preserved in bench
fixture `ns-continuity-accepted-20260908-223608.json`.

Acceptance covers this route's visual quality and build behavior. The pasted log
does not establish distance/dirt percentage/repeat metres or navigation outcomes.
Next live priority: Clean paved back-road quality, preserving the accepted
continuity behavior. LargerNB latency and CapeUnknown retrace remain open.

## Clean back-road candidate — local comparison

Rider additionally accepts NB Dirt: approximately9seconds and good-looking route.
That is acceptable observed timing, not a blanket guarantee for cold/largecases.

Clean's previous paved candidate treated primary/trunk like secondary/tertiary.
New candidate cost prefers secondary/tertiary/local paved roads: primary/link4,
trunk/link8,motorway/link/freeway32,service6,other1; nonpaved/unknown multiplier100.
These are relative search costs, no road bans. The service cost avoids parking/
service shortcuts; necessary fuel/anchor/highway access remains legal. Dirt and
mixed candidate objectives are untouched; shared pool surface selection remains.

ActualClean comparison:704.376km→962.273km, primary/trunk(includinglinks)497.986→
193.197km;99.999%paved,8m mappednonpaved,zero repeatedroad,4fuelstops. First softer
surfaceweight30trial retained14.161kmunknown and1.065kmrepeat; not selected.
48localmatrixcases pass fuel/escape/allcandidatechecks. All32Dirt/Balanced cases
retain exact geometry and plannedrefills against continuitybaseline. NSreported
hooks route also retains exactpublicgeometry/stops.175focused tests pass.

Short162kmusable crossClean has1.370km repeated paved approach at Irving
osm:w428976289, total stopposition226.647km. Explicit qualityflag; don't claim all
fuelspurs eliminated. Normal225km actualClean reference has0repeat. Privatehosted
verification pending; no stableDEV change. Bench compare-clean-backroads.js
records original, softer, and candidate costs without changing live state.

## Clean candidate held, then revised after NS hosted failure

Private6d61061 cross4requests passed, but NS hooks pavedcandidate hitlabel_limit.
Earlier local geometry-only comparison had not asserted poolComplete for this
specificNS case; hostedgate caught it beforeactivation. Clean at the samepin with
avoidMotorways also failed atweight2 and selected dirt-heavy feasible fallback.
That is a failed Clean outcome, not geographic proof. Stable9c15324 stayed live.

Explicit paved-candidate fuel guidance3 now completes NSCapeClean at757.037km,
99.88%paved,3pumps,0repeat; NSDirt unchanged. Otherobjectives retain previousweights.
Same400klabel/20sdeadline/workcaps. This is bounded heuristic guidance, not global
optimality; no extra retries or caps. New hosted NSClean regression assertspaved
candidate selected,>99%paved,0repeat andcompletepool.175focusedchecks pass.

Final24cross+24NB againpass fuel/escape/allcandidatechecks;32Dirt/Balanced exact
geometry/refills unchanged. NB Clean repeats0; cross162km reverseClean repeats
2.104km, explicit unresolved qualityflag (supersedes prior1.370kmstress note).
Actual225kmClean955.802km99.999%paved0repeat. Revised privatehosted checks pending;
no stable change yet. No claim that all route quality or fuelspurs are solved.

## Final Clean private qualification —8be23e95

Exact1krqzezwv/source8be23e95a91c7ebe8a02bf20a6917f57ad42a4b7.
NSClean757.037km99.88%paved3stops0repeat,12.022sserverfirstNSrequest; allcandidate
fuel searches complete, selectedpaved. ActualNBClean955.802km99.999%paved4stops
0repeat,6.797sserver; primary/trunk199.020km (old497.986km). ThreeNBDirt andNSDirt
hosted geometry/stops EXACTmatch stable9c15324. NSDirt8.144sserver, NBfirstjoined
14.824s, following8.094/8.516s. Everycasefuel/escape/joins/poolcomplete passes.

Final48localcases fuelchecks pass,32Dirt/Balanced exactunchanged;175focusedchecks.
SingleNS3reference profiles completepool/fullwindows/escape/joins; Dirt/Balanced
unchanged, Clean596.543km0repeat. Short162reversecrossClean2.104kmfuelreturn stays
flagged; normal225kmreference0repeat. Requested stableactivation onlyafterthese
checks; publicverification andphysicalhandoff recorded next. Summaries persisted
in routing/candidates/rebuild-clean-backroads-verification.

## Clean stable publication and independent public verification

Owner activated exact1krqzezwv/source8be23e95, publicly checked identity andupdated
activationguard; both02/ns-nb-v1/env unchanged. IndependentpublicClean request:
12.984sHTTP/10.709sserver,955.802km99.999%paved4pumps0repeat. Primary/trunk199.020km,
60%below497.986km baseline. Selectedpaved/allcandidatescomplete; fuel225km bounds,
destinationescape, geometryjoins andbuildidentityverified. No Xcode/phonepack/
production/GitHub change. PhysicalClean acceptance pending; guide requests fresh
NS→NB Clean withusual250kmrange/10%reserve, inspect backroads andfuelapproaches.
Knownshort162kmcrossreturn2.104km andCapeUnknownretrace remainflags. Public timing
is observed, not a percentile guarantee. Prior NB~9s physical timing was accepted.

## September 9 UTC — Clean final fuel exit/rejoin regression (local qualification)

Latest physical feedback on service `8be23e95a91c7ebe8a02bf20a6917f57ad42a4b7` is a partial fail for Clean: Porters Lake (44.764793,-63.340250) to (47.047134,-64.891699). Replay proves 22,703 m of repeated road around the final Shell station. The station exit rejoins the earlier approach beyond the immediate reversal cursor. Device 20,334 ms includes 14 seconds backgrounded; server replay was 13,644 ms.

The qualified local correction retains approach history during a second, complete fuel-aware search only when a paved candidate repeats roads. It does not insert pumps or splice geometry after construction. Distinct final station entry roads remain separate frontier states; histories sharing an entry can still be pruned. This is bounded candidate generation, not proof of globally optimal or loopless routing. Fuel, legal turn and destination escape checks are unchanged. A failed refinement preserves the prior feasible candidate and exposes its reason; shared request exhaustion remains visible.

Always retaining all histories failed regional label limits; retaining station entries on every search still failed NS Clean. Neither prototype was published. Broader Dirt/Balanced use remains unqualified. The final gated version passes 48 regional cases (24 NS/NB and 24 NB), all candidates complete, all fuel/escape checks and style ordering. All 32 selected Dirt/Balanced geometries and refills match the prior qualified matrix. 171 focused adventure tests pass, including exit/rejoin in either direction and integrated fuel refinement. NS Clean reference remains 757.037 km with all candidates fuel-complete.

Exact latest request now locally returns 586.973 km, 99.512% paved, zero repeated road and three stops in 4.803 seconds. First two fuel legs remain unchanged; third generated station changes to `osm:n5301512825`. The existing 2,866 m dirt section near the destination remains. Do not assert its necessity without a separate surface-data/legal-alternative investigation. Evidence: `/tmp/dirt-clean-f3-refine`, `/tmp/dirt-cross-refine`, `/tmp/dirt-nb-refine`, `/tmp/dirt-ns-refine`. Fixture: `scripts/pack-fabric/bench/fixtures/clean-final-fuel-20260909.json`.

Private hosted verification and stable DEV publication are pending. App/phone packs/Swift/production/GitHub are unchanged. Physical acceptance is still required after publication.

## September 9 UTC — final fuel correction live on DEV

Stable `https://pack-fabric.vercel.app` now points to exact `pack-fabric-3wcw1w2vh-goricksmith-7678s-projects.vercel.app`, source `edc55fdb42af4bb3c4dd6972ecdaabf8e4ba88c5` (stable8be23 + local fa08b4e). BOTH02 and ns-nb-v1 unchanged. Public exact replay returned HTTP200 in 11.246s, server10.339s: 586.973km, three pumps, zero repeated road, complete candidate pool, all fuel intervals/destination escape/geometry joins pass. Diagnostics explicitly show refinement22,703m→0. Third pump is Esso,11107 Rue Principale,Rogersville (`osm:n5301512825`).

Private hosted exact request passed twice: first18.975s server, repeat10.983s. NSClean10.486s/757.037km/0repeat; three earlier NB Dirt references7.737–9.128s; prior NBClean6.916s/955.802km/0repeat. All hosted candidate and fuel checks pass. Evidence `/tmp/dirt-final-fuel-public.json`, `/tmp/dirt-final-fuel-hosted`, `/tmp/dirt-final-fuel-hosted-repeat`, `/tmp/dirt-fuel-refine-hosted-ns`, `/tmp/dirt-fuel-refine-hosted-nb`.

Physical retest: build a fresh From Here route to the same pin47.047134,-64.891699, Clean, automaticfuelON,250km/10%. No reinstall or pack download. Saved route geometry remains stable. Device acceptance remains pending; 19s first-request latency and broader Dirt history qualification remain open. No production/GitHub/phone-pack/Swift changes.

## September 9 UTC — multi-waypoint Inverness circuit, reproduced

The user accepted the preceding Clean correction ("Pass!"). Subsequent four-rider-anchor Balanced itinerary was broadly successful but has a small box north of Inverness. This is a partial physical result, not complete Plan a Route qualification. Anchors and reconstructed departure requests are in `bench/fixtures/multi-waypoint-inverness-20260909.json`.

The first primary leg uses adventure-preview-v1; all subsequent legs fall back to legacy strategies. `canarySupported` explicitly rejects priorEdgeIds/arrivalEdgeId, which ItineraryBuilder sends after the first leg. Do not remove that guard without handling arrival restrictions and prior-road context. Fuel carry-forward is visible (212506m then52232m), but the last final generation took95s (00:38:21–00:39:56), with legacy windows and a timeout prefix. Earlier append cancellations were correctly discarded.

Public replay first two legs reproduces new→legacy strategy change and derives the same61 recent edge IDs/arrival `w117513698:40738:40713` at Point3. Isolated Point3→F5 replay is50228m with an actual664m closed circuit plus larger8444m closed walk near46.30,-61.24. It is not merely overlapping adjacent stage rendering. Removing priorEdgeIds and setting backtrackFactor1, retaining arrivalEdgeId, yields48129m with no repeated segment-start junctions and the same endpoint under52232m cap. This is a diagnostic counterfactual, not a published fix: it also changes which earlier roads are reused and must not be generalized by dropping restrictions/history. Coordinates reconstructed from rounded logs; the isolated request omits the customer endpoint-access hint. No global cause/optimality proof claimed.

Next integration priority: support waypoint arrival/recent-road state in the replacement engine, including direction/via-way restrictions, necessary returns from fixed rider waypoints, fuel carry-forward and continuation. Test all four anchors, profile edits, cancellations and saved stability. Stable DEV remainsedc55fdb; no runtime, app, pack, production or GitHub changes made for this issue. Evidence `/tmp/dirt-multi-20260909`.

## September 9 — waypoint arrival integration, local qualification

User explicitly approved replacing legacy routing throughout the multi-waypoint flow. Local implementation now resolves prior source-road IDs across regional/joined packs, reconstructs a continuous directed history suffix, seeds node/via-way restrictions conservatively, and preserves direction through interior projections. Unknown/ambiguous context returns incomplete. Covered Atlantic unsupported controls no longer silently fall through to the older engine. Other regions/admin actions retain existing dispatch. Missing source history is not silently treated as a free turn.

Continuation candidates use a positive fourfold recent-road cost, preserving necessary returns; the existing app sends only30km/256deduplicated edge IDs. This is NOT whole-itinerary variety. Continuations use the six-objective candidate pool and conditional fuel-approach refinement. Refinement can hit a label limit and retain the earlier feasible candidate with explicit diagnostics; no claim all candidates are loopless. Two-way/profile changes and truncated restrictions need physical qualification beyond local tests.

Local full replays: Inverness and Yarmouth four anchors, all three primary legs new-engine-only, complete pools, fuel carry-forward/escape/geometry joins pass. Extra Yarmouth Dirt→Balanced→Clean run at162km usable passes. Selected Inverness circuits removed. Yarmouth continuation258.261km still overlaps108.943km of the earlier leg (prior edge IDs, same regional pack); the30km history limit cannot prove whole-ride novelty. This remains an open quality issue, not a pass claim. Evidence `/tmp/dirt-multi-arrival-final`, `/tmp/dirt-multi-arrival-styles`; reproducible `bench/replay-multi-waypoint.js` supports private deployment replay.

No stable publication yet. Swift/app/phone packs/production/GitHub unchanged. Arrival restriction and graph mapping changes require native parity after live acceptance. Required pump overrides and other advanced controls remain explicitly unsupported in the opted-in Atlantic new-engine flow rather than using legacy routing.

### Arrival integration — hosted budget correction (September 8/9)

Private source 04b195e completed Inverness primary legs 1 and 2 but exhausted the final leg's comparison budget. No stable alias change. Reworked continuation search to finish the common candidate pool before optional approach refinement. Clean, Dirt and Balanced potential winners are considered in a fixed common order; refinement is limited to 2 seconds per attempt, charged to the parent budget, with 250 ms reserved before its deadline. An unfinished optional refinement retains the fuel-proved candidate and reports its limit. An unfinished core candidate comparison now returns explicit unknown, not a complete result or legacy fallback. Unqualified covered pack data also returns explicit unknown.

Local full Inverness and Yarmouth replays complete with fuel carryforward and all core candidates. Inverness selected Balanced continuation has no repeated road; its Dirt candidate still has about 16.9 km repetition after bounded refinement could not finish. Yarmouth's approximately 109 km overlap with an earlier primary leg remains open: native history covers only the recent 30 km. These are not claimed resolved. 179 focused tests pass. Private hosted qualification of this follow-up remains pending; stable DEV remains edc55fdb.

Private 47bc06a also exhausted the hardest Inverness leg. Added continuation-only fuel-first orchestration: a successful integrated fuel search no longer pays for a separate unfuelled advisory search first. If fuel feasibility fails, advisory search remains available within the same budget. Fresh accepted single-leg requests retain their prior ordering. Full local itinerary replay passes (hardest Inverness leg ~9.3 seconds locally); hosted qualification still pending. Incomplete response diagnostics now retain candidate timing and reasons. 181 focused tests pass, including shared profile pools with actual arrival history and equal fuel evidence with reduced search work. Stable unchanged.

Private 0716b5e completed all core leg searches but cold Inverness final-leg refinement left 16.9 km of repeated roads. This was rejected as a route-quality pass. Continuation comparison now uses four common objectives (paved, dirt-10, dirt-30, mixed-2), retaining both dirt strengths and a moderate mixed candidate. Potential profile winners are refined in distance order, common to every profile; this does not change fresh single-leg pools. Local full Inverness and Yarmouth selected Balanced routes have zero within-leg repeated roads in all six primary legs. The replay now explicitly asserts zero repetition on the reproduced Inverness continuation, not just completion and fuel proof. Hosted qualification pending; stable still unchanged. Earlier whole-itinerary Yarmouth overlap remains open.

Hosted fc2c42e still retained the Inverness circuit; the strengthened assertion correctly rejected it. Profiling showed ~2.3 seconds plus allocation pressure for an all-road arrival alias index, although requests contain at most 256 IDs. Arrival resolution now scans only requested way aliases and caches at most 4096 resolved request IDs per pack, preserving ambiguity checks and request-budget accounting. Cache eviction retains current-request hits. Optional winner refinement may use up to 4 seconds within the unchanged 20-second parent deadline; fresh routing remains unchanged. 182 tests pass, including sparse lookup/cache eviction, and both full local itineraries pass the circuit assertion. Stable remains edc55 pending private hosted requalification.

### Private arrival integration qualified — a518fd38

Exact private URL: https://pack-fabric-9pibwupnx-goricksmith-7678s-projects.vercel.app, source a518fd385ac2e6d794e29c1b445f96daba17e816. Both full Balanced itineraries (six primary legs) pass the new-engine identity, full core candidate pool, fuel carryforward, geometry continuity and escape assertions. Inverness final-leg repetition is zero. Mixed Dirt→Balanced→Clean Yarmouth with 162 km usable range also passes all three legs. Six accepted single-leg regression requests pass: Clean final fuel, NS dirt hooks, three NB Dirt endpoints and NB Clean backroads. 182 focused unit tests pass. Evidence: /tmp/dirt-multi-hosted-sparse, /tmp/dirt-multi-hosted-sparse-mixed, /tmp/dirt-sparse-regression-{final,hooks,nb}.

Stable DEV alias promotion requested under standing authorization, public verification pending. No Swift/app install/phone pack transfer, production or GitHub publication. This qualifies an online Atlantic multi-waypoint engine handoff for physical review, not every recovery control or full-itinerary novelty. Hardest hosted primary leg uses ~19.76 s server time; optional quality refinement can remain incomplete for unselected candidates. Yarmouth continuation still shares about 121 km of roads with the earlier primary leg in the current local replay. Native context supplies only its last30km, so that broader overlap is not claimed fixed.

### Stable DEV public verification complete — a518fd38

Stable `https://pack-fabric.vercel.app` now serves exact `9pibwupnx`, source a518fd385ac2e6d794e29c1b445f96daba17e816. Independent public full Inverness and Yarmouth chained replays pass all six primary legs, full core pools, fuel carryforward, joins and escape checks. Every response carries the expected source identity. The strengthened Inverness final-leg circuit assertion passes at zero repeated meters. Evidence: /tmp/dirt-multi-public-arrival (requests and full responses); instructions updated in ROUTING-DEVICE-CANARY.md. Ready for online physical multi-waypoint review in the existing app. Broader Yarmouth earlier-leg overlap and other documented limits remain open. No app installation, Swift change, phone pack transfer, production change or GitHub push occurred.

## Zoomed-out rider waypoint search — 9 September 2026, local qualification

Rider area placement keeps the existing nearby snap choice, then expands only when no connected endpoint pair is found. The fallback scales with map zoom (28 screen points), capped at 20 km; explicit match limits and street-level precision remain unchanged. Candidate roads must meet access rules and share a road component with the start, and the normal directed route and fuel search still must complete. This is an area-selection tolerance, not a fabricated connection. Fixed fuel station matching remains 150 m. Existing arrival history cannot be moved to another road. Successful route geometry supplies the snapped destination to the existing app pin update.

Local evidence: 185 focused tests and 18 real NS/NB fuel-supported area-placement cases across Dirt, Balanced, and Clean passed. The benchmark fixtures include eligible roads 2.2–17.4 km from the selected area point. Private hosted verification and stable DEV publication are pending; current stable remains a518fd385ac2e6d794e29c1b445f96daba17e816 on both Atlantic 02 packs. No native app or pack changes. Android must reproduce this rider-area selection behavior when parity work resumes.

Whole-itinerary overlap remains open: current native requests carry only the most recent 30 km / 256 road IDs. The service cannot reliably avoid earlier roads that were not included. Do not equate zero repetition within a primary leg with zero overlap across the whole itinerary.

Additional local waypoint qualification: both full Inverness/Yarmouth Balanced itineraries (six primary legs) exactly preserve the previously accepted public route geometry. Mixed Dirt/Balanced/Clean Yarmouth at 162 km usable also passed all three legs. The broader topology suite exposed an outdated test manifest missing its required timezone; supplying America/Halifax fixes that fixture without changing runtime validation. All 22 topology tests then passed.

Private hosted waypoint qualification: exact source 1c806472abab64278c2cebda4cd18afddb8f2bc5 at pack-fabric-l9frcmx1g-goricksmith-7678s-projects.vercel.app passed 30 requests: 18 coarse-area placements, six full-itinerary primary legs, and six accepted problem-route regressions. Both full itineraries match accepted public geometry exactly. Area server times 1.819–6.542 s; itinerary 1.577–19.366 s; earlier problem routes 7.321–10.718 s. BOTH Atlantic 02 identities verified. Evidence in /tmp/dirt-area-hosted, /tmp/dirt-radius-hosted-multi, and /tmp/dirt-radius-regress-{final,hooks,nb}. Stable publication requested from pack owner; awaiting independent public qualification.

Follow-up fixed-service guard: rider anchors within the app’s 150 m mapped-pump recognition radius retain the existing narrow endpoint search; they do not use coarse area expansion. This closes the distinction between a general area pin and a rider-selected pump even when the request carries coordinates without a station ID. 186 focused tests pass including this case. Stable area source 1c806472 passed six independent public area/style checks; the fixed-service follow-up is local pending hosted qualification.

Fixed-pump follow-up hosted qualification: source 7944b89ddabcd4df5ac60e5495cbe66ef087b9f7 / private pack-fabric-95glsdjaz passed nine requests (six coarse area/style cases and full three-leg Yarmouth). Local 18 area cases and full Yarmouth also pass; Yarmouth geometry remains exactly accepted. Runtime worktree18cb8f9; 186 adventure +22 topology tests pass. Publication requested, public verification pending.

## Qualified stable DEV — waypoint area search and mapped-pump guard

Stable https://pack-fabric.vercel.app now resolves to https://pack-fabric-95glsdjaz-goricksmith-7678s-projects.vercel.app, source **7944b89ddabcd4df5ac60e5495cbe66ef087b9f7**. Independent public six-case NS/NB area/style verification passed with exact source and BOTH fabric-v4-20260908-02 identities, after the local/private qualification above. Runtime worktree commit18cb8f9. Evidence: /tmp/dirt-fixed-poi-public/summary.json and per-request files. No reinstall, native changes, phone pack download, production change, or GitHub push. Physical acceptance of the wider snap remains pending the rider’s morning tests.

Overnight continuation: automation overnight-atlantic-routing-refinement is active every15minutes through the 08:00 Halifax September9 handoff. Continue varied styles, unknown-access settings, fuel ranges and moved-pin/primary-leg cases; do not repeat completed qualification without a new reason. Preserve this qualified stable source unless a replacement passes local and hosted checks. Whole-itinerary overlap beyond the native 30km/256edge history is still unresolved; do not claim it fixed. Native parity and a bounded whole-itinerary context contract remain subsequent integration work.

## Exact device log replay — 01:59–02:01 UTC September9

The supplied log uses a518fd (before wider snapping), with a repeatedly failing destination43.566279,-65.491539. Public7944b89d now completes the original coarse placement in6.032s and the first moved-start case in3.930s; destination projection is2391m away. Street-zoom12.5 still rejects that original off-road destination; after moving it onto the road, the logged final case completes in2.628s. Cancellations while adding/moving pins are expected superseded requests, not engine failures.

A new regression checks continuation from a wide-snapped waypoint when native still sends its original coordinates. Expand discovery of the exact supplied arrival edge within the allowed area radius; never switch arrival to another road. 187 adventure tests pass including a two-leg encoded-map proof with identical geometry join. The full original four-anchor device itinerary atzoom6.6 passes locally in all three primary legs with fuel carry and destination escape. Reproduce with bench/replay-multi-waypoint.js, REBUILD_MULTI_CASE=coarsepins REBUILD_MULTI_ZOOM=6.6. Live follow-up pending private/public qualification.

Remaining integration boundary: native must persist resolved coordinates/placement precision per waypoint so zooming into an unrelated edit does not shrink a previously placed area pin’s tolerance. Current requests supply one map zoom for all endpoints; this is not corrected by guessing previous user state on the service.

Wide-arrival private qualification: exact93826d3137c6c8fb05eba3e8f86ad145de2c293f at pack-fabric-aurvxp6er passed six primary legs (actual coarsepins and accepted Yarmouth), all full candidate pools, fuel carry, geometry joins, destination escape, and zero selected within-leg repeated road distance. Coarsepins server times8.357/2.061/16.217s; Yarmouth7.662/2.947/14.268s. Public promotion requested; follow-up evidence in /tmp/dirt-wide-arrival-hosted-{coarse,yarmouth}.

Qualified stable DEV now **93826d3137c6c8fb05eba3e8f86ad145de2c293f**, exact deployment https://pack-fabric-aurvxp6er-goricksmith-7678s-projects.vercel.app behind https://pack-fabric.vercel.app. Independent public replay of the original four coarse device pins passes all three primary legs with exact source/BOTH02 identities, full pools, fuel carry, joins and escape. Evidence /tmp/dirt-wide-arrival-public/coarsepins-complete.json. Runtime dd2ff41. Rollback7944b89d retained. No native/phone/pack/production/GitHub changes. Overnight follow-ups must use this new stable baseline, not earlier7944. The per-waypoint zoom/coordinate persistence issue and longer itinerary overlap remain open for app integration; neither is claimed fixed by this service handoff.

## Overnight batch 02:56 UTC — new combinations, stable unchanged

Nine new local primary legs pass with zero selected within-leg repeat: coarsepins Dirt/Balanced/Clean162km (unknown off), Inverness allClean225km, Yarmouth Balanced/Dirt/Balanced180km. Fuel carry, joins, full pools and destination escape pass. Evidence /tmp/dirt-overnight-coarse-mixed162, /tmp/dirt-overnight-inverness-clean225, /tmp/dirt-overnight-yarmouth-mixed180.

New reproduced failure: coarsepins Dirt/Balanced/Clean162km with Allow Unknown enabled passes legs1–2, but Clean leg3 fails endpoint_no_legal_snap, locally and on public93826d. Last arrival edges include verified paved117m, unknown unpaved432m (w280666072:42895:88884), unknown unpaved204.23m (w280666207:88884:88883). Clean correctly forces unknown access off under existing contract; arrival identity is then ineligible, leaving no departure. This is an access-policy handoff problem, not a fuel shortage or a reason to enable unknown roads globally for Clean. Reproduce with REBUILD_MULTI_CASE=coarsepins REBUILD_MULTI_ZOOM=6.6 REBUILD_MULTI_UNKNOWN=1 REBUILD_MULTI_PROFILES=dirt,balanced,cleanest REBUILD_MULTI_USABLE=162000. Evidence /tmp/dirt-overnight-coarse-unknown162 and /tmp/dirt-overnight-hosted-unknown162.

Control: Dirt/Balanced/Balanced with unknown enabled completes all3 locally, proving the Clean transition distinction, but leg1 has3491m repeated road and leg3 has291.77m. These are completions, not full ride-quality passes. Evidence /tmp/dirt-overnight-coarse-unknown-balanced162. Next investigation: locate the3491m circuit in the selected Dirt candidate and inspect existing fuel approach refinement. For Clean handoff, investigate a bounded departure back over previously supplied unknown-road history to the known network, with directional/turn/fuel proof and no global access relaxation; do not implement unqualified permission exceptions. The prior leg may need shared waypoint planning instead.

Only benchmark parameter support changed (REBUILD_MULTI_UNKNOWN); no service/runtime deployment or native change. Stable remains93826d3137c6c8fb05eba3e8f86ad145de2c293f/BOTH02. Existing zoom-persistence and full-itinerary context limitations remain. Continue from these new findings rather than replaying the already-qualified baseline next tick.

## Overnight fresh-route fuel repetition refinement — local

The3491m repeated-road case was not receiving the optional shared-pool refinement because it was a fresh route. Enabling the existing refinement alone still hit its400000-label cap. For optional fresh Dirt objectives only, a heuristic weight3 focuses the search enough to remove all3491m, retaining about79.58%known dirt (previous79.78%). Existing time/work/label limits and continuation heuristic stay unchanged. All profiles refine the same potential-winner pool. A candidate is replaced only if repetition strictly decreases without increased urban/avoidance exposure; a failed or non-improving refinement preserves the original fuel-proved route. No saved geometry changes.

187 focused tests pass. The coarsepins unknown162km Dirt/Balanced/Balanced fixture removes the first-leg repeat; add REBUILD_MULTI_FIRST_REPEAT_FREE=1 to make that a regression assertion. The final291.77m repeat remains unresolved and is not claimed removed. Clean-after-unknown departure remains a separate open issue. Stable93826d unchanged pending final local and hosted qualification.

The residual291.77m case is now located: the rider waypoint projects204.23m along w280666207:88884:88883 (496m full edge). Node88883 has exactly one incident graph edge; node88884 has two. The departure continues291.77m to that dead end before returning, reflecting the current no-invented-mid-edge-U-turn arrival rule. It is not another fuel-station circuit. Whether rider waypoints should authorize a mid-edge reversal requires an explicit routing contract and turn/direction tests; do not erase this geometry without those checks.

## Failed private qualification — keep stable93826d

Private bc639776757ebed32fe839f106b5a54578910d9b (worktree3d6553b) removes the targeted3491m repeat, but is **NOT qualified for publication**. All15 hosted requests completed within their existing broad checks; direct comparison exposed near-Dalhousie repeat increasing471→1163m and server time rising to19.751s from roughly8s. Dirt share dropped62.36→61.63%. A per-objective refinement can reduce its own repetition but change surface ranking enough to select a different, worse candidate. Preserve stable93826d/BOTH02. Owner explicitly notified not to promote this preview.

Evidence /tmp/dirt-fresh-hosted-{target,baseline,finalfuel,hooks,nb}. Add REBUILD_STRICT_NB_REPEAT=1 to the live device regression runner to enforce the qualified near-Dalhousie471m ceiling (the older broad2km check alone was insufficient). Runtime worktree3d6553b remains an unqualified experiment; do not mistake clean commits or completed fuel tests for acceptance.

Next bounded work: before accepting an optional candidate replacement, re-rank the whole shared pool for Clean/Dirt/Balanced and reject replacements that increase any profile winner’s repeated-road distance or urban exposure. Preserve shared pool parity. Also investigate a shared optional-refinement time allowance rather than up to4s per winner, to avoid slowing accepted fresh NB routes. Test the3491m target and strict near-Dalhousie comparison locally/private before any publication. If the experiment cannot satisfy both, discard it and retain the current qualified runtime. Clean-after-unknown, per-waypoint zoom persistence, and whole-itinerary context remain open.

## Shared winner guard — local qualification, September 9

Optional repetition refinements now re-rank the shared pool for all three styles before accepting a replacement. Reject a replacement if any resulting style winner has more repeated road distance or urban/avoidance exposure. This prevents the near-Dalhousie regression where improving one objective exposed a worse winner. Fresh-route optional refinements share one four-second allowance, prioritizing the largest repeat; continuation limits remain unchanged. The directed fresh refinement experiment remains private until hosted qualification.

189 focused tests pass. Local coarsepins Dirt/Balanced/Balanced, unknown enabled,162km usable passes all three legs and removes the first3491m repeat; final291.77m remains. Strict near-Dalhousie retains its accepted471m repeat (7.444s local). Full Inverness/Yarmouth six-primary-leg regression passes with fuel carry, joins and full pools. Evidence /tmp/dirt-winner-guard-{target,nb,baseline}. Stable DEV93826d remains unchanged pending private qualification; no native parity implementation is claimed. The failedbc639776 preview must not be promoted.

## Winner guard private qualification — source56308d4, publication held

Private https://pack-fabric-q194y7yik-goricksmith-7678s-projects.vercel.app (56308d4f9d45d74c72be1065f87213e68725f819, runtime23bd403) passed15 hosted requests after isolated retry: target3, baseline6, device4 including strict471m near-Dalhousie, final-fuel1, NS-hooks1. Exact source and Atlantic02 identities checked. All runs preserve required fuel/geometry assertions. Target first repeat is0; final291.77m remains.

Initial concurrent test batches produced one Clean final-fuel deadline at20s. The identical isolated request passed13.772s. Isolated near-Dalhousie passed13.927s; immediately subsequent stable93826d control passed18.525s. Thus current timings do NOT establish a refinement-induced slowdown; latency varies and concurrency is a possible contributor, not a proved cause. Do not infer a speed regression from the earlier19.778s concurrent private run. Keep stable93826d while checking reproducibility/performance before promotion. Owner has been told to hold alias. Evidence /tmp/dirt-winner-hosted-{target,baseline,nb,final,final-isolated,hooks,nb-isolated} and /tmp/dirt-winner-stable-nb-control.

Next overnight pass: perform controlled sequential comparison of the Clean final-fuel and near-Dalhousie cases, or otherwise investigate request-budget variability before any promotion. Do not weaken fuel/pool assertions or blindly enlarge budgets. If qualified, request owner promotion then independently verify public source/target/regression. Existing Clean-after-unknown departure, native per-pin persistence and broader itinerary-history limits remain unresolved. Automation remains active through08:00 Halifax handoff; no user input needed.

## Controlled follow-up 04:11 UTC

Clean final-fuel timed out on an isolated private request and on accepted stable93826d immediately afterward. Subsequent alternating private/stable/private/stable results: complete13.974s, unknown20.034s, complete14.015s, complete14.345s. Existing stable also exhibits this intermittent deadline; simultaneous tests are not its sole cause. This remains a reliability issue, not claimed fixed by winner refinement. The private refinement preserves the accepted route whenever this query completes.

New local coarsepins Balanced/Cleanest/Dirt180km passes all three legs with zero within-leg repetition, fuel carry and joins. Initial test invocation used invalid API profile clean; corrected to cleanest and added an explicit benchmark profile assertion. Invalid invocation is not a runtime failure or counted pass. Evidence /tmp/dirt-overnight-coarse-bcd180-corrected and /tmp/dirt-serial2-*.

Based on prior15 private hosted checks, strict NB quality comparison and controlled baseline comparison, requested owner promotion of exact56308d4/q194y7yik with93826d rollback retained. Public verification pending. This advances the3491m repetition fix only; existing intermittent Clean deadline,291.77m rider-deadend return, Clean-after-unknown transition and native context/pin persistence remain open.

## Public winner refinement qualified — 56308d4

StableDEV exactq194y7yik/source56308d4f9d45d74c72be1065f87213e68725f819 now independently passes public coarsepins Dirt/Balanced/Balanced162km unknown-on (three legs) and strict near-Dalhousie471m ceiling. Source/BOTH02 identities, full pools, fuel carry, geometry joins and escape verified. Evidence /tmp/dirt-winner-public-{target,nb}. Runtime23bd403; rollback93826d retained. New device handoff prepended to ROUTING-DEVICE-CANARY.md. No native/production/GitHub/pack changes; no physical acceptance claimed.

Continue overnight on the intermittent Clean deadline and other documented gaps; do not repeat completed basic qualification without a new reason. Deadline also occurred on prior93826d, so it is not attributed to winner refinement. Current latest stable is56308d4, superseding the earlier hold notices. Automation remains active until08:00 Halifax handoff.

## Concurrent Atlantic data loading — local, not deployed

Covered cross-province canary requests start independent NS/NB graph+fuel loads concurrently, retaining requested region order and rejecting any load failure rather than returning a partial list. Joining, pack identity checks, arrival/fuel/access contracts and the20s deadline are unchanged. New debug timings separate data loading/joining, candidate search, and response assembly. This targets avoidable serial I/O; no claim yet that it fixes the intermittent Clean deadline.191 focused tests pass, including load ordering and failure propagation. Private hosted qualification required before stable promotion. Stable56308d4 remains protected.

## Private load timing result — 42f1580, stable unchanged

Private3qcxx4vn1/source42f158025d12805ecb716317fc931ccad20fd6f0 cold Clean final-fuel returned unknown at20s: data/join8.583s, search11.417s. Subsequent identical requests passed15.123s and16.639s with data16–17ms. All three target coarsepin legs also pass. Concurrent region loading alone is not a qualified deadline fix. Stable56308d4 remains unchanged. Evidence /tmp/dirt-load-timing-final-{1,2,3} and /tmp/dirt-load-timing-target.

Add detailed per-region elapsed time plus join time/cache-hit diagnostics to distinguish remote loading from seam joining on the next cold request. This adds diagnostics only to the private experiment, not route-rule changes. Existing fuel/identity/deadline controls unchanged. Do not promote the experiment solely because warm requests pass.

## Cold-start bottleneck isolated — c1558c6 private diagnostics

First cold Clean final-fuel on privatejq5k0bm8i/sourcec1558c64f5df0d36f1bedcfc40333edfe2ba23e7 failed at20.011s. Regional loads overlapped: NB1.270s, NS1.902s; seam join5.921s (cache miss); total data7.922s, search12.089s. Evidence /tmp/dirt-join-timing-cold/clean-final-fuel-response.json. The measured dominant extra startup cost is joining, not the regional fetch sequence. Do not promote concurrent-loading-only experiment as a timeout fix. Stable56308d4 remains protected.

Next bounded optimization: inspect join-v4.js construction, especially allocating a Map per node for adjacency. Consider typed-array CSR assembly with per-node small-degree deduplication, preserving exact node/edge IDs, arc order, duplicate checks, restrictions, geometry and source aliases. Before changing, capture a full realNS/NB join structural digest; after changing compare all arrays/IDs/aliases/restrictions and run join/topology tests. Then private cold Clean and accepted regressions before any promotion. Keep20s deadline/fuel proofs unchanged. Worktree65e0b99 includes unpublished concurrent-load+timing experiment; stable runtime remains23bd403. No running tests or pending publication. Automation remains active for further overnight work.

## Exact-equivalent seam join optimization — local

Replace per-node adjacency Maps with bounded typed-array adjacency assembly and local duplicate checks; store a single canonical edge directly, allocating a peer list only for collisions. Preserve insertion order/Map.set behavior, exact node/edge IDs, source aliases, geometry, metadata, restrictions and duplicate validation. Full NS/NB structural digest matches old join: b70d296b3daaeb7f1ccbc29eb2777d0558a91005aac9e43d9ffbab930233a4b4 (353088nodes,416884edges,739038arcs).191 focused tests pass.

Separate-process local three-run medians: old1085ms vs optimized950ms; first runs1142ms vs894ms. Sampled process resident memory also fell, but these are local measurements, not hosted guarantees. Evidence /tmp/dirt-join-compact-{comparison,times}. Reproducible structural comparator bench/compare-atlantic-join.js accepts REBUILD_PACK_ROOT and JOIN_BASELINE_FILE (trusted earlier join module). Runtime is layered on unpublished concurrent-loading/timing commits; stable56308d4 unchanged pending private cold-request and regression verification. No deadline extension or fuel/access changes; no native parity implementation claimed.

## Hosted join optimization measured — private1219bd4, held

Private8yw9uif1f/source1219bd43b1ce6cb4466d3b7aa953b67247e7c7eb first cold Clean still hit20s. Data5.783s (NS1.550s/NB0.986s concurrent; join4.160s), search14.217s. Previous diagnostic cold join was5.921s. Useful measured join reduction, but NOT a completed cold-timeout fix.191 adventure +22 topology tests pass. All six private Inverness/Yarmouth primary legs pass with exact geometry AND fuel-stop IDs matching qualified56308d4, full pools/carry/joins/escape and BOTH02/source verified. Times8.247/1.825/16.740s and4.783/2.374/13.033s. Evidence /tmp/dirt-join-optimized-{cold,multi}.

Keep stable56308d4; do not promote this performance experiment yet. The cold search spent9.242s on paved (including6.176s search/advisory and accepted22703m→0 fuel approach refinement), then1.342s dirt10,1.281s dirt30,1.674s mixed2; expired during mixed3. Thus full shared pool still needs more cold budget headroom. Next investigate avoiding redundant search/preparation or a bounded faster paved-approach refinement while preserving the accepted Clean backroads geometry/quality. Do not skip core candidates, weaken fuel proofs, extend20s or silently switch engine. Current worktree45bd1c8 runtime includes unpublished9ca48b7/65e0b99 load/timing experiments; stable remains23bd403. No running tests/pending promotions. Owner notified to hold. Automation active through morning.

## Fresh fuel-first qualification — local

Directed paved-approach heuristic experiments at weights5 and4 failed the zero-repeat Clean regression (22.703km repeated). Both experiments were discarded; no heuristic weight change remains. Instead, fresh legs now use the existing fuel-first orchestration already used for continuations. The advisory road search is performed only if fuel routing cannot be proved, eliminating redundant pre-search while preserving the same shared objective pool and hard constraints.

191 tests pass, including existing fuel-first search equivalence coverage. Local Clean final-fuel completes5.793s with exact accepted586.9725km geometry and zero repeat. All six Inverness/Yarmouth primary legs exactly match previous qualified geometry; coarsepins unknown162km Dirt/Balanced/Balanced three-leg target passes including first-repeat0. Evidence /tmp/dirt-fuel-first-fresh-{final,multi,target}. Added finalfuel case to local replay benchmark. Combined with unpublished join/loading optimizations, private cold qualification is next. Stable56308d4 unchanged. No native parity implementation or timeout-fix claim yet.

## Fresh fuel-first hosted result — 82ac4c1, held private

Private dto4bulvk/source82ac4c1878cacc6a45c0ea9e8c2e6abbe578d1f9 passes15 hosted requests (coldClean1, baseline6, device4, hooks1, target3), exact source/BOTH02 and required fuel/quality checks. Six baseline geometries and fuel-stop IDs exactly match accepted routes. Earlier device cases completed6.164/8.266/6.832/6.528s. First coldClean passes18.159s (data5.143,join3.651,search13.013s).

Independent second untouched deployment fy0rnzzur, exactsame82ac4c1/config, still fails coldClean20s: data6.560s,join4.619s,search13.440s. This is insufficient cold-start headroom, despite the15 passes. No promotion; stable56308d4 remains. Evidence /tmp/dirt-fuel-first-hosted-{cold,cold2,multi,device,hooks,target}. No running tests or pending publication. More work remains; do not pause heartbeat yet.

Next investigate repeated reverse-bound preparation across shared candidates or other exact-equivalent work sharing. Avoid reintroducing rejected heuristic4/5 (22.703km repeat), dropping core candidates, weakening fuel/turn/access proof or enlarging20s deadline. Current runtime67bc630 includes private join/loading changes; accepted stable still23bd403. Overnight work should advance from this evidence rather than repeat all15 checks without a code change.

## Direct arc traversal for bound preparation — local

Reverse-cost preparation can visit projected/base road arcs directly instead of passing every arc through nested generators. Forward route search is unchanged. The direct visitor preserves arc order/projection fields and cancellation; generic graphs keep the iterator fallback. Identical full NS/NB reverse heads/from/next/cost digests for paved and distance-weighted costs. Five-run local medians improve approximately135→93ms and120→77ms. Evidence /tmp/dirt-visitor-{comparison,times}.192 focused tests pass including projected arc equivalence and visitor cancellation. Local Clean final-fuel retains exact accepted geometry with zero repeat in5.440s.

This is layered on private82ac4c1's join/loading/fuel-first changes. Stable56308d4 remains protected. Private cold request needed; do not claim fresh-load reliability from local speed measurements. No deadline, candidate pool, access, turn or fuel contract changes; no native implementation claimed.

## Direct visitor hosted results — private7117e36, publication held

First cold Clean jpq7s5aba/source7117e36bd8f5fd9a19a9344874c356c9a0221ee9 passes19.166s (data5.552/join3.931/search13.611s). Independent untouched ei9p3641t same source/config fails20s (data6.761/join4.795/search13.239s). Six baseline private geometries exactly match accepted output; device4, hooks and target3 checks pass.192 adventure +22 topology tests pass. Evidence /tmp/dirt-visitor-hosted-{cold,cold2,multi,device,hooks,target}. Stable56308d4 unchanged; owner told to hold. No running tests or pending promotion.

Next promising exact-equivalent join optimization: canonical duplicate-edge Map currently stores all416884edges, although cross-region duplicates are possible only when BOTH source endpoint nodes are shared. Mark shared nodes during the existing validated node-join pass; use canonical peer lookup/storage only when both endpoints are shared. Preserve node/edge ID strings, same-region parallel edges, sourcealiases, semantic/geometry conflict checks and all restrictions. Verify full structural digest against trustedoldjoin and measure before keeping. This could reduce allocation/hashing cold overhead without reducing candidate coverage or route quality. Current runtime20db121 includes private preceding join/loading/fuel-first experiments; stable remains23bd403. Do not reintroduce failed heuristic tuning or weaken20s/fuel/shared-pool constraints.

## Shared endpoint duplicate indexing — local qualification

Limit canonical duplicate-edge lookup/storage to edges whose two source nodes occur in multiple regions. The completed node pass establishes this before processing edges. Keep all source edges, IDs, geometry, aliases, same-region parallels, restrictions and cross-region conflict validation unchanged. Full real NS/NB structural digest matches the original trusted join: b70d296b3daaeb7f1ccbc29eb2777d0558a91005aac9e43d9ffbab930233a4b4; 353088 nodes,416884 edges,739038 arcs.192 adventure and22 topology tests pass. Separate-process three-run local median817ms versus preceding950ms and original1085ms; this does not establish hosted cold reliability. Evidence /tmp/dirt-shared-seam-{comparison,times}.json and /tmp/dirt-shared-seam-{tests,topology}.log.

Layered on private7117e36; private cold qualification next. Stable56308d4 remains unchanged. No route objective, deadline, candidate coverage, fuel/access/turn constraint or native code changes.

## Shared endpoint indexing hosted qualification —6cb2770

Privatepx2p5tl27 and independent untouched a25vvrcli, exactsource6cb27706cf0aa07d040c35ae278ecae984f754f2/runtime52c95b34: cold Clean passes19.378s and19.435s. Data4.983/5.494s; join3.441/3.579s; search14.392/13.938s. Accepted586.972545km,3pumps,0repeat preserved.16 hosted requests pass: two independent coldClean, baseline6, device4, hooks1, coarsepins unknown162 Dirt/Balanced/Balanced3. Exact source/releases asserted throughout; baseline6 geometry and fuel-stop IDs exactly match56308d4.192 adventure+22 topology pass. Evidence /tmp/dirt-shared-seam-hosted-{cold,cold2,multi,device,hooks,target}.

Requesting DEV promotion of exactqualifiedpx2p5tl27; rollback56308d4. This qualifies a measured performance improvement, NOT universal cold-start reliability: both cold runs have less than1s headroom. Follow with independent public DEV source/route checks. Production/native/GitHub unchanged.

## Public DEV performance publication verified

Owner promoted EXACTpx2p5tl27/source6cb27706cf0aa07d040c35ae278ecae984f754f2; no rebuild/config drift. Independent public coarsepins unknown162 Dirt/Balanced/Balanced3, strict near-Dalhousie and Clean final-fuel all pass, exactsource/releases/full pool asserted. Canary and parity authority updated. Rollback56308d4 retained. Production/native/GitHub unchanged.

No running tests or pending promotion. Continue overnight from qualified52c95b34 runtime; do not repeat baseline matrices without new changes/evidence. Cold headroom remains narrow despite2controlled passes; future useful work is profiling search reuse/preparation or additional genuinely different stress cases while preserving core pool/fuel proofs. Full-itinerary history and persistent per-pin intent remain native-contract limits, not solved by server guesses. Heartbeat remains active until morning08:00Halifax, then concise handoff/pause.

## Additional reverse/edited-waypoint stress batch — stable6cb2770

Benchmark now supports REBUILD_MULTI_REVERSE=1 and explicit REBUILD_MULTI_POINTS JSON, validates coordinates, preserves rider-selected Yarmouth pump refill by coordinate rather than ordinal, and asserts exact geometry joins between primary legs. No runtime change.

New local+hosted passes: reversedYarmouth180km usable Balanced/Dirt/Balanced,3legs929.511/365.521/597.310km at hosted9.553/2.796/6.665s; user's finaleditedpins180km Clean/Balanced/Dirt,3legs553.290/234.737/799.535km at1.588/3.349/7.754s. All6have0 within-primary-leg repeated road meters, exact adjacent geometry, full pool/fuel carry/escape assertions. Exactsource6cb2770 and releases02 asserted. Evidence /tmp/dirt-overnight-{hosted-,}{reverse-yarmouth180,edited-coarse180}. Whole-itinerary novelty is still NOT established by these within-leg metrics.

New reproducible failures: reversedcoarsepins162km usable Balanced/Dirt/Balanced completes first2legs, then fails third with dirt-30 label_limit (hosted9.832s, below20s). ReversedInverness180km allClean fails firstleg with dirt-30 label_limit (hosted11.688s). Shared full-pool gate properly prevents declaring complete when a core candidate is unproved. Both exact failing requests also fail on previous stable56308d4 with dirt-30 label_limit, so do not roll back the verified performance improvement for these pre-existing cases. Evidence /tmp/dirt-overnight-{hosted-,}{reverse-coarse162,reverse-inverness180}, /tmp/dirt-reverse162-previous-stable.json, /tmp/dirt-reverse-inverness180-previous-stable.json.

Attempted private LOCAL-only optimization: on label exhaustion, compute directed distance to any bound station/destination and prune provably dry labels in same-budget retry. Reversecoarse162still failed; both runtime file edits fully reverted. No deployment or retained fuel-bound helper. Stable runtime remains52c95b34/source6cb2770. Do not repeat this failed idea without new evidence.

Next priority: investigate dirt-30 label growth on the saved exact requests, maxFuelLabels400000 in live-canary, preserving shared candidates, fuel/turn/arrival proofs and20s budget. Search memory/frontier diagnostics may help distinguish low-fuel Pareto growth from approach history. Do not raise limits or drop candidates merely to pass. No active tests/pending owner actions. Heartbeat remains active before08:00Halifax; morning handoff must include these2new failure shapes.

## Continuation label-limit recovery — local qualified, private next

Trace on savedreversecoarse162thirdleg:400000 generated labels,220620expanded,160767statekeys,186852active,max frontier20; broad search rather than a single huge Pareto bucket. Exact uncapped reverse-bound retry did not solve either savedfailure and was reverted. Diagnostic console instrumentation also reverted.

A single directed retry (guidance3) with unchanged cost objective,400000labelcap, original20s/expansion budget recovers the continuation. Limit scope to non-paved CONTINUATIONS after label_limit; all profiles still evaluate the same core pool and cannot report complete without all fuel proofs. No fresh-route retry: experimental freshInverness recovery retained13723m fuelrepeat (approach refinement hit label_limit), so that behavior was rejected. Deferred winner refinement experiment provided no improvement and was reverted.

193 focused tests pass, including retry cannot bypass label limit/incomplete pool. Reversecoarse162full3legs now locallycomplete, all0repeat; local savedthirdleg variantsDirt/Balanced/Clean have identical recovered candidate surfaces/repeats and selected0repeat. Six baselineInverness/Yarmouth geometries ANDstopIDs exactly unchanged. Evidence /tmp/dirt-continuation-retry-{reverse162,baseline,dirt.json,cleanest.json,tests.log}; temptrace /tmp/dirt-label-trace.err. Stable6cb2770 remains while private qualification runs. FreshreverseInverness180 remains open; do not retry that rejected fresh heuristic expansion.

## Continuation retry hosted qualification —4da3822

Privatebz4kvcmdt/source4da3822dd7d37f6dde7720d61668aba1d7e883f8/runtimecfc8c3d passes19hosted requests: exact savedfailedcontinuation cold1, fullreversecoarse162chain3, savedDirt/Clean2, baseline6, device4, originalwidepin target3. Exactsource/releases/fullpool asserted. The formerly failing savedcontinuation completes14.326s coldBalanced,9.919s Dirt,11.142s Clean. All3selected0repeat; recoveredcandidate pool identical acrossstyles; Balanced49.750%dirt, Dirt52.666%dirt, Clean99.865%paved. Sixbaseline geometries+stopIDs exactly matchstable6cb2770.193adventure+22topology pass. Evidence /tmp/dirt-continuation-private-*.

Requesting exactqualifiedDEV promotion, rollback6cb2770. No fresh-leg recovery: reversedInverness180stillunresolved. Other open nativehistory/per-pin/unknown-arrival limits remain. Bench replay-saved-fuel.js preserves exact request history/fuel, verifies exactsource/release, stage joins/range/escape/fullpool and independent repeated-road audit; optionalprofileoverride compares sharedpool. No production/native/GitHub changes.

## Public continuation recovery verified — stable4da3822

Owner promoted EXACTbz4kvcmdt/no rebuild, source4da3822dd7d37f6dde7720d61668aba1d7e883f8/runtimecfc8c3d, same5regions02/ns-nb-v1. Independentpublic savedfailure1/reversedcoarse162chain3/originalwidepinunknown162target3 allpass, exactsource/releases/fullpool asserted. Recoverycase and entire reversechain0withinlegrepeat; originaltarget retainsknown291.77m fixeddeadendreturn only. Canary/parity authoritative docs updated; rollback6cb2770 protected. No production/native/GitHubchanges.

No active tests/pendingowner actions. Currentunresolvedfirstleg reverseInverness180: freshheuristic3 core recovery obtainsfuelroute but13.723km fuelrepeat; approach-history refinement hitslabel_limit. Do NOT reintroduce rejectedfreshretry/deferredwinner/exactbound/fuelreachability experiments unchanged. Continuationonlyretry is qualified andpublished. Next useful investigation is bounded fuelapproach state growth for that exact savedfreshrequest, or new independent stress shapes. Priorlimits native30kmhistory/per-pin precision/unknownClean departure still apply. Keepovernight heartbeat activebefore08:00Halifax, then handoff/pause.

## Connected-start waypoint recovery — local qualification

Found a reproducible snapping gap: nearby isolated start-road candidates can occupy the12candidate slots while a connected eligible road exists within the allowed radius. Existing fallback widened only the destination and retained nonempty isolated start candidates. Add a component-filtered start query after an unsuccessful pair, first within the same radius and then during existing area expansion. Preserve destination candidates, fixed fuel start, exact incoming arrival history, access checks and radius ceiling; do not stitch components or add off-road geometry. Already-valid pairs stay unchanged. Diagnostic waypointSnap.startComponentRecovery exposes use.

197adventure+22topology pass. New fixtures prove recovery past a nearer prohibited road, fixedfuel/arrival immobility, crowdedisolated candidates within explicit1000m cap and rejection at500m. Sixbaselinegeometry+stopIDs exactstable4da3822. ActualNS case44.68986511230469,-63.84516143798828→44.764835,-63.340265 zoom11 failed currentpublic4da3822 endpoint_no_connected_candidate, now localcomplete0repeat with500.17m snap. Widercase44.40485763549805,-65.24667358398438→44.44,-65.09 zoom6.6 localcomplete0repeat with3205.16m start snap. Evidence /tmp/dirt-isolated-{near,wide}-request.json, /tmp/dirt-isolated-{near,wide}-after.json, /tmp/dirt-isolated-near-before.json, /tmp/dirt-isolated-start-{tests,topology}.log, /tmp/dirt-isolated-start-baseline. No pack defect/changes.

Longerroute from samewidepoint toPorters passes snapping but hits pre-existing freshfuel label_limit; do not claim that whole route fixed. Mappedpump destinationRinger'sGarage44.42898,-65.119876 correctly hits existing adventure_endpoint_refill_unqualified after proving a road; do not weaken that explicit endpoint contract in this snapping patch. Tests separating snap/fuel outcomes saved /tmp/dirt-isolated-{real,short}-after.json. Stable4da3822 remains until private qualification; no native/prod/GitHubchanges.

## Connected-start snapping private qualification —f2da612

Privatequ663xg1q/sourcef2da612ae73dd175123430391010b48f0d9408a7/runtime0496982 passes22hosted requests: near/wide realNS snapcases all3styles6, baseline6, originalwidepin3, recoveredreversechain3, device4. Exactsource/releases/fullpool asserted; independent start snap distance within maximum checked. All6newcase selectedroutes0repeat and sharedpools identical acrossstyles. NearBalanced firstcold6.871s; nearDirt/Clean3.332/3.243s; wideallstyles0.674–0.698s. Sixbaselinegeometry+stopIDs exactpriorstable.197+22localpass.

Currentstable4da3822 exactsame nearrequest fails endpoint_no_connected_candidate. Exactwide request on4da3822 expands end back toward isolatedstart then fails no_feasible_chain_in_matched_graph; new version chooses mainnetworkstart3.205km away and retains near destination projection. Evidence /tmp/dirt-isolated-{near,wide}-before.json and /tmp/dirt-isolated-private-*. Requesting exactqualifiedDEV promotion; rollback4da3822, no pack/prod/native/GitHubchange. Publicverification next.

## Public connected-start snapping verified — stable f2da612

Owner promoted exactqu663xg1q/sourcef2da612ae73dd175123430391010b48f0d9408a7/runtime0496982, no rebuild or pack/config changes. Eight independent public checks pass: near/wide snap cases2, original coarsepins unknown162 Dirt/Balanced/Balanced3, reversed known162 Balanced/Dirt/Balanced3. Exact source and Atlantic02 releases independently asserted for all8; replay scripts enforce shared full pool, fuel carry/escape and geometry joins. Both recovered cases and reversed chain have zero within-leg repeated road. Original chain retains only documented291.77m rider-dead-end return. Public near4.422s/wide0.620s. Evidence /tmp/dirt-isolated-public-*. Canary/parity authority updated.219 local +30 hosted checks qualify this change; no physical acceptance claim. Rollback4da3822 retained; no native/production/GitHub change.

No running tests or pending promotion. Overnight heartbeat remains active before08:00Halifax. Next useful work: bounded fuel-approach state growth on saved fresh reversedInverness180, or independent new stress shapes; do not repeat rejected fresh guidance/deferred refinement/reverse-bound/fuel-pruning experiments unchanged. Whole-itinerary history and per-pin persistence still require native contract work outside this cycle. Explicit endpoint-refill gate remains unqualified; do not weaken it as a snapping workaround. At08:00Halifax provide morning handoff and pause heartbeat.
