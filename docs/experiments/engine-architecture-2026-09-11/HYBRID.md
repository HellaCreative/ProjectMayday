# Private GraphHopper + DIRT hybrid candidate

This is the preserved v1 report. The subsequent implementation, comparisons,
rejected approaches and current limits are in [the refinement report](HYBRID-REFINEMENT.md).

Owner selected this development direction on September 11. Keep GraphHopper's
prepared graph and search; retain DIRT's immutable source topology, access and
restriction checks, surface scoring, itinerary and fuel responsibilities.
This document supersedes the engine-selection pause for this private checkout.
Accepted DEV and published packs remain untouched. No native build, deployment,
remote push, paid infrastructure or app profile replacement is authorized here.

## Implemented boundary

`HybridHopper` is a persistent local JSON-lines service. It loads one verified
GraphHopper graph and accepts the existing experimental coordinate/profile request.
`ConcurrentVerifiedHopper` selects the same integration with `hybrid: true`, using
1–4 workers and an eight-request queue. Overflow is explicitly rejected.

Without a fuel request, return a road-only result. With fuel, preserve the original
road candidate separately and attempt a continuously legal fuel itinerary:

1. Search the requested additive road objective and certify existing on-path fuel.
2. Repair missing fuel using bounded excursions that return to the same graph
   node with a legal incoming-edge transition into the original next edge.
3. If needed, try two distance-penalized candidates (30, 300) and repeat fuel repair.
   Return the first verified candidate, scored with the original objective.
4. Return unresolved fuel if the bounded policy fails. Never turn a timeout or
   exhausted candidate policy into a proven physical fuel gap.

The hybrid does not invoke the previous global resource-label fallback. Its
90-second request deadline applies to road generation, repair and candidate work.
Fuel repair explores at most 30 km per excursion, 25,000 local labels per attempt,
and the request's label allowance per candidate (default 100,000; cap 500,000).
Those bounds restrict this candidate strategy, not the discoverable graph.
It may miss valid one-way station circuits, different rejoin points, longer fuel
excursions or an entirely different feasible corridor. Failure remains incomplete.

Refilling preserves the exact incoming edge and expanded restriction state. The
fixed repaired walk is then assigned a minimal-count reachable refill schedule;
no road geometry is removed during this scheduling. Destination escape remains
required. Road, query-graph, matching and repair timings are reported separately.

## Measured evidence

All raw inputs, responses, process guards and independent audits are retained at:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911/results/hybrid-*`.
The earlier graph imports and comparison baselines remain preserved.

- New synthetic fixture checks legal excursions, incoming restrictions, forbidden
  pump turnarounds, absent stations, range arithmetic and deadline reporting.
- Existing six fuel regressions and seven-seed portfolio checks pass.
- Boundary fixture checks road-only, fuel-verified, fuel-unresolved with retained
  road, and explicit refusal to discard imported arrival history.
- NS→NB: all four additive objectives × three runs pass independent source-walk
  and fuel audits. Usable range 180 km; initial fuel 90 km. Median end-to-end times:
  distance 0.179 s; paved 0.346 s; dirt10 0.375 s; dirt30 0.520 s. Sampled process-
  group peak 564 MiB. These are process-first then warm requests, not OS-cold.
- Initial naive repairs added 70–81 km on dirt profiles. Avoiding excursions when
  an on-route pump is reachable reduced that to 35–40 km. Fixed-walk scheduling
  reduced 15 reported refills to five on these cases.
- Compared with the older portfolio's roughly 5.5–6.1 s medians, this is faster
  candidate generation with different itineraries, not an exact-result speedup.
  New dirt10/dirt30 itineraries are 549/566 km versus 464/468 km previously.
- NS→WV normal dirt30: first local-only repair failed after 31.4 s overall;
  repair itself took 0.09 s. The refined fallback found a 2,638.3 km itinerary
  with 18 refills at 120 miles usable range, full initial tank, in 56.8 s overall.
  Independent fuel and continuous source-walk audits pass. Sampled group peak
  2,684.8 MiB. Original preferred road was 3,326.7 km; the selected fallback's
  road before fuel excursions was 2,512.2 km, so excursions added 126.1 km.
  Route plus 3.4 km destination escape contains 1,149.1 km known dirt, 812.4 km
  paved and 680.2 km unknown surface. This sacrifices dirt character for a
  certified fuel chain; unknown surface is not counted as dirt.
- Shared graph: six serial controls plus 36 workload requests across short NS,
  long NS and NS→NB, two rounds at 1/2/4 outstanding clients, two active workers.
  All 42 fuel/source audits pass and concurrent paths exactly match controls.
  Sampled group peak 678.9 MiB. This is not a 500-client or hosted capacity claim.

Strict 500× pavement/unknown-surface plus the pinned built-up-area mask also
produced a certified candidate: 2,743.1 km, 18 refills, 50.16 s end-to-end,
2,715.8 MiB sampled group peak. Independent continuous fuel/source audits pass;
a separate mask audit confirms zero blocked edges in the route and escape.
The audited route plus escape contains 1,363.8 km known dirt, 712.0 km paved,
and 670.6 km unknown. The first two road candidates failed local fuel repair;
the distance-penalty 300 candidate succeeded. Original 500× objective scoring is
retained for reporting; this is a first-feasible heuristic, not its proven minimum.
Previously the seven-seed/global fallback exhausted 90 seconds without a fuel
certificate. This establishes route admission, not the previous 500-client claim.
The generalized Natural Earth mask coverage limitations remain unchanged.
A second process ran one serial control and two simultaneous strict requests:
50.58 s serial; 50.26 s each concurrent. All returned exactly identical road and
fuel proofs. Combined sampled process-group peak was 3,263.8 MiB (3.19 GiB).
All three independently audited continuous itineraries pass. Two concurrent
50-second routes do not establish commercially sufficient throughput or 500-client
capacity; CPU throttling and hosted cold-cache behavior remain unmeasured.

## Qualification limits and fuel's product role

These are additive engine profiles, not completed Dirt/Balanced/Clean parity.
In particular, shortest fuel excursions can conflict with Clean pavement intent.
Balanced 50/50 targeting, richer DIRT candidate ranking, arbitrary rider waypoints,
editing/continuation import and offline application integration remain unqualified.
No new app API, navigation behavior or production UI is installed.

Fuel evidence is a legal projection of a packed station, not verified physical
entrance, current opening hours or operation. The experimental envelope explicitly
sets `navigationReady: false`. A fuel-unresolved road is a reviewable planning
candidate, never a silently fuel-safe itinerary. A rider-facing advisory mode is
an available product direction, not implemented permission to navigate unsafe gaps.

Fuel repair is now cheap on tested cases; road searches and alternative generation
still dominate long-route time. Therefore retain integrated fuel development for
now. Preserve the fallback road/fuel separation if future coverage tests show that
fuel needs an advisory role. Do not discard integrated fuel merely because the
first local candidate fails, and do not promise commercial capacity from laptop tests.

## Reproduce and recover

Use the SIDECAR private worktree `.build/engine-architecture`; the old Sandbox
working directory is gone. `build-gh-adapter.py` compiles all private extensions
against the pinned GH 11 jar and records source hashes in its build identity.
Do not recompile while a routing worker is active.

Run `check-gh-fuel.py`, `check-gh-portfolio.py`, `check-hybrid.py` and compile/run
`FuelRepairCheck.java` against that classpath. `verified-bench.py --hybrid` runs
serial cases; `verified-concurrency.py --hybrid` runs bounded shared-graph cases.
Use `guarded-run.py` with 4 GiB RSS and appropriate wall time, then independently
run `audit-verified-fuel.js` on the retained raw responses. Full benchmark commands
are stored in each guard JSON. Do not overwrite earlier named result files.

Previous checkpoint: `58dbe5a9717ca517e8fbe3c21303448f4c277581`. Return to it in a new
private worktree to compare the pre-hybrid implementation; do not reset/delete this
candidate or alter the accepted live baseline. Graph imports and all raw results
remain external to Git; rebuilding published packs is not required.
