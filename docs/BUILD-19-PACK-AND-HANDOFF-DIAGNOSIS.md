# Build 19: pack and handoff diagnosis

Owner scope: cross-region connectivity and accessible dirt/Allow Unknown; no general route tuning. Source cfa69055dae13595de7cb304f9d92afa73731856. Pack bytes untouched.

## Demonstrated regional selection failure

Physical log: /Users/richardsmith/Downloads/dirt-app-debug-2026-09-08T105615Z.txt. Exact Maine journey 44.76483005523871,-63.340264951978995 to 44.882764010410504,-68.78681042826338. Live replay fails hop 2/3 toward seam me-nb. Its loaded graph has 187354 nodes and 220770 edges: Nova Scotia, not New Brunswick.

Selected NS/NB seam [-64.24995422363281,45.87654495239258], ME/NB seam [-66.9678955078125,44.84646987915039]. Controlled request retained those exact endpoints, profile, service source and original pack objects but explicitly selected regionId=nb with chaining disabled. It returned complete, 550619 m, with sealed NB graph SHA 82b373be087f0ddd84d4c56b07fcc7c9e3f020ea02954a67f63766459376130e. This proves these points can connect in the existing NB pack, not route quality or fuel feasibility.

Code path: resolveChainSeamWaypoints replaces intermediate points with coordinates and between pairs. Both routeCanadaChain and cross-region fuel planning infer the next region from which administrative polygon contains the border coordinate. Intermediate hops prefer the start point’s polygon owner. A border point on the NS side therefore selects NS again for the NB section. Correct regional ownership should follow the ordered region journey and the shared membership of adjacent seam pairs; it cannot be inferred solely from the border coordinate. No runtime edits or deployment made during this diagnosis. Other state/state and state/province pairs require verification of the same mechanism; they are not all declared fixed.

## Dirt and unknown-access evidence

Read-only inventory of the sealed NS graph, using starting-node bounding box lon (-61.5,-59.7), lat (45.5,47.1), approximately Cape Breton (not an exact island polygon): about 2704 km explicitly gravel/loose with verified direction available, and 3098 km explicitly gravel/loose with unknown access and no verified direction. Counts are packed edge lengths, not unique geographic road coverage, and do not establish one connected journey or route-achievable percentages. Dirt is present in quantity; global absence is not supported.

The restored router’s V4 legality gate blocks denied/conditional and scoped endpoints but does not apply Allow Unknown to directional code 1. It then applies the older aggregate access enum. Inventory contains disagreements: in the box, 157 km known-unpaved unknown-direction edges have aggregate permissive classification, while 150 km verified gravel edges have aggregate unknown classification. Thus the switch does not consistently operate on V4 directional access. This is demonstrated code/data inconsistency; its share of the low-dirt journey result remains unmeasured. Both Swift and JS behavior must be checked together for a correction.

Unknown ACCESS and unknown SURFACE are different. Enabling uncertain permission must expose eligible known dirt; it cannot turn an unknown-surface edge into proven dirt. Do not change reported percentages to manufacture a near-100% outcome. Audit connected eligible dirt and rejected accesses separately from route ranking.

Evidence files in /Users/richardsmith/SandBox01/MAYDAYiOS/routing-recovery-20260907-230537: build19-maine-request.json, build19-maine-response.json, build19-nb-handoff-control-request.json, build19-nb-handoff-control-response.json, audit-pack-access.js, ns-access-inventory.json.
