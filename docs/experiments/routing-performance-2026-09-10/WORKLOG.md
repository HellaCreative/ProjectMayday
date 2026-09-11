# Routing performance implementation log

Scope: owner-authorized private implementation and qualification; no stable DEV, production, pack publication, GitHub push or native installation.

## Recovery

- Accepted DEV reference: `139a173`.
- Private pre-experiment repairs: `bf8f740509b7448373a3bb24e46f11bca6968c7a`.
- Preserved first diagnostic: `1807e0c` (local commit).
- Working directory: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/fuel-health-repair`.
- Initial paging evidence remains in `../selective-loading-2026-09-10/`.
- Current candidate is opt-in through `createRideAlternativeContext({useIncomingBounds:true})`; the default remains the existing materialized reverse preparation. No default live behavior has changed.

## Active cycle

1. Repeated reverse-cost preparation was identified in each objective and avoidance pass. It materializes full incoming arcs and a cost array for every changed objective/projection.
2. Implemented one bounded source incoming-adjacency index per pack/revision, shared across objective costs and endpoint/pump overlays. Guidance evaluates unchanged costs only as reverse exploration reaches a road. All source roads remain indexed; no corridor clipping.
3. Added exact incoming-order, direction, loop, parallel-edge, endpoint-access, restriction/fuel-route and capped/exact-distance comparisons. Three new tests passed; existing adventure suite passed with the feature off.
4. Verified immutable local copies for the full region matrix against the release catalog. Downloaded missing current copies into `/tmp/dirt-performance-packs`; published bytes unchanged. Acquisition logs are at `/tmp/dirt-performance-pack-acquisition.log` and `/tmp/dirt-performance-packs/acquisition.json`.
5. Added actual live-canary matrix runner with explicit fixed flags, staged timings, cold/repeated requests, proof hashes, surface data, first-hop fuel validation, continuation history and retained/peak memory. Initial artifact-directory creation bug was fixed before retaining results; these failed output attempts are not performance evidence.

Matrix inputs: `matrix-inputs.json`. Initial comparison outputs: `/tmp/dirt-perf/`. Continue recording results and refinements here; do not declare the mission complete from this initial implementation.

## V1 checkpoint and broad local qualification

- Implementation checkpoint `5700968`: shared incoming CSR plus neutral restriction fast path, both opt-in.
- 24 cases × baseline/candidate × one process-cold and two warm runs = 144 completed requests. All per-window proof signatures and first-run compressed full proof bodies match exactly. All geometry continuity, access and fuel-range checks pass. Matrix covers short/long NS, long QC and NS→NB, all three profiles and fuel on/off at 378 km. `v1-summary.json` records paired timings and process peaks. Raw evidence currently `/tmp/dirt-performance-matrix/`; preserve before final handback.
- Consistent speed benefit; peak RSS is not uniformly lower. QC road-only peaks sometimes rise despite smaller retained typed arrays. Do not claim universal memory improvement.
- Refined candidate removes per-node empty array churn and releases obsolete graph references from request-owned guidance cache. An immutable-source guard allows already qualified joined runtime reuse before source-reader fetches; mutable/local paths cannot use it. Feature gate: `DIRT_ROUTING_PREPARATION=shared-v1`. Default remains unchanged.
- 250 adventure tests pass after refinement. Initial refined QC Clean road: 5.577 s cold, 2.929/2.866 s warm, 912.6 MiB process peak; exactness and repeated cold trials still to qualify.
- Long-route phase 3 now running in `/tmp/dirt-performance-long/`. Local loader models ideal joined reuse; hosted reuse requires separate qualification.
- Private deployment route memory reset from inherited repair's 4096 MiB to accepted DEV's 2048 MiB for fair comparisons and no capacity increase. No deployment created yet.
- No Swift or Android behavior change is claimed: this is a gated JavaScript preparation experiment preserving existing outcomes; native parity remains an owner review item before adoption.
