#!/usr/bin/env bash
# Build bundled Nova Scotia trail GeoJSON from Geofabrik OSM extract.
# Run from repo root. Requires: curl, osmium-tool, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-ns-build"
OUT_DIR="$ROOT/app/data"
PBF_URL="https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf"

mkdir -p "$TMP" "$OUT_DIR"
cd "$TMP"

echo "Downloading Nova Scotia OSM extract…"
curl -L --fail -o nova-scotia-latest.osm.pbf "$PBF_URL"

echo "Filtering track / path / bridleway ways…"
osmium tags-filter nova-scotia-latest.osm.pbf \
  w/highway=track \
  w/highway=bridleway \
  w/highway=path \
  -o ns-dirt-ways.osm.pbf --overwrite

echo "Exporting GeoJSON sequence…"
osmium export ns-dirt-ways.osm.pbf -f geojsonseq -o ns-dirt.geojsonseq --overwrite

echo "Classifying and packing…"
node "$ROOT/scripts/pack-ns-trails.js" "$TMP/ns-dirt.geojsonseq" "$OUT_DIR"

echo "Done → $OUT_DIR/ns-trails.geojson"
ls -lh "$OUT_DIR"/ns-trails.*
