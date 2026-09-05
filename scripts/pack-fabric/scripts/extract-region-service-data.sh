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
WORK_DIR=""
if [ -f "$CACHED_PBF" ]; then
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

OUT_DIR="$ROOT/data-raw/osm-services/$SLUG"
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
  "$ROOT/scripts/pack-fabric/app/data/rider-services/v1/$REGION_ID/rider-services.v1.json"

if [ "$MODE" = "with-fuel" ]; then
  FUEL_V1_OUT="$ROOT/scripts/pack-fabric/app/data/packs/v1/$REGION_ID/fuel.v1.json" \
  FUEL_REGION_ID="$REGION_ID" \
  node "$ROOT/scripts/pack-fabric/scripts/build-fuel-pack.js" "$SEQUENCE"
fi

echo "service data complete region=$REGION_ID sourceUpdatedAt=$SOURCE_UPDATED_AT"
