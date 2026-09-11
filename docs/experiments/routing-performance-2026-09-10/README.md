# DIRT route preparation experiment — owner review candidate

The experiment produced a worthwhile, opt-in JavaScript preparation candidate. It improves regional and multi-region routing speed without removing roads or changing the routing objectives. It is **not** a completed geographic “fog of war” loader, and it is **not** ready for unrestricted national rollout: repeated hosted NS→West Virginia remains unreliable at the private runtime's 4 GB ceiling.

This is completion under criterion A: implemented improvement, applicable correctness/performance qualification, and a concrete review candidate. It does not claim criterion B or that all architectural alternatives have been exhausted.

## Candidate and protected checkpoints

- Core candidate: `571123c9b40fb2d58833abc2678576a89ce36ad9`, opt-in `DIRT_ROUTING_PREPARATION=compact-v4`. Default remains off.
- Private preview: `dpl_FhamX9tXkSUHFbM6KTyhnLjpA9Ei`, <https://pack-fabric-bg6e3eazd-goricksmith-7678s-projects.vercel.app>.
- Matched private baseline: `dpl_aC3VKkDXJHngsztXn66mnzyDgcEP`, source `8b83ee7`, preparation off. URL: <https://pack-fabric-dtbay1q8u-goricksmith-7678s-projects.vercel.app>.
- Accepted DEV source: `139a17340d705c7e1ed7d9505943802234135802`; accepted preview <https://pack-fabric-gez7gslte-goricksmith-7678s-projects.vercel.app>. Stable DEV <https://pack-fabric.vercel.app> was not changed.
- Private pre-experiment repair: `bf8f740509b7448373a3bb24e46f11bca6968c7a`. This includes prior region/join repairs and must not be confused with accepted DEV. Main app checkpoint `91cc3cc` is preserved.
- Intermediate checkpoints: `1807e0c` rejected paging diagnostics; `5700968` shared guidance/neutral turns; `8b83ee7` immutable runtime reuse; `eff863e` compact alternatives; `d027615` join scratch retention fix; `86d1544` deferred legacy grid; `571123c` exact compact bounds/request scratch.

All work is local or in isolated private previews. No production change, stable alias promotion, GitHub push, published pack rebuild/replacement, native installation or Apple delivery occurred. No paid infrastructure or always-running service was provisioned.

## What changed

1. Build one bounded immutable incoming-adjacency index, reuse it across objectives and projected endpoints/stations, and evaluate unchanged costs only when reverse guidance visits an arc. This removes repeated whole-graph reverse-cost construction.
2. Avoid restriction-state strings and cache entries for demonstrably neutral turns. Node and via-way restrictions still use the original transition logic.
3. Reuse a joined runtime before source reads only when ordered immutable source URLs and independently qualified graph/geometry/fuel identities agree. Clear obsolete preparation on a different source set.
4. Pack spatial memberships and exact node identities; store spatial bounds at float32 only when every value is exactly representable, otherwise upgrade losslessly to float64.
5. Defer the legacy snapping grid until a caller actually accesses it. The hosted loader previously built that grid before Adventure built its own index. The initial local engine benchmark omitted this cost; the later runtime model and private previews include the distinction.
6. Reuse request-owned guidance scratch between sequential objectives; release obsolete graph references from compatible cached bounds.

The incoming-index bound is 256 MiB, request scratch reuse is 128 MiB, and the source-reader model retains three regions. These are byte/entry limits on particular structures, **not a bound on total process memory**. An oversized scratch request bypasses reuse. Reverse storage exhaustion reports incomplete rather than silently omitting roads. Whole joined topology and geometry remain discoverable and resident in this candidate. No post-route background fetch is used to establish validity.

## Controlled results

Local Node 22.17.0; verified immutable release `fabric-v4-20260909-02`. The first two rows each use three fresh processes per variant, each with one process-cold and five warm requests. Variant order alternates. “Cold” includes local reads/validation/decoding, not a guaranteed empty operating-system disk cache.

| Local case | Baseline cold median | Candidate cold median | Baseline warm median | Candidate warm median | Warm reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| NS→NB Balanced, fuel | 2.529 s | 2.176 s | 1.502 s | 1.152 s | 23.3% |
| Long Quebec Balanced, road | 7.557 s | 5.695 s | 4.815 s | 2.911 s | 39.5% |
| NS→Ontario Dirt, road (one cold + one warm) | 29.434 s | 20.965 s | 31.979 s | 11.471 s | 64.1% |

Warm ranges are 1.467–1.642 versus 1.122–1.286 seconds for NS→NB and 4.799–4.888 versus 2.889–3.057 seconds for Quebec. All control proof signatures match the final case. See `controlled-timings.json` and `evidence/controls`.

Across the three six-request processes, NS→NB lifetime peak RSS was 422.6–423.4 MiB baseline versus 315.2–383.4 MiB candidate. Quebec was 996.1–1001.0 versus 889.8–890.5 MiB. The NS→Ontario two-request peak was **2229.5 versus 2289.8 MiB**, a regression despite the speed gain. No universal peak-memory reduction is claimed.

The NS→Ontario baseline's three-region source cache thrashes across four regions: each request reads 463,034,900 bytes and rejoins (3.23/3.51 seconds). The candidate reads those bytes once, then reuses the qualified joined runtime with no source rereads or join on the warm request. This is an actual read/preparation saving, not a count of displayed segments.

### Where the time went

Representative matched control requests, summed across objective candidates; milliseconds. These diagnostic sums omit some dispatch/refinement overhead and are not an exhaustive wall-time partition.

| Stage | Quebec warm baseline → candidate | NS→Ontario warm baseline → candidate |
| --- | ---: | ---: |
| Spatial/urban preparation | 0 → 0 | 6874 → 0 |
| Endpoint matching | 9 → 10 | 167 → 5 |
| Station matching | 21 → 18 | 0 → 0 |
| Projected graph | 44 → 51 | 74 → 72 |
| Reverse guidance | 2999 → 1894 | 10525 → 6852 |
| Forward search/advisories | 1711 → 911 | 9273 → 4526 |

NS→NB fuel geometry/proof assembly in that representative warm request was 17→13 ms; matching 17→17 ms. These were not the dominant costs. Compact spatial preparation has a cold construction cost: representative Quebec preparation 1868→2131 ms, offset by savings elsewhere. Per-source read, validation, decode and legacy-grid timings, per-candidate phases, response stages, retained heap/array buffers and lifetime RSS are preserved in raw reports. Hosted diagnostics separate fetch/decode from joining and search; cached source diagnostics describe the original load, not a new fetch.

### Private hosted comparisons

Both variants ran on the existing project's actual **4096 MiB, Node 24** configuration. Active CPU billing ignored the per-function 2048 MiB setting. Project settings were not altered. These results do not qualify the accepted 2048 MiB deployment. “First observed” does not assert an infrastructure cold start. Times below are server totals; raw reports also retain HTTP duration.

| Case | Baseline first / warm | compact-v4 first / warm |
| --- | ---: | ---: |
| NS→Ontario Dirt road | 65.949 / 63.181 s | 45.481 / 24.213 s |
| Ontario Balanced fuel | 62.782 / 46.477 s | 47.296 / 34.045 s |
| Quebec Balanced fuel | 34.336 / 25.526, 24.592 s | 27.628 / 18.958, 18.721 s |
| Accepted NS→NB, 180 km fuel | 4.979 / 3.574 s | 5.975 / 2.418, 2.356 s |

Short NS fuel also improved under the earlier shared-v1 candidate (baseline warm 1.277/1.081 s, candidate .660/.766 s). Latest partial-initial-tank replay completed at 1.308/.471 s. The accepted `139a173` NS→NB response matches the new baseline's full route/fuel proof; accepted-source parity is demonstrated for that saved case, not inferred for every region.

**West Virginia remains a failure.** Baseline/shared/compact/deferred private attempts were killed for memory. With deferred preparation, sampled RSS progressed from 1.216 GB after source load to 2.522 GB after joining, 3.328 GB after preparation and 3.968 GB after the first search. Latest compact-v4 had a separately preserved source `ECONNRESET`, then one complete 90.007-second retry with exact route proof and `alternativeSearchLimited=true`; its warm repeat was killed for memory after about 52.5 seconds. This is neither a reliable recovery nor full alternative-pool qualification.

## Correctness and test scope

- Final matrix: **45 distinct cases, all complete locally**; 44 full first-run proofs exactly match the selected baseline. Every repeated final-case proof is consistent within that case.
- Independent baseline-adapter replay passes all 45 cases, 62 windows and 89,115 segments: canonical edge identities, exact node continuity, directed access, node/via-way turn restrictions and continuation arrival state. The checker was corrected for a junction where the incoming road differs from the first outgoing road; a regression test confirms that a prohibited continuation turn is still rejected.
- Initial 24-case matrix: 144 complete requests (24 × two variants × three runs), all exact. Longer matrix includes Ontario, NS→Bangor, NS→Ontario, NS→West Virginia, NS→Alberta (6748.98 km), and BC→Yukon including a nine-stop fuel trip.
- All three profiles, fuel on/off, 162/180/220/378 km ranges, partial initial fuel, accepted deep and Clean windowed journeys, unknown-access policy and intermediate wander preference are represented. The full Cartesian product is not claimed. Geometry continuity, fuel range/escape checks, excluded stops and bounded continuation histories are recorded.
- Core focused suite at candidate checkpoint: **265 passed**. Final combined suite: **267 passed**, including the junction-audit regression and prepared-sidecar corruption/identity, exact seam restriction and metadata isolation checks.

The one legitimate difference is the accepted deep windowed Dirt journey: faster execution completes an existing four-second refinement in window 2. The third pump changes; the complete five-stop trip grows 131 m (0.0085%), with 180 m less dirt and 311 m more paved road, unknown distance unchanged. The full refined candidate removes 1237 m of repeated road. All five returned windows pass legal and fuel checks. This is disclosed rather than hidden as an exact match. Existing timeout-dependent selection remains a correctness/performance limitation.

Fuel coverage here means the existing mapped-station and range contract, including its provisional station-access status. It does not prove physical entrances or current fuel availability. Native parity and production concurrency have not been established.

### Bounded mixed workload

Each batch queued 48 requests: eight each of short NS Balanced road, long NS Dirt road, NS→NB Balanced road, long Quebec Balanced road, short NS Clean fuel and partial-initial-tank fuel. Static assignments balance estimated cost. Workers use natural collection, with no forced GC, and each worker has its own routing data. All 240 requests across original and control batches completed with reference proof signatures.

| Workers | Batch time | Observed requests/s | Sampled summed RSS | Batch completion p95 |
| --- | ---: | ---: | ---: | ---: |
| 1, clean control | 75.52 s | .636 | 1230 MiB | 67.01 s |
| 2, clean control | 42.36 s | 1.133 | 2386 MiB | 38.90 s |
| 4, original batch | 28.62 s | 1.677 | 2893 MiB | 25.77 s |

The original one/two-worker batches overlapped evidence archiving and were repeated without that interference; both sets are preserved. Four workers did not overlap that archiving. RSS is sampled every .2 seconds and can miss peaks or double-count shared pages; sum of per-worker lifetime high-water RSS is also recorded. The batch includes harness/proof overhead, and all work was queued at once. These percentiles are **not sustainable production p95**, and this is not a baseline-versus-candidate capacity comparison or hosted Fluid Compute qualification. Large WV-class concurrent requests remain outside the demonstrated capacity.

## Alternatives tested and rejected or held back

- Geometry LRU working sets of 5000/10000/30000 **geometry entries**, and separate columnar topology byte caches: smaller residency did not remove full-graph preparation. The topology adapter reread roughly 0.86–3.4 GB from a 15 MB NS graph and took about 3.7–4.4 s versus .65 s. Reject these adapters; do not conclude that genuine geographic loading cannot work. See the separate selective-loading experiment.
- Incoming guidance alone: speed benefits but a measured Quebec peak regression (1566 versus 1288 MiB in that component cohort). Retain only as part of the refined combined candidate with disclosed limits.
- Compact-v2/v3 alone: still hosted WV OOM. Deferment reduced load/preparation pressure but did not bound search allocation.
- Derived joined-runtime sidecar: implemented and tested locally from unchanged immutable bytes. NS→NB cold query 1.864 s, warm 1.150 s; 31.54 MB sidecar, 1.160 s build. WV cold 39.726 s, warm 30.866/32.890 s; 593.07 MB sidecar, 23.808 s build. It eliminates source-graph loading and request-time joining, and retained heap+typed buffers fall from an earlier baseline's 2635.4 to 1602.7 MiB. However observed peak is 3117.6 MiB, and sidecar+original geometry/fuel reads total about 1.015 GB. It is a reviewable prototype, **not** a peak-memory or hosted-performance fix. Separate full joins for arbitrary region combinations also scale poorly. No sidecar was uploaded.

The ten-family status and remaining credible architectures are recorded in `ARCHITECTURE-REVIEW.md`. Geographic/federated topology, exact seam directories, landmarks, hierarchy, numeric search labels and alternate engines remain open investigations. No fabricated benchmark or “all options exhausted” conclusion is offered.

## Review decision and recovery

The concrete review decision is whether to advance **compact-v4 as a gated incremental candidate within the demonstrated scope**. Unrestricted national promotion is not recommended. Stable DEV/production/native adoption is a separate owner decision, outside this experiment's authorization; this report is not requesting permission to finish ordinary local work.

Recovery starts in `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/fuel-health-repair`. Do not reset the accepted main checkout. The local branch `experiment/routing-preparation-20260910` preserves the evidence checkpoint with benchmark helpers, matrix, raw results and this report; core executable candidate identity remains `571123c`.

```sh
# Read-only input recovery, if temporary verified copies have disappeared:
python3 scripts/pack-fabric/bench/prepare-performance-packs.py docs/experiments/routing-performance-2026-09-10/evidence/immutable-catalog.json docs/experiments/routing-performance-2026-09-10/evidence/region-ids.json /tmp/dirt-performance-packs

# One meaningful repeated control; output to a new path to preserve evidence:
node --expose-gc scripts/pack-fabric/bench/compare-routing-preparation.js nsnb-balanced-fuel runtime-candidate /tmp/dirt-review-nsnb.json 6
node scripts/pack-fabric/bench/audit-performance-result.js /tmp/dirt-review-nsnb.json

# Focused checks:
node --test scripts/pack-fabric/bench/audit-route-proof.test.js scripts/pack-fabric/bench/prepared-joined-runtime.test.js
```

Prepared sidecars are retained outside Git at `/Users/richardsmith/.codex/experiments/routing-performance-2026-09-10/prepared-joins`; `/tmp/dirt-prepared-joins` points there. Adjacent receipts pin manifest/source hashes. To regenerate into a **new** directory, run `build-prepared-join.js nsnb-balanced-fuel OUTPUT_ROOT` or `build-prepared-join.js wv-road OUTPUT_ROOT`; the builder refuses to overwrite an existing artifact. Select it through `PREPARED_JOIN_ROOT` for the `prepared` benchmark variant.

To disable the candidate in a future authorized deployment, remove `DIRT_ROUTING_PREPARATION` or set it to `off`, then create a fresh deployment to discard process caches. No accepted alias was changed, so no live rollback is needed now. Deployment receipts and immutable input digests are in `evidence`; raw response bodies are compressed. Authorization headers are excluded. `/tmp` paths inside reports identify original runs; their durable copies are under the correspondingly named evidence subdirectories.
