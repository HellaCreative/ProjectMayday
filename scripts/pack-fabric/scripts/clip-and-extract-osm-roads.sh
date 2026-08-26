#!/usr/bin/env bash
# Clip a Geofabrik PBF to the OSM admin polygon, then export roads+ferries.
#
#   bash scripts/pack-fabric/scripts/clip-and-extract-osm-roads.sh pe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FABRIC="$(cd "$SCRIPT_DIR/.." && pwd)"
DIRT="$(cd "$FABRIC/../.." && pwd)"
export FABRIC
ID="${1:-}"
if [ -z "$ID" ]; then
  echo "Usage: clip-and-extract-osm-roads.sh <region-id>" >&2
  exit 1
fi

eval "$(node -e "
const { geofabrikSource } = require(process.env.FABRIC + '/routing/registry/geofabrik');
const { clipGeojsonPath } = require(process.env.FABRIC + '/scripts/fetch-admin-polygon');
const s = geofabrikSource(process.argv[1]);
const poly = clipGeojsonPath(s.id);
if (!poly) {
  console.error('missing admin polygon for ' + s.id + '; run fetch-admin-polygon.js');
  process.exit(1);
}
console.log('SLUG=' + JSON.stringify(s.slug));
console.log('COUNTRY=' + JSON.stringify(s.country));
console.log('POLY=' + JSON.stringify(poly));
" "$ID")"

CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="${OSM_ROADS_ROOT:-${OSM_ROADS_OUT_ROOT:-$FABRIC/data-raw/osm-roads}}/$SLUG"
mkdir -p "$OUT_DIR" "$CACHE_ROOT/$SLUG"
PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
CLIPPED="$CACHE_ROOT/$SLUG/admin-clipped.osm.pbf"
BASE_URL="https://download.geofabrik.de/north-america/$COUNTRY"

bash "$SCRIPT_DIR/ensure-current-osm-pbf.sh" "$BASE_URL" "$SLUG" "$PBF"

echo "Clipping $SLUG to OSM admin polygon…"
osmium extract --polygon "$POLY" --strategy complete_ways --overwrite -o "$CLIPPED" "$PBF"

HIGHWAY_FILTER="motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path,cycleway"

echo "Filtering highways from clipped PBF…"
osmium tags-filter "$CLIPPED" \
  w/highway="$HIGHWAY_FILTER" \
  -o "$OUT_DIR/roads-clipped.osm.pbf" --overwrite

osmium export "$OUT_DIR/roads-clipped.osm.pbf" \
  --geometry-types=linestring \
  --add-unique-id=type_id \
  -a type,id,version,timestamp \
  -f geojsonseq \
  -o "$OUT_DIR/roads.geojsonseq" --overwrite

osmium tags-filter "$CLIPPED" w/route=ferry -o "$OUT_DIR/ferries.osm.pbf" --overwrite
osmium export "$OUT_DIR/ferries.osm.pbf" \
  --geometry-types=linestring \
  --add-unique-id=type_id \
  -a type,id,version,timestamp \
  -f geojsonseq \
  -o "$OUT_DIR/ferries.geojsonseq" --overwrite

if [ -s "$OUT_DIR/ferries.geojsonseq" ]; then
  cat "$OUT_DIR/ferries.geojsonseq" >> "$OUT_DIR/roads.geojsonseq"
  echo "merged ferries"
fi
ls -lh "$OUT_DIR/roads.geojsonseq"
