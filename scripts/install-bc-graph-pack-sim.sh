#!/usr/bin/env bash
# Copy rebuilt BC graph.v2 + geometry.v1 into a booted Simulator Dirt pack cache.
# Usage (from MAYDAYiOS/Dirt):
#   bash scripts/install-bc-graph-pack-sim.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${1:-$ROOT/scripts/pack-fabric/routing/data/regions/bc}"
BUNDLE_ID="${DIRT_BUNDLE_ID:-com.mayday.dirt}"

GRAPH="$SRC_DIR/graph.v2.bin"
GEOM="$SRC_DIR/geometry.v1.bin"
if [ ! -f "$GRAPH" ] || [ ! -f "$GEOM" ]; then
  echo "Missing $GRAPH or $GEOM — run stitch-adventure-tips.js --pack-v2 first." >&2
  exit 1
fi

UDID="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
if [ -z "${UDID:-}" ]; then
  echo "No booted Simulator — boot one, launch Dirt once, re-run." >&2
  exit 1
fi

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [ -z "${DATA:-}" ]; then
  echo "App container not found for $BUNDLE_ID — launch Dirt once first." >&2
  exit 1
fi

PACK_ROOT="$DATA/Library/Application Support/dirt-graph-packs"
if [ ! -d "$PACK_ROOT" ]; then
  echo "No pack cache at $PACK_ROOT — download BC from PACKS once, then re-run." >&2
  exit 1
fi

DEST_DIR="$(find "$PACK_ROOT" -type d -path '*/bc' | head -n 1 || true)"
if [ -z "${DEST_DIR:-}" ]; then
  echo "No installed bc folder under $PACK_ROOT — download BC from PACKS first." >&2
  exit 1
fi

echo "Installing $(du -h "$GRAPH" | awk '{print $1}') graph + $(du -h "$GEOM" | awk '{print $1}') geom → $DEST_DIR"
cp -f "$GRAPH" "$DEST_DIR/graph.v2.bin"
cp -f "$GEOM" "$DEST_DIR/geometry.v1.bin"
echo "Done. Force-quit Dirt and relaunch so the pack reloads."
