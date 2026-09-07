#!/usr/bin/env bash
# Build DIRT-owned regional Rider Services data and, when requested, the
# existing fuel.v1 sidecar. OSM is contacted only here at pack-build time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REGION_ID="${1:-}"
MODE="${2:-rider-only}"
if ! [[ "$REGION_ID" =~ ^[a-z]{2}$ ]]; then
  echo "Usage: extract-region-service-data.sh <region-id> [rider-only|with-fuel]" >&2
  exit 1
fi
if [ "$MODE" != "rider-only" ] && [ "$MODE" != "with-fuel" ]; then
  echo "Mode must be rider-only or with-fuel" >&2
  exit 1
fi

read -r SLUG COUNTRY URL <<EOF
$(node -e 'const g=require(process.argv[1]); const s=g.geofabrikSource(process.argv[2]); process.stdout.write(s.slug+" "+s.country+" "+g.geofabrikPbfUrl(s.id));' "$ROOT/scripts/pack-fabric/routing/registry/geofabrik.js" "$REGION_ID")
EOF

CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
CACHED_PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
RIDER_OUT="${RIDER_SERVICES_V1_OUT:-$ROOT/scripts/pack-fabric/app/data/rider-services/v1/$REGION_ID/rider-services.v1.json}"
FUEL_OUT="${FUEL_V1_OUT:-$ROOT/scripts/pack-fabric/app/data/packs/v1/$REGION_ID/fuel.v1.json}"
WORK_DIR=""

# A V4 fabric may not combine independently refreshed graphs, fuel, and Rider
# Services. When a source lock is supplied, use and verify that exact PBF.
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
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dirt-service-$REGION_ID.XXXXXX")"
  PBF="$WORK_DIR/source.osm.pbf"
  echo "Downloading $URL"
  curl -L --fail \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 90 --max-time 900 \
    -o "$PBF.partial" "$URL"
  mv "$PBF.partial" "$PBF"
fi

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

OUT_DIR="${OSM_SERVICE_WORK_ROOT:-$ROOT/data-raw/osm-services}/$SLUG"
mkdir -p "$OUT_DIR"
CANDIDATES="$OUT_DIR/service-candidates.osm.pbf"
SEQUENCE="$OUT_DIR/services.geojsonseq"
SOURCE_UPDATED_AT="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF" || true)"

osmium tags-filter "$PBF" \
  -e "$ROOT/profiles/dirt-service-data.osmium" \
  -o "$CANDIDATES" --overwrite
osmium export "$CANDIDATES" \
  --add-unique-id=type_id \
  -a type,id,timestamp \
  -f geojsonseq \
  -o "$SEQUENCE" --overwrite

RIDER_SERVICES_REGION_ID="$REGION_ID" \
RIDER_SERVICES_SOURCE_UPDATED_AT="$SOURCE_UPDATED_AT" \
node "$ROOT/scripts/pack-fabric/scripts/build-rider-services-pack.js" \
  "$SEQUENCE" \
  "$RIDER_OUT"

if [ "$MODE" = "with-fuel" ]; then
  FUEL_V1_OUT="$FUEL_OUT" \
  FUEL_REGION_ID="$REGION_ID" \
  FUEL_SOURCE_UPDATED_AT="$SOURCE_UPDATED_AT" \
  node "$ROOT/scripts/pack-fabric/scripts/build-fuel-pack.js" "$SEQUENCE" "$OUT_DIR/fuel-chunks"
fi

echo "service data complete region=$REGION_ID sourceUpdatedAt=$SOURCE_UPDATED_AT"
