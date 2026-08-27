# DIRT — iOS TestFlight guide

Fully native SwiftUI app. **Develop only in** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`.

- Routing: on-device `graph.v2` packs (R2) when installed; live `/api/route` when online without that pack
- Accounts: Supabase (baked publishable config)
- Map style: bundled Shortbread JSON + local sprites

MapLibre Native + Supabase Swift via SPM.

## App identity (App Store Connect)

| Field | Value |
| --- | --- |
| App name | DIRT (Mayday) |
| Display name on home screen | DIRT |
| **Bundle ID** | `com.mayday.dirt` |
| **SKU** (ASC only) | `MAYDAY-DIRT-IOS-001` |
| Apple Team ID (`DEVELOPMENT_TEAM`) | `34XM6B4G7A` |
| Marketing version / build | `1.0` / `1` |
| Test target bundle ID | `com.mayday.dirt.tests` |
| UI test target bundle ID | `com.mayday.dirt.uitests` |

> The **SKU** lives only in App Store Connect — it is not a build setting and
> does not appear in the Xcode project. Enter `MAYDAY-DIRT-IOS-001` when
> creating/confirming the app record in ASC.

## Requirements

- Xcode 26.x, iOS 26.5 deployment target
- Swift Package dependencies resolve automatically:
  - `maplibre-gl-native-distribution` (MapLibre Native, 6.x)
  - `supabase-swift` (2.x)

## Open in Xcode

```bash
open /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/Dirt.xcodeproj
```

Select the **Dirt** scheme → your iPhone (or iPhone 17 Pro simulator) → ⌘R.

## Run on a device

1. Open `Dirt.xcodeproj` in Xcode.
2. Wait for SPM to resolve MapLibre + Supabase (File ▸ Packages ▸ Resolve if needed).
3. Select the **Dirt** scheme and your connected iPhone (signing is automatic
   with team `34XM6B4G7A`). Device must be on **iOS 26.5+** (deployment target).
4. Build & Run (⌘R). Grant Location "While Using" (and "Always" when you start
   navigation or group sharing).

## Command-line build / test

```bash
cd /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt

# Unit tests on Simulator
xcodebuild test -project Dirt.xcodeproj -scheme Dirt \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO

# Device build (generic)
xcodebuild -project Dirt.xcodeproj -scheme Dirt \
  -destination 'generic/platform=iOS' build
```

## Archive & export IPA

`ExportOptions.plist` is in the project root (method `app-store-connect`, team
`34XM6B4G7A`, automatic signing).

```bash
cd /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt

# 1. Archive (already succeeds locally → build/Dirt.xcarchive)
xcodebuild -project Dirt.xcodeproj -scheme Dirt \
  -destination 'generic/platform=iOS' \
  -archivePath build/Dirt.xcarchive archive

# 2. Export a signed IPA
xcodebuild -exportArchive \
  -archivePath build/Dirt.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

### Current machine status (2026-07-25)

| Step | Result |
| --- | --- |
| Simulator build | Succeeded |
| Device / `generic/platform=iOS` build | Succeeded |
| Archive → `build/Dirt.xcarchive` | Succeeded (Apple Development identity) |
| `xcodebuild -exportArchive` | **Failed**: `No profiles for 'com.mayday.dirt' were found` — needs an App Store Connect distribution profile for this bundle ID |
| ASC API upload | **Skipped** — no API key / app-specific password on this Mac |

**Fix for export:** In Xcode (signed into team `34XM6B4G7A`), open the Dirt target ▸ Signing & Capabilities, ensure “Automatically manage signing”, then use **Product ▸ Archive** and **Distribute App ▸ App Store Connect**. That creates the App Store distribution certificate + `com.mayday.dirt` profile if the ASC app record exists. After that, CLI `exportArchive` should succeed too.

## Upload to TestFlight

**No App Store Connect API key or app-specific password was found on this
machine** (checked `~/.appstoreconnect/private_keys`, Xcode APIKeys, and
keychain). Upload interactively, or drop a key in place and run:

```bash
# Option A — Xcode Organizer (recommended without API key)
# Window ▸ Organizer ▸ Dirt archive ▸ Distribute App ▸ App Store Connect

# Option B — ASC API key (AuthKey_<KEY_ID>.p8 in ~/.appstoreconnect/private_keys/)
xcrun altool --upload-app -f build/export/Dirt.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>

# Option C — Apple ID + app-specific password
xcrun altool --upload-app -f build/export/Dirt.ipa -t ios \
  -u <apple-id> -p <app-specific-password>
```

ASC prerequisites before the first upload succeeds:

1. App record exists with Bundle ID `com.mayday.dirt` and SKU `MAYDAY-DIRT-IOS-001`.
2. Agreements / banking / tax are accepted for team `34XM6B4G7A`.
3. A distribution certificate + App Store provisioning profile are available
   (automatic signing usually creates these when you archive from Xcode signed in).

## Permissions declared

- `NSLocationWhenInUseUsageDescription` — map position, From-here routing, nav.
- `NSLocationAlwaysAndWhenInUseUsageDescription` — background nav + live group sharing.
- `UIBackgroundModes = location` — keep navigating / sharing with the screen off.

## Beta feature coverage (TestFlight-ready)

| Area | Status |
| --- | --- |
| Map idle (Shortbread + NS overview + brand + dock + locate) | Shipped |
| From here / Plan stages / Saved routes | Shipped |
| Save + Export GPX + Start/End nav HUD | Shipped |
| Offline tile prefetch on Start (45s cap, skip) | Shipped |
| Email OTP auth + profile | Shipped |
| Groups create/join/share + route-to-member | Shipped (validated Realtime presence + polling fallback; stop-trigger route refresh) |
| Layers legend + persisted toggles | Shipped (overlay streams deferred) |
| Design tokens / CTA matrix | Shipped |

## Known v1 gaps

- Group alerts are persisted and delivered live in-app; push delivery and a historical-alert screen are deferred.
- Offline nav tiles use a bounding-box pyramid (z8–14), 45s cap.
- Incident reports are device-local.
- Voice cues, haptics, Live Activities, CarPlay, and Watch are out of scope for v1.
