#!/bin/zsh
# Runs the routing speed matrix with dirt-routing-probe and writes one JSON
# receipt per case. Compare two runs with compare-receipts.py.
#
# usage: speed-matrix.sh PROBE OUTDIR [case ...]
#   PROBE   path to a built dirt-routing-probe
#   OUTDIR  directory for <case>.json receipts and <case>.time resource usage
#   case    names below; default runs every case in order
# env:    DIRT_PACKS  directory holding ns/ and nb/ packs
#                     (default: the evidence packs in the main checkout)
#         DIRT_SECONDS  per-case budget (default 60)
set -u
PROBE=$1; OUT=$2; shift 2
PACKS=${DIRT_PACKS:-/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/greenfield-routing-evidence/packs}
SECONDS_BUDGET=${DIRT_SECONDS:-60}
mkdir -p "$OUT"

PL="-63.34024797349485 44.764804567541226"   # Porters Lake, exact owner coordinates
typeset -A CASES
# name: "packs FROM_LON FROM_LAT TO_LON TO_LAT STYLE SEED ZOOM|- [FUEL_USABLE FUEL_FIRST]"
CASES[ns-short-dirt]="ns -63.340265 44.764830 -63.574 44.666 dirt 1 -"
CASES[ns-short-balanced]="ns -63.340265 44.764830 -63.574 44.666 balanced 1 -"
CASES[ns-short-clean]="ns -63.340265 44.764830 -63.574 44.666 cleanest 1 -"
CASES[ns-mid-dirt]="ns $PL -66.1175 43.8375 dirt 7 12.5"
CASES[ns-mid-balanced]="ns $PL -66.1175 43.8375 balanced 7 12.5"
CASES[ns-mid-clean]="ns $PL -66.1175 43.8375 cleanest 7 12.5"
CASES[owner-dirt]="ns,nb $PL -67.29131337653283 45.262939746458734 dirt 3806057305948982 12.5"
CASES[owner-balanced]="ns,nb $PL -67.29131337653283 45.262939746458734 balanced 3806057305948982 12.5"
CASES[owner-clean]="ns,nb $PL -67.29131337653283 45.262939746458734 cleanest 3806057305948982 12.5"
# Destinations and zooms from the 2026-09-15 phone logs (app session seeds are not logged).
CASES[phone-capebreton-dirt]="ns $PL -60.497036 46.884834 dirt 1 10.5"
CASES[phone-capebreton-clean]="ns $PL -60.497036 46.884834 cleanest 1 10.5"
CASES[phone-antigonish-dirt]="ns $PL -61.715371 45.598475 dirt 1 7.5"
CASES[phone-yarmouth-unknown-dirt]="ns $PL -66.134042 43.844148 dirt 1 8.7"
# Fuel: 200 km at 10% reserve (probe default), and the phone's 300 km at 10% in app windows.
CASES[owner-fuel-dirt]="ns,nb $PL -67.29131337653283 45.262939746458734 dirt 3806057305948982 12.5 180000 180000"
CASES[ns-mid-fuel-dirt]="ns $PL -66.1175 43.8375 dirt 7 12.5 180000 180000"
CASES[phone-fuel-newglasgow-dirt]="ns $PL -62.338316 45.583325 dirt 1 7.4 270000 270000"
CASES[phone-fuel-yarmouth-window-dirt]="ns $PL -66.13404 43.84414 dirt 1 9.7 270000 270000"

typeset -A ENVS
ENVS[phone-yarmouth-unknown-dirt]="DIRT_ALLOW_UNKNOWN=1"
ENVS[phone-fuel-yarmouth-window-dirt]="DIRT_FUEL_MAX_STOPS=4 DIRT_FUEL_ALLOW_PARTIAL=1"

ORDER=(ns-short-dirt ns-short-balanced ns-short-clean ns-mid-dirt ns-mid-balanced ns-mid-clean
       owner-dirt owner-balanced owner-clean phone-capebreton-dirt phone-antigonish-dirt
       phone-yarmouth-unknown-dirt owner-fuel-dirt ns-mid-fuel-dirt phone-fuel-newglasgow-dirt
       phone-fuel-yarmouth-window-dirt)
[[ $# -gt 0 ]] && ORDER=("$@")

for c in $ORDER; do
  if [[ -z ${CASES[$c]:-} ]]; then echo "unknown case: $c"; continue; fi
  a=(${=CASES[$c]})
  regions=$a[1]; style=$a[6]; seed=$a[7]; zoom=$a[8]
  args=($PACKS $regions $a[2] $a[3] $a[4] $a[5] $style $SECONDS_BUDGET $seed)
  if [[ $zoom != "-" ]] || (( $#a > 8 )); then args+=($zoom); fi
  (( $#a > 8 )) && args+=($a[9] $a[10])
  env ${=ENVS[$c]:-} DIRT_PROBE_COMPACT=1 /usr/bin/time -l "$PROBE" $args > "$OUT/$c.json" 2> "$OUT/$c.time"
  python3 - "$OUT/$c.json" "$OUT/$c.time" "$c" <<'PY'
import json, re, sys
try:
    j = json.load(open(sys.argv[1]))
except Exception as error:
    print(f"{sys.argv[3]:32s} CRASH or no output ({error})"); sys.exit(0)
t = open(sys.argv[2]).read()
fp = re.search(r"(\d+)\s+peak memory footprint", t)
mib = f"{int(fp.group(1))/1048576:.0f}" if fp else "?"
print(f"{sys.argv[3]:32s} {j.get('status'):16s} {j.get('seconds',0):6.2f}s prep={j.get('prepareSeconds',0):.2f}"
      f" km={j.get('distanceMeters',0)/1000:.1f} dirt={j.get('knownDirtPercent')} searches={j.get('searches')}"
      f" pops={j.get('totalPops')} usPerPop={j.get('microsecondsPerPop')} stops={len(j.get('fuelStops') or [])}"
      f" limit={j.get('limit')} peakMiB={mib}")
PY
done
