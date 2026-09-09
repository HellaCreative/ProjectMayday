#!/bin/bash
set -euo pipefail
archive="${1:-${ARCHIVE_PATH:-}}"
: "${archive:?Archive path required}"
app="$archive/Products/Applications/Dirt.app"
framework="$app/Frameworks/MapLibre.framework"
repo=$(cd "$(dirname "$0")/.." && pwd)
symbols="$repo/.build/release-assets/maplibre-6.28.0/MapLibre_ios_device.framework.dSYM"
if [[ ! -d "$symbols" ]]; then
  cache="$repo/.build/release-assets/maplibre-6.28.0"
  mkdir -p "$cache"
  curl --fail --location --retry 2 'https://github.com/maplibre/maplibre-native/releases/download/ios-v6.28.0/MapLibre_ios_device.framework.dSYM.zip' -o "$cache/symbols.zip"
  echo "8061c6639884c0023a2f2f1fdc9685bea7ed3a5f51b8abfa0cb4a44fdf4864b8  $cache/symbols.zip" | shasum -a 256 --check
  unzip -q -o "$cache/symbols.zip" -d "$cache"
fi
[[ -d "$app" && -d "$framework" && -d "$symbols" ]] || { echo 'Missing archive or MapLibre symbols' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$framework/Info.plist")
[[ "$version" == '6.28.0' ]] || { echo 'Unreviewed MapLibre version' >&2; exit 1; }
xcrun vtool -show-build "$framework/MapLibre" | grep -Eq '^[[:space:]]*platform IOS$'
[[ "$(lipo -archs "$framework/MapLibre")" == arm64 ]]
binary_uuid=$(dwarfdump --uuid "$framework/MapLibre" | awk '{print $2}')
symbol_uuid=$(dwarfdump --uuid "$symbols" | awk '{print $2}')
[[ "$binary_uuid" == "$symbol_uuid" ]] || { echo 'MapLibre symbol UUID mismatch' >&2; exit 1; }
platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$framework/Info.plist")
if [[ "$platform" == iPhoneSimulator ]]; then
  signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$signing_identity" ]]; then
    cert_dir=$(mktemp -d)
    trap 'rm -rf "$cert_dir"' EXIT
    codesign -d --extract-certificates="$cert_dir/cert" "$app"
    signing_identity=$(shasum -a 1 "$cert_dir/cert0" | awk '{print $1}')
  fi
  /usr/libexec/PlistBuddy -c 'Set :CFBundleSupportedPlatforms:0 iPhoneOS' "$framework/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :DTPlatformName iphoneos' "$framework/Info.plist"
  sdk=$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$framework/Info.plist")
  /usr/libexec/PlistBuddy -c "Set :DTSDKName ${sdk/iphonesimulator/iphoneos}" "$framework/Info.plist"
  codesign --force --sign "$signing_identity" --preserve-metadata=identifier,entitlements,flags,runtime "$framework"
  codesign --force --sign "$signing_identity" --preserve-metadata=identifier,entitlements,flags,runtime "$app"
elif [[ "$platform" != iPhoneOS ]]; then
  echo "Unexpected MapLibre platform: $platform" >&2; exit 1
fi
mkdir -p "$archive/dSYMs"
ditto "$symbols" "$archive/dSYMs/MapLibre.framework.dSYM"
codesign --verify --deep --strict "$app"
echo 'Archive metadata and MapLibre symbols verified.'
