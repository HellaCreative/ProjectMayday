# OSM Pack Quality Standard

This is the release gate for every DIRT province, territory, and US state pack. The live pack is the source of truth. A downloadable/offline pack is published from the exact same `graph.v2.bin` only after its live routes are approved.

The foundational pack is OSM-only. Provincial, state, DRA, FTEN, NRN, and other secondary sources stay out until that region's OSM pack and router pass this standard. Secondary data must later be evaluated as an explicit, separately reported layer; it must never silently change the OSM baseline.

## Product invariants

- Preserve OSM facts. Never infer dirt merely from `highway=service`, `track`, `path`, `cycleway`, or another road class.
- An explicit `surface=*` tag wins over every road-class fallback.
- Missing surface is `unknown`, except conventional untagged major roads may use the documented paved default.
- Access precedence is `motorcycle` → `motor_vehicle` → `vehicle` → `access`.
- Known restrictions such as `private`, `customers`, `delivery`, `forestry`, `agricultural`, and `destination` are not permissive through-routes.
- Unknown motorcycle access remains behind **Allow unknown**. Dataset identity (including OSM) cannot bypass that switch.
- No free-space connectors. A stitch may only join eligible dangling tips within the audited stitch tolerance.
- Every cross-pack seam is the same OSM way ID at the same quantized OSM vertex in both packs, with zero measured gap. Both sides must be permissive/verified and part of each pack's largest permissive component. Proximity, road name, and sampled border points are never seam evidence.
- An intermediate seam must be at least 5 km outside every embedded urban core. A chain seam is an implementation detail, not A or B, and must never trigger the endpoint-inside-core exemption.
- Because regional OSM extracts overlap at borders, each binary embeds adjacent-region core/settlement boxes that intersect its own graph bounding box. Urban policy therefore follows the road fabric across the seam instead of stopping at the administrative line.
- Urban blocking tests both graph nodes and the segment between them. A long OSM edge cannot tunnel through a core merely because its endpoints are outside the box.
- Pack statistics and route scoring must use the same surface interpretation.
- A profile corridor is an outer search envelope, not mileage the route is expected to consume. Dirt compares several envelopes and works back from 100% dirt; total distance is never its objective. When dirt yield is effectively tied, less pavement and then less backward/lateral movement win.
- OSM `place=city|town` is packed in two levels. Cities at 20,000+ people, cities whose population is missing, and towns at 50,000+ are hard urban-core walls. Core radius is population-scaled (3.5 km below 50k, 4.5 km at 50k, 5.5 km at 100k, 10 km at 200k, 14 km at 500k, and 18 km at 1M+) so a municipal boundary or rural rectangle corner is not mistaken for downtown. Smaller cities/towns carry a scored avoidance penalty so they lose to a comparable wilderness alternative without severing a rural graph whose only through-road crosses town. A or B inside the same box is exempt.

## Repeatable build

Run from `scripts/pack-fabric/`. Replace the region code and Geofabrik slug only.

1. Cache the current Geofabrik `.osm.pbf` and record its replication timestamp/checksum. The shared extractor cache automatically refreshes inputs older than 12 hours so a file named `latest` cannot remain stale indefinitely. Set `OSM_REFRESH=1` for an unconditional download or `OSM_PBF_MAX_AGE_HOURS=<n>` to tighten the gate.
2. Extract the common DIRT highway set with `scripts/extract-osm-roads.sh <geofabrik-slug> [canada|us]`. This deliberately includes roads through ATV-scale paths but excludes pedestrian-only classes.
3. Build the region as OSM-only:

   ```sh
   OSM_ROADS_ROOT=/path/to/osm-roads node scripts/build-region-with-supplement.js <region> --osm-only
   ```

4. Create an OPL copy of the same included ways for the independent raw-tag audit:

   ```sh
   osmium tags-filter -R -f opl source.osm.pbf \
     w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path,cycleway \
     -o roads.opl -O
   ```

5. Audit raw OSM tags against the intermediate pack:

   ```sh
   node --max-old-space-size=4096 scripts/audit-osm-surface-normalization.js \
     --opl /path/to/roads.opl \
     --pack routing/data/regions/<region>/graph.v1.json.gz
   ```

6. Derive both levels of settlement policy from the same OSM release. The shared population thresholds above define hard walls; smaller cities/towns become scored settlement avoidance. For BC/AB/WA the slug is built in. Every other province/state supplies the Geofabrik slug explicitly, so no region-specific policy code is required:

   ```sh
   bash scripts/extract-osm-urban.sh <geofabrik-slug> [canada|us]
   node scripts/pack-region-urban.js <region> [geofabrik-slug]
   ```

7. Add only eligible short tip stitches and create the phone/live binary in one operation. This embeds the urban sidecar and any already-built seam sidecar:

   ```sh
   node --max-old-space-size=8192 scripts/stitch-adventure-tips.js --pack-v2 \
     routing/data/regions/<region>/graph.v1.json.gz
   ```

8. For every adjacent pack pair, build a topology-authored seam and then regenerate both binaries so both directions carry matching metadata:

   ```sh
   node scripts/build-cross-pack-seams.js <left-region> <right-region>
   node --max-old-space-size=8192 scripts/stitch-adventure-tips.js --pack-v2 \
     routing/data/regions/<left-region>/graph.v1.json.gz
   node --max-old-space-size=8192 scripts/stitch-adventure-tips.js --pack-v2 \
     routing/data/regions/<right-region>/graph.v1.json.gz
   ```

   The seam build also refreshes `routing/schema/cross-pack-topology.v1.json`.
   That compact deployment index is mandatory: live routing uses it to choose
   the already-proven OSM seam without downloading both full graph packs just
   to rediscover boundary topology. Never hand-edit the index.

   For a graph too large for Node's single-string limit, pass border-clipped GeoJSON sequences from the two original OSM extracts with `--left-seq` and `--right-seq`. The acceptance rules are unchanged.

9. Stage the packs and merge their manifest entries. Never replace the whole manifest for a one-region release:

   ```sh
   node scripts/publish-packs-cdn.js <region> --local-only
   ```

10. Run automated tests and the deliberate regional matrix. A new region first ships under an immutable live-candidate prefix. The production API can use that candidate for the named region while every approved downloadable pack and every other live region remain unchanged:

   ```sh
   node scripts/audit-region-routes.js <region> \
     --out routing/data/reports/<region>-route-acceptance.json
   node scripts/ship-routing.js --candidate <release-id> --pack <region> --live
   ```

11. Run the candidate matrix against production and complete physical route-shape, fuel, gesture, incident-report, and offline detour tests. Approval promotes only when the local bytes still match the immutable candidate record. This updates the stable manifest and removes the live candidate override; a changed checksum requires a new release ID and another test cycle:

   ```sh
   node scripts/audit-region-routes.js <region> \
     --live https://dirt-mayday.vercel.app/api/route \
     --out routing/data/reports/<region>-production-acceptance.json
   node scripts/ship-routing.js --promote <release-id> --pack <region> --live --assert
   ```

Deploying `--live` without a candidate override immediately returns live routing to the approved stable pack set. The candidate upload never rewrites `manifest.json`, so an unapproved live experiment cannot become an offline download accidentally.

For a US state, first add its Geofabrik slug/region mapping to the regional builder. The classification, audit, acceptance, and publication gates do not change.

## Acceptance gates

A pack is rejected unless all of these are true:

- The raw-tag audit reports zero semantic contradictions: no chipseal-as-dirt and no invented surfaces on untagged service/track/path/cycleway ways.
- OSM lineage is present for every native OSM edge; non-OSM source edge count is zero for the foundational release.
- Access tests pass, including motorcycle precedence and Allow-unknown gating.
- Stitch report contains no free-space connectors; every stitch is separately identifiable and within tolerance.
- `graph.v2.bin`, `geometry.v1.bin`, optional `fuel.v1.json`, and manifest size/SHA-256 values agree locally and on R2.
- Every adjacent-pack profile matrix crosses through a topology seam in both directions of the metadata. Local, preview, production, and on-device routing all consume that same seam list.
- Each selected seam is outside the 5 km urban clearance, and a geometry-to-core audit reports zero non-endpoint urban-core intersections unless `urbanCoreFallbackUsed=1` is explicitly present.
- Live `/api/route` reports the same schema and edge count as the phone pack.
- Route matrix verifies the product promises: Dirt maximizes dirt with earned detours, Balanced is nearest 50/50, Direct follows the A→B alignment, and Clean stays paved while avoiding major cities/highways.
- Dirt acceptance includes the same long route through at least three corridor envelopes. The chosen result must have the highest material dirt yield; a corridor-boundary route is rejected when a comparable-dirt candidate has materially less backward/lateral movement.
- Settlement acceptance includes at least one route whose A→B chord intersects a smaller city/town. The normal result should avoid the settlement when a comparable alternative exists. A forced single-road case must complete with `settlementFallbackUsed=1`, never silently treat the settlement as ordinary routing fabric.
- Cross-pack debug must preserve each hop's routing revision, objective, cap outcome, pops, chosen corridor, dirt percentage, and fallback status. A combined route may not appear as `legacy` when its hops used the current engine.
- Long routes complete within the search caps and expose timeout/pop-cap outcomes instead of silently falling back.
- A physical live-pack test is approved before the downloadable pack is considered released.
- A confirmed real-world surface mismatch on an acceptance route is investigated by OSM way ID. If the packed class disagrees with the current explicit OSM tag, the normalizer is rejected. If current OSM itself is stale or wrong, correct OSM (or archive the exact known limitation) before promotion; never silently invent a local surface override inside the foundational OSM pack.

## Release record

Archive these together for every region/version:

- Geofabrik source URL, source timestamp, and checksum
- adapter/test revision
- raw normalization audit JSON
- build, exclusion, stitch, and edge-count reports
- surface/access kilometre census
- route-matrix inputs and results, including route-shape metrics
- hard-core and smaller-settlement counts, thresholds, radii, and forced-fallback test results
- Dirt corridor candidates considered, selected dirt percentage, paved metres, backward metres, and lateral/cross-track metrics
- final binary byte counts and SHA-256 values
- production deployment URL/ID and live lockstep result
- tester approval date and any known OSM tagging limitations

## Router acceptance matrix for every new region

Pack correctness and route quality are separate gates. A semantically correct graph can still produce a poor ride if the search stops at the first connected corridor.

For every province/state, record representative routes in these classes:

| Test | Required evidence |
| --- | --- |
| Short Dirt | Dirt is not lower than Balanced on the same eligible fabric without an explicit cap/fallback explanation. |
| Long Dirt | Multiple corridor candidates are reported; selection works back from 100% dirt and does not use shortest distance. |
| Balanced | Result is nearest 50/50 among completed candidates; distance is not the objective. |
| Direct | Route follows the A→B alignment and uses the narrowest viable corridor; “direct” is not redefined as shortest. |
| Clean | Pavement first, major urban cores remain walls, major highways are avoided, and any wall relaxation is labeled. |
| Smaller town | Avoids the settlement when an alternative connects; otherwise labels the last-resort settlement crossing. |
| Border | Uses a topology-authored shared OSM vertex and carries per-hop current-engine diagnostics. |
| Gesture/device | After pin drag, pinch, route-sheet collapse, cancellation, and pin removal, one-finger map pan still works. |

Do not promote the downloadable pack merely because these routes complete. Promote only after the live-pack matrix is physically approved, then publish the exact same graph and metadata bytes for offline use.

## BC baseline (2026-08-19)

The corrected BC foundation contains 910,528 native OSM edges plus 25,448 audited tip stitches, for 935,976 `graph.v2` edges. DRA and FTEN are inactive. The rebuild corrected the following pack defects:

- 103,418 untagged service ways had been falsely forced to dirt/resource.
- `chipseal` had been normalized as gravel.
- explicit unknown surfaces could be overwritten by road-type fallback.
- broader access tags could override motorcycle-specific access.
- the live server could count unknown local/service roads as dirt while route eligibility treated them as paved.
- OSM source identity could bypass the Allow-unknown switch in one search path.

BC release binaries after embedding the OSM urban-core and BC↔AB/BC↔WA seam metadata, including the adjacent-pack overlap policy:

- 33 BC-derived hard cores and 145 smaller settlements; 42 hard cores and 220 settlements embedded after adjacent-pack overlap
- `graph.v2.bin`: 58,225,824 bytes; SHA-256 `35598b0ade69655933989420f1ffb4daa6e582cc07717129e00e4a30ba8f2723`
- `geometry.v1.bin`: 72,002,756 bytes; SHA-256 `ef5940c9ae8920413672bdfcdb59afef0f66f7c83346df80d5e325cc2e5e16b5`
- `fuel.v1.json`: 427,970 bytes; 2,111 stations; SHA-256 `f6ae834e58a90533a769ec44687bbe7edec65f7702d3b536fa6d57167d7927c9`

These figures are a traceable baseline, not universal thresholds. Every later region must pass the same semantic gates using its own complete current OSM extract.

## Alberta and Washington production release (2026-08-20)

Both candidates are OSM-only, use current Geofabrik extracts, and passed the independent raw-tag audit with zero unmatched OSM edges and zero semantic contradictions. The extracted road PBF is retained as the reproducible normalized build input.

Alberta:

- Geofabrik source: `north-america/canada/alberta-latest.osm.pbf`; source timestamp `2026-08-20 00:36:51 GMT`
- road extract: 42,395,843 bytes; SHA-256 `2f8191e5d65d61694aaf5bac9f5c360ea2a227b33109445b14d7614696b73ed6`
- 956,740 native OSM edges + 15,522 audited tip stitches = 972,262 final edges
- raw audit: 956,740 matched edges, 0 unmatched, 0 semantic contradictions
- 14 Alberta-derived hard cores and 125 smaller settlements; 19 hard cores and 152 settlements embedded after adjacent-pack overlap; 2,834 packed fuel stations
- `graph.v2.bin`: 59,770,727 bytes; SHA-256 `676fe126cbd890a6e27f6e682d71531211d61204d46c975d0b3c4316cb4a9f9e`
- `geometry.v1.bin`: 41,931,900 bytes; SHA-256 `a35c6e049296391c2a2e4743a4d50b19a41c829796d43bd4cfc6566a587bad43`
- `fuel.v1.json`: 558,498 bytes; SHA-256 `b2e0bb32396fc188782a0d775c30477bdd681035ab5177e59fc9dcd70798efcf`

Washington:

- Geofabrik source: `north-america/us/washington-latest.osm.pbf`; source timestamp `2026-08-20 00:30:47 GMT`
- road extract: 101,746,466 bytes; SHA-256 `89fcf553dfc8cf07cc95c0a366084766bdb3bf9606af0ff675595f4c9784dd4a`
- 1,719,403 native OSM edges + 16,037 audited tip stitches = 1,735,440 final edges
- raw audit: 1,719,403 matched edges, 0 unmatched, 0 semantic contradictions
- 58 Washington-derived hard cores and 159 smaller settlements; 67 hard cores and 175 settlements embedded after adjacent-pack overlap; 4,460 packed fuel stations
- `graph.v2.bin`: 108,045,055 bytes; SHA-256 `42ace8d1b453bc6d4cd62e0ad1b31b977d8ed6901e328883268ca535691acc9c`
- `geometry.v1.bin`: 97,041,620 bytes; SHA-256 `8b372305cefc17cae5d5978bc2a67d83a486d6df2be16110595ddf72b1814c5d`
- `fuel.v1.json`: 794,915 bytes; SHA-256 `2144def5299f08e502144f1dbf7231e463b4d1191a049d44c1e004353a81a391`

Topology seam results:

- BC↔Alberta: 2,555 eligible shared vertices; 96 geographically spread anchors across 48 OSM ways; maximum gap 0 m
- BC↔Washington: 7,537 eligible shared vertices; 96 geographically spread anchors across 56 OSM ways; maximum gap 0 m
- Local route matrix: all 8 combinations passed (four profiles across both borders), each reporting `same-osm-way-and-vertex`
- Production deployment: `dpl_55PrpBzAym7TKihciB88KYXGUqh8`, aliased to `https://dirt-mayday.vercel.app`
- Production lockstep: all nine staged files matched R2 byte counts exactly; the live BC route reported the full 935,976-edge pack
- Production route matrix: all 8 combinations passed and reported `same-osm-way-and-vertex`

## Nova Scotia OSM-only live candidate (2026-08-20)

Live fuel is source-locked with the live graph candidate. `/api/fuel` resolves
the same per-region candidate override as `/api/route`; the app uses that
source while online and the approved installed `fuel.v1.json` only while
offline. This allows physical candidate testing without prematurely promoting
the downloadable pack or silently testing fuel from another release.

Online planning never silently falls back to an installed pack. A live graph or
fuel failure is reported as a live-service failure. On Start Navigation, the app
downloads the route corridor basemap plus every published province/state routing
pack touched by the ride. Installed packs become authoritative only after the
device loses both Wi-Fi and cellular connectivity.

Nova Scotia is the first east-to-west rollout pack and the first pack built through the expanded regional acceptance gate. The foundational graph is OSM-only. NSTDB, NRN, and every other provincial overlay are retained for possible later comparison but are inactive and contribute zero edges to this candidate.

- Geofabrik source: `north-america/canada/nova-scotia-latest.osm.pbf`
- source replication timestamp: `2026-08-19T20:20:48Z`; newest object timestamp in that extract: `2026-08-19T18:46:54Z`; retrieved for this build on `2026-08-20T13:06:24Z`
- 141,021 normalized OSM input features produced 211,931 native OSM edges; 5,128 audited permissive OSM tip joins produced 217,059 final edges
- largest native connected component: 209,332 edges (98.77% of native edges)
- raw audit: 141,063 included ways, 211,931 matched packed edges, 0 unmatched edges, 0 semantic contradictions
- surface census: 30,768.0 km access/resource, 1,075.6 km gravel, 19,411.4 km paved, and 9,650.9 km unknown/Allow-gated
- 3 OSM-derived hard urban cores and 57 smaller settlements; 668 packed fuel stations
- `graph.v2.bin`: 13,535,078 bytes; SHA-256 `20d1c4b79fbbc63ca164ffe683c3e057813c3ddad9f8b3a33d6b4a479c3bf555`
- `geometry.v1.bin`: 23,394,912 bytes; SHA-256 `41659ed9374ea0f399bfff285a41dd3a5e3f5a9153dcae97fd1146dbffd66a63`
- `fuel.v1.json`: 143,384 bytes; SHA-256 `fab91d4030cb3098a9ff2c846abde1444f2496c25fc24ec12bc3a2f1dc866b3f`
- deliberate local matrix: 15/15 routes passed, including Dirt with Allow unknown on/off, with zero caps and zero non-endpoint urban-core intersections
- Dirt results: Yarmouth→Sydney 87%, Halifax→Antigonish 86%, Truro→New Glasgow 86%
- Dirt with Allow unknown: 91%, 91%, and 88%; unknown access remains explicitly labeled
- Balanced results: 46%, 50%, and 50%; Clean results: 0% dirt for all three
- immutable candidate: `ns-osm-20260820-01`; production deployment `dpl_E5EGKXNKTAqBm8S7KCnzYz6KrM63`, aliased to `https://dirt-mayday.vercel.app`
- deliberate production matrix: 15/15 routes passed with the same distances, surface percentages, completed-search outcomes, and zero non-endpoint urban-core intersections as the local candidate
- stable downloadable manifest safeguard verified: it still references the previously approved NS checksum `2780f625f38f3c78f7c720afe094bf7f02dde389525501c86ce2987062b7ccbc`; the OSM-only candidate has not been made available as an offline pack

This remains a live candidate until physical route-shape, map-gesture, fuel, offline incident-report, and on-device detour tests are approved. Approval promotes these exact bytes; it does not trigger a second pack build.

### Physical finding: Myra Road / Calling Rock Trail

The first Nova Scotia field check confirmed why surface and access must remain separate. OSM explicitly tags the northern Myra Road ways as `highway=track surface=unpaved`, which the pack normalizes as dirt. The adjoining Calling Rock Trail is only `highway=path`; it has neither `surface=*` nor `motorcycle=*`/`motor_vehicle=*` evidence. It therefore remains dirt-like unknown surface with `motorized_unknown` access and correctly requires **Allow unknown**. The selected-route renderer must show that segment as purple unknown access—not black pavement. Known-access resource/track surfaces remain orange. Do not make all `highway=path` ways permissive: the same local OSM network contains explicitly motor-prohibited hiking paths.

The extract is therefore current to the evening before this candidate was built; a road that is physically paved but still tagged `surface=unpaved` is an upstream OSM freshness/correctness issue, not evidence that this build used an old cached province file. Graph tap diagnostics expose both `edgeId` and normalized `surface` so a field report can be traced to the exact OSM way and corrected without guessing.
