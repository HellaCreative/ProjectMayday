# DIRT pack recovery — Atlantic canary first

September 8, 2026. Planning only. No builds, downloads, pack deletions, application changes or deployments have been performed for this revision.

## The one immediate objective

**Establish a passing Nova Scotia pack and working connections across Nova Scotia, New Brunswick, PEI, and Newfoundland and Labrador, using the actual packaged data and readers intended for the product. Until that passes, V4 is unaccepted.**

This replaces the previous multi-stage repair programme. Historical comparisons are supporting evidence only when they answer a concrete question. Reconstructing when every regression happened is not a workstream. Preserving the existing packs is not a requirement.

Quebec is the next conditional gate because it tests the same factory at larger scale. National repair or rebuilding is decided from the Atlantic and Quebec results. California does not displace this sequence.

## What the Atlantic canary must establish

The canary covers the pack factory's complete output, not just a line drawn between selected towns.

| Requirement | Evidence of a pass |
| --- | --- |
| Roads and dirt detail | Required source roads, intersections, surface detail and unknown-access distinctions survive into the packaged data. Known dirt is available for routing where its access and connections permit it. Missing or blocked roads have a specific explanation, not an assumption that the search engine is at fault. |
| Legal details | One-way roads, turns, bridges, barriers and access are represented and read correctly. Unknown access and uncertain gates have explicit, consistent handling. A restriction cannot disappear at a pack boundary. |
| Atlantic connections | Complete journeys within each region and between the regions work through the actual roads, bridge and ferry connections as applicable. Check both directions and different crossings and origins. Do not mistake a working border fragment for a working journey. |
| Fuel | Stations survive the build, appear correctly, and connect to the road network at usable entrances. Pack defects must not strand fuel stops or make them inaccessible. |
| Layers | The required road/access/surface and service information appears correctly. Display data and routing data must not give contradictory accounts of the same road. Their separate files remain separately identifiable. |
| Compression and delivery | Validate the exact final packaged output, including compression. Opening it on the service and phone preserves the same roads, connections, attributes and restrictions. A compressed file being readable is not sufficient. |
| Actual use | Automated source-to-route checks and iPhone acceptance agree. Complete journeys work with the matching live data and downloaded data. Failures remain visible until resolved. |

Route requests are an instrument for checking the packs and their readers. Broad Dirt/Balanced/Clean retuning is paused. If a reader or regional handoff prevents valid pack data from working, correct that necessary consumer defect within the canary; do not compensate for it with route-preference changes.

The geographical examples exercise general requirements. Fix the cause in the factory or shared reader, then test different manifestations. Do not install special directions for one named journey.

## Repair or rebuild: the canary decides

Use existing evidence to identify demonstrable failures without starting another historical investigation. The border-selection cap and inconsistent V4 access interpretation are already demonstrated problems.

If existing Atlantic files can meet the complete requirements through a clear, reliable correction, repair them. If their generation is unreliable, their required content cannot be established, or accumulated corrections are less reliable than a clean build, replace the Atlantic candidates from fresh OSM using the corrected factory. Fresh source data alone will not fix a faulty builder.

For a clean build, use a recorded source snapshot with complete road and restriction references, one declared factory configuration, and compression included before acceptance. Record what is included, excluded and uncertain. Prove that the final files retain those decisions and that the app uses them correctly.

Do not rebuild all regions while still discovering the recipe. First obtain the passing Atlantic canary. Then apply that same process to Quebec, including its Atlantic connection, full-region loading, compression and phone use. If Quebec requires a shared factory change, recheck the Atlantic canary against it before declaring the process established.

If these results establish that every existing pack needs replacement, rebuild every pack. If they establish a narrower reliable correction, apply that. Neither outcome is assumed now. Old candidates can remain recoverable until replacements pass; they have no acceptance status merely because they exist.

## What established tools contribute

These are references for the factory requirements, not a decision to replace DIRT's engine with another product. Reviewed from primary documentation on September 8, 2026.

| Reference | Documented practice | Application to the canary — proposed |
| --- | --- | --- |
| Osmium extraction and reference checking | Geographic extracts can omit referenced objects. Extraction strategies and explicit checks distinguish complete roads from incomplete references; relation checking is an additional option. | Require complete relevant road and restriction references before building. A clean download is not itself proof of completeness. [Extraction](https://docs.osmcode.org/osmium/latest/osmium-extract.html), [reference checks](https://docs.osmcode.org/osmium/latest/osmium-check-refs.html). |
| Valhalla routing tiles | Routing files contain road and access information and use geographical tiles at multiple levels. Its build tooling parses OSM, builds routing tiles and checks data deficiencies. | Separate how data is divided for storage from whether roads connect. Evaluate bounded loading for large data without sacrificing local roads. This is a design reference, not a requirement to copy its road hierarchy or favour highways. [Tile structure](https://valhalla.github.io/valhalla/concepts/tiles/), [build process](https://valhalla.github.io/valhalla/contributing/architecture/mjolnir/). |
| Valhalla integration tests | Tests cover map parsing through routing results, using constructed maps and expected outcomes. | Protect general failure causes through source-to-pack-to-route checks, alongside real Atlantic data and physical acceptance. This avoids tests that only prove a decoder accepts a file. [Integration tests](https://valhalla.github.io/valhalla/contributing/gurka/). |
| OSRM preparation and serving | Separate extraction, graph preparation and serving stages; prepared data can be memory-mapped or shared rather than always fully copied into each server process. | Treat storage size and working memory as distinct requirements. Prove the final dataset and loading method together in Quebec. Compression alone is not proof of sufficient runtime memory. [Data pipeline and loading](https://project-osrm.org/docs/v26.4.0/tools). |

These references do not prove DIRT's particular road permissions or dirt objective, and their formats are not interchangeable with DIRT's. They supply concrete practices against which to check the proposed factory rather than inventing another format revision on assumption.

## Decision and reporting boundary

The next result should be an Atlantic canary verdict: which requirements pass, which fail, the demonstrated causes, and whether correcting or rebuilding the candidate is the reliable path. During implementation, report meaningful discoveries and offer the physical canary at the acceptance boundary. Do not wait for national rollout before the owner tests it.

There is no national-completion claim and no routing-optimization programme attached to this gate. **Atlantic first. Quebec after Atlantic passes. The resulting proven factory determines the national work.**

The earlier evidence is retained in [the assessment record](RECOVERY-EVIDENCE-2026-09-08.md). Its previous proposed sequence is superseded. It is not necessary to re-investigate every historical item before proceeding with the canary when implementation resumes.
