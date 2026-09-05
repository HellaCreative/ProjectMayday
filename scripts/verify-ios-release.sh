#!/bin/bash
set -euo pipefail

require_signing=0
if [[ "${1:-}" == "--require-signing" ]]; then
  require_signing=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [--require-signing] /absolute/path/to/Dirt.app" >&2
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

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

assert_plist_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual=$(plist_value "$file" "$key")
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected $expected, found ${actual:-missing})"
  fi
}

if [[ ! -d "$app_bundle" || ! -f "$info_plist" ]]; then
  echo "FAIL: not an iOS application bundle: $app_bundle" >&2
  exit 66
fi

assert_plist_value "$info_plist" CFBundleIdentifier com.mayday.dirt \
  "production bundle identifier"
assert_plist_value "$info_plist" CFBundleDisplayName DIRT \
  "production display name"
assert_plist_value "$info_plist" MinimumOSVersion 26.0 \
  "minimum supported iOS version is 26.0"
assert_plist_value "$info_plist" LSApplicationCategoryType public.app-category.navigation \
  "navigation App Store category"
assert_plist_value "$info_plist" ITSAppUsesNonExemptEncryption false \
  "export metadata declares no non-exempt encryption"

if [[ -f "$privacy_manifest" ]] && plutil -lint "$privacy_manifest" >/dev/null; then
  pass "valid app privacy manifest is bundled"
else
  fail "PrivacyInfo.xcprivacy is missing or invalid"
fi

if [[ -f "$privacy_manifest" ]]; then
  assert_plist_value "$privacy_manifest" NSPrivacyTracking false \
    "app privacy manifest declares no tracking"

  tracking_domains=$(plutil -extract NSPrivacyTrackingDomains json -o - "$privacy_manifest" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ "$tracking_domains" == "[]" ]]; then
    pass "app privacy manifest has no tracking domains"
  else
    fail "app privacy manifest contains tracking domains or omits the tracking-domain array"
  fi

  accessed_apis=$(plutil -extract NSPrivacyAccessedAPITypes json -o - "$privacy_manifest" 2>/dev/null || true)
  for token in \
    NSPrivacyAccessedAPICategoryUserDefaults CA92.1 \
    NSPrivacyAccessedAPICategoryFileTimestamp C617.1; do
    if grep -q "$token" <<<"$accessed_apis"; then
      pass "app privacy manifest includes $token"
    else
      fail "app privacy manifest is missing $token"
    fi
  done

  collected_data=$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$privacy_manifest" 2>/dev/null || true)
  for data_type in \
    NSPrivacyCollectedDataTypeName \
    NSPrivacyCollectedDataTypeEmailAddress \
    NSPrivacyCollectedDataTypeUserID \
    NSPrivacyCollectedDataTypePreciseLocation \
    NSPrivacyCollectedDataTypeCoarseLocation \
    NSPrivacyCollectedDataTypeOtherUserContent; do
    if grep -q "$data_type" <<<"$collected_data"; then
      pass "app privacy manifest includes $data_type"
    else
      fail "app privacy manifest is missing $data_type"
    fi
  done
fi

for forbidden_pattern in '*.mbtiles' '*.storekit' '*.md'; do
  if find "$app_bundle" -name "$forbidden_pattern" -print -quit | grep -q .; then
    fail "$forbidden_pattern files must not ship in the public Release bundle"
  else
    pass "$forbidden_pattern files excluded from Release"
  fi
done

for required_resource in \
  ThirdPartyNotices.txt \
  RegionPolygons.json \
  UrbanSettlements.json \
  shortbread-style.json \
  svwd03sprite.json \
  svwd03sprite.png \
  svwd03sprite@2x.json \
  svwd03sprite@2x.png; do
  if [[ -s "$app_bundle/$required_resource" ]]; then
    pass "$required_resource is bundled"
  else
    fail "$required_resource is missing or empty"
  fi
done

unexpected_root_entries=0
while IFS= read -r entry; do
  name=$(basename "$entry")
  case "$name" in
    Dirt|Info.plist|PkgInfo|PrivacyInfo.xcprivacy|ThirdPartyNotices.txt|Assets.car|AppIcon*.png|Frameworks|swift-crypto_Crypto.bundle|_CodeSignature|embedded.mobileprovision|SC_Info|RegionPolygons.json|UrbanSettlements.json|shortbread-style.json|svwd03sprite.json|svwd03sprite.png|svwd03sprite@2x.json|svwd03sprite@2x.png)
      ;;
    *)
      fail "unexpected top-level Release resource: $name"
      unexpected_root_entries=$((unexpected_root_entries + 1))
      ;;
  esac
done < <(find "$app_bundle" -mindepth 1 -maxdepth 1 -print | sort)
if [[ $unexpected_root_entries -eq 0 ]]; then
  pass "top-level Release resources match the reviewed allowlist"
fi

maplibre="$app_bundle/Frameworks/MapLibre.framework"
if [[ -d "$app_bundle/Frameworks" ]]; then
  framework_count=$(find "$app_bundle/Frameworks" -mindepth 1 -maxdepth 1 -type d -name '*.framework' | wc -l | tr -d '[:space:]')
else
  framework_count=0
fi
if [[ "$framework_count" == "1" && -d "$maplibre" ]]; then
  pass "MapLibre is the only embedded executable framework"
else
  fail "embedded framework set changed (expected only MapLibre.framework)"
fi

if [[ -f "$maplibre/PrivacyInfo.xcprivacy" ]] && plutil -lint "$maplibre/PrivacyInfo.xcprivacy" >/dev/null; then
  pass "MapLibre privacy manifest is bundled and valid"
else
  fail "MapLibre privacy manifest is missing or invalid"
fi

assert_plist_value "$maplibre/Info.plist" CFBundleShortVersionString 6.28.0 \
  "reviewed MapLibre version is embedded"

maplibre_platform=$(plist_value "$maplibre/Info.plist" CFBundleSupportedPlatforms:0)
if [[ "$maplibre_platform" == "iPhoneOS" ]]; then
  pass "MapLibre device framework declares the iPhoneOS platform"
else
  fail "MapLibre device framework declares ${maplibre_platform:-missing} instead of iPhoneOS"
fi

maplibre_archs=$(lipo -archs "$maplibre/MapLibre" 2>/dev/null || true)
if [[ "$maplibre_archs" == "arm64" ]]; then
  pass "MapLibre device framework contains only arm64"
else
  fail "unexpected MapLibre device architectures: ${maplibre_archs:-unreadable}"
fi

if xcrun vtool -show-build "$maplibre/MapLibre" 2>/dev/null | grep -Eq '^[[:space:]]*platform IOS$'; then
  pass "MapLibre Mach-O load command targets physical iOS"
else
  fail "MapLibre Mach-O load command does not target physical iOS"
fi

crypto_manifest="$app_bundle/swift-crypto_Crypto.bundle/PrivacyInfo.xcprivacy"
if [[ -f "$crypto_manifest" ]] && plutil -lint "$crypto_manifest" >/dev/null; then
  pass "Swift Crypto privacy manifest is bundled and valid"
else
  fail "Swift Crypto privacy manifest is missing or invalid"
fi

while IFS= read -r bundled_manifest; do
  if plutil -lint "$bundled_manifest" >/dev/null; then
    :
  else
    fail "invalid bundled privacy manifest: $bundled_manifest"
  fi
done < <(find "$app_bundle" -name PrivacyInfo.xcprivacy -type f | sort)

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

size_bytes=$(find "$app_bundle" -type f -exec stat -f '%z' {} \; | awk '{total += $1} END {print total + 0}')
size_mb=$((size_bytes / 1024 / 1024))
echo "INFO: uncompressed application files total ${size_bytes} bytes (${size_mb} MiB)"
if [[ $size_bytes -le $((60 * 1024 * 1024)) ]]; then
  pass "uncompressed Release bundle remains within the reviewed 60 MB ceiling"
else
  fail "uncompressed Release bundle exceeds the reviewed 60 MB ceiling"
fi

if codesign -d "$app_bundle" >/dev/null 2>&1; then
  signature_details=$(codesign -dvv "$app_bundle" 2>&1 || true)
  if codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1; then
    pass "application and nested executable signatures verify"
  else
    fail "application or nested executable signature verification failed"
  fi

  if [[ $require_signing -eq 1 ]]; then
    if grep -q '^Authority=Apple Distribution:' <<<"$signature_details"; then
      pass "application uses an Apple Distribution certificate"
    else
      fail "application is signed, but not with an Apple Distribution certificate"
    fi

    signed_entitlements=$(codesign -d --entitlements :- "$app_bundle" 2>/dev/null || true)
    if grep -q 'com.apple.developer.applesignin' <<<"$signed_entitlements" && \
       grep -q 'com.mayday.dirt' <<<"$signed_entitlements"; then
      pass "signed entitlements include Sign in with Apple and the production app identity"
    else
      fail "signed entitlements do not prove Sign in with Apple and the production app identity"
    fi

    get_task_allow=$(plutil -extract get-task-allow raw -o - - 2>/dev/null <<<"$signed_entitlements" || true)
    if [[ "$get_task_allow" == "true" ]]; then
      fail "distribution application enables debugger attachment"
    else
      pass "distribution application does not enable debugger attachment"
    fi
  fi
elif [[ $require_signing -eq 1 ]]; then
  fail "distribution signing was required, but the application is unsigned"
else
  echo "INFO: signing check skipped for unsigned engineering build; rerun with --require-signing against the archived app"
fi

if [[ $failures -ne 0 ]]; then
  echo "Release verification failed with $failures issue(s)." >&2
  exit 1
fi

echo "Release verification passed."
