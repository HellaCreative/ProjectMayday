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

| Code | Jurisdiction | Phase-1 soon? | Status |
|------|----------------|---------------|--------|
| PE | Prince Edward Island | Defer | Weak resource-road value |
| NL | Newfoundland and Labrador | **Yes** | VERIFIED — FFA Resource Roads |
| NT | Northwest Territories | **Yes (after main queue)** | VERIFIED — Transportation_LCC (old portal dead) |
| YT | Yukon | **Yes** | VERIFIED — Forest Resource Roads 50k |
| NU | Nunavut | Defer | No territorial road portal found |

### Deferred Atlantic & Territories research

*Research pass 2026-07-21 via [Deferred provinces research](322836cf-b815-4cd4-8df1-54796f9f0dbb). Government open data only.*

#### PE — Defer
- Portals live: data.princeedwardisland.ca, gis.princeedwardisland.ca
- `road_centerline` FeatureServer/0 (~16.9k): NAME/OWNERSHIP/ROAD_STATU only — sparse, likely NRN overlap
- Confederation Trail: motor-free summer; not a resource-road supplement
- Licence: confirm OGL-PE vs GIS EULA before any ingest

#### NL — Phase-1 soon (best Atlantic after NB)
- **NF Resource Roads:** `https://services8.arcgis.com/aCyQID5qQcyrJMm2/arcgis/rest/services/FFA_ResourceRoads_NF/FeatureServer/2` (~12.4k) — use layer **2**
- **LB Resource Roads:** `…/FFA_ResourceRoads_LB/FeatureServer/0` (~1.0k)
- Fields: ROAD_ACCESS (coded Open/Limited/ATV/…), ROAD_CLASS, ROAD_SURFACE (often null)
- Licence: Open Government Licence – Newfoundland and Labrador
- Hub: geohub-gnl.hub.arcgis.com

#### NT — Phase-1 after main provincial queue; fix registry URL
- Old `nwtgeomatics.ca` **BLOCKED** (DNS)
- Use `https://www.geomatics.gov.nt.ca` + REST `https://www.apps.geomatics.gov.nt.ca/arcgis/rest/services/GNWT/Transportation_LCC/MapServer`
- Layer 3 Roads (~11k): filter ROADTYPE Resource/Recreation, Winter, Trails — do not ingest highways wholesale (NRN overlap)
- Licence: Open Government Licence – Northwest Territories

#### YT — Phase-1 soon (small, clean)
- **Forestry Resource Roads 50k:** `https://mapservices.gov.yk.ca/arcgis/rest/services/GeoYukon/GY_Forestry/MapServer/39` (~556) — ROAD_CLASS / tenure; incomplete by design
- Optional filter: Yukon Road Network Resource/Recreation + Winter (MapServer/60)
- Defer bulk trails/cutlines
- Licence: Open Government Licence – Yukon (catalogue)

#### NU — Defer / BLOCKED
- nunavutgeoportal.ca DNS fail; NRN only; no capillary supplement found

#### Cross-cutting
1. Update NT registry stub off nwtgeomatics.ca
2. NL access coding is the richest of this set; surface often null → keep `motorized_unknown` stance
3. Still exclude Trailforks / AllTrails / Backroad / Wikiloc

## Blocked / deferred

1. **Quebec uncapped pack vs Node JSON limit** — Full 3-tier QC (~1.78M edges, ~1.0GB inflate, ~231MB gz) builds successfully as `graph.v1.full.json.gz` (gitignored). Node `JSON.parse` cannot load strings &gt; ~512MB, so **production** `graph.v1.json.gz` is NRN+OSM + 40k Lac Normand–biased provincial edges (~925k edges, ~98MB gz). Next: streaming inflate or graph.v2 for uncapped QC.
2. **Routing / pack format / search / nav cues / basemap** — not modified (per constraints).
3. **Trailforks / AllTrails / Backroad / Wikiloc** — not used.
4. **Manitoba** — still unverified per spec; confirm portal before ingest.
5. **Large artifacts** — provincial graphs/chunks are build outputs; push when user needs production review.

---

## Part 3 — OSM gap-fill proof (NB + QC) — 2026-07-21

Stack locked: **NRN identity → OSM motorized gap-fill → provincial capillary**. Exclude foot/bike-only, private/no, abandoned, pure path without motor tags.

| Province | Deploy pack | Sources (deploy) | Notes |
|----------|-------------|------------------|-------|
| NB | ~305k edges / ~38MB gz | NRN 70k + OSM 56k + Forest Roads 180k | Full 3-tier; longhaul rebuilt |
| QC | ~925k edges / ~98MB gz | NRN 505k + OSM 380k + Multiusage 40k | Full uncapped local; deploy capped for Node |

**Lac Normand:** on uncapped pack, nearest edge ~111m (provincial / `motorized_unknown`). Enable unknown-access toggle; pin on/near road.

**Build tooling:** `routing/adapters/osm-roads.js`, `scripts/extract-osm-roads.sh`, 3-tier `build-region-with-supplement.js` (`--osm-only` / `--skip-osm`). QC MapServer fetch: timeouts + retries (source stalls).
