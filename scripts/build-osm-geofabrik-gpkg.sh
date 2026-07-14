#!/usr/bin/env bash
# Build bundled Nova Scotia OSM Geofabrik GPKG comparison overlay.
# Run from repo root. Requires: curl, unzip, ogr2ogr, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-osm-geofabrik-gpkg-build"
OUT_DIR="$ROOT/app/data"
GPKG_PATH="${GPKG_PATH:-$ROOT/OSM-tracks/nova-scotia.gpkg}"
GPKG_URL="${GPKG_URL:-https://download.geofabrik.de/north-america/canada/nova-scotia-latest-free.gpkg.zip}"

mkdir -p "$TMP" "$OUT_DIR"
cd "$TMP"

if [[ -f "$GPKG_PATH" ]]; then
  echo "Using local Geofabrik GPKG: $GPKG_PATH"
  SOURCE_GPKG="$GPKG_PATH"
else
  echo "Downloading Geofabrik GPKG export..."
  curl -L --fail -o nova-scotia-latest-free.gpkg.zip "$GPKG_URL"
  unzip -o -j nova-scotia-latest-free.gpkg.zip '*.gpkg' -d "$TMP"
  SOURCE_GPKG="$(find "$TMP" -maxdepth 1 -name '*.gpkg' | head -n 1)"
fi

if [[ -z "${SOURCE_GPKG:-}" || ! -f "$SOURCE_GPKG" ]]; then
  echo "No GeoPackage found." >&2
  exit 1
fi

echo "Exporting Geofabrik road/path candidates..."
ogr2ogr \
  -f GeoJSONSeq "$TMP/osm-geofabrik-gpkg-candidates.geojsonseq" \
  "$SOURCE_GPKG" gis_osm_roads_free \
  -where "fclass LIKE 'track%' OR fclass IN ('path','bridleway')" \
  -lco RS=YES

echo "Classifying and packing..."
node "$ROOT/scripts/pack-osm-geofabrik-gpkg.js" \
  "$TMP/osm-geofabrik-gpkg-candidates.geojsonseq" \
  "$OUT_DIR" \
  "$GPKG_URL"

echo "Done:"
ls -lh "$OUT_DIR"/osm-geofabrik-gpkg.*
