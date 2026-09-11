# Private hybrid refinement — September 11, 2026

This is a worthwhile second private candidate following
`f3a10ffe10ae7f319af263073e7694bdbcb67afd`. It improves legal fuel excursions and
strict long-route search, and adds bounded service cancellation and JVM diagnostics.
It is ready for owner review as an engine experiment. It does not qualify the app,
full Dirt/Balanced/Clean behavior, physical fuel entrances, or commercial hosting.
Production, stable DEV, published packs, native builds and remotes are untouched.
No Android counterpart is changed by this private Java/Python implementation.

## What changed and why

Fuel repair now compares complete, certified itineraries from three bounded
policies: the existing same-node distance excursion; a legal downstream rejoin;
and a downstream excursion ordered by the original road objective. It retains
the lowest original-cost verified itinerary. Earlier fuel exploration is a
fourth retry only when the other policies fail. A failed refinement cannot
replace an already verified fuel chain.

Downstream rejoin uses actual graph nodes within the next three road edges and
at most 10 km of skipped road. Every traversed road and the incoming-to-next-edge
turn must be legal. No proximity connection, disconnected station connector, or
restriction bypass is invented. Arbitrary rider waypoints are not implemented
in this endpoint-only protocol; imported arrival history is explicitly rejected.

The excursion limit is 30 km of traversed road, with 25,000 labels per attempt.
The default 100,000-label allowance (maximum 500,000) applies to each repair
policy on each road candidate, not the whole request. Up to four policies and
three road candidates can be attempted within one shared 90-second deadline.
Destination-escape searches have their own bounded label allowance. These are
incomplete search limits, never evidence that a physical fuel gap is unavoidable.

Measured strict WV preparation/search took about 44 seconds while all repairs
took about one second. We therefore prepared stronger Landmarks (LM) guidance
on an isolated copy of the existing GraphHopper graph, using the pinned 500×
paved/unknown-surface cost and urban mask. CH remains disabled. Uniformly dividing
all internal costs by 1,000 avoids GraphHopper's landmark storage-factor overflow
without changing relative costs. Published pack bytes and the source graph were
not rebuilt or modified; eight copied base graph files retain identical hashes.

This stronger index is specific to that fixed mask/cost family. It is opt-in,
with a distinct descriptor/mask identity. It cannot be reused for unmasked or
cheaper request weights. The ordinary distance index remains available. A normal
product profile does not silently acquire the strict stress-test mask or costs.

The persistent service now subtracts queue time from request deadlines, limits
active workers to 1–4 and waiting jobs to eight, rejects overflow explicitly,
and supports running/queued cancellation without late successful responses.
JVM heap, mapped-buffer capacity, allocation and GC are reported separately.
See [diagnostic schema and protocol](HYBRID-DIAGNOSTICS.md).

## Measured comparisons

All results below are local disk, process-first followed by warm requests. No
OS-wide cache purge was performed. Comparisons are separate local runs, not
randomized hosted trials. Group RSS is sampled once per second and can miss peaks.

| Case | Previous hybrid | Refined candidate | Meaning |
| --- | --- | --- | --- |
| Strict NS→WV, first request | 48.0 s with refined repair and original LM; v1 50.2 s | 35.9 s with stronger LM | Same exact roads, stops and escape; about 25% less time than the 48.0 s control |
| Strong-LM strict WV repeats | — | 35.9, 29.8, 30.5 s; median 30.5 s | Three successful serial requests; no equivalent three-run warm control for a median speedup claim |
| Two simultaneous strict WV requests | 50.26 s each | 34.37 and 34.38 s | Same exact proof; about 32% less time in this local comparison |
| Shared-graph group peak | 3,263.8 MiB / 3.19 GiB | 2,931.8 MiB / 2.86 GiB | About 10% lower sampled peak in this workload; not a general memory guarantee |
| NS→NB dirt30 | 566.166 km; 299.952 km known dirt including escape | 569.536 km; 327.554 km known dirt including escape | +27.602 km dirt for +3.370 km route distance |
| NS→NB dirt30 median | 0.520 s | 0.512 s | Similar latency while improving character |

NS→NB used 180 km usable range and 90 km initial fuel. All four additive profiles
ran three times and passed independent fuel/source audits. New medians are
distance 0.167 s, paved 0.430 s, dirt10 0.504 s, dirt30 0.512 s. The paved and
dirt10 medians increased from 0.346/0.375 s as more repairs were compared; these
are quality improvements with some extra latency, not a universal speedup.
Paved distance fell from 594.896 to 588.086 km and dirt10 from 549.184 to
546.018 km; their original objective costs also fell. Sampled group peak was
549.7 MiB versus 564.4 MiB. Three repetitions do not establish a small memory win.

Strict WV is 2,743.056 km with 18 refills and a 3.417 km destination escape.
The benchmark explicitly supplies a full initial tank, 193,121.28 m usable
range (120 miles), and zero additional reserve. Seven refined/strong-index
serial/concurrent responses exactly match v1's steps and escape. Independent
audits carry turn state continuously through every refill; all pass. Six
strong-index mask audits find zero blocked edges. Route plus escape contains
1,363.828 km known dirt, 711.999 km paved and 670.646 km unknown surface.
Unknown surface is not counted as dirt. This is a first-feasible corridor
heuristic, not a proven optimum of the 500× objective.

The new Quebec long case passed all four objectives at 120-mile full initial
range. Distance/paved/dirt10/dirt30 took 4.64/1.63/4.18/7.23 seconds respectively;
all fuel and source audits pass. Group peak was 1,596.0 MiB. However, dirt10
contains 49.769 km known dirt, while dirt30 contains only 18.067 km (including
escape). Different fuel fallbacks cause this reversal. These results explicitly
reject treating penalty strength as complete DIRT product behavior. A shared
candidate pool and DIRT's final character ranking remain required.

## Memory and preparation evidence

The 48.0-second strict control allocated 4.068 GB cumulatively on its request
thread and sampled a 970 MB heap peak. The stronger index's first request
allocated 2.777 GB but sampled a 1.111 GB heap peak. Its three-run group peak
was 2,671.9 MiB versus the control's 2,414.2 MiB. Lower allocations therefore
do not establish lower peak memory. Both expose about 1.956 GB of mapped-buffer
capacity; this is a virtual mapping size, not resident pages or OS page cache.
Heap after a request still contains uncollected garbage. Process-wide GC deltas
include concurrent activity; they are not attributable to one request.

A separate NSNB idle diagnostic explicitly requested JVM GC and observed about
20 MiB used heap afterward. This is disclosed diagnostic GC, not an ordinary
request timing, whole-process retained-memory measurement, or OS cache purge.
No CPU throttling, hosted cold-cache behavior, precise mmap bytes read, or
500-client acceptance is established. Two long requests completing together
still offer modest throughput; the queue contains demand, it does not create
capacity. No warming daemon, GPS collection or paid infrastructure was added.

Stronger landmark preparation took 176.1 seconds and 2,337.3 MiB sampled group
peak. This is a one-time private search-index cost, separate from routing and
from the original graph import. The original WV import's peak was 3.76 GiB;
the previously cited 2.43 GiB was a request measurement, not import memory.

## Rejected approaches and experiment integrity

- Broad early fuel plus objective exploration regressed NSNB, including a
  distance case exhausting its allowance. Keep early exploration as a failed-
  policy retry, not a universal trigger. A synthetic fixture confirms that some
  routes nevertheless need an early off-road pump.
- Downstream rejoin alone improved NSNB but broke the formerly successful WV
  fuel chain. Comparing whole verified itineraries and retaining the incumbent
  fixes that regression; locally shorter is not necessarily globally feasible.
- Multiplying the existing distance landmark bound for scalar candidates saved
  less than 1% of visited nodes and added overhead (52.6 s first corrected run).
  It remains an opt-in rejected experiment, disabled by default. Two completed
  runs were retained; the third was intentionally interrupted after diminishing
  returns. That guard exit is not a router timeout.
- The first strict-index preparation failed at GraphHopper's integer storage
  factor limit, not the memory guard. Uniform cost normalization made the next
  preparation succeed. Both artifacts/recipes remain preserved.
- An earlier scaled-guidance comparison continued after compilation failed and
  ran stale classes. `hybrid-scaled-guidance-wv.INVALID.md` excludes it from
  conclusions. Builds now compile into a separate directory and replace the
  previous build only after success. Benchmark launch verifies recorded source
  and jar hashes, and refuses stale builds. Dependent shell batches use `set -e`.
- The v1 receipt's tiny `hybrid-boundary-fixture.json` was overwritten by an
  earlier rerun before preservation was added. Its original bytes are unavailable;
  do not claim that one historical hash verifies. All other v1 receipt files
  still match. New final fixture evidence uses `hybrid-deep-check-*` names.

## Correctness scope and outstanding qualification

Final synthetic checks cover early necessary fuel, dirt/paved excursion choice,
one-way downstream rejoin, a forbidden next turn, absent pumps, fuel arithmetic,
deadlines, and existing via restrictions. Existing fuel, seven-seed portfolio
and hybrid boundary regressions pass. Service checks cover active and queued
cancellation, duplicate IDs, expiry, overflow, invalid inputs, idle-only GC and
recovery. Twenty real diagnostic records pass the documented schema checks.

Fuel remains certified only to legal road projections of packed stations.
Selected strict WV pumps lie 8.4–63.9 m from their physical POI coordinates.
The certificate does not establish a mapped driveway, open pump, operating
hours, or the extra distance of an unrepresented entrance. `navigationReady`
and `productProfileParity` remain false. No fuzzy geometry can close that gap.

The strict mask pins Natural Earth Urban Areas v4.0.0, generalized from 2002–03
MODIS imagery. It is not a current complete metropolitan/township inventory.
Whole source edges intersecting these polygons are excluded. Mask SHA-256:
`f59bced37a7537eec149dc17524802c630c234f17ee67fc04c4bfa29845e8480`.

This pass expands NSNB and dense Quebec coverage and retains the strict WV
crossing. It does not newly qualify Ontario (absent from this six-region graph),
all ranges, full fuel-off behavior, arbitrary waypoints, imported approach
history, navigation/offline parity, or hosted capacity. Previous v1's 42 mixed
NS/NSNB concurrency cases are historical evidence, not claimed reruns of this
refinement. Bounded failure is reported as unresolved, never proven infeasible.

Fuel repair is not the measured long-route burden now. Keep it integrated while
developing DIRT's shared ranking and station-access boundary. No owner decision
or new infrastructure is needed to accept this private milestone for further
development; production integration and publication remain separately gated.

## Reproduction and recovery

Use `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`, branch
`experiment/engine-architecture-20260911`. Do not use the removed Sandbox cwd.
The baseline checkpoint above and the commit containing this report preserve
both versions. Compare in a separate private worktree; do not reset either one.

External root is
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911`.
`hybrid-refinement-evidence.json` pins raw results, audits, recipes, index files
and the compiled adapter identity. Final compiled identity:
`b4616ada9de91da9560b9c61b16cdd37c589ef808838639f4d2bb7b9eabb2595`.
No routing/preparation worker remains active at this checkpoint.

Build with `python3 scripts/routing-architecture/build-gh-adapter.py`, only while
workers are stopped. Keep the pinned GH 11 jar and upstream sources. Existing
graphs need no published pack rebuild. Default NSNB benchmarks use
`--dataset nsnb --objective-landmarks --hybrid`; the strong strict WV benchmark
uses `--dataset wv --case wv-road --profiles dirt30 --hybrid --repeat 3
--usable-range-meters 193121.28 --initial-usable-meters 193121.28 --artifact
<root>/data/gh-verified-wv-strict-lm-km-v2` and an unused `--out` name.
Set Java properties `-Ddirt.stressMask=<root>/unified-stress/blocked-source-edges.bin`
and `-Ddirt.stressLandmarks=true` for that artifact, as recorded in its recipe.
Run through `guarded-run.py` with 4,096 MiB RSS and a suitable total wall budget.
The load runner `hybrid-long-load.py --artifact ... --out ...` uses the same
properties and one serial plus two concurrent requests.

Run `audit-verified-fuel.js` on raw responses using the corresponding prepared
join and station descriptor. Do not infer a pass from service success alone.
Exact source identities, inputs, outputs, timing phases and rejection evidence
are in the receipt. `RELOCATION-AND-RESUME.md` at the external root records the
final Git checkpoint. Future runs must use new evidence names.
