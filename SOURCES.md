# DIRT. Data Sources

Comprehensive list of open-source trail, road, and track data sources for Canadian dual-sport riding.

## Implementation Priority

**Phase 1** (Start here):
- OpenStreetMap (Geofabrik)
- British Columbia
- Alberta
- Ontario
- Québec
- Nova Scotia
- GravelTravel.ca routes

---

## National Coverage Sources

### 1. OpenStreetMap via Geofabrik
- **Coverage**: All provinces and territories
- **Format**: `.osm.pbf`, shapefile
- **Data**: Forestry tracks, unpaved roads, trails, paths, ATV/motorcycle access tags
- **Update frequency**: Frequent
- **License**: ODbL (attribution + share-alike required)
- **URL**: https://download.geofabrik.de/north-america/canada.html
- **Status**: ✅ Verified - HTTP 200, application/octet-stream

### 2. CanVec / Geo.ca
- **Coverage**: National topographic data
- **Format**: Various GIS formats
- **Data**: Roads, tracks, trails, cutlines, hydrography, elevation, backcountry features
- **Note**: Some components dated, but can expose roads missing from newer datasets
- **URL**: https://geo.ca
- **Status**: 🔄 Testing

### 3. Statistics Canada Road Network File
- **Coverage**: Annual nationwide road geometry
- **Format**: Shapefile, GeoPackage
- **Data**: Better for conventional roads than trails, useful for connectivity gaps
- **License**: Statistics Canada licence permits reuse and value-added products
- **URL**: https://www150.statcan.gc.ca/n1/en/catalogue/92-500-G
- **Status**: ✅ Verified - HTTP 200

### 4. Geo.ca Map Browser
- **Coverage**: Federal and provincial geospatial layers
- **Format**: ArcGIS REST, WMS, GeoPackage, shapefile
- **Search terms**: forest road, resource road, trail, recreation line, access road, cutline, winter road
- **URL**: https://geo.ca
- **Status**: 🔄 Testing

---

## Provincial Sources

### 5. British Columbia Data Catalogue
- **Layers**:
  - Forest Service Roads
  - Road Permit Roads
  - Recreation Sites and Trails
  - Digital Road Atlas
  - Integrated Roads
  - Recreation Lines
- **Note**: BC likely has the richest government source for detailed resource-road data
- **URL**: https://catalogue.data.gov.bc.ca
- **Status**: ✅ Verified — HTTP 200, JSON API working

### 6. Alberta Open Data / GeoDiscover Alberta
- **Layers**:
  - Access and Facility Roads (authoritative provincial road dataset)
  - Trails and cutlines
  - Forestry Trunk Roads
  - Public-land access layers
- **URL**: https://geodiscover.alberta.ca
- **Status**: ✅ Verified — HTTP 200

### 7. Ontario GeoHub
- **Layers**:
  - Ontario Road Network (includes resource and recreational roads)
  - MNR Road Segments
  - Ontario Trail Network
  - Road barriers and access points
- **Format**: Shapefile, file geodatabase
- **URL**: https://geohub.lio.gov.on.ca
- **Status**: ✅ Verified — HTTP 200

### 8. Données Québec
- **Layers**:
  - Référentiel québécois du transport terrestre
  - Multi-use forest roads
  - Provincial road network
  - Trails and terrestrial transportation features
- **Search terms (French)**: chemins multiusages, chemins forestiers, sentiers, réseau routier
- **URL**: https://www.donneesquebec.ca
- **Status**: ✅ Verified — HTTP 200

### 9. Nova Scotia Open Data / GeoNOVA
- **Layers**:
  - Roads, Trails and Rails
  - Nova Scotia Topographic Database
  - Crown-land boundaries
  - Vegetation Inventory Roads
- **Note**: Includes resource roads, trails and tracks beyond ordinary public-road coverage
- **URL**: https://data.novascotia.ca
- **Status**: ✅ Verified - HTTP 200, Socrata API working

### 10. Manitoba Land Initiative / Manitoba Geoportal
- **Layers**:
  - Provincial road network
  - Forest-access roads
  - Wildlife Management Area trails
  - Provincial forest and Crown-land layers
- **Format**: Multiple GIS formats
- **URL**: https://mli2.gov.mb.ca
- **Status**: ❌ Unavailable — fetch failed

### 11. Saskatchewan GeoHub
- **Layers**:
  - Road network
  - Trails
  - Crown lands
  - Provincial forest and recreation datasets
- **Format**: ArcGIS REST, GeoJSON, KML, shapefile, GeoPackage
- **URL**: https://www.saskatchewan.ca/geohub
- **Status**: ❌ Unavailable — HTTP 404

### 12. Newfoundland and Labrador Geoportal
- **Layers**:
  - Roads and transportation
  - Resource roads
  - Crown land
  - Trails and recreation layers
- **Note**: Coverage quality varies between Newfoundland and Labrador
- **URL**: https://www.gov.nl.ca/ecc/maps
- **Status**: ✅ Verified — HTTP 200

### 11. Prince Edward Island Open Data
- **Layers**:
  - Provincial roads
  - Trails
  - ATV road connectors
  - Land ownership and Crown-land context
- **Note**: Limited forestry-road value, useful for complete national coverage
- **URL**: https://data.princeedwardisland.ca
- **Status**: ✅ Verified — HTTP 200

### 12. Yukon Open Data
- **Layers**:
  - Roads
  - Resource roads
  - Trails
  - Winter roads
  - Mining and forestry-access features
- **Note**: Particularly useful because OSM coverage becomes less complete in remote areas
- **URL**: https://open.yukon.ca
- **Status**: ✅ Verified — HTTP 200

### 11. Northwest Territories Open Data / Spatial Data Warehouse
- **Layers**:
  - Highways
  - Winter roads
  - Resource roads
  - Trails and land-use layers
- **URL**: https://www.nwtgeomatics.ca
- **Status**: ❌ Unavailable — fetch failed

### 12. Nunavut Geoportal
- **Layers**:
  - Trails
  - Winter routes
  - Community transportation
- **Note**: Less relevant for forestry roads, useful for snowmobile and overland travel
- **URL**: https://nunavutgeoportal.ca
- **Status**: ❌ Unavailable — fetch failed

---

## Curated GPX Routes

### 11. GravelTravel.ca
- **Routes**:
  - Trans Canada Adventure Trail (TCAT)
  - The North East
  - Swisha Loop
  - The Rock
  - Gaspé Loop
  - Telkwa Pass
  - Alberta Forestry Trunk Road
  - Mackenzie Heritage Trail
  - The Big Empty
  - Ottawa-area routes
- **Format**: Free GPX files
- **Note**: Best initial curated route collection. Verify redistribution permission before bundling.
- **URL**: https://graveltravel.ca
- **Status**: ✅ Verified — HTTP 200

### 12. Trans Canada Trail
- **Coverage**: ~30,000 km national trail
- **Format**: Interactive route downloads
- **Note**: Much of it is non-motorized; preserve activity and access attributes
- **URL**: https://tctrail.ca
- **Status**: ✅ Verified — HTTP 200

### 11. Provincial ATV Federations
- **Organizations**:
  - ATV Association of Nova Scotia
  - QuadNB
  - ATV Manitoba
  - Saskatchewan ATV Association
  - Ontario Federation of ATV Clubs
  - Fédération Québécoise des Clubs Quads
  - PEI ATV Federation
- **Format**: GPX, KML, PDFs, interactive maps
- **Note**: Treat as leads for individual route imports; verify permissions
- **Status**: 📋 Manual research needed

### 12. Adventure-Riding Forums & Community Libraries
- **Sources**:
  - ADVrider regional forums
  - Horizons Unlimited route discussions
  - DualSportBC
  - Regional Facebook riding groups
- **Note**: Seed tracks require contributor permission and provenance
- **Status**: 📋 Manual research needed

---

## Testing Status Legend

- ✅ Verified - source accessible, format confirmed
- ⚠️ Limited - accessible but with restrictions or issues
- ❌ Unavailable - source not accessible or deprecated
- 📋 Manual - requires manual research or permissions

---

## Test Results Summary

**Test Date**: July 13, 2026  
**Total Sources Tested**: 17  
**Accessible**: 13+  
**Note**: Canada NRN and New Brunswick entries dropped from catalogue and APIs.

### ✅ Priority 1 Sources: 7/7 accessible
Critical sources for initial map are working.

**See `INTEGRATION.md` for detailed integration instructions.**  
**See `test-results.json` for full technical test results.**

---

## License Compliance

### Must provide attribution
- OpenStreetMap (ODbL)
- Most provincial open data (varies by province)

### Share-alike requirement
- OpenStreetMap (ODbL) - derivative works must be open

### Verify before bundling
- GravelTravel.ca routes
- ATV federation maps
- Community-contributed GPX files

---

## Implementation Notes

**Priority testing order**: OSM → BC → Alberta → Ontario → Québec → Nova Scotia → GravelTravel

This combination should produce a credible first Canadian map without depending on BRMB, Trailforks, Gaia or other closed commercial datasets.
