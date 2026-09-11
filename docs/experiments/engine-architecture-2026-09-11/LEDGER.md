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
