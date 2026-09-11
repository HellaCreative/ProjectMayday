# Hybrid capacity candidate

Development is now hybrid only. The bespoke graph-search effort and competing
engine comparisons are retired. The accepted deployed engine remains unchanged
until a qualified replacement is approved. This candidate is local/private.

## Commercial gate

The initial single-machine 500-independent-long-route target **fails**. A bounded
broker prevents uncontrolled work and shares identical requests, but sharing is
not independent computing capacity. Five hundred active riders making occasional
requests is a different workload from five hundred simultaneous new long routes.
Neither a laptop burst nor cache reuse establishes hosted commercial capacity.

The full four-objective NS→WV selection also initially exceeded its 90-second
budget. The first dirt30 candidate took57.257s:29.246s initial road search,
23.979s alternatives,1.957s matching,0.725s query-graph construction and0.900s fuel
repair. Road search is the current optimization target; removing fuel would not
remove that measured bottleneck.

## Implemented admission and reuse

- One immutable GraphHopper graph serves a configurable1–4 workers. Default
  broker admission allows2 active selection jobs and8 distinct waiting jobs.
- Equivalent requests share one in-flight candidate pool. The key includes graph
  and compiled-adapter identities plus all normalized constraints; only riding
  style is excluded. Each style selects from the same immutable pool.
- Completed pools use a64MiB serialized-byte LRU, with a five-minute TTL.
  Partial, cancelled and late pools are not cached. Oversized complete results
  still return. This limit bounds output caching, not graph topology or total RAM.
- Waiting time reduces the routing budget. A cancelled subscriber leaves shared
  work running for other subscribers; cancelling the last subscriber aborts it.
  Queue overflow is429, expiry504, and neither becomes a no-path proof.
- The loopback HTTP adapter returns the selected geometry plus candidate
  summaries, reuses encoded/gzipped response buffers and bounds active handlers
  at512. It is a local capacity boundary, not a deployed public API.
- Serving startup requires prepared graph/index files. It cannot silently turn
  a missing index into a serving-time build.

Serialized cache bytes exclude decoded JavaScript objects, response buffers,
query graphs, JVM heap, mapped graph pages and socket buffers. Actual process
group RSS is measured independently. Nothing in the admission/cache policy
removes roads from a running search.

## Initial measured comparison

Same pinned500x paved-cost/urban-mask NS→WV case,120mi usable range, full initial
fuel, one90s overall selection deadline. Measurements are fresh processes on a
local8-core/16GiB Mac; OS caches are not flushed.

| Configuration | Submitted | Complete responses | Rejected | Expired | Peak group RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous single-selection API |500 identical|1|499|0|1999.8MiB|
| Broker,2 workers |500 identical|500|0|0|2793.7MiB|
| Broker,2 workers |500 distinct coordinates|4|490|6|3409.9MiB|

The shared run performed **one** calculation, with499 subscribers. Its response
p50/p95 were34.046/35.743s; all selected proof bytes match the previous baseline.
The distinct run performed six jobs before deadlines, completed four, and expired
four additional queued jobs. The successful-response p50/p95 were39.126/72.305s;
these percentiles omit failures and must not be presented as overall service SLOs.
Distinct starts vary by one-millionth of a degree along the same long corridor;
they test distinct request keys, not broad geographic diversity.

Every response payload hash was checked. Independent source audits pass for all
five unique returned itineraries; all six retained strict proof records also
avoid every blocked source edge. The audit carries turn history continuously
through stops and the destination escape. Station evidence remains a legal road
projection, not verified physical pump access.

## Guidance refinement and subsequent qualification

In progress: private per-objective landmark guidance on the unchanged six-region
graph. Kilometer cost units avoid native landmark-storage overflow; external
cost units are preserved. Preparation runs one objective per process, then
serving loads all four indexes. Preparation allows endpoint/unknown access, so
the index remains a lower bound when request restrictions or positive distance
penalties are added. It does not apply the fixed urban mask to normal profiles.

The normalization fixture passes1044 checks:1028 restriction walks plus16 road/
fuel cases across four objectives. Geometry and fuel proofs match the existing
fixture exactly; numeric costs agree within1e-5. Nineteen broker, HTTP and shared
selection tests pass. Full-route performance and capacity qualification follow
the preparation receipt; the new index is not yet promoted by this report.

## Reproduction and evidence

All commands run from the private worktree:
`/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`.
Runtime and large evidence root:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911`.

`hybrid-capacity.js` supports baseline/broker modes,1–4 workers, identical,
unique, warm, geographically mixed and scheduled sustained workloads. Counts
are bounded at500. `strict-wv` is the one-cost mask case; `wv` is the original
full graph; `wv-objective` is the new full graph with objective-specific guidance;
`nsnb` is the smaller Atlantic graph. Use a new output path for every run and
wrap load runs with `guarded-run.py` using a4096MiB guard and enough wall time
for the90s request deadlines plus setup/draining. The harness preserves request
rows, selected controls, individual candidate proofs and phase/heap/GC metrics.

The driver and HTTP server share one Node process; reported group RAM includes
client overhead. CPU accounting includes harness/samplers. Hosted CPU quotas,
throttling, storage latency, bandwidth and truly cold page caches are unmeasured.
No infrastructure was provisioned, no native app installed and no pack or live
API changed. Navigation and full DIRT riding-profile parity remain explicitly
false. Quebec surface quality and verified station entrances remain product gates.

## Artifact retirement

Owner-authorized retirement removed75 explicit obsolete paths and recovered
27.10GiB. Working hybrid graphs, verified inputs, source packs, graph-generation
recipes, Git checkpoints and small evidence remain. The exact external receipt
is `results/retirement-20260911/manifest.json`; unique retired notes/patches are
archived in its165248-byte sibling tarball. Retired Valhalla/OSRM binaries and
derived datasets cannot be rerun without rebuilding. Source revisions are in
the receipt. Do not restart their historical scripts as active work.
