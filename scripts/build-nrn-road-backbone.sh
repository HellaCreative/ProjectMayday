#!/usr/bin/env bash
# Build bundled Nova Scotia NRN road backbone overlay.
# Run from repo root. Requires: curl, unzip, GDAL/ogr2ogr, node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/dirt-nrn-build"
OUT_DIR="$ROOT/app/data"
NRN_URL="${NRN_URL:-https://geo.statcan.gc.ca/nrn_rrn/ns/nrn_rrn_ns_GPKG.zip}"
LAYER="${NRN_LAYER:-NRN_NS_18_0_ROADSEG}"

rm -rf "$TMP"
mkdir -p "$TMP" "$OUT_DIR"
cd "$TMP"

echo "Downloading NRN Nova Scotia GeoPackage..."
curl -L --fail -o nrn.zip "$NRN_URL"

echo "Unpacking..."
unzip -q nrn.zip
GPKG="$(find "$TMP" -name '*_GPKG_en.gpkg' | head -1)"
if [[ -z "$GPKG" ]]; then
  echo "No English NRN GeoPackage found" >&2
  exit 1
fi

echo "Exporting road segment GeoJSON sequence..."
ogr2ogr \
  -f GeoJSONSeq \
  -t_srs EPSG:4326 \
  -select "NID,ROADSEGID,ROADCLASS,PAVSTATUS,PAVSURF,UNPAVSURF,STRUNAMEEN,R_STNAME_C,L_STNAME_C,RTNUMBER1,RTENAME1EN,ROADJURIS,PROVIDER,NBRLANES,SPEED,TRAFFICDIR" \
  "$TMP/nrn-roadseg.geojsonseq" \
  "$GPKG" "$LAYER"

echo "Classifying and packing..."
node "$ROOT/scripts/pack-nrn-road-backbone.js" "$TMP/nrn-roadseg.geojsonseq" "$OUT_DIR" "$NRN_URL"

echo "Done:"
ls -lh "$OUT_DIR"/nrn-road-backbone.*
