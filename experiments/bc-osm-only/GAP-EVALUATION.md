# BC OSM-Only Feasibility — Gap Evaluation

**Status:** `BC.mbtiles` built · Layers toggle wired for Simulator visual review  
**Question:** Can OSM alone (no DRA / FTEN / RSTBC) cover BC well enough for DIRT dual-sport?

## Intentional deviations from the paste prompt

1. **`highway=footway` excluded** — Rick (2026-08-11): open all categories except foot routes/trails/paths. `path` and `cycleway` are retained.
2. **Tippecanoe instead of stock Planetiler** — OpenMapTiles/Planetiler collapses `highway=*` and drops dual-sport tags. Schema intent remains in `profiles/dirt-full-hierarchy.yml`.
3. **Location** — scripts live in the iOS repo (`MAYDAYiOS/Dirt`), in this repo.

## How to rebuild

```bash
cd /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt
bash scripts/filter-bc-osm.sh      # Geofabrik BC → geojsonseq
bash scripts/build-bc-tiles.sh     # normalize → tippecanoe → experiments/bc-osm-only/out/BC.mbtiles
```

## Build artifact

| Item | Value |
|---|---|
| Output | `experiments/bc-osm-only/out/BC.mbtiles` |
| Size | ~185 MB |
| Zooms | 4–14 |
| Layer | `dirt_roads` |
| Features | **574,654** ways |
| Low confidence (`data_confidence=low`) | **306,549 (53.3%)** — missing both `surface` and `tracktype` |

### Highway class counts (filtered extract, no footway)

| highway | count |
|---|---|
| service | 167,242 |
| residential | 110,873 |
| track | 105,872 |
| path | 70,669 |
| unclassified | 29,663 |
| tertiary | 24,962 |
| secondary | 20,513 |
| cycleway | 17,566 |
| trunk (+ link) | 11,122 |
| primary (+ link) | 8,889 |
| motorway (+ link) | 4,338 |
| living_street / road / other links | remainder |

**Note:** Tippecanoe used `--drop-densest-as-needed` so mid-zooms thin dense urban mesh; zoom **≥12–14** for honest track/path inspection.

## How to view in the iOS app (Xcode → device)

1. Ensure tiles exist: `bash scripts/build-bc-tiles.sh` (already done) then `bash scripts/sync-bc-mbtiles-resource.sh` if you rebuilt.
2. **Run from Xcode** to your phone (`Dirt/Resources/BC.mbtiles` is bundled automatically).
3. Layers → **BC OSM hierarchy (test)** ON.
4. Pan to BC; zoom ≥12. Paint: dark = highway · gray = local · purple = `track` · dashed orange = `path`/`cycleway`.
5. Leave gov **British Columbia** lens OFF (mutually exclusive).

**This does not change routing.** PACKS BC is still the CDN graph until an OSM-only pack is published.

## Open questions (do not guess)

1. **Known-ground-truth set** — which 5–10 roads/trails (paved → unofficial ATV) should we score? Paste names + approx lat/lon or OSM way IDs.
2. **Zoom convention** — this run defaults z4–14. Confirm if you want z0–14 or tighter for field review.
3. **iOS pack schema** — phone “map packs” are routing binaries (`graph.v2` / `geometry.v1`), not province `.mbtiles`. `BC.mbtiles` is an evaluation artifact until we rebuild/publish an OSM-only BC routing pack.
4. **Size ceiling** — ~185 MB tiles alone; a full unfiltered routing pack will be larger. What’s comfortable for a test drop?

## Evaluation grid (fill after Rick’s test set)

| # | Road / trail (Rick) | Class target | In OSM? | `surface`/`tracktype` | `access`/`motor_vehicle`/`atv` | Notes |
|---|---|---|---|---|---|---|
| 1 | _TBD_ | highway | | | | |
| 2 | _TBD_ | FSR / resource | | | | |
| 3 | _TBD_ | FSR branch | | | | |
| 4 | _TBD_ | dual-sport track | | | | |
| 5 | _TBD_ | unofficial ATV | | | | |
| 6–10 | _TBD_ | | | | | |

### Gap map (categories) — preliminary from counts only

| Category | Verdict | Notes |
|---|---|---|
| Primary / trunk highways | likely dense | OSM highway stack present at scale |
| Secondary / tertiary | likely dense | large counts |
| FSR mainlines (as mapped in OSM) | unknown | need ground-truth; often tagged `track`/`unclassified` |
| Dual-sport track | unknown | 105k `track` ways — quality/access tags sparse (53% low confidence) |
| Unofficial ATV / path | unknown | 70k `path` + cycleway retained; motor tags rare |
| Footway (excluded from this run) | n/a | intentionally omitted |
