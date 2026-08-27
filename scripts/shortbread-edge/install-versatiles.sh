#!/usr/bin/env bash
set -euo pipefail

version="4.9.1"
expected_sha="96e7613c8fb64ba1c2ab1b8aceefdb4929e21b6170765a945a15f9e3c6bc4188"
script_dir="$(cd "$(dirname "$0")" && pwd)"
tool_dir="${script_dir}/artifacts/tooling/versatiles-${version}"
archive="${script_dir}/artifacts/tooling/versatiles-${version}-macos-aarch64.tar.gz"
url="https://github.com/versatiles-org/versatiles-rs/releases/download/v${version}/versatiles-v${version}-macos-aarch64.tar.gz"

mkdir -p "$tool_dir"
if [[ ! -f "$archive" ]]; then
  curl --fail --location "$url" --output "$archive"
fi

actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "VersaTiles checksum mismatch: ${actual_sha}" >&2
  exit 65
fi

tar -xzf "$archive" -C "$tool_dir"
"${tool_dir}/versatiles" --version
echo "${tool_dir}/versatiles"
