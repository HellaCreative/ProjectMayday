# Selective routing-data loading — private experiment, September 10, 2026

## Decision supported by this experiment

Do not promote this paging adapter. Reusable spatial preparation improves first-route latency, and exact-range geometry reads sharply reduce read amplification. Demand-reading the current columnar topology preserves the tested results but makes these routes slower and does not reduce peak process memory. The current whole-graph join and reverse preparation prevent a genuinely expanding working area.

This is an investigation result, not a live fix, full routing replacement, or rejection of the expanding-area idea. Production, stable DEV, app files, packs and GitHub were untouched. Work remains at private checkpoint `bf8f740`; the accepted DEV checkpoint remains `139a173`. No Swift or Android behavior changed; these standalone benchmark tools have no Android counterpart.

## What was built

- A local exact spatial-index artifact derived from unchanged pack geometry. It retains the existing cell order, full-polyline bounds and broad-edge fallback. Its version and graph/geometry/fuel hashes must match; the runner also checks the artifact SHA before decoding it. It is disposable preparation, not a rebuilt or published map pack.
- An exact-edge geometry reader with LRU limits of 5,000, 10,000 or 30,000 entries and an independent 8 MiB coordinate-cache cap per source. An oversize edge is returned fully, uncached. Eviction never removes a road from the graph.
- A disk-backed V4 decoder exposing the same graph arrays, exact 64-bit OSM identities, directions, access and restriction records. It uses 8 KiB file pages with a separate topology cache budget of `64 × requested geometry entries` bytes, rounded down to whole pages. These are byte budgets, **not proof of a 5k/10k/30k complete-road working set**. Geometry capacity is divided between source regions for crossing tests. Restrictions and metadata remain resident.
- A fresh-process comparison runner with the original full-data baseline, indexed/full-data control, geometry-only paging, and geometry-plus-topology paging. Each mode repeats the same request using existing bounded preparation/station/reverse caches; NS also moves the destination.

All searches use the existing route engine, directional access checks, turn handling, profile objective and fuel proof. The adapter never clips to a corridor or changes the available road network. The crossing test still runs the existing full join: it does **not** demonstrate lazy region joins.

## Baselines and qualification limits

Routing Agent -08 independently confirmed NS and NB local graph/geometry/fuel identities against `verified-pack-revisions.json`, release `fabric-v4-20260909-02`. Every benchmark process also hashes all three files. Exact identities are in the attached JSON results. The runner checks geometry against the graph's embedded SHA. Verification reads **all source bytes**; a smaller resident cache is not evidence of selective network download.

NS: `(44.76481,-63.34024)` → `(45.39330,-62.18066)`, 162,000 m usable fuel. The edit moves the destination to `(45.38,-62.2)`. Original route: 219,193.682342 m, one planned pump.

NS/NB: `(44.764804,-63.340199)` → `(47.013162,-65.244265)`, 180,000 m usable fuel. The fixture comes from a successful hosted crossing, but this runner deliberately retains the previous harness's single `dirt-30` objective instead of claiming to reproduce the live candidate pool. Its full baseline is 571,611.545427 m with three planned pumps; it is a different road/pump selection from the accepted hosted result. Passing/repeated-route advisory flags are off for this NS/NB test, as advised by Routing Agent -08.

Every compared road, planned refill and destination-escape signature matches its own full baseline, including NS destination edits. Fuel state is `provisional_station_access`: the planner completed range coverage using legal road projections, but this is **not** verified forecourt access or full device qualification. No background task is used to repair a returned proof.

Quebec was not used to qualify fuel: the preceding full Quebec benchmark already hit `label_limit`. Its old staging copy is not an acceptable current baseline. No West Virginia success or large-region scalability is claimed.

## Measurements

Node v22.17.0, local macOS disk, one fresh process per mode. Each process includes an explicit collection before the measured route, but OS filesystem cache is not flushed. “First” means a fresh application process, not a cold physical disk. Peak RSS covers the whole process including load and all repeats/edits; it includes indexes, labels, output and allocation overhead. Milliseconds are single observed samples, not statistical performance guarantees. Each table uses its own contemporaneous full baseline.

### Geometry and persistent spatial preparation — NS

| Mode | Load + first route (ms) | Repeat (ms) | Edited destination (ms) | Peak process (MiB) |
| --- | ---: | ---: | ---: | ---: |
| full | 672 | 172 | 221 | 240 |
| indexed-full | 524 | 172 | 220 | 237 |
| indexed-5000 | 851 | 170 | 347 | 219 |
| indexed-10000 | 939 | 172 | 223 | 217 |
| indexed-30000 | 769 | 165 | 228 | 233 |

The preparation artifact is 8.40 MB and took about 210 ms to build locally, including validation/load. The first-route benefit appears only when it is reused: full + index improves total time from 672 to 524 ms. Charging the initial artifact build makes the first-ever total about 734 ms. The index remains fully resident; it does not yet provide demand-loaded spatial metadata.

Paged first-request geometry reads are 2.20–2.57 MB, plus 0.88 MB of offset metadata. The earlier 1,000-edge page harness reread 507–638 MB during the first route. This comparison excludes each process's full-file integrity pass. The new exact-edge reader needs roughly 55k–65k tiny read operations, explaining why the lower volume does not deliver lower latency. The 5k/10k cache's lower RSS here is not universal.

### Geometry and persistent spatial preparation — NS/NB

| Mode | Load + first route (ms) | Repeat (ms) | Edited destination (ms) | Peak process (MiB) |
| --- | ---: | ---: | ---: | ---: |
| full | 1272 | 153 | — | 304 |
| indexed-full | 1029 | 156 | — | 338 |
| indexed-5000 | 1477 | 164 | — | 327 |
| indexed-10000 | 1726 | 170 | — | 325 |
| indexed-30000 | 2681 | 175 | — | 326 |

The joined spatial artifact is 15.94 MB, built in about 593 ms including full source loading/joining. The join still takes about 270–278 ms per fresh worker. First-request geometry read volume is 4.13–4.85 MB, but the random per-edge cache is slower; the 30k case is especially poor. Memory is not consistently improved.

### Demand topology plus geometry — NS

| Mode | Load + first route (ms) | Repeat (ms) | Edited destination (ms) | Peak process (MiB) |
| --- | ---: | ---: | ---: | ---: |
| full | 683 | 185 | 237 | 234 |
| demand-5000 | 4458 | 651 | 2792 | 242 |
| demand-10000 | 4410 | 483 | 2766 | 248 |
| demand-30000 | 3794 | 426 | 2361 | 328 |

First-route topology reads reach 3.40 GB / 2.30 GB / 0.86 GB for the 5k / 10k / 30k labels, respectively, against a 15.01 MB graph file. The numeric columns are separate, so alternating endpoint/access/cost reads repeatedly displace pages. The graph page caches stay below approximately 0.32 / 0.64 / 1.92 MB, but those tiny cache totals do not bound the process's retained indexes, search labels or allocation peak.

The repeated request hits existing preparation, station and reverse caches. Moving the destination preserves spatial/station reuse but invalidates projected reverse preparation, visible as `reverse:false` in the results. This is evidence for separating reusable base topology from per-request projections, not for reusing an incompatible cached result.

### Demand topology plus geometry — NS/NB

| Mode | Load + first route (ms) | Repeat (ms) | Edited destination (ms) | Peak process (MiB) |
| --- | ---: | ---: | ---: | ---: |
| full | 1293 | 157 | — | 301 |
| demand-5000 | 3610 | 158 | — | 413 |
| demand-10000 | 3959 | 165 | — | 416 |
| demand-30000 | 4159 | 156 | — | 425 |

The full join copies road topology into joined arrays. Demand reading therefore slows the join to about 1.97–2.43 seconds and then still leaves a resident joined graph. Its fast second route is not evidence of selective topology during search. Source topology reads reach roughly 239–492 MB by the end of the first request, and RSS is worse than the full-data control.

## What must change for expanding areas to be worthwhile

1. **Separate immutable preparation from request state.** Persist a compact spatial directory, exact border alias/duplicate information, and incoming adjacency once per verified source identity. Current `createPreparationCache` already protects pack/geometry identity; it is process/instance-local. Persisted artifacts must also bind algorithm version, source epoch and all safety inputs, and reject incomplete generation. Count build, load and storage costs independently.
2. **Stop joining every source road upfront.** Keep region-local IDs and resolve boundary transitions through complete exact OSM identity/alias evidence. Restriction sequences must retain their canonical edge identity across evictions and overlaps. Near coordinates and bounding-box adjacency are never substitutes. No implementation or correctness qualification of this lazy join exists yet.
3. **Avoid reconstructing reverse adjacency per request.** `prepareReverseCosts` visits every source node and allowed outgoing arc; `buildLowerBounds` also allocates a graph-sized distance array. Store reusable incoming adjacency and apply the selected costs as traversal reaches it. Handle endpoint/pump split edges as request overlays, with correct reverse arcs. Reuse only when the relevant cost, projection and graph identities match; do not silently weaken or omit the bound.
4. **Make both search frontiers demand-driven.** Load neighboring data whenever a frontier reaches unloaded territory, including outward widening and backtracking for restrictions, obstacles or fuel. The complete directory must distinguish absent roads from missing pages. Completion must follow the selected search's proof conditions, not exhaustion of loaded pages. Deadline, I/O failure or an unresolved required boundary remains incomplete/unknown, never a no-path/fuel-gap proof.
5. **Keep fuel and legal evidence complete.** This experiment intentionally retains all fuel records and restrictions. Paging either requires an exact, complete index and continuation history across pages, plus destination escape before completion. Loading more detail after returning a result can assist the next edit only; it cannot validate the previous result retroactively.
6. **Measure locality and retained memory together.** Try bounded reusable read buffers and coalesced source ranges after eliminating global preparation. Test spatially grouped access without reauthoring the immutable road bytes. A larger LRU alone is not a demonstrated solution. A strict road-entry limit also needs an independent byte limit for variable-length geometry and request search state.

These are proposed next experiments, not accepted changes to route behavior. The current evidence supports reusable preparation first; it does not support promoting either paging reader or deploying an always-running service.

## Infrastructure implications

This work used local file reads only. No hosting, request-charge or network-latency saving was measured. A direct mapping of tens/hundreds of thousands of small reads to remote range requests would add that many request/latency events; it should not be used without range coalescing and a local cache. Cached artifacts add at least the measured 8.40 MB (NS) / 15.94 MB (NS+NB) spatial files plus their resident decoded representations; proposed reverse and border indexes are additional and unmeasured. Fresh workers must obtain/validate those artifacts. Warm-process savings cannot be assumed across workers, restarts or evictions. No extra service was provisioned and no pricing estimate is claimed.

## Checks and reproducibility

247 focused tests passed: existing adventure suite plus four new paging/index tests. The new tests cover exact geometry after eviction, oversize-edge handling, missing/truncated geometry failure, spatial query order including crossing roads/poles, all V4 columns and >2^53 IDs through disk paging, directional eligibility and a blocked turn after eviction. Existing adventure regressions cover fuel, border joins and restrictions. The two real-data comparisons and the destination edit provide road/refill/escape equivalence evidence for these fixtures only.

Run from the private worktree. The runner creates only local output and `.index` files. It defaults to all eight modes and automatically checks each result against the full baseline.

```sh
node --test scripts/pack-fabric/bench/working-set.test.js scripts/pack-fabric/routing/lib/adventure/*.test.js
PAGING_EDIT_ANCHOR='{"lat":45.38,"lon":-62.2}' node scripts/pack-fabric/bench/compare-selective-loading.js /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs/ns /tmp/dirt-selective-ns.json
PAGING_ANCHORS='[{"id":"a","lat":44.764804,"lon":-63.340199},{"id":"b","lat":47.013162,"lon":-65.244265}]' PAGING_USABLE_METERS=180000 PAGING_OPTIONS='{"allowPassingRefillAdvisory":false,"allowRepeatedPassingRoute":false}' node scripts/pack-fabric/bench/compare-selective-loading.js /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs/ns,/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs/nb /tmp/dirt-selective-nsnb.json
```

The recorded cohorts used `PAGING_MODES=full,indexed-full,indexed-5000,indexed-10000,indexed-30000` or `PAGING_MODES=full,demand-5000,demand-10000,demand-30000`. Each test process uses the same 120-second/200-million-work-unit allowance as the prior harness. These are measurement allowances, not live deadline changes. The source-identity file records the checkpoint and new benchmark source hashes; JSON results retain all source-byte identities and observed metrics. The demand decoder and persisted spatial index are explicitly private copies of current reader/index logic; their oracle tests must accompany any future upstream change.
