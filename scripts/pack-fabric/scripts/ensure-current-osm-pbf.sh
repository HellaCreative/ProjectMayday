#!/usr/bin/env bash
# Keeps shared Geofabrik input fresh without downloading the same regional PBF
# once for roads, again for fuel, and again for settlement extraction.
set -euo pipefail

BASE_URL="${1:?base URL required}"
SLUG="${2:?Geofabrik slug required}"
PBF="${3:?destination PBF required}"
MAX_AGE_HOURS="${OSM_PBF_MAX_AGE_HOURS:-12}"

if ! [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  echo "OSM_PBF_MAX_AGE_HOURS must be a non-negative integer" >&2
  exit 1
fi

needs_download=0
if [ ! -f "$PBF" ] || [ "${OSM_REFRESH:-0}" = "1" ]; then
  needs_download=1
else
  pbf_mtime="$(stat -f %m "$PBF" 2>/dev/null || stat -c %Y "$PBF")"
  pbf_age_seconds=$(( $(date +%s) - pbf_mtime ))
  if [ "$pbf_age_seconds" -gt $(( MAX_AGE_HOURS * 3600 )) ]; then
    needs_download=1
  fi
fi

if [ "$needs_download" -eq 1 ]; then
  mkdir -p "$(dirname "$PBF")"
  echo "Downloading $BASE_URL/${SLUG}-latest.osm.pbf"
  curl -L --fail \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 90 \
    --continue-at - \
    -o "$PBF.partial" "$BASE_URL/${SLUG}-latest.osm.pbf"
  mv "$PBF.partial" "$PBF"
else
  echo "Reusing fresh cached PBF (≤${MAX_AGE_HOURS}h): $PBF"
fi

echo "OSM replication timestamp: $(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF")"
