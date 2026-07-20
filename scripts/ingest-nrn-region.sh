#!/usr/bin/env bash
# Download one province/territory NRN GeoPackage, export ROADSEG GeoJSONSeq,
# build a regional routing graph, then delete raw intermediates to save disk.
#
# Usage: scripts/ingest-nrn-region.sh <province-code>
# Example: scripts/ingest-nrn-region.sh pe
set -euo pipefail

CODE="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$CODE" ]]; then
  echo "Usage: $0 <province-code>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="$ROOT/data-raw/nrn/$CODE"
TMP="${TMPDIR:-/tmp}/dirt-nrn-$CODE-$$"
URL="https://geo.statcan.gc.ca/nrn_rrn/${CODE}/nrn_rrn_${CODE}_GPKG.zip"
OUT_REGION="$ROOT/routing/data/regions/$CODE"
SEQ="$RAW_DIR/nrn-roadseg.geojsonseq"

mkdir -p "$RAW_DIR" "$TMP"
cd "$TMP"

echo "[$CODE] Downloading $URL"
curl -L --fail --retry 3 --retry-delay 5 -o nrn.zip "$URL"
echo "[$CODE] Zip size: $(wc -c < nrn.zip) bytes"

echo "[$CODE] Unpacking…"
unzip -q nrn.zip
GPKG="$(find "$TMP" -name '*_GPKG_en.gpkg' -o -name '*_GPKG.gpkg' | head -1)"
if [[ -z "$GPKG" ]]; then
  GPKG="$(find "$TMP" -name '*.gpkg' | head -1)"
fi
if [[ -z "$GPKG" ]]; then
  echo "[$CODE] No GeoPackage found" >&2
  exit 1
fi

LAYER="$(ogrinfo -q -so "$GPKG" | awk '/ROADSEG/{print $2; exit}')"
if [[ -z "$LAYER" ]]; then
  echo "[$CODE] No ROADSEG layer in $GPKG" >&2
  ogrinfo -q -so "$GPKG" >&2 || true
  exit 1
fi
echo "[$CODE] Layer $LAYER from $(basename "$GPKG")"

echo "[$CODE] Exporting GeoJSONSeq…"
ogr2ogr \
  -f GeoJSONSeq \
  -t_srs EPSG:4326 \
  -select "NID,ROADSEGID,ROADCLASS,PAVSTATUS,PAVSURF,UNPAVSURF,STRUCTTYPE,TRAFFICDIR,STRUNAMEEN,R_STNAME_C,L_STNAME_C,RTNUMBER1,RTENAME1EN,ROADJURIS,PROVIDER,NBRLANES,SPEED" \
  "$SEQ" \
  "$GPKG" "$LAYER"

# Free zip + gpkg before Node build.
rm -rf "$TMP"
echo "[$CODE] GeoJSONSeq: $(wc -c < "$SEQ") bytes"

echo "[$CODE] Building regional graph…"
node "$ROOT/scripts/build-regional-nrn-graph.js" "$CODE" "$SEQ" "$URL" "$LAYER"

# Drop bulky intermediate after successful pack (keep a tiny marker).
rm -f "$SEQ"
echo "ok $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RAW_DIR/INGESTED.txt"
echo "[$CODE] Done → $OUT_REGION"
ls -lh "$OUT_REGION"/graph.v1.* 2>/dev/null || true
