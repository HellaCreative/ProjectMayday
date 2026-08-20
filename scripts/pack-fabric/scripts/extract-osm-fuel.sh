#!/usr/bin/env bash
# Extract OSM fuel stations from a Geofabrik provincial PBF.
#
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/pack-fabric/scripts/extract-osm-fuel.sh british-columbia canada
#   bash scripts/pack-fabric/scripts/extract-osm-fuel.sh washington us
#
# Writes: data-raw/osm-fuel/<slug>/fuel.geojsonseq
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLUG="${1:-}"
COUNTRY="${2:-canada}"
if [ -z "$SLUG" ]; then
  echo "Usage: extract-osm-fuel.sh <geofabrik-slug> [canada|us]" >&2
  exit 1
fi

FILTER="$ROOT/profiles/dirt-fuel.osmium"
case "$COUNTRY" in
  canada|us) ;;
  *) echo "Country must be canada or us" >&2; exit 1 ;;
esac
BASE_URL="https://download.geofabrik.de/north-america/$COUNTRY"
CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="$ROOT/data-raw/osm-fuel/$SLUG"
mkdir -p "$OUT_DIR" "$CACHE_ROOT/$SLUG"

PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
bash "$SCRIPT_DIR/ensure-current-osm-pbf.sh" "$BASE_URL" "$SLUG" "$PBF"

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
