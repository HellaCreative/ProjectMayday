#!/usr/bin/env bash
# Lossless OSM extract for graph.v4. GeoJSON is not the legal source.
#
#   bash scripts/pack-fabric/scripts/extract-region-osm.sh ns
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FABRIC="$(cd "$SCRIPT_DIR/.." && pwd)"
export FABRIC
ID="${1:-}"
if [ -z "$ID" ]; then
  echo "Usage: extract-region-osm.sh <region-id>" >&2
  exit 1
fi

eval "$(node -e "
const { geofabrikSource, geofabrikDownloadSlug } = require(process.env.FABRIC + '/routing/registry/geofabrik');
const { clipGeojsonPath } = require(process.env.FABRIC + '/scripts/fetch-admin-polygon');
const { bufferProjection } = require(process.env.FABRIC + '/routing/registry/timezones');
const s = geofabrikSource(process.argv[1]);
const poly = clipGeojsonPath(s.id);
if (!poly) {
  console.error('missing admin polygon for ' + s.id);
  process.exit(1);
}
const downloadSlug = geofabrikDownloadSlug(s.id);
console.log('SLUG=' + JSON.stringify(s.slug));
console.log('DOWNLOAD_SLUG=' + JSON.stringify(downloadSlug));
console.log('COUNTRY=' + JSON.stringify(s.country));
console.log('POLY=' + JSON.stringify(poly));
console.log('BUFFER_EPSG=' + JSON.stringify(bufferProjection(s.id, s.country)));
" "$ID")"

CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="${OSM_LEGAL_ROOT:-$FABRIC/data-raw/osm-legal}/$SLUG"
mkdir -p "$OUT_DIR" "$CACHE_ROOT/$DOWNLOAD_SLUG"
PBF="$CACHE_ROOT/$DOWNLOAD_SLUG/source.osm.pbf"
CLIPPED="$OUT_DIR/admin-halo.osm.pbf"
BASE_URL="https://download.geofabrik.de/north-america/$COUNTRY"

if [ -n "${DIRT_V4_SOURCE_LOCK:-}" ]; then
  read -r LOCK_PATH LOCK_BYTES LOCK_SHA LOCK_TIMESTAMP <<EOF
$(node -e '
const fs=require("fs"); const path=require("path");
const lock=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(lock.schema!=="dirt-osm-source-lock.v1"||!lock.fabricEpoch) throw new Error("invalid V4 source lock");
const row=lock.regions&&lock.regions[process.argv[2]];
if(!row) throw new Error("source lock missing "+process.argv[2]);
process.stdout.write([path.resolve(row.cachedPath),row.sourceBytes,row.sourceSha256,row.osmTimestamp].join(" "));
' "$DIRT_V4_SOURCE_LOCK" "$ID")
EOF
  PBF="$LOCK_PATH"
  [ -f "$PBF" ] || { echo "Locked source is missing: $PBF" >&2; exit 1; }
  [ "$(stat -f '%z' "$PBF")" = "$LOCK_BYTES" ] || { echo "Locked source byte mismatch for $ID" >&2; exit 1; }
  [ "$(shasum -a 256 "$PBF" | awk '{print $1}')" = "$LOCK_SHA" ] || { echo "Locked source hash mismatch for $ID" >&2; exit 1; }
  [ "$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF")" = "$LOCK_TIMESTAMP" ] || {
    echo "Locked source timestamp mismatch for $ID" >&2; exit 1;
  }
  echo "Using source-locked PBF $PBF"
else
  bash "$SCRIPT_DIR/ensure-current-osm-pbf.sh" "$BASE_URL" "$DOWNLOAD_SLUG" "$PBF"
fi

POLY_LAYER="$(basename "$POLY" .geojson)"
# GeoJSON's GDAL driver cannot delete an existing layer in place. This is a
# generated work file, so replace it explicitly to keep interrupted runs safe.
rm -f "$OUT_DIR/halo.geojson"
ogr2ogr -f GeoJSON "$OUT_DIR/halo.geojson" "$POLY" \
  -dialect sqlite \
  -sql "SELECT ST_Transform(ST_Buffer(ST_Transform(geometry, $BUFFER_EPSG), 2000), 4326) AS geometry FROM '$POLY_LAYER'" \
  -nln halo
ogrinfo -ro -so "$OUT_DIR/halo.geojson" halo >/dev/null

echo "Clipping $SLUG with ${2:-2000}m halo…"
osmium extract --polygon "$OUT_DIR/halo.geojson" --strategy smart \
  -S types=multipolygon,restriction --overwrite -o "$CLIPPED" "$PBF"

HIGHWAY_FILTER="motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path"

osmium tags-filter "$CLIPPED" \
  w/highway="$HIGHWAY_FILTER" \
  w/route=ferry \
  r/type=restriction \
  n/barrier \
  -o "$OUT_DIR/filtered.osm.pbf" --overwrite

set +e
osmium getid "$CLIPPED" --add-referenced --overwrite \
  --id-osm-file "$OUT_DIR/filtered.osm.pbf" \
  -o "$OUT_DIR/legal-topology.osm.pbf"
GETID_STATUS=$?
set -e
if [ "$GETID_STATUS" -gt 1 ] || [ ! -s "$OUT_DIR/legal-topology.osm.pbf" ]; then
  echo "Failed to assemble legal topology for $ID" >&2
  exit 1
fi
osmium fileinfo -e "$OUT_DIR/legal-topology.osm.pbf" >/dev/null
if [ "$GETID_STATUS" -eq 1 ]; then
  echo "Source has unresolved OSM references; retaining the valid subset so the graph builder can reject them fail-closed."
fi
osmium cat "$OUT_DIR/legal-topology.osm.pbf" -f opl -o "$OUT_DIR/legal-topology.opl" --overwrite

python3 - <<PY
import hashlib, json, os, subprocess, pathlib
pbf = pathlib.Path("$PBF")
legal = pathlib.Path("$OUT_DIR/legal-topology.osm.pbf")
def sha256_file(path):
  digest = hashlib.sha256()
  with path.open("rb") as handle:
    for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
      digest.update(block)
  return digest.hexdigest()
h = sha256_file(pbf)
ts = subprocess.check_output(["osmium","fileinfo","-g","header.option.osmosis_replication_timestamp","$PBF"], text=True).strip()
poly_path = pathlib.Path("$POLY")
record = {
  "sourceUrl": "https://download.geofabrik.de/north-america/$COUNTRY/$DOWNLOAD_SLUG-latest.osm.pbf",
  "sourceBytes": pbf.stat().st_size,
  "sourceSha256": h,
  "osmTimestamp": ts,
  "clipPolygonId": "$ID",
  "clipPolygonSha256": sha256_file(poly_path),
  "haloMeters": 2000,
  "toolVersions": {"osmium": subprocess.check_output(["osmium","--version"], text=True).splitlines()[0]},
  "legalPbfBytes": legal.stat().st_size,
  "legalPbfSha256": sha256_file(legal)
}
lock_path = os.environ.get("DIRT_V4_SOURCE_LOCK")
if lock_path:
  lock = json.loads(pathlib.Path(lock_path).read_text())
  expected = (lock.get("regions") or {}).get("$ID")
  if not expected:
    raise SystemExit("source lock missing region $ID")
  if expected.get("sourceSha256") != h or expected.get("osmTimestamp") != ts or expected.get("sourceBytes") != pbf.stat().st_size:
    raise SystemExit("source identity does not match lock for $ID")
  record["sourceUrl"] = expected["sourceUrl"]
  if lock.get("commonSource"):
    record["commonSource"] = lock["commonSource"]
    record["sourceExtraction"] = expected.get("extraction")
pathlib.Path("$OUT_DIR/provenance.v1.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
PY
ls -lh "$OUT_DIR"
