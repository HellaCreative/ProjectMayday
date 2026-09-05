#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/Dirt.app" >&2
  exit 64
fi

app_bundle="$1"
info_plist="$app_bundle/Info.plist"
privacy_manifest="$app_bundle/PrivacyInfo.xcprivacy"
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

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
if [[ "$bundle_id" == "com.mayday.dirt" ]]; then
  pass "production bundle identifier"
else
  fail "unexpected bundle identifier: $bundle_id"
fi

display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")
if [[ "$display_name" == "DIRT" ]]; then
  pass "production display name"
else
  fail "unexpected production display name: $display_name"
fi

minimum_ios=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$info_plist")
if [[ "$minimum_ios" == "26.0" ]]; then
  pass "minimum supported iOS version is 26.0"
else
  fail "unexpected minimum supported iOS version: $minimum_ios"
fi

if [[ -f "$privacy_manifest" ]] && plutil -lint "$privacy_manifest" >/dev/null; then
  pass "valid app privacy manifest is bundled"
else
  fail "PrivacyInfo.xcprivacy is missing or invalid"
fi

for forbidden in BC.mbtiles Dirt.storekit; do
  if find "$app_bundle" -name "$forbidden" -print -quit | grep -q .; then
    fail "$forbidden must not ship in the public Release bundle"
  else
    pass "$forbidden excluded from Release"
  fi
done

tester_symbols=$(
  strings "$app_bundle/Dirt" \
    | grep -E 'Skip as tester|Continue as tester|Tester tools|Reset free Starts' \
    || true
)
if [[ -n "$tester_symbols" ]]; then
  fail "tester subscription bypass copy is present in the Release executable"
else
  pass "tester subscription bypass copy absent from Release executable"
fi

binary_strings=$(strings "$app_bundle/Dirt")
if grep -q 'iiiguqknqxoumlmppzfw.supabase.co' <<<"$binary_strings"; then
  pass "production Supabase project is embedded"
else
  fail "production Supabase project is missing"
fi

if grep -Eq 'xoufaiypnrgukzmdwicz.supabase.co|DIRT development' <<<"$binary_strings"; then
  fail "development identity is present in the Release executable"
else
  pass "development identity absent from Release executable"
fi

if grep -q 'dirt-mayday.vercel.app' <<<"$binary_strings"; then
  pass "production routing service is embedded"
else
  fail "production routing service is missing"
fi

if grep -q 'pack-fabric.vercel.app' <<<"$binary_strings"; then
  fail "development routing service is present in the Release executable"
else
  pass "development routing service absent from Release executable"
fi

size_bytes=$(du -sk "$app_bundle" | awk '{print $1 * 1024}')
size_mb=$((size_bytes / 1024 / 1024))
echo "INFO: uncompressed application bundle is ${size_mb} MB"

if [[ $failures -ne 0 ]]; then
  echo "Release verification failed with $failures issue(s)." >&2
  exit 1
fi

echo "Release verification passed."
