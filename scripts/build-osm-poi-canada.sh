#!/usr/bin/env bash
# Build Rider Services POI packs from Geofabrik provincial extracts.
#
# Extends the NS-only build to all Canadian provinces/territories. Same OSM
# filters (fuel, lodging, campground, liquor), same pack-osm-poi.js normalizer,
# same chunked-by-viewport delivery. One merged manifest covers all regions.
#
# Env:
#   POI_REGIONS   space-separated Geofabrik slugs (default: all Canada)
#   POI_OUT_DIR   output directory (default: app/data/poi)
#   SKIP_DOWNLOAD=1  reuse cached PBFs under TMP
#
# Run from repo root. Requires: curl, osmium-tool, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-osm-poi-build"
OUT_DIR="${POI_OUT_DIR:-$ROOT/app/data/poi}"
BASE_URL="https://download.geofabrik.de/north-america/canada"

# Geofabrik canada/* slugs (provinces + territories).
DEFAULT_REGIONS=(
  alberta
  british-columbia
  manitoba
  new-brunswick
  newfoundland-and-labrador
  northwest-territories
  nova-scotia
  nunavut
  ontario
  prince-edward-island
  quebec
  saskatchewan
  yukon
)

if [ -n "${POI_REGIONS:-}" ]; then
  # shellcheck disable=SC2206
  REGIONS=($POI_REGIONS)
else
  REGIONS=("${DEFAULT_REGIONS[@]}")
fi

mkdir -p "$TMP" "$OUT_DIR" "$TMP/regions"
MERGED="$TMP/poi-candidates-canada.geojsonseq"
: > "$MERGED"
SOURCES_JSON="$TMP/poi-sources.json"
echo "[" > "$SOURCES_JSON"
FIRST_SRC=1

for slug in "${REGIONS[@]}"; do
  echo "=== POI region: $slug ==="
  PBF_URL="$BASE_URL/${slug}-latest.osm.pbf"
  REGION_DIR="$TMP/regions/$slug"
  mkdir -p "$REGION_DIR"
  cd "$REGION_DIR"

  if [ "${SKIP_DOWNLOAD:-0}" != "1" ] || [ ! -f source.osm.pbf ]; then
    if [ ! -f source.osm.pbf ]; then
      echo "Downloading $PBF_URL"
      curl -L --fail -o source.osm.pbf "$PBF_URL"
    else
      echo "Reusing cached extract: $REGION_DIR/source.osm.pbf"
    fi
  else
    echo "SKIP_DOWNLOAD=1 and cache missing for $slug" >&2
    exit 1
  fi

  echo "Filtering Rider Services POIs…"
  osmium tags-filter source.osm.pbf \
    n/amenity=fuel w/amenity=fuel \
    n/tourism=hotel,motel,hostel,guest_house,chalet w/tourism=hotel,motel,hostel,guest_house,chalet \
    n/tourism=camp_site,caravan_site w/tourism=camp_site,caravan_site \
    n/shop=alcohol w/shop=alcohol \
    -o poi-candidates.osm.pbf --overwrite

  echo "Exporting GeoJSON sequence…"
  osmium export poi-candidates.osm.pbf \
    --add-unique-id=type_id \
    -a type,id,timestamp \
    -f geojsonseq \
    -o poi-candidates.geojsonseq --overwrite

  cat poi-candidates.geojsonseq >> "$MERGED"
  if [ "$FIRST_SRC" -eq 1 ]; then
    FIRST_SRC=0
  else
    echo "," >> "$SOURCES_JSON"
  fi
  printf '  {"slug":"%s","url":"%s"}' "$slug" "$PBF_URL" >> "$SOURCES_JSON"
done

echo "" >> "$SOURCES_JSON"
echo "]" >> "$SOURCES_JSON"

echo "Normalizing and packing Canada-wide chunks…"
POI_REGION_LABEL="Canada" \
POI_SOURCES_FILE="$SOURCES_JSON" \
  node "$ROOT/scripts/pack-osm-poi.js" "$MERGED" "$OUT_DIR" "geofabrik:canada-provinces"

echo "Done:"
ls -lh "$OUT_DIR"/poi.manifest.json
du -sh "$OUT_DIR/chunks"
