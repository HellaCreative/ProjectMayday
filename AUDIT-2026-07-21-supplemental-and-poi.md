# AUDIT — Supplemental roads + Canada POI (2026-07-21)

Road-data half follows `Supplemental Services.md`. Constraints: no changes to routing search, pack format, navigation cues, or base-map styling; government open data only; live verify before ingest.

---

## Part 1 — Provincial supplemental road/trail data

### New Brunswick (Forest Roads) — COMPLETE (stop here before next province)

| Item | Value |
|------|--------|
| Live service | `https://gis-erd-der.gnb.ca/server/rest/services/OpenData/ForestRoads/FeatureServer` layer 0 “Roads” (`?f=json` OK) |
| Geometry | `esriGeometryPolyline`; queries `outSR=4326` |
| Fields | `OBJECTID`, `GLOBALID`, `Shape__Length` only (sparse) |
| Adapter | `routing/adapters/nb-forest-roads.js` |
| Build wire | `scripts/build-region-with-supplement.js` → `SUPPLEMENTS.nb` |
| Registry | `routing/registry/sources.json` → NB `routingMode: nrn+provincial`, adapter `nb-forest-roads` |
| Regional pack | `routing/data/regions/nb/graph.v1.json.gz` (~32 MB) |
| Build report | `routing/data/reports/nb-nrn-supplement-build.json` |

**Mapping (canonical enums):** all kept edges → `surfaceClass=resource`, `accessClass=motorized_unknown`, `roadTrackClass=resource`. No legality claim.

**Lineage:** `lineageId` `nb-fr:{layer}:{featureId}:{part}`; `edgeId` `nb-fr-` + sha1; licence Open Government Licence - New Brunswick.

**Conflation (NRN identity wins, no free-space connectors):**

| Metric | Count |
|--------|------:|
| NRN backbone | 69,585 |
| Supplement scanned | ~184,389 (59 no geometry) |
| Supplement added | 181,466 |
| Duplicate skipped | 2,923 |
| Free-space connectors | **0** |
| Final graph edges | 251,051 |

**Display pack (Layers inspection):** `scripts/pack-nb-forest-roads-display.js` → `app/data/nb-gov-roads.manifest.json` + `app/data/nb-gov-chunks/` (79 chunks, ~18 MB gz). Display `surfaceClass=access` (map paint vocabulary).

### Remaining provinces (NOT started — awaiting green light after NB report)

Per `Supplemental Services.md` order: ON → AB → BC → QC → SK → MB. Caveats unchanged (SK ROADSEG∩NRN, QC sheet-based, MB unverified).

---

## Part 2 — POI for all provinces — COMPLETE

| Item | Detail |
|------|--------|
| Scripts | `scripts/build-osm-poi-canada.sh` (all Geofabrik canada/* slugs); `scripts/build-osm-poi.sh` kept for single-extract; `scripts/pack-osm-poi.js` adds `region` + `sources[]` via `POI_REGION_LABEL` / `POI_SOURCES_FILE` |
| Filters | Unchanged: fuel, lodging, campground, liquor |
| Runtime | Unchanged: chunked viewport / corridor fetch |
| Output | `app/data/poi/poi.manifest.json` + `chunks/` |

**Canada-wide pack (2026-07-21):**

- Region label: `Canada`
- Sources: 13 (AB, BC, MB, NB, NL, NT, NS, NU, ON, PE, QC, SK, YT)
- Kept: **59,484** (fuel 18,450 · lodging 17,568 · campground 18,853 · liquor 4,613)
- Chunks: **1,772** (0.5° grid), ~2.8 MB gz total

---

## Part 3 — POI icon zoom tuning — COMPLETE (no layer rebuild)

| Constant / paint | Before | After |
|------------------|--------|-------|
| `POI_MIN_ZOOM` | 8.5 | 8.5 (unchanged) |
| `POI_DETAIL_ZOOM` (cluster → individual) | 12.5 | **11.5** |
| `clusterMaxZoom` | `floor(12.5)=12` | `floor(11.5)=11` |
| `poi-marker` circle-radius | zoom 11→6, 14→9, 16→11 | zoom **10.5→7**, 14→10, 16→12 |
| `poi-marker-icon` icon-size | zoom 11→0.42, 16→0.6 | zoom **10.5→0.52**, 16→**0.72** |

Far-out clustering retained below DETAIL; icons appear one zoom earlier and larger at first appearance.

---

## Part 4 — Per-province Layers toggles — COMPLETE (NS + NB)

| Toggle | Pack | Behavior |
|--------|------|----------|
| `data-network-toggle="NS"` | `ns-gov-roads` / `ns-gov-chunks` | Existing show-all path; labeled **Show NS route lines** |
| `data-network-toggle="NB"` | `nb-gov-roads` / `nb-gov-chunks` | Same paint path (`nsGov` source + layers); labeled **Show NB route lines** |

Mutually exclusive. Corridor mode (both off) still uses NS display pack for route context. Product-internal only.

### Layers UI follow-up (2026-07-21)

- **Map Visibility** kept (access / gravel / branches / bridge / tunnel / restricted) but nested in a closable drawer (`#mapVisibilityDrawer`), default collapsed; open state persisted in `localStorage` key `dirt.layers.mapVisibilityOpen.v1`.
- Route Data labels use the province pattern: “Show NS route lines”, “Show NB route lines” (Ontario will follow as “Show ON route lines”).

---

## Verification

- [x] NB FeatureServer `?f=json` live; fields inspected
- [x] NB regional graph build report: freeSpaceConnectors=0
- [x] NB display pack written (79 chunks)
- [x] Canada POI build completed for all 13 Geofabrik extracts
- [x] POI threshold/size edits in `app/index.html` only (no layer id/schema changes)
- [x] Layers toggles wired to existing `showAllNetworkData` / `refreshContextNetwork` path

---

## Product decision (2026-07-21)

- **Allow unknown access stands as-is.** Provincial forest/resource supplements (e.g. NB Forest Roads) do not assert motorcycle legality; keep them `motorized_unknown` and gated by the existing toggle. Do not invent permissive acceptance from sparse government sources.

## Build order (user-directed, after NB)

1. Quebec  
2. Ontario  
3. Manitoba  
4. Saskatchewan  
5. Alberta  
6. British Columbia  

## Deferred — research only (not in build queue yet)

Capture for a later investigation pass (parallel research agent):

| Code | Jurisdiction | Why deferred |
|------|----------------|--------------|
| PE | Prince Edward Island | Not in Supplemental Services.md primary list; NRN may already be dense; need PE-specific resource/trail sources |
| NL | Newfoundland and Labrador | Same — research forest/resource/winter roads and trails |
| NT | Northwest Territories | Same — winter roads / territorial network |
| YT | Yukon | Same — resource/territorial roads |
| NU | Nunavut | Optional note only if obvious open data appears |

Research findings append under **Deferred Atlantic & Territories research** when the parallel session returns.

## Blocked / deferred

1. **Quebec ingest cap** — live AQréseau+ layer 37 (`Oui [250K - 1]`) reports **~944,719** features; build script capped QC at **250,000** (`scripts/build-region-with-supplement.js` `maxByCode.qc`). Must lift cap and rebuild for full coverage before treating QC as complete.
2. **Routing / pack format / search / nav cues / basemap** — not modified (per constraints).
3. **Trailforks / AllTrails / Backroad / Wikiloc** — not used.
4. **Manitoba** — still unverified per spec; confirm portal before ingest.
5. **Large artifacts** — provincial graphs/chunks are build outputs; push when user needs production review.
