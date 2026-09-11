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


## Owner-selected hybrid v1 implementation

Implemented persistent HybridHopper and bounded FuelRepair with exact incoming
state through excursions and rejoin; retained independent road and fuel outcomes.
NSNB four additive objectives x3, mixed NS/NSNB 42 shared-graph requests, normal WV
and strict masked500x WV fuel candidates pass source and fuel audits. Strict WV
now found ~50 s versus previous90 s incomplete; two concurrent strict repeats
match control at ~50 s each under3.19GiB group peak. This is a feasible heuristic
candidate with explicit dirt-character trade-offs, not global optimality, complete
product profile parity or500-client qualification. Initial local-only WV repair
failed; two-seed repaired fallback solves it. Naive redundant fuel stops/avoidable
excursions were refined. See HYBRID.md and pinned hybrid-evidence.json for scope,
commands, failures, comparisons and recovery. No production, app, pack or remote
change. Private Android parity not claimed.


## Hybrid refinement: fuel alternatives, stronger LM and bounded service

Following private v1 f3a10ffe, implemented incumbent-preserving same-node/downstream/
objective fuel repairs, early retry, separate JVM/phase diagnostics, and service
queue deadlines/cancellation. NSNB four objectives x3 pass independent fuel/source
audits; dirt30 adds 27.602 km known dirt for 3.370 km route distance at similar
0.512 s median. Paved/dirt10 improve objective cost but incur extra median latency.
Quebec four objectives pass at 120-mile full initial range, 1.63–7.23 s, but dirt30
is less dirt-rich than dirt10 after fuel fallbacks: full DIRT ranking remains open.

Strict WV keeps exact v1 roads/refills/escape through seven refined/strong-index
responses. Private cost/mask-specific LM preparation succeeds after uniform
1/1000 cost normalization avoids a native storage-factor overflow. Eight copied
base graph files remain hash-identical; published source bytes are unchanged.
Stronger index: first request 35.9 s vs refined distance-LM control 48.0 s; three
serial runs median30.5 s. New shared-graph test36.6 s control, two concurrent34.4 s
each, peak2.86 GiB vs earlier50.3 s/3.19 GiB. All independent source/fuel/mask audits
pass. No hosted/500-client, app, full-profile or physical pump-access qualification.

Rejected broad early/objective exploration, downstream-only replacement, and
scaled old distance bounds (<1% visit savings, added overhead). One initial
scaled-guidance result used stale classes after compile failure and is explicitly
invalidated. Build staging and source-identity launch checks prevent repeating it.
One historical tiny boundary output was overwritten; all other v1 receipt hashes
remain valid. Current named final fixtures and evidence are preserved separately.

Final checks cover fuel/range/restrictions, legal downstream and prohibited turns,
service cancellation/expiry/overflow/duplicates/recovery, idle-only GC and stale
build refusal. Twenty real diagnostic records validate. See HYBRID-REFINEMENT.md,
HYBRID-DIAGNOSTICS.md and hybrid-refinement-evidence.json for exact scope, failed
approaches, recovery and raw evidence. Fuel remains integrated: about1 s repair
versus44 s road/alternative work in the measured original-LM control.


## First shared DIRT selection over the hybrid

After c9e077b, implemented hybrid-rides.js using the existing DIRT surface
comparator and fuel arithmetic over one shared GraphHopper candidate pool.
Dirt/Balanced/Clean select the same generated feasible set; completed pool reuse
avoids graph work on style edits. One serialized output cache is bounded to16MiB,
not a topology/memory bound. Unknown surface remains separate and station access
is explicitly provisional. Unsupported waypoints/history and missing initial
fuel are refused. Java changes add scoring metadata only; engine costs unchanged.

Integrated six-case matrix: four NS/NSNB pools0.699–1.818s, Quebec17.788s, strictWV
36.644s.18cached style edits0.97–6.83ms local.21source audits pass including17fuel
itineraries. Metadata independently matches source surface and DIRT backroad cost.
StrictWV unchanged exactwalk/escape,zero maskededges.9focused tests and actual
service cancel/busy/recovery/deadline/cache checks pass. Quebec selection fixes
3.49%→9.53%dirt but remains too paved; finding richer feasible corridors is still
required. Strong strictmask profiles share one fixed cost,so one seed is executed;
coincident style choices there do not demonstrate product profile diversity.

See HYBRID-SHARED-SELECTION.md and hybrid-shared-selection-evidence.json for raw
inputs, outputs, limits, checks, source identities and recovery. Private milestone
only; no app, Android, pack, deployment or remote change. Hybrid is the selected
development foundation based on improved route admission, not a full replacement
or500-client qualification. Earlier bespoke28slabel exhaustion and priorGH90s
fuel timeout remain distinct comparison outcomes.


## Combined endpoint search and device-first workload milestone

Private checkpoint e211ea9 combines legal endpoint searches over the prepared
objective landmark graph. Complete unmasked NS→WV selection fell from 72.330s
fresh / 58.020s warm to 39.395s fresh / 39.491s after regional work. Four WV
candidate geometries, fuel positions, costs, distances and escape paths match;
two source decompositions differ only in representation. Full six-pool matrix
passes 24 independent candidate audits (4 road, 20 fuel). Fixture checks1044,
real Dijkstra comparisons96 plus24 combined minima, and19 JavaScript checks pass.
Earlier 500-distinct and sustained load failures remain recorded; new combined
search concurrency is unqualified. No live deployment changed.

Owner then authorized a bounded device/server experiment and clarified no automatic
server escalation for ambitious personal planning. Added a policy/state-machine
reference with16 controlled tests, preserved full constraint fingerprints,
acknowledged cancellation, stale-result rejection and retained last-valid route.
Actual phone limits remain unset. Supported fallback requires explicit admission.

Snapshotted the main checkout's native Swift sources into a standalone macOS
probe; actual input/output source hashes are retained. Six NS road cases complete,
250.953MiB sampled group peak,1.027s decode,0.366–11.746s search. Independent V4
source-direction/access/turn/distance audits pass all six. The approach geometry
is separately labelled; no fuel-chain or iPhone qualification is claimed.
Native cancellation continued5.525s after cancellation. Private generated-source
checks in five search loops and road guidance reduce the observed tail to0.204s.
A20ms search budget returns incomplete after0.215s, exposing uninterruptible
preparation. Recovery works; repeat six-case native matrix has exact legs for all
routes and six passing source audits. Resource-pressure handling, full decode/
preparation cancellation, native fuel/history/custom-settings parity and physical
hardware measurements remain necessary before app integration.

SIDECAR briefly disconnected; isolated policy work continued on internal storage
and was copied back with hashes when the owner reconnected it. No data loss or
app/source-pack modification. Evidence: DEVICE-WORKLOAD.md and
 device-workload-evidence.json. The hardware-target question is pending; no Red
operation or physical-device installation is authorized.


## Authorized White iPhone 16 phone-lab milestone

The owner authorized a separate private phone app, corrected the target from
iPhone17 to White/iPhone16, and supplied two completed exports. RED was never
operated. Built from the pinned native-v6-cancel source snapshot and unchanged NS
bytes, with a UIKit control screen, serial work, latched stop state, sample-based
resource guards, background/memory-warning handling and local evidence export.
Existing wildcard development signing was used locally; no portal operation or
accepted app replacement. No product Android behavior changed.

Physical iPhone16/iOS26.6.2: two six-check suites13.974s/14.343s. Clean0.200–0.213s,
Dirt3.977–4.082s, Balanced9.197–9.469s. Four intentional interruptions return
incomplete at~100ms (20ms trigger,~80ms overshoot). Eight completed road results
are EXACT versus the earlier native baseline and all8 independent direction,
access, continuous-turn and distance audits pass. Peak footprint201.860MiB; peak
resident296.563MiB; thermal state nominal; main-thread100ms heartbeat max101.043ms.
45% battery readout unchanged is not an endurance result. No phone OOM/pressure
was induced. Simulated memory-warning handling and actual simulator Stop-button
interaction preserve recovery and prior candidates. Simulator copied out/cleaned
and shut down; no clones.

This demonstrates only one regional fixture across three profiles, fuel off,
Allow Unknown false. Full app overhead, complete prep cancellation, actual memory
pressure, larger/multi-region routing, fuel/ordered-history parity and general
resource limits remain unqualified. Capability policy still has no production
qualified-device entry; no automatic server escalation. GraphHopper–DIRT remains
the controlled server foundation. PHONE-LAB.md and phone-lab-evidence.json pin
inputs, final source manifest, signed executable and raw logs/audits. Final bundle
local.dirt.experiments.phonelab20260911 remains on White with completed workers.

## Native fuel preparation and continuity correction

The next private candidate snapshots the actual `PackRoutingSource.fuelChain`
method and improves only the preparation around it. A conservative geometry-bounds
index reduces the 671-station NS matching comparison from 65.211 s broad matching
to 0.838 s indexed first pass; bounded match caching repeats in 0.073 s. A full
reference-area verification omits zero qualifying segments. Broad edges remain
discoverable and eviction recomputes matches; no topology or decoded road graph is
removed. Twelve index fixtures pass, including curved geometry, polar longitude,
broad-edge allocation and empty results. Clean candidate fuel searches complete in
3.34–3.86 s on the local macOS facade; Dirt and Balanced hit their 30 s diagnostic
budget after repeated road calls. No phone fuel, hosted capacity, pump availability
or complete itinerary success is claimed.

The initial 21-case continuity receipt contained a diagnostic path weakness: its
synthetic motor-vehicle-only restriction did not surface the unsupported mask to
the gate. The result was rejected and not promoted. The corrected fresh
`native-fuel-v7` build exposes the decoded masks and passes 22/22 continuity cases;
the 12 index fixtures also pass in `index-fixtures-v8`. The gate preserves source
identity, range, access, ordered turn state and fuel continuation, and fails closed
on unsupported restriction scope and unmapped pump approaches. The actual accepted
Swift app remains unchanged; this is a review candidate only.

### Direct-search skip A/B (rejected)

The native-fuel-v7 private probe compared the optional direct-search skip for
the two cases that still exhaust the 30-second budget. Dirt was 30.064 s with
the switch off and 30.038 s on, six calls both ways. Balanced was 30.003 s off
and 30.004 s on, eleven versus ten calls. The result is not a material gain;
repeated candidate-leg searches remain the bottleneck. Raw runs and the exact
decision are recorded in `native-fuel-evidence.json`.

## Private Dev app integration candidate

The next step moved into the real app boundary in the isolated worktree. The
bounded native fuel-snap cache and cooperative pump-loop cancellation are active
in `Dirt/Routing/OnDevice/OnDeviceRouter.swift`; the prior matcher remains
available as an in-branch rollback path. The DIRT Dev simulator build succeeded,
and the arm64 DIRT Dev build signed and installed on White/iPhone 16 as
`com.mayday.dirt.dev`. After White was unlocked, it launched cleanly; StoreKit,
the map style and the app root all appeared. No route has yet been executed
from this app build.

The focused test run had 49 passes and one existing request-shape failure in
`atlanticDevRequestsCombinedFuelGeometry` (`forwardFeeler` optional `nil` versus
expected `false`). The candidate diff only touches `OnDeviceRouter.swift`; this
must be resolved or baselined before promotion. The app candidate is a timing
and preparation test, not fuel qualification; the continuity gate, pump access,
larger regions and Dirt/Balanced completion remain open.
