#!/usr/bin/env bash
# Copy BC.mbtiles into a booted Simulator's Dirt Documents folder.
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/install-bc-mbtiles-sim.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/experiments/bc-osm-only/out/BC.mbtiles}"
BUNDLE_ID="${DIRT_BUNDLE_ID:-com.mayday.dirt}"

if [ ! -f "$SRC" ]; then
  echo "Missing $SRC — run bash scripts/build-bc-tiles.sh first" >&2
  exit 1
fi

UDID="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
if [ -z "${UDID:-}" ]; then
  echo "No booted Simulator — boot one, launch Dirt once, re-run." >&2
  exit 1
fi

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [ -z "${DATA:-}" ]; then
  echo "App container not found for $BUNDLE_ID on $UDID — launch Dirt once first." >&2
  exit 1
fi

DEST="$DATA/Documents/BC.mbtiles"
mkdir -p "$(dirname "$DEST")"
echo "Copying $(du -h "$SRC" | awk '{print $1}') → $DEST"
cp -f "$SRC" "$DEST"
echo "Done. Toggle Layers → BC OSM hierarchy (test)."
