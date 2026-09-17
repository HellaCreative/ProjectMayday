#!/usr/bin/env bash
# Extract attractions.v1 for every registered catalog region. Cached Geofabrik
# PBFs are reused. Missing extracts are downloaded unless ATTRACTIONS_SKIP_DOWNLOAD=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CACHE_ROOT="${OSM_PBF_CACHE:-$ROOT/scripts/pack-fabric/routing/pbf-cache}"
export OSM_PBF_CACHE="$CACHE_ROOT"

FAILED=()
while IFS= read -r REGION_ID; do
  DOWNLOAD_SLUG="$(node -e 'process.stdout.write(require(process.argv[1]).geofabrikDownloadSlug(process.argv[2]));' "$ROOT/scripts/pack-fabric/routing/registry/geofabrik.js" "$REGION_ID")"
  CACHED_PBF="$CACHE_ROOT/$DOWNLOAD_SLUG/source.osm.pbf"
  if [ ! -f "$CACHED_PBF" ] && [ "${ATTRACTIONS_SKIP_DOWNLOAD:-}" = "1" ]; then
    echo "skip $REGION_ID (no cached PBF)"
    continue
  fi
  echo "=== attractions $REGION_ID ==="
  if ! "$ROOT/scripts/pack-fabric/scripts/extract-region-attraction-data.sh" "$REGION_ID"; then
    FAILED+=("$REGION_ID")
  fi
done < <(node -e 'require(process.argv[1]).catalogRegionIds().forEach((id) => console.log(id));' "$ROOT/scripts/pack-fabric/routing/registry/geofabrik.js")

if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "attraction extract failed: ${FAILED[*]}" >&2
  exit 1
fi
echo "attraction extract complete for cached/downloaded regions"
