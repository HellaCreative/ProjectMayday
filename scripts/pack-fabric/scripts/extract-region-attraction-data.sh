#!/usr/bin/env bash
# Build DIRT-owned regional attractions.v1 from Geofabrik. OSM is contacted
# only here at pack-build time. Graph packs and rider-services.v1 are untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REGION_ID="${1:-}"
if ! [[ "$REGION_ID" =~ ^[a-z]{2}(-[a-z0-9]+)?$ ]]; then
  echo "Usage: extract-region-attraction-data.sh <region-id>" >&2
  exit 1
fi

read -r SLUG DOWNLOAD_SLUG COUNTRY URL <<EOF
$(node -e 'const g=require(process.argv[1]); const s=g.geofabrikSource(process.argv[2]); process.stdout.write(s.slug+" "+g.geofabrikDownloadSlug(s.id)+" "+s.country+" "+g.geofabrikPbfUrl(s.id));' "$ROOT/scripts/pack-fabric/routing/registry/geofabrik.js" "$REGION_ID")
EOF

CACHE_ROOT="${OSM_PBF_CACHE:-$ROOT/scripts/pack-fabric/routing/pbf-cache}"
CACHED_PBF="$CACHE_ROOT/$DOWNLOAD_SLUG/source.osm.pbf"
ATTRACTIONS_OUT="${ATTRACTIONS_V1_OUT:-$ROOT/scripts/pack-fabric/app/data/attractions/v1/$REGION_ID/attractions.v1.json}"
WORK_DIR=""

if [ -n "${DIRT_V4_SOURCE_LOCK:-}" ]; then
  read -r LOCK_PATH LOCK_BYTES LOCK_SHA LOCK_TIMESTAMP <<EOF
$(node -e '
const fs=require("fs");
const path=require("path");
const lock=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(lock.schema!=="dirt-osm-source-lock.v1"||!lock.fabricEpoch) throw new Error("invalid V4 source lock");
const row=lock.regions&&lock.regions[process.argv[2]];
if(!row) throw new Error("source lock missing "+process.argv[2]);
process.stdout.write([path.resolve(row.cachedPath),row.sourceBytes,row.sourceSha256,row.osmTimestamp].join(" "));
' "$DIRT_V4_SOURCE_LOCK" "$REGION_ID")
EOF
  PBF="$LOCK_PATH"
  [ -f "$PBF" ] || { echo "Locked source is missing: $PBF" >&2; exit 1; }
  ACTUAL_BYTES="$(stat -f '%z' "$PBF")"
  ACTUAL_SHA="$(shasum -a 256 "$PBF" | awk '{print $1}')"
  ACTUAL_TIMESTAMP="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF")"
  [ "$ACTUAL_BYTES" = "$LOCK_BYTES" ] || { echo "Locked source byte mismatch for $REGION_ID" >&2; exit 1; }
  [ "$ACTUAL_SHA" = "$LOCK_SHA" ] || { echo "Locked source hash mismatch for $REGION_ID" >&2; exit 1; }
  [ "$ACTUAL_TIMESTAMP" = "$LOCK_TIMESTAMP" ] || { echo "Locked source timestamp mismatch for $REGION_ID" >&2; exit 1; }
  echo "Using source-locked PBF $PBF"
elif [ -f "$CACHED_PBF" ]; then
  PBF="$CACHED_PBF"
  echo "Reusing cached source $PBF"
else
  mkdir -p "$CACHE_ROOT/$DOWNLOAD_SLUG"
  PBF="$CACHED_PBF"
  echo "Downloading $URL"
  curl -L --fail \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 90 --max-time 1800 \
    -o "$PBF.partial" "$URL"
  mv "$PBF.partial" "$PBF"
fi

OUT_DIR="${OSM_ATTRACTION_WORK_ROOT:-$ROOT/data-raw/osm-attractions}/$SLUG"
mkdir -p "$OUT_DIR"
CANDIDATES="$OUT_DIR/attraction-candidates.osm.pbf"
SEQUENCE="$OUT_DIR/attractions.geojsonseq"
SOURCE_UPDATED_AT="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF" || true)"

osmium tags-filter "$PBF" \
  -e "$ROOT/profiles/dirt-attraction-data.osmium" \
  -o "$CANDIDATES" --overwrite
osmium export "$CANDIDATES" \
  --add-unique-id=type_id \
  -a type,id,timestamp \
  -f geojsonseq \
  -o "$SEQUENCE" --overwrite

ATTRACTIONS_REGION_ID="$REGION_ID" \
ATTRACTIONS_SOURCE_UPDATED_AT="$SOURCE_UPDATED_AT" \
node "$ROOT/scripts/pack-fabric/scripts/build-attractions-pack.js" \
  "$SEQUENCE" \
  "$ATTRACTIONS_OUT"

node "$ROOT/scripts/pack-fabric/scripts/write-attractions-manifest.js"

echo "attraction data complete region=$REGION_ID sourceUpdatedAt=$SOURCE_UPDATED_AT"
