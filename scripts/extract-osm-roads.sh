#!/usr/bin/env bash
# Extract motorized OSM road ways from a Geofabrik provincial PBF for gap-fill.
#
# Usage:
#   bash scripts/extract-osm-roads.sh new-brunswick
#   bash scripts/extract-osm-roads.sh quebec
#
# Writes: data-raw/osm-roads/<slug>/roads.geojsonseq
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: extract-osm-roads.sh <geofabrik-slug>" >&2
  exit 1
fi

BASE_URL="https://download.geofabrik.de/north-america/canada"
CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="$ROOT/data-raw/osm-roads/$SLUG"
mkdir -p "$OUT_DIR"

PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
if [ ! -f "$PBF" ]; then
  mkdir -p "$CACHE_ROOT/$SLUG"
  echo "Downloading $BASE_URL/${SLUG}-latest.osm.pbf"
  curl -L --fail -o "$PBF" "$BASE_URL/${SLUG}-latest.osm.pbf"
else
  echo "Reusing cached PBF: $PBF"
fi

echo "Filtering motorized highway ways…"
osmium tags-filter "$PBF" \
  w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track \
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
