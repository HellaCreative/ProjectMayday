#!/usr/bin/env bash
# Extract OSM fuel stations from a Geofabrik provincial PBF.
#
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/pack-fabric/scripts/extract-osm-fuel.sh british-columbia
#   bash scripts/pack-fabric/scripts/extract-osm-fuel.sh nova-scotia
#
# Writes: data-raw/osm-fuel/<slug>/fuel.geojsonseq
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "Usage: extract-osm-fuel.sh <geofabrik-slug>" >&2
  exit 1
fi

FILTER="$ROOT/profiles/dirt-fuel.osmium"
BASE_URL="https://download.geofabrik.de/north-america/canada"
CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="$ROOT/data-raw/osm-fuel/$SLUG"
mkdir -p "$OUT_DIR" "$CACHE_ROOT/$SLUG"

PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
if [ ! -f "$PBF" ]; then
  echo "Downloading $BASE_URL/${SLUG}-latest.osm.pbf"
  curl -L --fail --retry 3 -o "$PBF.partial" "$BASE_URL/${SLUG}-latest.osm.pbf"
  mv "$PBF.partial" "$PBF"
else
  echo "Reusing cached PBF: $PBF"
fi

echo "Filtering amenity=fuel…"
osmium tags-filter "$PBF" \
  -e "$FILTER" \
  -o "$OUT_DIR/fuel-candidates.osm.pbf" \
  --overwrite

echo "Exporting GeoJSON sequence (points + areas, with timestamps)…"
osmium export "$OUT_DIR/fuel-candidates.osm.pbf" \
  --add-unique-id=type_id \
  -a type,id,timestamp \
  -f geojsonseq \
  -o "$OUT_DIR/fuel.geojsonseq" \
  --overwrite

echo "Done: $OUT_DIR/fuel.geojsonseq"
ls -lh "$OUT_DIR/fuel.geojsonseq"
