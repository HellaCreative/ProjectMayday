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
