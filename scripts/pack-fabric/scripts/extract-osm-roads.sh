#!/usr/bin/env bash
# Extract motorized OSM road ways from a Geofabrik provincial PBF (road fabric).
#
# Usage:
#   bash scripts/extract-osm-roads.sh new-brunswick canada
#   bash scripts/extract-osm-roads.sh washington us
#
# Writes: data-raw/osm-roads/<slug>/roads.geojsonseq
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLUG="${1:-}"
COUNTRY="${2:-canada}"
if [ -z "$SLUG" ]; then
  echo "Usage: extract-osm-roads.sh <geofabrik-slug> [canada|us]" >&2
  exit 1
fi

case "$COUNTRY" in
  canada|us) ;;
  *) echo "Country must be canada or us" >&2; exit 1 ;;
esac
BASE_URL="https://download.geofabrik.de/north-america/$COUNTRY"
CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_ROOT="${OSM_ROADS_OUT_ROOT:-$ROOT/data-raw/osm-roads}"
OUT_DIR="$OUT_ROOT/$SLUG"
mkdir -p "$OUT_DIR"

PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
bash "$SCRIPT_DIR/ensure-current-osm-pbf.sh" "$BASE_URL" "$SLUG" "$PBF"

# Dual-sport fabric: highways → track/path/cycleway. Exclude footway/pedestrian/steps
# (those never enter this filter). Adapter also hard-drops foot infrastructure.
HIGHWAY_FILTER="motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path,cycleway"

echo "Filtering OSM highway ways (includes track/path/cycleway; no footway)…"
osmium tags-filter "$PBF" \
  w/highway="$HIGHWAY_FILTER" \
  -o "$OUT_DIR/roads.osm.pbf" --overwrite

echo "Exporting GeoJSON sequence…"
osmium export "$OUT_DIR/roads.osm.pbf" \
  --geometry-types=linestring \
  --add-unique-id=type_id \
  -a type,id,version,timestamp \
  -f geojsonseq \
  -o "$OUT_DIR/roads.geojsonseq" --overwrite

echo "Done: $OUT_DIR/roads.geojsonseq"
ls -lh "$OUT_DIR/roads.geojsonseq"

echo "Filtering OSM route=ferry ways (timed harbour connectors)…"
osmium tags-filter "$PBF" \
  w/route=ferry \
  -o "$OUT_DIR/ferries.osm.pbf" --overwrite

echo "Exporting ferry GeoJSON sequence…"
osmium export "$OUT_DIR/ferries.osm.pbf" \
  --geometry-types=linestring \
  --add-unique-id=type_id \
  -a type,id,version,timestamp \
  -f geojsonseq \
  -o "$OUT_DIR/ferries.geojsonseq" --overwrite

if [ -s "$OUT_DIR/ferries.geojsonseq" ]; then
  cat "$OUT_DIR/ferries.geojsonseq" >> "$OUT_DIR/roads.geojsonseq"
  echo "Merged ferries into roads.geojsonseq"
fi
ls -lh "$OUT_DIR/ferries.geojsonseq" "$OUT_DIR/roads.geojsonseq"
