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
