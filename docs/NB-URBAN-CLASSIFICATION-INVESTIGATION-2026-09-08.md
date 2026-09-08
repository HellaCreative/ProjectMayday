# City classification omission — read-only investigation

## Finding

All63 candidate03 graph metadata sections were read directly using the V4 header offsets (60 to72), without modifying any graph. NS contains3 cores and57 settlements. Other62 regions have null city/settlement metadata. NB03 reuses NB02 graph bytes. This is not a missing OSM city record: the source-locked NB PBF SHA2568b91a1af07eafcc7a35e8d8eadb4a17a37db01f08e544a3eea5616a6ac6745e5 matches the lock and includes the named cities. Source timestamp2026-09-06T20:21:35Z.

## Cause

Build-region-graph-v4.js only embeds routing/data/regions/<id>/urban-cores.v1.json if already present. Frozen factory checkout a4589c2 has no such sidecars. The factory neither generates them nor fails when absent. Main working tree has16 generated regional sidecars, but none for NB. Existing NS was retained by accepted-pack reuse. Thus the national verification did not establish completeness of this feature. The national candidate must not be described as complete for city avoidance.

## Original source evidence

|Place|OSM node|OSM category|Population tagged (2021)|Existing DIRT classification|
|---|---|---|---|---|
|Moncton|204466183|city|79470|core,4.5km estimated radius|
|Fredericton|204462923|city|63116|core,4.5km estimated radius|
|Saint John|129999186|city|69895|core,4.5km estimated radius|
|Dieppe|1756239979|town|28114|settlement, not core|

Source nodes extracted read-only from the exact locked PBF, not downloaded current OSM. Extract also includes neighbouring-region places; any repair needs ownership filtering or explicitly documented overlap handling. This node probe is evidence, not a complete production classification artifact. Existing algorithm uses place and population to estimate rectangular areas; those rectangles are DIRT policy, not OSM-defined urban boundaries. Dieppe must not silently be promoted to a city core contrary to that policy.

## Repair options for review

1. For isolated live evaluation, generate a versioned classification sidecar from the locked source with recorded source hash, ownership rules and existing classification-policy version. Have the live reader consume that explicitly identified sidecar while preserving road, fuel, legal and border data and sealed02. Verify resulting Clean behavior with routing owner. This requires a small explicit loader integration; it is not currently implemented.
2. Once behavior is accepted, embed the same proven metadata in new versioned graphs, re-encode/reseal and update manifests, checksums and service release guards. Demonstrate road/geometry/fuel/legal/border sections are unchanged. This is a metadata correction and need not require downloading OSM or recalculating road topology. Existing metadata/provenance writer support must be reviewed before implementing this option.

Factory correction must make classification generation and verification explicit for every region, distinguishing genuinely empty results from missing work. Preserve sources and current candidate objects; no deletion, overwrite or activation performed. Stable945978 and NS02/NB02 unchanged. National activation remains pending feature completeness and live verification.

Evidence: scripts/pack-fabric/routing/candidates/fabric-v4-20260908-03/nb-urban-investigation contains pack-urban-inventory.json, place-nodes.opl and place-node-summary.json.

## Local review sidecar prepared

Routing owner requested a bounded local review using place=city|town population>=20000, including Dieppe, based on Richard’s workshop intent. This changes the candidate threshold explicitly; it does not silently redefine the frozen factory. File candidate03/nb-urban-investigation/nb-urban-review-20260908-01.json; SHA256 f0ff6558341b52ea7a869458c709aba8872808677445dc5e1c8bb81e1d989b9f. Four cores: Moncton/SaintJohn/Fredericton4.5km; Dieppe1.8km using existing place-sensitive radius formula. Fourteen known smaller settlements,26 missing-population records separate,3 neighbouring-region nodes excluded with shared polygon ownership. Populations/dates and source identities retained. This is explicitly a node-source review; area-only place features not assessed. Source checksum reverified before generation. prepare-nb-review.cjs reproduces JSON from saved source extract. No pack mutation, publication or live consumption.
