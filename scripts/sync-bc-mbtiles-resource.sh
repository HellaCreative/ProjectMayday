#!/usr/bin/env bash
# Hardlink experiments/bc-osm-only/out/BC.mbtiles → Dirt/Resources/BC.mbtiles
# so Xcode's synchronized Dirt group bundles it for device installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/experiments/bc-osm-only/out/BC.mbtiles"
DEST="$ROOT/Dirt/Resources/BC.mbtiles"
mkdir -p "$(dirname "$DEST")"
if [ ! -f "$SRC" ]; then
  echo "Missing $SRC — run: bash scripts/build-bc-tiles.sh" >&2
  exit 1
fi
rm -f "$DEST"
ln "$SRC" "$DEST"
echo "Linked $(du -h "$DEST" | awk '{print $1}') → $DEST"
echo "Rebuild/Run from Xcode to your device. Layers → BC OSM hierarchy (test)."
