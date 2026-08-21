# Pack rebuild 2026-08

Live OSM-only candidates for all regions except frozen Nova Scotia (`ns-osm-20260820-01`).
Follows `docs/09-OSM-PACK-QUALITY-STANDARD.md` steps 1–10. No promotion.

**Branch:** `feature/pack-rebuild-2026-08` (from `feature/routing-itinerary-rebuild` @ d196992 — `main` lacks pack-fabric scripts)
**Worktree:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt-pack-rebuild`
**Checkpoint:** `e9c6f8a`
**Live project:** `dirt-mayday` (worktree `.vercel` must stay linked; accidental `pack-fabric` project ignored)
**Live overrides:** always include frozen `ns-osm-20260820-01` plus every uploaded candidate this run.

## Regions

```
region: bc   release-id: bc-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 0d8cb68a6fb32e244eef2ae2fc9d237d248701c7eea1c7e286c70f2ad8644fa2
steps 1–7: ok
audit contradictions: 0
non-OSM edges: 0
stitches: 25450  free-space: 0
largest permissive component: 70.97% of edges
urban cores: 33 hard / 145 scored
seams built: (none yet)           seams deferred: bc-ab, bc-wa (neighbours not yet rebuilt this run); *-ns skipped
route acceptance: 13/15 — red rows: urban-abbotsford-merritt/dirt 65%<70%; urban-abbotsford-merritt/dirt 26.7% backward >25%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/bc-osm-20260821-01   promoted: NO
commit: (pending)   tag: pack-bc-osm-20260821-01
pin notes: all three fixtures snapped; no pin moves
```

## Promote commands (do not run until physical OK)

```
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-01 --pack bc --live --assert
```
