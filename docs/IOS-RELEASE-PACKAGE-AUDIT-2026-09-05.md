# DIRT iOS Release-package audit — 2026-09-05

**Scope:** public iOS package, SDK/privacy inventory, export metadata, and local
signing readiness. This audit did not change routing, packs, Rider Services,
backend state, production services, or physical devices.

**Audited baseline:** commit `3b3fada`, Xcode 26.6, iOS 26.5 SDK, `DIRT
Production` Release configuration, generic physical-iOS destination, signing
disabled.

## Outcome

The app's own public-package configuration is internally consistent, but the
package is **not yet cleared for App Store upload**. The two remaining technical
package blockers are distribution signing and malformed metadata in the current
MapLibre binary artifact. A signed archive and Xcode/App Store validation remain
required; an unsigned build cannot close either gate.

The audit also found an internal routing implementation `README.md` copied into
the public app by Xcode's synchronized folder. Release now excludes Markdown
files, and the verifier rejects any future documentation or unexpected top-level
resource in the app bundle.

## Actual unsigned Release bundle

| Item | Evidence |
| --- | --- |
| App identity | `com.mayday.dirt`, display name `DIRT` |
| Version | `2 (14)` |
| Minimum OS | iOS 26.0 in the built `Info.plist` and app Mach-O |
| Device family | iPhone and iPad (`1,2`); the retained-device decision is still an owner gate |
| Build result | clean generic physical-iOS Release build succeeded |
| Xcode validation | unsigned shallow Store validation succeeded |
| Uncompressed app files | 32,694,352 apparent bytes (31 MiB as reported by the verifier) |
| Main executable | 21,272,064 bytes |
| MapLibre executable | 7,774,480 bytes |
| Largest app resources | standard and Retina sprite PNGs, 1,102,873 bytes each; MapLibre resolves both variants from the runtime sprite base URL |
| Development-only content | no `.mbtiles`, `.storekit`, development backend identity, or tester-bypass copy |

The reviewed top-level resource set is the app executable and metadata, asset
catalog/icons, privacy manifest, MapLibre framework, Swift Crypto resource
bundle, region/settlement JSON, Shortbread style, and standard/Retina sprite
JSON/PNG pairs. Release has a 60 MiB uncompressed ceiling so an accidental large
resource becomes a deterministic failure rather than a subjective review item.
Final thinned install/download size still has to be read from the signed archive
or App Store Connect.

## Third-party dependency and privacy inventory

| Dependency | Pin | Packaging in DIRT | Privacy evidence |
| --- | --- | --- | --- |
| MapLibre Native | 6.28.0, revision `5ee345c`, SwiftPM artifact checksum `72c20a6d…d6588e2` | one dynamic `MapLibre.framework` | valid framework `PrivacyInfo.xcprivacy`; declares no collection/tracking and required-reason APIs `C617.1`, `35F9.1`, `CA92.1` |
| Supabase Swift | 2.53.0, revision `6dcceb2` | statically linked with its Swift dependencies | no separate executable framework; linked code is covered by the app manifest and final Xcode privacy report |
| Swift Crypto | 4.5.1, revision `47d3869` | statically linked plus `swift-crypto_Crypto.bundle` | valid resource-bundle manifest; no collection, tracking, or required-reason APIs |
| Supporting Swift packages | exact revisions in `Package.resolved` | statically linked | no additional executable SDK bundles in the app |

The app manifest is valid, declares tracking false with no tracking domains, and
records Name, Email Address, User ID, Precise Location, Coarse Location, and
Other User Content for app functionality. It declares the app's User Defaults
and File Timestamp required-reason APIs (`CA92.1`, `C617.1`). Final App Privacy
answers and the public privacy policy must still be reconciled against Xcode's
archive privacy report.

### MapLibre artifact blocker

SwiftPM correctly selects the `ios-arm64` device slice, and its Mach-O load
command is physical `IOS` with only the `arm64` architecture. However, the
device slice's own `Info.plist` incorrectly declares:

- `CFBundleSupportedPlatforms = iPhoneSimulator`
- `DTPlatformName = iphonesimulator`
- `DTSDKName = iphonesimulator26.5`

The same values are present in the immutable downloaded XCFramework, not
introduced by DIRT's copy step. The device framework is also unsigned at source,
and the official XCFramework contains no MapLibre dSYM. Xcode's shallow unsigned
validation did not reject the platform mismatch, but it is not proof that App
Store validation will accept it. The missing dSYM is a known upstream packaging
gap that prevents complete third-party crash symbolication.

Do not hand-edit or re-sign the cached artifact. Use an official corrected
MapLibre artifact (or a reproducibly built and reviewed replacement), rerun map
regression/device tests, then archive and validate. As of this audit,
[6.28.0 is the current official iOS release](https://github.com/maplibre/maplibre-native/releases/tag/ios-v6.28.0),
and MapLibre tracks the
[XCFramework dSYM gap upstream](https://github.com/maplibre/maplibre-native/issues/3155).

## Export-compliance technical inventory

`ITSAppUsesNonExemptEncryption` is `false` in the built public `Info.plist`.
Code inspection found these cryptographic uses:

- TLS/HTTPS and secure WebSocket transport supplied by Apple's networking stack
  for DIRT, R2, map tiles, and Supabase;
- CryptoKit SHA-256 for downloaded pack/Rider Services integrity;
- CryptoKit SHA-256 for the Sign in with Apple nonce flow;
- Apple's Security/Keychain APIs for local credentials/state; and
- Swift Crypto used through the Supabase authentication dependency.

There is no DIRT-implemented encryption algorithm, VPN, encrypted messaging,
cryptocurrency, or custom cryptographic protocol in the Release executable.
This inventory supports the current non-exempt-encryption metadata; the account
holder must still answer App Store Connect's legal/export questionnaire from the
final signed build.

## Signing and archive readiness

The Mac currently exposes one valid `Apple Development` certificate and no
locally installed public-app provisioning profile. No `Apple Distribution`
identity was available, so a distribution-signed archive/export was not
represented as tested.

After distribution signing is available:

1. Archive `DIRT Production` with automatic App Store signing.
2. Export with `ExportOptions.plist` (`app-store-connect`, team
   `34XM6B4G7A`, automatic signing, symbols uploaded).
3. Run `scripts/verify-ios-archive.sh /path/to/Dirt.xcarchive`.
4. Resolve every failure, including framework platform metadata and missing
   executable dSYMs.
5. Run Xcode **Validate App** and inspect the generated privacy report.
6. Confirm thinned sizes, retained iPhone/iPad support, export answers, and App
   Privacy disclosures before upload.

The archive verifier requires an Apple Distribution signature, production Sign
in with Apple/app identity entitlements, no debugger entitlement, all existing
Release bundle checks, and UUID-matched dSYMs for the app and every embedded
framework.

## Android counterpart

None. This change audits Xcode's `.app`/`.xcarchive` packaging, Apple privacy
manifests, Apple distribution signatures, and iOS dSYMs. It does not change a
rider-visible behaviour, shared data contract, backend, or routing artifact.
Android retains its own release-package and signing verification obligations in
`ANDROID-PARITY.md`.
