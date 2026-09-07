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
const { geofabrikSource } = require(process.env.FABRIC + '/routing/registry/geofabrik');
const { clipGeojsonPath } = require(process.env.FABRIC + '/scripts/fetch-admin-polygon');
const s = geofabrikSource(process.argv[1]);
const poly = clipGeojsonPath(s.id);
if (!poly) {
  console.error('missing admin polygon for ' + s.id);
  process.exit(1);
}
console.log('SLUG=' + JSON.stringify(s.slug));
console.log('COUNTRY=' + JSON.stringify(s.country));
console.log('POLY=' + JSON.stringify(poly));
" "$ID")"

CACHE_ROOT="${OSM_PBF_CACHE:-${TMPDIR:-/tmp}/dirt-osm-poi-build/regions}"
OUT_DIR="${OSM_LEGAL_ROOT:-$FABRIC/data-raw/osm-legal}/$SLUG"
mkdir -p "$OUT_DIR" "$CACHE_ROOT/$SLUG"
PBF="$CACHE_ROOT/$SLUG/source.osm.pbf"
CLIPPED="$CACHE_ROOT/$SLUG/admin-halo.osm.pbf"
BASE_URL="https://download.geofabrik.de/north-america/$COUNTRY"

bash "$SCRIPT_DIR/ensure-current-osm-pbf.sh" "$BASE_URL" "$SLUG" "$PBF"

python3 - <<'PY' "$POLY" "$OUT_DIR/halo.geojson"
import json, sys, math
src, dest = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)
# ~2 km halo in degrees
halo = 2000.0 / 111000.0
def ring_pad(ring):
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    return [[min(lons)-halo, min(lats)-halo], [max(lons)+halo, min(lats)-halo],
            [max(lons)+halo, max(lats)+halo], [min(lons)-halo, max(lats)+halo],
            [min(lons)-halo, min(lats)-halo]]
geom = data.get("geometry") or (data.get("features") or [{}])[0].get("geometry")
coords = geom["coordinates"]
if geom["type"] == "Polygon":
    padded = {"type":"Polygon","coordinates":[ring_pad(coords[0])]}
else:
    padded = {"type":"Polygon","coordinates":[ring_pad(coords[0][0])]}
with open(dest, "w") as f:
    json.dump({"type":"Feature","properties":{"haloMeters":2000},"geometry":padded}, f)
print("halo", dest)
PY

echo "Clipping $SLUG with ${2:-2000}m halo…"
osmium extract --polygon "$OUT_DIR/halo.geojson" --strategy smart --overwrite -o "$CLIPPED" "$PBF"

HIGHWAY_FILTER="motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path"

osmium tags-filter "$CLIPPED" \
  w/highway="$HIGHWAY_FILTER" \
  w/route=ferry \
  r/type=restriction \
  n/barrier \
  -o "$OUT_DIR/filtered.osm.pbf" --overwrite

osmium getid "$CLIPPED" --add-referenced --overwrite \
  --id-osm-file "$OUT_DIR/filtered.osm.pbf" \
  -o "$OUT_DIR/legal-topology.osm.pbf"
osmium cat "$OUT_DIR/legal-topology.osm.pbf" -f opl -o "$OUT_DIR/legal-topology.opl" --overwrite

python3 - <<PY
import hashlib, json, os, subprocess, pathlib
pbf = pathlib.Path("$PBF")
legal = pathlib.Path("$OUT_DIR/legal-topology.osm.pbf")
src = pbf.read_bytes()
h = hashlib.sha256(src).hexdigest()
ts = subprocess.check_output(["osmium","fileinfo","-g","header.option.osmosis_replication_timestamp","$PBF"], text=True).strip()
poly = pathlib.Path("$POLY").read_bytes()
record = {
  "sourceUrl": "https://download.geofabrik.de/north-america/$COUNTRY/$SLUG-latest.osm.pbf",
  "sourceBytes": pbf.stat().st_size,
  "sourceSha256": h,
  "osmTimestamp": ts,
  "clipPolygonId": "$ID",
  "clipPolygonSha256": hashlib.sha256(poly).hexdigest(),
  "haloMeters": 2000,
  "toolVersions": {"osmium": subprocess.check_output(["osmium","--version"], text=True).splitlines()[0]},
  "legalPbfBytes": legal.stat().st_size,
  "legalPbfSha256": hashlib.sha256(legal.read_bytes()).hexdigest()
}
pathlib.Path("$OUT_DIR/provenance.v1.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
PY
ls -lh "$OUT_DIR"
