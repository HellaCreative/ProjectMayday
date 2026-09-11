# OSRM compatibility gate — bounded executable evidence

Private spike owned by the OSRM investigation. Engine source: OSRM 26.9.0, commit `d63a1df9c25c84f2edf304de8bc7b691aa9020f9`. Runtime uses the existing isolated native wheel; no duplicate installation, published-pack changes or production changes. Code: `scripts/routing-architecture/osrm-spike/`. Scratch and raw results: `/Users/richardsmith/.codex/experiments/routing-architecture-20260911/osrm-spike/`.

## Executable gate

`profile.lua` accepts explicit verified source access codes and known surface family. This is deliberately not a production OSM tag importer. It admits verified and unknown motorized edges, rejects denied/purpose-limited directions, and tags unknown edges as an OSRM exclusion class. That allows query-time Allow Unknown through the prepared exclusion mechanism. Excluding endpoint-only access entirely is conservative but incomplete: legal endpoint exceptions remain an adapter requirement, not a passing test.

It implements distance times the existing additive paved, Dirt 10 and Dirt 30 factors, plus `30*(1-wander)^2` per-meter charge. Speeds remain separate from route weights. Five tiny metrics exercise paved, Dirt 10, Dirt 30, wander 0 and wander 0.5. These settings are baked at extraction, not dynamically selected by a request on one prepared dataset. A prepared metric per finite candidate/settings combination is possible. Continuous arbitrary settings require metric customization before querying, a different search implementation, or explicitly qualified discretization.

`probe.py --build` creates three small disconnected control networks and a directed via-way restriction network. It sequentially extracts/partitions/customizes private metrics, then queries surface choices, unknown exclusion, denied/reverse direction, a complete restricted route, a mid-via intermediate stop and separate arrival/resumption. `audit.js` compares returned node walks to the existing DIRT V4 transition engine and asserts the forbidden and legal source walks independently. Executed under the parent’s sequential tiny-workload slot. Five metric imports and 55 queries completed; `audit.js` and `check.py` pass. First harness run stopped on the expected NoRoute exception; handling was fixed and original failure log retained.

## Source findings and adaptation costs

- `docs/profiles.md` and `profiles/lib/way_handlers.lua`: rate is meters per unit of weight; arbitrary additive per-road preferences are expressible. Defaults are policy, not a fundamental paved-road limitation.
- `src/updater/updater.cpp`: segment CSV rate overrides alter prepared edge weights; `customize` updates metrics without rebuilding topology. This is preprocessing, not per-request dynamic costing. Input direction/road identity and all rates must remain consistent with derived topology.
- `include/engine/api/base_parameters.hpp` / `route_parameters.hpp`: stock requests expose excludes, bearings, hints and waypoint continuation; they do not expose arbitrary edge-cost functions or prior restriction-edge history. Bearings constrain direction, not the entire approach history.
- `include/engine/routing_algorithms/shortest_path_impl.hpp`: multi-leg state retains forward/reverse phantom reachability and previous paths. The executable mid-via case passes in a single request, including an off-road station projected 2.22 m onto that via edge. Separate route calls lose the preceding restriction history.
- `include/extractor/class_data.hpp`: seven named classes and seven prepared exclusion combinations. Allow Unknown fits; treating every rider setting as an exclusion combination is not a general solution.
- OSRM weights use fixed precision and bounded integer representation. The spike keeps default precision 1. Equality with floating-point DIRT results requires quantified rounding and long-route overflow tests; raising precision to 3 trades away substantial long-route headroom.
- Balanced selection is a finite-candidate ranking layer, not the minimum additive scalar. Current lexicographic city exposure also needs a separate compatible implementation. No full P or F qualification from custom Lua alone.
- Fuel planning cannot rely on a shortest-distance table alone. Different arrivals at a station may permit different legal continuations; range feasibility also needs actual road distances, partial start/reserve, excluded stops and destination escape. A query API carrying expanded restriction state would be a substantial but bounded engine integration. Rechecking a completed route can reject illegal joins but cannot by itself recover the lost legal alternatives.

## Comparative status

The shared Atlantic R-tier matrix is already available (360 requests across all engines/modes). It is ordinary-car, different source data from DIRT and is not the result of this compatibility profile. Long-region and concurrency workloads must be coordinated through the parent's memory guard. The OSRM Python binding retains the GIL; native `osrm-routed` is required for a meaningful threaded service benchmark. No concurrent capacity claim yet.


## Measured gate result

55 native queries over five prepared metrics. The synthetic source has17 nodes, 10 ways and one via-way restriction and is deliberately small. Paved chooses 315.5 m pavement; Dirt 10/30 choose 737.6 m known dirt. Dirt 10 wander 0 and0.5 choose the shorter pavement, demonstrating an intermediate-setting effect rather than a renamed car profile. Allow Unknown on permits the 315.3 m dirt shortcut; off selects 737.6 m verified pavement. Explicit denied directions are absent, and reverse travel on the one-way control returns NoRoute.

All five whole restricted routes and all five single-request mid-via-stop routes use the same 1017.4 m legal detour. Moving the station 2.22 m off the road still snaps to the same projected location and returns exactly the same geometry in all five metrics. This is provisional road-projection evidence, not proof of a physical fuel entrance.

All five separate arrival/resumption pairs instead join into a 472.8 m route containing the forbidden from/via/to sequence. Constraining resumed bearing east does not fix it. Each individual leg is legal in isolation; the existing V4 transition oracle rejects their concatenation. This is a decisive reproducer against a stateless shortest-leg fuel graph, not against OSRM’s complete-route restriction support.

`check.py` demonstrates a narrow successful fuel certificate: initial usable 250 m reaches the pump at 236.4 m; refill to 1000 m covers the remaining 781 m, leaving 219 m. Destination is a known station, so escape is zero. Initial 200 m, excluding the pump, or full usable 300 m fails this fixed itinerary. Independent legs would falsely certify the 300 m case because each is 236.4 m; the V4 history audit catches that failure. This does not establish complete feasible-fuel search or full F qualification.

Five extract/partition/customize pipelines totaled 0.736 s, including CLI startup, and produced 1,320,000 bytes across five tiny datasets. Native extract logs report approximately 34 MB peak; the one-second guard missed these short subprocess peaks, so its 0.9–2.5 MiB samples are explicitly NOT retained/peak memory measurements. These numbers characterize reproducibility overhead only, not regional capacity or import scaling. Shared Atlantic/eastern measurements remain separate R-tier evidence.

Fixture SHA256:`ba2370f00547eb4305c7ce7fd40347097ed271e407b09ea27d255056479ac6d2`.
Profile SHA256:`7ca8170c54b2c46437db8f7578a09ca7676aacd4bb5201e02250bbf4852f4f7a`.
Raw outputs: `results.json`, `v4-audit.json`, `checks.json`, `build-results.json`, per-metric logs, guard failure/success logs and `receipt.json` under the scratch directory stated above. The receipt pins all four spike source files.

## Smallest credible continuation extension

The existing edge-expanded graph already contains restriction-state copies, and extraction deliberately puts duplicate via edges in the snapping index (`src/extractor/edge_based_graph_factory.cpp`, around 386–420). `InternalRouteResult` retains each selected target phantom and whether it was traversed in reverse. The narrow extension is therefore to return an opaque dataset-bound continuation token containing that selected directed expanded segment and projection, and allow the next request to seed only that exact source state. Keep existing MLD traversal and restriction transitions. Bind the token to topology/metric identity, reject stale or mismatched locations, and do not permit a newly snapped unrestricted copy or reverse direction to replace it silently. Fuel-station labels would retain these state tokens rather than only station IDs.

This is a proposed source extension, not implemented evidence. It needs changes in request parsing, source-phantom selection and response assembly plus directed/via-history regression tests; it does not require inventing a new shortest-path engine. Importing legacy DIRT history additionally requires replaying its exact directed source-way sequence through OSRM’s expanded graph and mapping aliases/IDs. A full-route re-query can certify an itinerary before travel, as demonstrated, but cannot assert that its recomputed prefix is the rider’s already-traveled history. Passing extra coordinates/bearings is not an exact source-edge sequence contract on parallel roads.

A stock hint is not a shortcut to this extension in the pinned version: `include/engine/hint.hpp` and `src/engine/hint.cpp` deprecate the old phantom payload and retain checksum-only placeholder serialization. The actual fixture responses contain that placeholder. Reusing them cannot import the chosen restriction-state copy.

## Decision for comparison

Advance OSRM as a credible prepared additive road oracle and candidate engine beneath a fuel planner. It passes a meaningful subset of P and a bounded fixed-itinerary fuel certificate. Do not select it as a complete DIRT engine yet: continuous rider costs, exact legacy continuation, endpoint-only access, city lexicographic objective, independent feasible fuel alternatives and real-region custom-profile measurements remain unqualified. Its fixed-metric serving advantage must be weighed against preparing/customizing enough metrics and the continuation API extension. Nothing in this gate demonstrates that preferring dirt itself is incompatible with OSRM.

Reproduce after obtaining the coordinator’s resource slot:

```text
<isolated-python> scripts/routing-architecture/osrm-spike/probe.py --build
node scripts/routing-architecture/osrm-spike/audit.js <scratch-directory>
python3 scripts/routing-architecture/osrm-spike/check.py
```

Wrap the first command in the existing guarded-run.py (256 MiB, 120 s for this tiny fixture). Omit `--build` to reuse immutable synthetic engine artifacts. No production recovery action is needed: remove only this experiment’s scratch directory to retire the spike; preserved candidates and published packs were not changed.

## Native HTTP concurrency harness

`osrm-spike/concurrency.py` is ready for coordinated R-tier capacity runs. It launches exactly one local native `osrm-routed` through the existing wheel CLI, using `--algorithm MLD --mmap --ip 127.0.0.1 --port <ephemeral> --threads 2 <dataset>`. This maps immutable prepared files in one server; it does not create a System V shared-memory datastore. No import or new engine build is performed.

Defaults are client concurrency 1, 2, 4 and 8, three rounds of32 mixed requests each, and two native workers held constant. The four default destinations are prior NS-short, NS-long, NS→NB and Bangor fixtures. Their rider profile and fuel settings are explicitly ignored by the ordinary-car dataset; this is R-tier only. Custom `--fixtures` and `--dataset eastern` allow the coordinator to supply covered long cases after successful preparation.

The harness reports startup plus first request, warm controls, per-request HTTP latency and submission-to-dispatch client queue delay, throughput, maximum outstanding HTTP requests, route-proof stability, response bytes, sampled process-group RSS, idle retained RSS and bounded shutdown. It samples every100ms, enforces a2GiB server-group RSS limit,4GiB disk reserve and600s total deadline by default, and only terminates its own server process group. Requests have60s client timeouts. Short batches may have no in-batch RSS sample; empty samples are not zero memory. Exact native-search concurrency, internal server queue delay, per-request private memory and mmap bytes read are not directly measured.

A tiny `--smoke` run completed two rounds at client levels1/2 with one native worker, stable proofs and orderly native shutdown. It sampled23.2MiB process-group peak; this is an API/lifecycle check, not a regional capacity finding. The disconnected-request probe confirms subsequent health, but does not establish native cancellation: synchronous `RunQuery` has no propagated client cancellation token. The raw server log retains native request durations and shutdown events.

Scheduled Atlantic command:

```text
<isolated-python> scripts/routing-architecture/osrm-spike/concurrency.py --dataset atlantic --workers 2 --levels 1,2,4,8 --rounds 3 --requests 32 --out <scratch-directory>/concurrency-atlantic.json
```

Do not run this comparison while imports or other capacity runs are active. Compare repeated rounds and process starts; network-local startup and warm throughput do not establish hosted latency or production-user capacity. The ordinary-car dataset supplies a single fixed metric even though destination fixture labels include Dirt and Balanced.
