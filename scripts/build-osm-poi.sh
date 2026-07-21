#!/usr/bin/env bash
# Build the bundled Rider Services POI pack from an OpenStreetMap extract.
#
# OpenStreetMap data only. No live Overpass — this runs offline at build time
# against a Geofabrik extract, then emits small grid-chunked JSON the browser
# fetches by viewport / route corridor.
#
# For all Canadian provinces, prefer:
#   bash scripts/build-osm-poi-canada.sh
#   POI_REGIONS="nova-scotia new-brunswick" bash scripts/build-osm-poi-canada.sh
#
# Run from repo root. Requires: curl, osmium-tool, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-osm-poi-build"
OUT_DIR="$ROOT/app/data/poi"
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf}"

mkdir -p "$TMP" "$OUT_DIR"
cd "$TMP"

if [ ! -f source.osm.pbf ]; then
  echo "Downloading OSM extract: $PBF_URL"
  curl -L --fail -o source.osm.pbf "$PBF_URL"
else
  echo "Reusing cached extract: $TMP/source.osm.pbf"
fi

echo "Filtering Rider Services POIs (fuel / lodging / campground / liquor)..."
osmium tags-filter source.osm.pbf \
  n/amenity=fuel w/amenity=fuel \
  n/tourism=hotel,motel,hostel,guest_house,chalet w/tourism=hotel,motel,hostel,guest_house,chalet \
  n/tourism=camp_site,caravan_site w/tourism=camp_site,caravan_site \
  n/shop=alcohol w/shop=alcohol \
  -o poi-candidates.osm.pbf --overwrite

echo "Exporting GeoJSON sequence (with centroids + timestamps)..."
osmium export poi-candidates.osm.pbf \
  --add-unique-id=type_id \
  -a type,id,timestamp \
  -f geojsonseq \
  -o poi-candidates.geojsonseq --overwrite

echo "Normalizing and packing chunks..."
SLUG="$(basename "$PBF_URL" | sed -E 's/-latest\.osm\.pbf$//')"
POI_REGION_LABEL="${POI_REGION_LABEL:-$SLUG}" \
  node "$ROOT/scripts/pack-osm-poi.js" "$TMP/poi-candidates.geojsonseq" "$OUT_DIR" "$PBF_URL"

echo "Done:"
ls -lh "$OUT_DIR"/poi.manifest.json
du -sh "$OUT_DIR/chunks"
