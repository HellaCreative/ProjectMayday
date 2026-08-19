#!/usr/bin/env bash
# DIRT: BC OSM-only feasibility — normalize tags → tippecanoe → BC.mbtiles.
#
# Tippecanoe (not stock Planetiler) so highway tags + dual-sport attributes survive.
#
# Prerequisites: bash scripts/filter-bc-osm.sh
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/build-bc-tiles.sh
#
# Layer name `-l dirt_roads` must match MapLibre `sourceLayerIdentifier` and
# MBTilesVectorProxy tileJSON vector_layers id.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BC_OSM_OUT:-$ROOT/experiments/bc-osm-only/out}"
RAW="$OUT/british-columbia-highways.geojsonseq"
NORM="$OUT/british-columbia-highways.normalized.geojsonseq"
MBTILES="$OUT/BC.mbtiles"
MINZOOM="${BC_TILE_MINZOOM:-4}"
MAXZOOM="${BC_TILE_MAXZOOM:-14}"

if [ ! -f "$RAW" ]; then
  echo "Missing $RAW — run: bash scripts/filter-bc-osm.sh" >&2
  exit 1
fi

echo "Normalizing tags (flag low confidence, do not invent surface)…"
node "$ROOT/scripts/normalize-bc-osm-tags.js" "$RAW" "$NORM"

echo "Building $MBTILES (z${MINZOOM}–z${MAXZOOM})…"
rm -f "$MBTILES"
# Gzip tile compression stays ON (default). MBTilesVectorProxy serves
# Content-Encoding: gzip when magic is 1F8B. To store raw MVT instead, add
# --no-tile-compression to the tippecanoe args below.
tippecanoe \
  -o "$MBTILES" \
  -l dirt_roads \
  -Z"$MINZOOM" -z"$MAXZOOM" \
  --drop-densest-as-needed \
  --extend-zooms-if-still-dropping \
  --force \
  -y highway -y name -y ref -y surface -y tracktype -y mtb:scale \
  -y access -y motor_vehicle -y atv -y ohv -y maxwidth -y width \
  -y trail_visibility -y smoothness -y data_confidence \
  -n "DIRT BC OSM full hierarchy (no footway)" \
  -A "© OpenStreetMap contributors · Geofabrik BC extract" \
  "$NORM"

echo "Done:"
ls -lh "$MBTILES"
sqlite3 "$MBTILES" "SELECT name, value FROM metadata;" 2>/dev/null || true
