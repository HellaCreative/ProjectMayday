# Supplemental Services

Provincial resource-road, forest-road, and trail data sources to conflate on top of NRN, the same way NSTDB was layered onto NRN + OSM for Nova Scotia. Goal: restore the capillary network (resource roads, forestry roads, two-track, ATV/recreation routes) that NRN alone does not carry.

## The paradigm

NRN is the paved/gravel road backbone for every province. It does NOT contain the fibrous detail: resource roads, forestry access roads, unclassified two-track, recreation trails. Each province publishes that separately, usually from its natural-resources / forestry ministry, and usually as a live ArcGIS REST feature service that returns GeoJSON on query.

Conflation rule (already implemented for NS): NRN owns road identity; the provincial supplemental layer adds unmatched resource/track detail and may enrich NRN edges whose surface/access is unknown. No free-space connectors.

Status legend: VERIFIED means the endpoint appeared in an authoritative catalogue during this research pass. Each still needs Cursor to hit the service, confirm it is live, and inspect attributes before ingest.

---

## Nova Scotia (reference / already done)

- NSTDB (Nova Scotia Topographic Database) roads/trails, via GeoNOVA Socrata. Already conflated. This is the pattern to replicate.

---

## New Brunswick

Primary supplement: **Forest Roads** (DNR-ED).
- What: roads not maintained by DTI whose primary purpose is to access forest resources on crown or private land. The NRN complement.
- Feature service: `https://gis-erd-der.gnb.ca/server/rest/services/OpenData/ForestRoads/FeatureServer`
- Hub download: `https://hub.arcgis.com/datasets/NBDNR::forestry-roads-chemins-forestiers/about`
- Secondary (later, access/legality): **Crown Lands** layer, same DNR-ED OpenData ArcGIS server.
- Not covered: true ATV/snowmobile singletrack (NB ATV federation / Trans Canada Trail, permission-gated).
- Status: VERIFIED (feature service confirmed in GNB open-data portal).

---

## Quebec

Primary supplement: **Réseau routier / chemins forestiers** and **Infrastructures en milieu forestier**, via Données Québec / Forêt ouverte (MRNF).
- What: multi-use forest roads (chemins multiusages, chemins forestiers) and forest infrastructure not in the provincial road backbone.
- Catalogue: `https://www.donneesquebec.ca/recherche/dataset/infrastructures-en-milieu-forestier`
- Forêt ouverte hub: `https://www.quebec.ca/agriculture-environnement-et-ressources-naturelles/forets/recherche-connaissances/inventaire-forestier/foret-ouverte-donnees`
- Provincial GDB (ecoforest + infrastructure, by sheet): distributed via `https://diffusion.mffp.gouv.qc.ca/Diffusion/DonneeGratuite/Foret/`
- Format note: distributed by 1/250k or 1/10k sheet as GDB / GeoJSON, not one province-wide feature service. Cursor will need to enumerate and merge sheets covering the corridor.
- Search terms (French): chemins multiusages, chemins forestiers, réseau routier, infrastructures en milieu forestier.
- Status: VERIFIED (Données Québec + MRNF diffusion confirmed). Sheet-based delivery is the integration wrinkle.

---

## Ontario

Primary supplement: **MNRF Road Segments** (Ministry of Natural Resources and Forestry), via Ontario GeoHub / LIO.
- What: roads under MNRF jurisdiction including Forests Division, Parks/Lands/Waters, and resource access roads. Explicitly includes resource access roads NRN lacks. (Note: it also re-includes municipal/highway roads sourced from ORN, so dedupe against NRN.)
- Feature service (ESRI REST): `https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/LIO_OPEN_DATA/LIO_Open09/MapServer/18`
- File geodatabase: `https://ws.gisetl.lrc.gov.on.ca/fmedatadownload/Packages/fgdb/MNRRDSEG.zip`
- Hub: `https://geohub.lio.gov.on.ca/datasets/mnrf-road-segments`
- Status: VERIFIED (ESRI REST confirmed in Ontario open-data catalogue).

---

## Manitoba

Primary supplement: **Manitoba Land Initiative (MLI)** provincial road + forest-access + WMA trail layers.
- What: forest-access roads, Wildlife Management Area trails, provincial forest and Crown-land layers.
- Portal: `https://mli2.gov.mb.ca` (also `https://geoportal.gov.mb.ca`)
- Status: UNVERIFIED. The MLI portal failed to fetch during earlier source testing (noted in SOURCES.md as unavailable). Cursor should confirm current portal URL and whether a live feature service or bulk download exists; MLI historically distributes as downloadable shapefiles rather than a REST service. Treat as the highest-risk province for supplemental data.

---

## Saskatchewan

Primary supplement: **Resource/Recreation roads** class within the Saskatchewan Road Network.
- What: resource and recreation roads within Saskatchewan.
- Feature service (ESRI REST): `https://gis.saskatchewan.ca/arcgis/rest/services/Highways/SaskatchewanRoadNetwork/MapServer` (Resource/Recreation is layer 10 in this service)
- Also on GeoHub: `https://services3.arcgis.com/zcv98lgAl8xQ04cW/arcgis/rest/services/ROADSEG/FeatureServer/0`
- IMPORTANT: Saskatchewan's ROADSEG IS the NRN source for the province. Do not re-ingest ROADSEG wholesale (duplicates NRN). Extract only the Resource/Recreation and OTHER_ROAD classes not already promoted into NRN.
- Status: VERIFIED (ESRI REST confirmed), with the NRN-overlap caveat above.

---

## Alberta

Alberta's "Access" data collection is the richest single provincial source and separates roads from trails/cutlines.

Primary supplement: **Access and Facility Roads** (Base Features, GeoDiscover Alberta).
- What: authoritative Alberta road data including resource/access roads. Part of the Access collection (roads, railways, powerlines, cutlines, trails, industrial facilities).
- Feature service (ESRI REST): `https://geospatial.alberta.ca/titan/rest/services/utility/access/MapServer`
- Offline vector tiles (relevant to our offline paradigm): `https://geospatial.alberta.ca/arcgis/rest/services/Hosted/base_access_road_offline/VectorTileServer`
- Open data record: `https://open.alberta.ca/opendata/a477aa82-1bd9-42b6-9192-b8f91e2b1967`

Secondary supplement (trail-level detail): **Access — Trails and Cutlines** layer, same Access collection.
- What: trails and cutlines, the singletrack-adjacent layer NRN and even the roads layer omit. This is Alberta's closest equivalent to true trail data in an open source.
- Same GeoDiscover Access collection; enumerate the sibling layers in the `utility/access` MapServer.
- Status: VERIFIED (roads ESRI REST confirmed; trails/cutlines is a sibling layer in the same service, confirm layer index on ingest).

---

## British Columbia

BC has the deepest resource-road coverage in the country, plus a dedicated recreation-trail dataset. Two sources.

Primary supplement: **Forest Tenure Road Segment Lines (FTEN)**, BC Data Catalogue.
- What: all forest-tenure road segments. The BC resource-road network, very dense.
- WMS/OWS: `https://openmaps.gov.bc.ca/geo/pub/WHSE_FOREST_TENURE.FTEN_ROAD_SEGMENT_LINES_SVW/ows`
- Catalogue: `https://catalogue.data.gov.bc.ca/dataset/forest-tenure-road-segment-lines`
- Note: BC primarily publishes via WMS/WFS/OWS and BCGW custom download rather than an ESRI FeatureServer. Use WFS for vector pull, or the `bcdata` access pattern. Use FTEN_ROAD_SEGMENT_LINES (the actual road line), NOT FTEN_ROAD_SEGMENT_POLY (a 75m tenure buffer that does not represent the road on the ground).

Secondary supplement (recreation/trail): **Recreation Sites and Trails BC**.
- What: managed recreation trails and sites (RSTBC). Adds recreation-designated routes.
- Catalogue: search `recreation-sites-and-trails` on `https://catalogue.data.gov.bc.ca`
- Also useful: **Cariboo Consolidated Roads** and **Integrated/Digital Road Atlas (DRA)** for regional gap-filling.
- Status: VERIFIED (catalogue records confirmed). Integration wrinkle: WMS/WFS delivery, not ESRI REST, so the adapter differs from NB/ON/AB.

---

## Integration plan for Cursor

Fits the existing conflation architecture (`routing/adapters/`, `routing/registry/sources.json`). Each province becomes a new adapter alongside `nrn` and `ns-nstdb`.

Suggested order (richest and cleanest first):
1. New Brunswick — Forest Roads. Clean ESRI REST, direct NSTDB analog, smallest province, best first proof.
2. Ontario — MNRF Road Segments. Clean ESRI REST, dedupe against NRN.
3. Alberta — Access Roads + Trails/Cutlines. Clean ESRI REST, richest attributes, adds a true trail layer.
4. British Columbia — FTEN + Recreation Sites and Trails. Densest data, but WMS/WFS adapter is new work.
5. Quebec — chemins forestiers / infrastructures. Sheet-based GDB, enumeration + merge needed.
6. Saskatchewan — Resource/Recreation class only. Careful NRN de-duplication.
7. Manitoba — MLI. Unverified; confirm portal and delivery method before committing effort.

Per-province adapter checklist:
- Confirm the service is live (query `?f=json` on the layer).
- Inspect attributes: map the province's surface/class fields to the canonical surface enum (`routing/schema/enums.js`: paved / gravel / access / track).
- Map access/legality fields where present (crown vs private, seasonal, restricted).
- Preserve source lineage per `SOURCES.md` (source, source id, licence, retrieval date) so a source can be rebuilt or removed without corrupting rider observations.
- Dedupe against NRN by geometry/NID where the provincial set overlaps the backbone.
- Conflate: NRN identity wins; supplement adds unmatched detail; no free-space connectors.
- Record licence and attribution. Most are Open Government Licence variants; BC and each province have their own. Verify before bundling.

## Licence note

Every source above is government open data under an Open Government Licence variant (attribution required, generally permits derivative and value-added products). This is distinct from the community/commercial sources (Backroad Mapbooks, Trailforks, Wikiloc, AllTrails, ATV federation GPX) named in DIRT_PRODUCT_NOTES.md as NOT to be ingested without licensing. Keep that line clean.

## House rules

- No em dashes anywhere, including code comments.
- Verify live before ingest. A catalogue listing is not a guarantee the endpoint is up today.
