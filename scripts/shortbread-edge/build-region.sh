#!/usr/bin/env bash
set -euo pipefail

: "${VERSATILES_BIN:?Set VERSATILES_BIN to the pinned VersaTiles executable.}"

if [[ $# -ne 4 ]]; then
  echo "usage: build-region.sh <region-id> <release-id> <west,south,east,north> <source.versatiles>" >&2
  exit 64
fi

region_id="$1"
release_id="$2"
bounds="$3"
source_archive="$4"
script_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${script_dir}/artifacts/${release_id}"
output_file="${output_dir}/${region_id}.pmtiles"

mkdir -p "$output_dir"
if [[ -e "$output_file" ]]; then
  echo "refusing to overwrite ${output_file}" >&2
  exit 73
fi

"$VERSATILES_BIN" convert \
  --bbox="$bounds" \
  --bbox-border 1 \
  --min-zoom 0 \
  --max-zoom 14 \
  --compress gzip \
  "$source_archive" \
  "$output_file"

shasum -a 256 "$output_file"
