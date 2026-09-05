# iOS Release Hygiene Audit — 2026-09-05

This is a read-only static audit of the tracked iOS application and a clean,
unsigned `Release-iphoneos` application bundle. It supplements the package and
privacy-manifest checks in `scripts/verify-ios-release.sh`; it does not approve
routing, map packs, Rider Services, backend policy, deployment state, or device
behavior.

## Artifact inspected

- Executable SHA-256: `5da031093174369801a78283fcca092db209297a5caac526e1b9030588b99e7a`
- Executable size: 21,272,064 bytes
- Total uncompressed application files: 32,694,352 bytes
- Built: `2026-09-05T16:09:17-0300`
- Bundle identifier: `com.mayday.dirt`
- Minimum OS: iOS 26.0

The artifact is an unsigned engineering Release bundle. Signing, provisioning,
archive export, and the separate MapLibre package-metadata blocker remain
covered by `docs/IOS-RELEASE-PACKAGE-AUDIT-2026-09-05.md`.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Private credentials | Pass | No tracked credential files and no private-key, service-role, bearer-token, or common privileged-key marker in the app executable. |
| Public client identifier | Expected | The production Supabase `sb_publishable_...` value is deliberately embedded. It is not a service-role secret. |
| Backend identity | Pass | Production DIRT, Supabase, R2, and tile-edge identities are present. DEV Vercel, DEV Supabase, and `DIRT development` identities are absent. |
| Tester controls | Pass | The public Release build compiles `BuildChannel.showsTesterUnlock` to false. Tester UI copy is absent from the executable, stored bypass values are cleared on launch, and entitlement checks also require that build-channel gate. |
| Internal/test payload | Pass | `Dirt.storekit`, source READMEs, map databases, and Markdown files are absent from the application bundle. Packaged root resources match the reviewed allowlist. |
| Transport security | Pass with intentional exception | ATS has only `NSAllowsLocalNetworking = true`; this supports the loopback-bound offline tile proxy. No arbitrary-load or external HTTP exception is present. |
| Privacy manifests | Pass | App, MapLibre, and Swift Crypto manifests are bundled and valid. The app manifest declares precise/coarse location, name, email, user ID, and other user content, with tracking disabled. |
| Diagnostic logging | Owner decision | `RoutingDebugLog` retains a 1,200-entry in-memory field-diagnostic ring buffer in Release. Route attempts include endpoint coordinates. The share/copy controls are inside the compile-time-disabled tester footer, and normal Release console printing is disabled, so the inspected public build has no user path that exports the buffer. |

## Required owner decisions

1. Decide whether the inaccessible in-memory diagnostic buffer should remain in
   App Store builds for support value or be disabled for data minimization. If
   any public support/export UI is added later, coordinates must be redacted or
   the user must receive an explicit disclosure before export.
2. Keep `DIRT_PRE_RELEASE_TESTER_UNLOCK` out of the App Store archive. The final
   archived app must continue to pass `scripts/verify-ios-release.sh
   --require-signing` so DEV identities and tester copy cannot regress.

## Guardrails confirmed

- No credential rotation is indicated by this audit.
- Do not rotate or conceal the Supabase publishable key; authorization belongs
  in backend policy, not in secrecy of public client configuration.
- The local-networking exception must remain loopback-only in implementation;
  it must not become a general arbitrary-load exception.
