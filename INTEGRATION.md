# DIRT. Data Integration Guide

Tested and verified data sources with specific integration instructions.

**Test date**: July 13, 2026  
**Result**: ✅ 15/19 sources accessible | 🎯 8/8 Priority 1 sources working

---

## Quick Start: Priority 1 Sources

These sources are **verified accessible** and ready for integration:

1. ✅ **OpenStreetMap via Geofabrik** — Direct PBF download
2. ✅ **National Road Network (NRCan)** — Province-level downloads
3. ✅ **British Columbia Data Catalogue** — JSON API + direct downloads
4. ✅ **Alberta GeoDiscover** — Catalogue with download links
5. ✅ **Ontario GeoHub** — ArcGIS REST services
6. ✅ **Données Québec** — CKAN API + downloads
7. ✅ **Nova Scotia Open Data** — Socrata API
8. ✅ **GravelTravel.ca** — Curated GPX routes

---

## Integration Methods

### 1. OpenStreetMap via Geofabrik ✅

**Status**: Working — Direct binary download available

**Data URL**: 
```
https://download.geofabrik.de/north-america/canada-latest.osm.pbf
```

**Provincial extracts**:
```
https://download.geofabrik.de/north-america/canada/alberta-latest.osm.pbf
https://download.geofabrik.de/north-america/canada/british-columbia-latest.osm.pbf
https://download.geofabrik.de/north-america/canada/ontario-latest.osm.pbf
https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf
https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf
```

**Integration approach**:
- Download `.osm.pbf` files (binary, efficient)
- Process with osmium or osm2pgsql
- Filter for: `highway=track|path|unclassified`, `surface=unpaved|gravel|dirt`
- Extract `motorcycle=yes`, `atv=yes`, `4wd_only=yes` tags
- Convert to GeoJSON for map display

**Next steps**:
1. Build PBF → GeoJSON converter
2. Filter for relevant trail/road types
3. Extract grading/surface attributes

---

### 2. National Road Network (NRCan) ✅

**Status**: Working — Catalogue page accessible

**Catalogue URL**:
```
https://open.canada.ca/data/en/dataset/3d282116-e556-400c-9306-ca1a3cada77f
```

**Integration approach**:
- Visit catalogue page
- Find province-specific download links (shapefile or GeoPackage)
- Parse HTML or use Open Canada API
- Download and merge provincial datasets

**API endpoint** (to discover downloads):
```
https://open.canada.ca/data/api/3/action/package_show?id=3d282116-e556-400c-9306-ca1a3cada77f
```

**Next steps**:
1. Fetch package metadata via API
2. Extract download URLs for shapefiles
3. Build automated downloader
4. Convert to GeoJSON

---

### 3. British Columbia Data Catalogue ✅

**Status**: Working — CKAN API responding with JSON

**API Test URL**:
```
https://catalogue.data.gov.bc.ca/api/3/action/package_search?q=forest+service+roads
```

**Key datasets**:
- Forest Service Roads (FSR)
- Digital Road Atlas (DRA)
- Recreation Sites and Trails BC

**CKAN API endpoints**:
```javascript
// Search
https://catalogue.data.gov.bc.ca/api/3/action/package_search?q=forest

// Get specific package
https://catalogue.data.gov.bc.ca/api/3/action/package_show?id=forest-service-roads-fsr

// List all packages
https://catalogue.data.gov.bc.ca/api/3/action/package_list
```

**Integration approach**:
- Use CKAN API to search for road/trail datasets
- Extract resource download URLs (shapefile, GeoJSON, or WMS)
- Many datasets offer WMS/WFS services for direct map integration
- BC often provides ArcGIS REST endpoints

**Next steps**:
1. Search API for all trail/road datasets
2. Identify best format (WFS > GeoJSON > Shapefile)
3. Build fetcher with caching
4. Test data quality on map

---

### 4. Alberta GeoDiscover ✅

**Status**: Working — Catalogue accessible

**URL**:
```
https://geodiscover.alberta.ca
```

**Key datasets to search**:
- Access and Facility Roads
- Forestry Trunk Road
- Trails and Cutlines

**Integration approach**:
- Alberta uses a custom portal (not standard CKAN)
- Likely provides ArcGIS REST services or direct downloads
- May need to scrape or use embedded API

**Next steps**:
1. Investigate portal structure
2. Find API or download endpoints
3. Identify Access Roads dataset URL
4. Test data extraction

---

### 5. Ontario GeoHub ✅

**Status**: Working — ArcGIS Hub accessible

**URL**:
```
https://geohub.lio.gov.on.ca
```

**Key datasets**:
- Ontario Road Network (ORN)
- MNR Road Segments
- Ontario Trail Network

**Integration approach**:
- Ontario uses ArcGIS Hub
- Data available via ArcGIS REST API
- Search for datasets by keyword
- Access via GeoJSON, Shapefile, or WFS

**Example REST endpoint pattern**:
```
https://ws.lioservices.lrc.gov.on.ca/arcgis1071a/rest/services/LIO_Cartographic/...
```

**Next steps**:
1. Search hub for "Ontario Road Network"
2. Locate ArcGIS REST service URL
3. Query REST API for trail/resource road features
4. Convert to GeoJSON

---

### 6. Données Québec ✅

**Status**: Working — CKAN catalogue accessible

**URL**:
```
https://www.donneesquebec.ca
```

**Search terms** (French):
- chemins forestiers (forest roads)
- chemins multiusages (multi-use roads)
- sentiers (trails)
- réseau routier (road network)

**CKAN API**:
```javascript
// Search
https://www.donneesquebec.ca/recherche/api/3/action/package_search?q=chemins+forestiers

// Get package
https://www.donneesquebec.ca/recherche/api/3/action/package_show?id=[id]
```

**Integration approach**:
- Standard CKAN API (like BC)
- Search for transportation/trail datasets in French
- Download shapefiles or access WMS/WFS
- Parse bilingual attribute names

**Next steps**:
1. Search API for key terms
2. Identify best road/trail dataset
3. Download sample and test
4. Map French attributes to English

---

### 7. Nova Scotia Open Data / GeoNOVA ✅

**Status**: Working — Socrata API responding

**API URL**:
```
https://data.novascotia.ca/api/views/metadata/v1
```

**Key datasets**:
- Roads, Trails and Rails
- Nova Scotia Topographic Database
- Vegetation Inventory Roads

**Integration approach**:
- Uses Socrata open data platform
- RESTful API with JSON responses
- Can filter, query, and export GeoJSON directly

**Socrata API pattern**:
```
https://data.novascotia.ca/resource/[dataset-id].json
https://data.novascotia.ca/resource/[dataset-id].geojson
```

**Next steps**:
1. Browse catalogue for trail datasets
2. Get dataset resource ID
3. Fetch as GeoJSON directly
4. This is your home province — prioritize!

---

### 8. GravelTravel.ca ✅

**Status**: Working — Site accessible

**URL**:
```
https://graveltravel.ca
```

**Available routes** (curated GPX):
- Trans Canada Adventure Trail (TCAT)
- Alberta Forestry Trunk Road
- The Big Empty
- Gaspé Loop
- Many more regional routes

**Integration approach**:
- Manual download of GPX files
- Parse GPX → GeoJSON
- These are **curated, high-quality routes**
- Must verify redistribution permission

**Next steps**:
1. Download sample GPX (TCAT segment)
2. Build GPX parser
3. Display on map to verify quality
4. Contact site owner about redistribution

---

## Failed Sources

### ❌ Manitoba Geoportal
**Error**: `fetch failed`  
**Note**: Domain may have moved or be temporarily down

### ❌ Saskatchewan GeoHub
**Error**: `HTTP 404`  
**Note**: URL incorrect or service deprecated

### ❌ Northwest Territories Spatial Data
**Error**: `fetch failed`  
**Note**: May require VPN or special access

### ❌ Nunavut Geoportal
**Error**: `fetch failed`  
**Note**: May require special access or be offline

---

## Recommended Implementation Order

### Phase 1: Proof of Concept (Week 1)
1. **GravelTravel.ca GPX** — Manual download one route, parse, display
2. **OpenStreetMap Nova Scotia** — Download PBF, extract trails, show on map
3. **NS Open Data** — Fetch via Socrata API, overlay on OSM

### Phase 2: Core Provinces (Week 2-3)
4. **BC Forest Service Roads** — CKAN API integration
5. **Alberta Access Roads** — Portal scraping/API
6. **Ontario Road Network** — ArcGIS REST
7. **Québec forest roads** — CKAN API (French)

### Phase 3: National Coverage (Week 4+)
8. **National Road Network** — All provinces
9. **Remaining accessible provinces** — NB, NL, PEI, YT
10. **Secondary GPX sources** — Trans Canada Trail, forums

---

## Next Steps

✅ **Immediate**:
1. Create GPX parser for GravelTravel routes
2. Build OSM PBF → GeoJSON converter for Nova Scotia
3. Fetch NS trail data via Socrata API
4. Display all three sources on test map

🔄 **This Week**:
1. Standardize all formats to GeoJSON
2. Build unified data layer system
3. Add source attribution to map
4. Cache downloaded data locally

📋 **Planning**:
1. Design database schema for multi-source data
2. Build automatic update pipeline
3. Create diff detection for changed trail data
4. Plan grading/difficulty normalization across sources
