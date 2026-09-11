# Architectural experiment ledger

Active mission: MISSION.md. Continue until its architecture/integration, repeated WV, and concurrency criteria are met, or a specific external dependency prevents meaningful progress. The prior preparation candidate is parked, not a preferred architecture.

## Isolation and resource budget

Worktree: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/engine-architecture`, branch `experiment/engine-architecture-20260911`, based on preserved evidence c12bab7. Prior core571123c and accepted checkpoints unchanged. Experimental tools/source/data: `/Users/richardsmith/.codex/experiments/routing-architecture-20260911`. No deployment or remote changes. User explicitly authorizes local open-source tool installs and bounded public extracts; this supersedes historical pack-publication/freeze rules for these isolated artifacts. No native/Android product change or parity claim.

Initial host:16GiB RAM,8logical CPUs,~11GiB disk available. Keep at least4GiB disk free; run heavy imports one at a time with <=2threads and bounded memory. Avoid other apps/processes. Never delete another task's artifacts.

## A01: established implementations first — active

Hypothesis: reusable prepared native/tiled graphs remove the request-time join/scans and offer much lower request-private memory. All three engines were previously untested. Read research report and architecture review, then upstream release/source. Pinned tags:Valhalla3.8.3,GraphHopper11.0,OSRMv26.9.0. Acquire shallow source, upstream binaries/bindings where supplied, build graph data locally and inspect actual algorithm/access code. Do not confuse a binary install with a graph import or a road benchmark with DIRT qualification.

Current operations:source clones plus isolated Python environment/pyvalhalla3.8.3 installation;GraphHopper11.0 upstream jar download. First common bounded input will exercise real roads; expand only after recording dataset sizes and build memory.

Untested families to compare: Valhalla tiled hierarchy/dynamic costs;GraphHopper flexible/LM/CH;OSRM MLD/prepared/shared data;fuel itinerary layer with directed continuation;genuine geographic graph access if integration cannot satisfy product. BRouter/OsmAnd are additional source references.

### First import evidence

GraphHopper11.0 actual import completed106.80s,1416.16MiB sampled process-group peak,233MiB artifact. Common253.88MB input;938,985nodes/1,112,878edges;CH1,438,402shortcuts plus16landmarks. A first configuration-only failure required explicit import.osm.ignored_highways;fixed with an empty exclusion list and preserved failure log. Current car importer still has its own eligibility/subnetwork filters,so this is R-tier only.

OSRM extraction runs with2threads throughguarded-run.py. A sequential pipeline waits for successful extract,then performs MLD partition/customize,then compiles Valhalla C++ tools with2jobs. Guard caps groupRSS4GiB,keeps4GiB disk reserve,and records commands/RSS/block faults/limits. Build and benchmark must not overlap.

### All three engines running; first repeated R-tier comparison complete

Valhalla compiled fromsource335.84s/1106.09MiB peak;admin DB3.09s/602MiB;tiles44.05s/1255.28MiB. Timezone DB was absent,so this first ordinary-road dataset does not qualify time-dependent restrictions. OSRM extract79.89s/1853.52MiB,MLD partition10.24s/594.73MiB,customize4.12s/466.31MiB.

Fourcases(NSshort,NSlong,NSNB,Bangor)×5engine/modes×3freshprocesses×6requests=360complete ordinary-road requests. Seeatlantic-road-summary.json and raw~/.codex/experiments/routing-architecture-20260911/results/atlantic-road. Source dates/eligibility/costs differ from V4;notDirt orfuelqualification. OSRM binding returns custom Object/Array containers;fixed harness conversion explicitly,notenginecode. Failures preserved in smoke logs.

Expanded public input underway:complete routing/admin subsets ofNS,NB,QC,ON,NY,PA,WV dated260907. prepare-eastern-input.py records fullsourcehash/header and subsethash;retains all highway/ferry ways,restrictions,adminrelations,fuel/barrier nodes and referenced members,not a routecorridor. Deletes only its own newlydownloaded fullrawfile after the exacttested subset is persisted;earlierAtlanticinputs retained.

Advance GraphHopper as the first integration hypothesis because CH/LM offer exact additive objectives and its public import/restriction APIs can consume verified DIRT topology. Valhalla remains a credible tiled candidate;stockuse_trails is notDirt scoring and hierarchy under strong custom weights needs testing. OSRM remains a strong fixed-metric performance/serving reference. This is a prioritization,not a rejection of the other two. Implement verified-data adapter and fuel continuation prototype only after preserving these practical comparisons;bigregion benchmarks stillrequiredforallcrediblecandidates.

### Verified adapter implementation — active, not qualified

Eastern seven-region input complete: all source/filter hashes and merged receipt are under external data/eastern-source.json. GH eastern import first invocation failed because macOS java shim had no runtime; corrected to installed absolute JDK binary. v2 uses2GiB heap/4GiB RSS guard. Landmark preparation completed; CH preparation in progress. eastern-builds.py serializes remaining native imports after this guard result, preserving failures.

Implemented a private GraphHopper subclass, verified sidecar exporter, explicit directed-restriction extension (compiled from pinned upstream source, no upstream edits), preference cost factory, and paired-direction endpoint queries. Initial undirected representation failed4of1028 bounded legal walks because reversing along a via edge retained the artificial-edge restriction state. Rejected that representation. Directed per-arc representation now passes1028walks against V4transition (not merely against the compiler) on the first synthetic via restriction fixture. It doubles road edges/geometry in this first prototype; memory benefit must be measured, not assumed. Additional compiler tests caught/fixed simultaneous node-only/via-only and differing-length only-rule interactions;4tests pass. More real-world and integration checks remain required.

The prototype preserves source directed keys as source_edge=2*V4edge+direction; GH artificial restriction edges copy this value. Endpoint queries split both directional copies and compare all four directional combinations. Standard GH nearest-single-edge snapping is insufficient for this representation. Flexible comparison uses Dijkstra; LM uses the prepared distance lower bound. No city-avoidance, endpoint-only access exception, fuel or continuation qualification yet. Timing fields are not travel-time estimates. All prototype code is isolated and no product runtime, pack, deployment or remote was modified.

### Expanded correctness and fuel prototype

Six synthetic restriction cases now compare5982bounded walks to V4 withzero mismatches. Eighteen endpoint routes include arrivals/departures in the middle of a restricted via road. Endpoint snapping now includes artificial restriction-edge copies as well as both source directions; otherwise a valid mid-road endpoint can be inaccessible after its approach. Source copy lookup scans only added restriction edges, not the entire graph. QueryGraph virtual piece lengths are normalized to sum to their authoritative source edge length; GH's default geometric recomputation changed totals when adding projections and could undermine prepared lower bounds. All this remains private.

FuelSearch.java is a bounded Pareto-label integration over GH's expanded graph, with unchanged arrival edge during refill and a directional, range-limited destination escape search. Initial synthetic assertions pass for partial starting fuel, necessary stops, carrying via restrictions through a pump, exclusion of an essential station, and legal destination escape. It explicitly rejects legacy arrivalHistory until a compatible import is implemented. No full-profile/fuel qualification or scalable performance claim. Current prototype is plain resource Dijkstra without landmark guidance; measure before selecting acceleration. Real-region fuel import/continuation/city avoidance/ranking still outstanding.

Offline station matching forNSNB uses the exact prior immutable fuels/geometry and current matcher:1376canonical stations,0.610s for index plus both access policies (single local observation, not a comparison). stations.json pins source identities, carries exact selected source edge/fraction and provisional legal_road_projection evidence. Runtime can materialize those prepared positions without redoing spatial matching. Candidate has not yet run NSNB real routing; it is queued after the large GH import under the sequential build driver.

New scripts:verified-bench.py records per-objective request latency/RSS/proof;audit-verified-routes.js checks source walk continuity/access/turns/surface/meters independently viaV4;export-restriction-checks.js produced20757real walks rooted at199NSNBrestrictions, to execute after import. Raw external results and current sessions are in the task context; no remote writes. This checkpoint is work in progress, not completion.


### Exact stop history and first verified regional results

The upstream GH virtual-turn wrapper minimizes across artificial restriction copies. A stronger fuel fixture exposed an illegal via turn after a mid-road projection. Private ExactQueryGraph now maps virtual pieces to their exact original restriction-state edge; a constructor visibility extension is the only QueryGraph source change. The native minimum-road fuel certificate now shares the same precise graph as resource fallback. Six synthetic fuel checks pass, including insufficient starting fuel, excluded essential pump, forced detour search, and no invented projected turnaround. Legacy continuation still explicitly unsupported.

GH rejects self-loop roads. NSNB has2214 source loops (none referenced by its restrictions). Private representation uses a zero-distance one-way head to a private coincident node, then full-distance geometry tail back to the real junction. No other road connects to the private node. Loop fixture3540walks passes; real NSNB import v2 succeeds11.283s at683.44MiB sampled group peak. This adaptation adds topology and doubles directed geometry; total memory must still be measured at eastern scale.

Real NSNB smoke on identical verified V4 inputs: distance376.564km/0.380s; paved535.795km/0.600s; Dirt10 objective509.328km/1.382s; Dirt30 objective531.578km/1.775s. These are four additive candidates, not full DIRT ranking. Paved candidate is entirely paved; Dirt30 contains299.128km dirt. All four independent source-walk audits pass access, continuity, turns and distance checks. Initialization0.668s; resident memory rose from154.55MiB to441.45MiB. Single process/single repetition; no broad performance conclusion. All20757 bounded real restriction walks rooted at199 NSNB rules agree with V4. Sampler misses subsecond process peaks; do not use its1.56MiB sample as Java memory evidence.

Public eastern GH CH+LM preprocessing exceeded1800s wall guard at2969MiB peak, after import and LM completed but CH unfinished. This is not a successful routable artifact. Follow-up should use a separate LM-only artifact. OSRM eastern extraction completed; the eastern pipeline driver PID75626 was intentionally paused at its boundary for verified regional checks. Resume with SIGCONT after checks; ROOT/results/PAUSED-PIPELINE.json records recovery. Valhalla/OSRM deeper preference and fuel-state gates run in separate owned spike directories under bounded tiny correctness slots, following the owner's request for comparable investigation. No product code, deployment, published data or remote changed.


### Deeper competing-engine gates and resource failures

Valhalla gate:16native requests and8 importer comparisons. Its stock preferences do not express Dirt10/30; native DynamicCost extension is credible. All three stop types lose via prefix in the synthetic restriction fixture. Source-backed continuation extension design retained in VALHALLA-GATE.md. OSRM gate:55queries, exact V4 walk audit and fixed-itinerary fuel certificate. Custom Lua metrics select dirt and represent unknown exclusion/directional permissions. A full request retains via state through a projected pump; separate requests lose it even with bearings. Existing expanded phantom-state continuation token is a credible narrow extension, not yet implemented. OSRM-GATE.md records metric quantization and customization limits. Neither engine is rejected merely for stock API mismatch.

Correction to earlier log-based interpretation: OSRM eastern extraction printed its final completion text but its process group still exceeded4GiB (4243.94MiB,1071.43s), so this is a FAILED budgeted build. Downstream partition/customize are labeled salvage diagnostics, not proof of compliant preparation. Valhalla eastern build similarly failed at4314.59MiB/123.14s; source investigation identified full mmap residency during cul-de-sac scan of2.4GiB way_nodes plus2.1GiB ways. A bounded scan adaptation is being investigated privately. Driver75626 was resumed and completed. Current comparison driver10036 is paused only until the queued objective-landmark stage finishes, which resumes it in finally; PAUSED-COMPARISON.json and objective-landmark-stage.py record recovery. Do not leave it paused.

Initial real NSNB fuel query (180km usable range/90km starting usable fuel) hit100k labels with unguided resource Dijkstra. Distance-landmark resource guidance found a376.714km route with three refills at93227labels. Independent V4 audit of combined route+escape and station/fuel accounting passes. Paved objective still hits100k; no full-profile success. These overlapping correctness runs are not uncontended latency comparisons.

A separate equivalence check caught GH bidirectional landmark search returning544.223km for the paved road minimum after adding interior pump projections, versus535.795km with flexible Dijkstra. Forward landmark A* matches535.795km. Fuel road-certificate search now uses forward A*, whose reopen behavior handles inconsistent zero virtual-node estimates. This fix must be retained and repeated across larger cases; original endpoint-only road results still require flexible comparisons. Stronger objective-specific landmark preparation is now a separate artifact hypothesis, keeping the distance-only artifact intact. Seven synthetic restriction cases and six fuel assertions pass after these changes. Full fuel continuation/ranking/city policies, eastern verified cases and concurrency remain outstanding.


### Resumed on SIDECAR; eastern native HTTP capacity

Owner resumed architecture work after relocation. Active private checkout now /Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture. Ran eastern OSRM shared mmap HTTP server with 2 and 4 workers, outstanding client levels 1/2/4/8, three rounds of32 mixed NS short/QC/ON/NSNB/NS-ON/WV queries per level:768 workload requests passed stable geometry/distance controls. Peak process-group RSS402.16/427.67MiB. Two-worker median throughput55.1/72.8/77.6/82.3rps; median round p95response35.5/56.0/84.7/158.0ms. Raw results and summary in external results/eastern-road/osrm-concurrency-workers*.json and concurrency-summary.json. Process-cold startup, warm OS cache; car metric only, no DIRT profiles/fuel, exact native queue or private-memory counters, hosted capacity or thousands-user claim. Build remains salvage artifact after failed extract RSS guard.

Started staged private Valhalla streaming parser retry under4GiB/1800s per stage, one native thread, failed original preserved. Implementing opt-in scalar road portfolio plus exact-path fuel certificates in GH to avoid global Pareto label growth; no qualification until measured/audited.


### Valhalla phase repair measured; scalar fuel portfolio correctness

Private full eastern parseways stage succeeds148.60s/267.31MiB sampled peak, versus original build RSS guard failure4314.59MiB at the cul-de-sac scan. Same input bytes; one thread rather than two, and streamed scan. Stage2 parserelations/parsenodes succeeds103.80s/3513.47MiB. Remaining graph stages still running; do not claim full import success. Process RSS does not include filesystem cache residency.

Implemented opt-in fuelPortfolio/portfolioOnly in VerifiedHopper: seven nonnegative distance-penalty road seeds on the same projected turn-state graph, original-objective scoring, fixed-path refill and destination-escape certification, explicit incomplete if the bounded portfolio has no certificate. This is finite candidate generation, not constrained optimum. Small check-gh-portfolio.py passes original-cost recovery, via history, fuel/escape accounting, exclusions and partial-start failure; existing six check-gh-fuel.py regressions pass. Tiny correctness checks overlapped the import, so no performance result is inferred. Regional comparison remains pending the heavy-work boundary.


### Repeated NSNB fuel portfolio; verified WV expansion

Regional portfolio first Dirt10 run11.172s/481.75MiB group peak; Dirt30 run6.208s/508.81MiB, both independent V4/fuel audits pass. All four additive objectives then repeated3times in one process:12stable source-path proofs, all independent fuel/source-walk audits pass. Median requestseconds distance5.529,paved6.109,dirt10=5.735,dirt30=5.801; process group peak870.84MiB. Raw results external results/portfolio-{dirt10,dirt30,all-repeat}* include exactqueries,steps,guards,audits. Final routes:distance376.714km (4.106km dirt,27.662km unknown surface),paved525.054km entirely paved,Dirt10=464.204km/218.555km dirt,Dirt30=467.855km/223.625km dirt. Unknown surface is distinct from unknown motorized access. Earlier Dirt resource searches hit500klabels; portfolio produces feasible finite candidates, not global constrained optima. Compared with unconstrained Dirt30=531.578km/299.128km dirt, this fuel portfolio loses some dirt; full rider ranking/continuation/national qualification remains required. Distance-only scalarization repeats an identical road path and adds overhead; skip those redundant candidates in the next refinement.

Valhalla stage3 fails4GiB guard during local tile construction138.47s/4126.33MiB. Source shows read-only working sequences remain mapped across all tiles; investigate releasing mapped pages at tile boundaries without dropping data. First streaming fix remains a measured phase improvement, not full-build qualification.

Verified WV prepared join exported10.24s/731.34MiB:6,595,291nodes,8,096,548edges,68,399compiled restrictions; original immutable six-region bytes. Stations export17.38s/1467.89MiB. GH distance-lower-bound import underway in separate gh-verified-wv-directed-v2 artifact under4GiB/1800s guard. No published data or product runtime changed.


### Unified500x/hard urban/120-mile admission benchmark

Owner authorized a pinned built-up dataset with coverage limits. Full evidence external unified-stress/RESULT.md,contract.json,results.json and rawguards. Bespoke strongest available incoming-index path finds road but hits500kfuel labels28.0s/2232.55MiB sampled; GH finds road seeds but nofuelcertificate before90s/2487.17MiB. Valhalla/OSRM exact regional adapters absent, not claimed native runtime failures. No candidate passed admission, so500-client load and CPU throttling were NOT measured. Full route physical infeasibility and architecture superiority are NOT established by these failures. Superseded harness/configuration failures retained. No production or native app changes.
