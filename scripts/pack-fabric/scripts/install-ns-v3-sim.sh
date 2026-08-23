#!/usr/bin/env bash
# Install local NS graph.v3 into the iOS Simulator app Documents/DirtLocalPacks/ns/
# so GraphPackStore seeds it on next launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/DirtTests/Fixtures/DirtLocalPacks/ns"
APP_ID="${DIRT_BUNDLE_ID:-com.mayday.Dirt}"
UDID="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
if [[ -z "${UDID:-}" ]]; then
  echo "No booted simulator. Boot one in Xcode, then re-run." >&2
  exit 1
fi
if [[ ! -f "$SRC/graph.v3.bin" ]]; then
  echo "Missing $SRC/graph.v3.bin — run build-ns-graph-v3.js first." >&2
  exit 1
fi
DATA="$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)"
if [[ -z "$DATA" ]]; then
  echo "App $APP_ID not installed on $UDID. Build & run Dirt once, then re-run." >&2
  exit 1
fi
DEST="$DATA/Documents/DirtLocalPacks/ns"
mkdir -p "$DEST"
cp -f "$SRC/graph.v3.bin" "$DEST/"
cp -f "$SRC/geometry.v1.bin" "$DEST/"
echo "Installed NS v3 pack → $DEST"
echo "Relaunch Dirt; GraphPackStore will seed graph.v3.bin into the pack cache."
