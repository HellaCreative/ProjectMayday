#!/usr/bin/env bash
# Build bundled Nova Scotia OSM motorized/off-road overlay.
# Run from repo root. Requires: curl, osmium-tool, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-osm-motorized-build"
OUT_DIR="$ROOT/app/data"
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf}"

mkdir -p "$TMP" "$OUT_DIR"
cd "$TMP"

echo "Downloading OSM extract..."
curl -L --fail -o source.osm.pbf "$PBF_URL"

echo "Filtering candidate track / path / bridleway ways..."
osmium tags-filter source.osm.pbf \
  w/highway=track \
  w/highway=path \
  w/highway=bridleway \
  -o osm-motorized-candidates.osm.pbf --overwrite

echo "Exporting GeoJSON sequence..."
osmium export osm-motorized-candidates.osm.pbf \
  --add-unique-id type_id \
  -f geojsonseq \
  -o osm-motorized-candidates.geojsonseq --overwrite

echo "Classifying and packing..."
node "$ROOT/scripts/pack-osm-motorized.js" "$TMP/osm-motorized-candidates.geojsonseq" "$OUT_DIR" "$PBF_URL"

echo "Done:"
ls -lh "$OUT_DIR"/osm-overpass-motorized.*
