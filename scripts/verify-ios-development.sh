#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/Dirt.app" >&2
  exit 64
fi

app_bundle="$1"
info_plist="$app_bundle/Info.plist"
executable="$app_bundle/Dirt.debug.dylib"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev_scheme="$repo_root/Dirt.xcodeproj/xcshareddata/xcschemes/DIRT Dev.xcscheme"
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $1"
}

if [[ ! -d "$app_bundle" || ! -f "$info_plist" ]]; then
  echo "FAIL: not an iOS application bundle: $app_bundle" >&2
  exit 66
fi

if [[ ! -f "$executable" ]]; then
  executable="$app_bundle/Dirt"
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")
[[ "$bundle_id" == "com.mayday.dirt.dev" ]] \
  && pass "development bundle identifier" \
  || fail "unexpected development bundle identifier: $bundle_id"
[[ "$display_name" == "DIRT Dev" ]] \
  && pass "development display name" \
  || fail "unexpected development display name: $display_name"

binary_strings=$(strings "$executable")
if grep -q 'xoufaiypnrgukzmdwicz.supabase.co' <<<"$binary_strings"; then
  pass "development Supabase project is embedded"
else
  fail "development Supabase project is missing"
fi

if grep -q 'DIRT development' <<<"$binary_strings"; then
  pass "visible development marker is compiled"
else
  fail "development marker is missing"
fi

if grep -q 'iiiguqknqxoumlmppzfw.supabase.co' <<<"$binary_strings"; then
  fail "production Supabase project is present in the development executable"
else
  pass "production Supabase project absent from development executable"
fi

if grep -q 'pack-fabric.vercel.app' <<<"$binary_strings"; then
  pass "development routing service is embedded"
else
  fail "development routing service is missing"
fi

if grep -q 'dirt-mayday.vercel.app' <<<"$binary_strings"; then
  fail "production routing service is present in the development executable"
else
  pass "production routing service absent from development executable"
fi

# Xcode resolves the identifier from xcshareddata, one level above xcschemes.
storekit_relative_path='../../Dirt/Dirt.storekit'
expected_storekit_reference="identifier = \"$storekit_relative_path\""
storekit_reference_count=$(grep -F -c "$expected_storekit_reference" "$dev_scheme" || true)
if [[ "$storekit_reference_count" -eq 2 ]] \
  && [[ -f "$(dirname "$dev_scheme")/../$storekit_relative_path" ]]; then
  pass "DIRT Dev StoreKit catalogue reference resolves"
else
  fail "DIRT Dev StoreKit catalogue reference is missing or invalid"
fi

if [[ $failures -ne 0 ]]; then
  echo "Development verification failed with $failures issue(s)." >&2
  exit 1
fi

echo "Development verification passed."
