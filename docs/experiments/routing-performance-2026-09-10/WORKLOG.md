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

## Hosted qualification and next memory experiment

- Private source checkpoint `8b83ee7`: baseline `https://pack-fabric-dtbay1q8u-goricksmith-7678s-projects.vercel.app` (`dpl_aC3VKkDXJHngsztXn66mnzyDgcEP`); candidate `https://pack-fabric-3ebft6y0a-goricksmith-7678s-projects.vercel.app` (`dpl_8WhjbxvHWUCP7UFmCPDLptfZEoEw`). Same code, flags differ only `DIRT_ROUTING_PREPARATION=off/shared-v1`. Both preview, no stable alias/push/native change.
- Actual Vercel inspection reports Node24 and 4096 MiB: Active CPU billing ignores the supplied function memory field. Existing project settings were not modified. These two private deployments can be compared with each other but not treated as a 2048 MiB accepted-DEV performance qualification. This limitation was reported immediately.
- Hosted short NS fuel first server request baseline3344ms/candidate3353ms; warm baseline1277/1081ms, candidate660/766ms. Explicit curl total, server stage timings, full responses and exact proof artifacts stored in `/tmp/dirt-performance-hosted/`. First observed request is not proof of infrastructure cold start.
- Local Ontario Balanced road: 15018→11264ms cold; ~11291→7442ms warm. Fuel: 24258→21316ms cold, ~21545→17780ms warm. Bangor road/fuel also complete; all four exact per-window signatures match. Memory is mixed. Phase3 continues.
- Added compact spatial memberships alternative (separate `compact` benchmark variant; not enabled in private deployments). Keeps exact Float64 bounds, cell order, broad-road fallback, dateline/polar behavior. Packs cell memberships into uint32 offset/member arrays instead of per-cell expandable JS arrays. Costs an additional bounds-only fill pass; measure cold cost versus retained-memory benefit.
- Added accepted unchanged NSNB180km and deep/clean windowed baseline requests, plus162km and partial-initial-tank tests (phase5). They must be qualified before final candidate handback.
- Peak measurement caveat: `resourceUsage.maxRSS` is a lifetime high-water mark. First run is sampled before proof serialization; later runs may include prior proof serialization/allocator residency even after GC. Retained heap/arrayBuffers are reported separately. No exact per-stage peak or hosted peak-memory claim is made.

## Hosted long-route failure and compact candidate

- Hosted WV Dirt baseline: HTTP500 after86.809s; Vercel request `gpnpw-1789088606692-3b64d255a77e` explicitly reports out-of-memory kill. Six regions (NB,NS,NY,PA,QC,WV),6,601,968 source nodes/8,102,621 roads. Join18.549s, RSS1,745,244,160 before and2,908,049,408 after. Shared-v1 candidate also HTTP500 after about81s; no route validity claim. Original responses and runtime error logs retained under `/tmp/dirt-performance-*`.
- Local WV Dirt baseline completes69971ms cold,54613/57267ms warm; shared preparation50756ms cold,31771/32157ms warm. Candidate lifetime peak2920MiB versus2676MiB. This is a speed improvement and a memory regression, not a fix for hosted WV.
- Compact regional join alternative retains node identities in signed64-bit storage and uses exact numeric map keys (BigInt beyond safeNumber range). Shared nodes, canonical edge IDs, overlap aliases, CSR order and restrictions remain identical. It does not remove roads, change packs or bound the number of loaded regions.
- `compact-v2` opt-in combines shared guidance, neutral turns, compact spatial memberships and compact node identities. It remains undeployed and unqualified pending measurements. Local benchmark variant `compact-join` selects the same representation; `compact` isolates spatial membership changes.
- Added independent legal replay tools. They resolve every returned source edge, rebuild projected traversal, check directed adjacency and exact node continuity, carry turn state across pump splits, and seed continuation history against the baseline turn adapter. Tests demonstrate detection of prohibited turns, false identities and invented reversal at a fuel projection. These audits run outside measured requests.
- Added source hashes to future benchmark reports. Earlier shared-v1 local evidence is tied to5700968/8b83ee7; later optional compact code leaves flags off for baseline/combined. Very small baseline query-dispatch changes from compact support must be distinguished from identical executable-byte comparisons.

- Compact spatial first QC Clean road measurement:5744ms cold,2929/2967ms warm,884.6MiB lifetime peak. Retained heap134.1MiB plus250.1MiB typed buffers versus shared-v1 heap166.8+243.0MiB: about25.6MiB less retained heap+buffers, with a small cold-time cost. Peak remains above the original baseline's observed peak. This supports continued testing, not a universal memory claim.
- Compact ID reader moved to an external closure factory before measurement to avoid retaining the join allocation scope. Full adventure suite255 tests and independent replay2 tests pass. Candidate checkpoint follows; private compact deployment is authorized as an experiment, not promotion.
