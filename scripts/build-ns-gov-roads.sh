#!/usr/bin/env bash
# Build bundled Nova Scotia government NSTDB non-paved/track road overlay.
# Run from repo root. Requires: node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/app/data"
SOURCE_URL="${NS_GOV_ROADS_URL:-https://data.novascotia.ca/resource/a6gf-w68e.json}"

mkdir -p "$OUT_DIR"

echo "Downloading and packing Nova Scotia NSTDB roads..."
node "$ROOT/scripts/pack-ns-gov-roads.js" "$OUT_DIR" "$SOURCE_URL"

echo "Done:"
ls -lh "$OUT_DIR"/ns-gov-roads.*
