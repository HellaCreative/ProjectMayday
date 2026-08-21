# Pack rebuild 2026-08

Live OSM-only candidates for all regions except frozen Nova Scotia (`ns-osm-20260820-01`).
Follows `docs/09-OSM-PACK-QUALITY-STANDARD.md` steps 1–10. No promotion.

**Branch:** `feature/pack-rebuild-2026-08` (from `feature/routing-itinerary-rebuild` @ d196992)
**Worktree:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt-pack-rebuild`
**Checkpoint:** `e9c6f8a`
**Live:** `dirt-mayday` with cumulative `R2_REGION_BASE_OVERRIDES` always including frozen NS.

## Regions

```
region: bc   release-id: bc-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 0d8cb68a6fb32e244eef2ae2fc9d237d248701c7eea1c7e286c70f2ad8644fa2
steps 1–7: ok
audit contradictions: 0
non-OSM edges: 0
stitches: 25450  free-space: 0
largest permissive component: 70.97% of edges
urban cores: 33 hard / 145 scored
seams built: bc-ab           seams deferred: bc-wa (WA not yet); *-ns skipped
route acceptance: 13/15 — red: urban-abbotsford-merritt/dirt 65%<70%; urban-abbotsford-merritt/dirt 26.7% backward>25%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/bc-osm-20260821-02   promoted: NO
note: bc-osm-20260821-01 superseded after BC–AB seam embedded (new checksums → -02)
tag: pack-bc-osm-20260821-02
```

```
region: ab   release-id: ab-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 4d8b08d3e48a06fac87376acf21970e89245ea1ec6996a19071ecf21d3a55ebb
steps 1–7: ok
audit contradictions: 0
non-OSM edges: 0
stitches: 15522  free-space: 0
largest permissive component: 98.57% of edges
urban cores: 14 hard / 125 scored
seams built: bc-ab           seams deferred: ab-sk, ab-mt (not yet); ab-ns N/A
route acceptance: 15/15 — red rows: none (short pin moved Bragg Creek→Black Diamond; Longview/Turner Valley off-graph)
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ab-osm-20260821-01   promoted: NO
tag: pack-ab-osm-20260821-01
```

## Promote commands (do not run until physical OK)

```
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-02 --pack bc --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote ab-osm-20260821-01 --pack ab --live --assert
```
