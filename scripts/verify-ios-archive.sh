#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/Dirt.xcarchive" >&2
  exit 64
fi

archive="$1"
archive_info="$archive/Info.plist"
app="$archive/Products/Applications/Dirt.app"
script_dir=$(cd "$(dirname "$0")" && pwd)
export_options="$script_dir/../ExportOptions.plist"
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $1"
}

if [[ ! -d "$archive" || ! -f "$archive_info" || ! -d "$app" ]]; then
  echo "FAIL: not a DIRT application archive: $archive" >&2
  exit 66
fi

set +e
"$script_dir/verify-ios-release.sh" --require-signing "$app"
release_verifier_exit=$?
set -e
if [[ $release_verifier_exit -ne 0 ]]; then
  fail "Release bundle verification failed"
fi

archive_app_path=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_info" 2>/dev/null || true)
if [[ "$archive_app_path" == "Applications/Dirt.app" ]]; then
  pass "archive application path identifies Dirt.app"
else
  fail "unexpected archive application path: ${archive_app_path:-missing}"
fi

if [[ -d "$archive/dSYMs" ]]; then
  pass "archive contains a dSYM directory"
else
  fail "archive has no dSYM directory"
fi

if [[ -f "$export_options" ]] && plutil -lint "$export_options" >/dev/null; then
  pass "App Store export options are valid"
else
  fail "App Store export options are missing or invalid"
fi

export_method=$(/usr/libexec/PlistBuddy -c 'Print :method' "$export_options" 2>/dev/null || true)
export_team=$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$export_options" 2>/dev/null || true)
export_signing=$(/usr/libexec/PlistBuddy -c 'Print :signingStyle' "$export_options" 2>/dev/null || true)
export_symbols=$(/usr/libexec/PlistBuddy -c 'Print :uploadSymbols' "$export_options" 2>/dev/null || true)
manage_versions=$(/usr/libexec/PlistBuddy -c 'Print :manageAppVersionAndBuildNumber' "$export_options" 2>/dev/null || true)
if [[ "$export_method" == "app-store-connect" && \
      "$export_team" == "34XM6B4G7A" && \
      "$export_signing" == "automatic" && \
      "$export_symbols" == "true" && \
      "$manage_versions" == "false" ]]; then
  pass "export options target App Store Connect with the reviewed team, signing, symbols, and version policy"
else
  fail "App Store export options differ from the reviewed release policy"
fi

check_dsym() {
  local executable="$1"
  local label="$2"
  local executable_uuids
  local dsym_uuids

  executable_uuids=$(dwarfdump --uuid "$executable" 2>/dev/null | awk '{print $2}' | sort -u)
  if [[ -z "$executable_uuids" ]]; then
    fail "$label has no readable Mach-O UUID"
    return
  fi

  if [[ -d "$archive/dSYMs" ]]; then
    dsym_uuids=$(
      find "$archive/dSYMs" -type d -name '*.dSYM' -print0 \
        | while IFS= read -r -d '' dsym; do dwarfdump --uuid "$dsym" 2>/dev/null || true; done \
        | awk '{print $2}' \
        | sort -u
    )
  else
    dsym_uuids=""
  fi

  while IFS= read -r uuid; do
    if grep -qx "$uuid" <<<"$dsym_uuids"; then
      pass "$label dSYM covers UUID $uuid"
    else
      fail "$label dSYM is missing UUID $uuid"
    fi
  done <<<"$executable_uuids"
}

check_dsym "$app/Dirt" "DIRT executable"

while IFS= read -r framework; do
  framework_name=$(basename "$framework" .framework)
  framework_executable="$framework/$framework_name"
  if [[ -f "$framework_executable" ]]; then
    check_dsym "$framework_executable" "$framework_name framework"
  else
    fail "$framework_name framework executable is missing"
  fi
done < <(find "$app/Frameworks" -mindepth 1 -maxdepth 1 -type d -name '*.framework' 2>/dev/null | sort)

if [[ $failures -ne 0 ]]; then
  echo "Archive verification failed with $failures issue(s)." >&2
  exit 1
fi

echo "Archive verification passed. Complete Xcode App Store validation and inspect the generated privacy report before upload."
