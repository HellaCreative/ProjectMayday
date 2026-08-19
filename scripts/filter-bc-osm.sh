#!/usr/bin/env bash
# DIRT: BC OSM-only feasibility — Geofabrik BC → filtered highway GeoJSONSeq.
#
# Retains full highway hierarchy EXCEPT footway (Rick: no foot routes/trails/paths).
# Keeps path + cycleway + track so dual-sport / ATV resolution is visible.
#
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/filter-bc-osm.sh
#
# Env:
#   BC_OSM_OUT   output root (default: experiments/bc-osm-only/out)
#   OSM_PBF_CACHE cache dir for Geofabrik PBF
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BC_OSM_OUT:-$ROOT/experiments/bc-osm-only/out}"
CACHE="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions/british-columbia}"
FILTER="$ROOT/profiles/bc-full-hierarchy.osmium"
BASE_URL="https://download.geofabrik.de/north-america/canada"
PBF="$CACHE/british-columbia-latest.osm.pbf"

mkdir -p "$OUT" "$CACHE"

if [ ! -f "$PBF" ]; then
  echo "Downloading $BASE_URL/british-columbia-latest.osm.pbf …"
  curl -L --fail --retry 3 -o "$PBF.partial" "$BASE_URL/british-columbia-latest.osm.pbf"
  mv "$PBF.partial" "$PBF"
else
  echo "Reusing cached PBF: $PBF ($(du -h "$PBF" | awk '{print $1}'))"
fi

echo "Filtering highways (no footway) via $FILTER …"
osmium tags-filter "$PBF" \
  -e "$FILTER" \
  -o "$OUT/british-columbia-highways.osm.pbf" \
  --overwrite

echo "Exporting GeoJSONSeq (lines only)…"
osmium export "$OUT/british-columbia-highways.osm.pbf" \
  --geometry-types=linestring \
  --add-unique-id=type_id \
  -a type,id,version,timestamp \
  -f geojsonseq \
  -o "$OUT/british-columbia-highways.geojsonseq" \
  --overwrite

echo "Done:"
ls -lh "$OUT/british-columbia-highways.osm.pbf" "$OUT/british-columbia-highways.geojsonseq"
