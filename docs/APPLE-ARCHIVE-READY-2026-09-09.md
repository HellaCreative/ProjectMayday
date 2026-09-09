# Apple archive packaging ready

Production archive: .build/archives/DIRT-Production-Automatic.xcarchive
Signed App Store IPA: .build/exports/DIRT-Production/Dirt.ipa

The DIRT Production Archive post-action runs scripts/finalize-ios-archive.sh.
It validates MapLibre6.28.0's actual arm64 IOS Mach-O, corrects the erroneous
Simulator plist labels, re-signs the unchanged binary/framework and app using
the archive's certificate, and includes the official matching device dSYM.
Source: https://github.com/maplibre/maplibre-native/releases/tag/ios-v6.28.0
Symbol zip SHA256:8061c6639884c0023a2f2f1fdc9685bea7ed3a5f51b8abfa0cb4a44fdf4864b8.
Binary/symbol UUID:00FEEAD7-92B6-3BFA-9FAE-E76AA232C2E2.

Archive verification passes, including exact dSYM UUIDs, resources, production
identity, no tester-bypass copy, and strict signatures. App Store export with
automatic provisioning succeeds; extracted IPA passes require-signing checks
with Apple Distribution certificate and no debugger attachment.

Archive remains version2 build17; owner knows to choose an unused build number
before upload. No upload, Apple server validation, processing, beta review or
App Store approval is claimed. This is packaging readiness, not national engine
qualification. National engine activation remains a separate service task.

The first scheme action exposed missing EXPANDED_CODE_SIGN_IDENTITY; the script
now derives the certificate fingerprint directly from the archive signature.
That path was exercised successfully without the environment variable. Logs:
/tmp/dirt-auto-verification.log and /tmp/dirt-export-verification.log.
