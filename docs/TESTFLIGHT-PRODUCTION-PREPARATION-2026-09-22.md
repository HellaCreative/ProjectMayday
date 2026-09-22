# DIRT production TestFlight preparation — September 22, 2026

## Current September 22 delivery checkpoint

Richard explicitly authorized the latest repair on his phone and production
TestFlight preparation/upload. Optimized DEV source `00e416c` is installed and
launched on White, stamp `continental-70-country-20260922`. 218 engine and 103
focused app tests pass; the actual NH–Indiana extension still times out near
OH–IN in the Debug simulator. It stays in the U.S.; completion is not repaired.
An additional optimized simulator attempt hit a Swift compiler crash in the
IssueReporting dependency and supplies no runtime qualification.

Production build 2 (46) archives at
`.build/archives/DIRT-Production-2-46-Country.xcarchive` with production bundle,
backend hosts and `fabric-v4-20260922-01` selection. DEV hosts are absent.
Existing tracked `ride.mov` onboarding video and `ne-admin1-na.json` map boundary
resources were byte-compared to their sources and added to the release resource
allowlist; no unknown resource was blindly permitted.

App Store export is blocked: Xcode reports **No Accounts** and no **iOS
Distribution** certificate. Only an Apple Development identity is available.
Richard must sign into the appropriate Apple Developer account in Xcode and
make distribution signing available. No IPA export or TestFlight upload succeeded.
Production data copying and independent download/hash verification are running
under `.build/production-full70-20260922/promote.py`; inspect `state.json` and
`production-data-receipt.json` before claiming completion. All 495 objects must
verify, with discovery last. Its temporary authenticated worker is deleted by
its cleanup handler. Production hosted-service settings still name the old
release and must be aligned and checked after data verification, before upload.
Fuel identity parsing now recognizes both candidate and release namespaces;
focused fuel identity/cache tests pass. No hosted service was changed yet.

The older preparation baseline below is historical. Current authorization and
these pending gates supersede its preparation-only wording.

## Purpose

Prepare the next TestFlight candidate without changing the public production
service, catalog, or App Store state. The full Canada/US DEV fabric has passed
its release qualification and is being accepted on a physical DEV build first.

## Verified DEV baseline

- Initial delivered Git checkpoint: `869ff85` on `main`; use the later all-leg
  routing follow-up and its device receipt for the next production candidate.
- Immutable fabric: `fabric-v4-20260922-01`.
- Scope: 70 regions and 155 neighbouring pairs, including `ca-n` and `ca-s`.
- Qualification: 1,165 route/resource cases passed; 213 engine and 64 integrated
  app checks passed before the small Plan-mode follow-up.
- Latest follow-up: From Here, Plan, appended/edited legs and loop halves share
  editable roughly 800 km sections for long legs. All 215 engine and 64 app
  checks pass, including a real NS–Maine–Tennessee append. See the routing
  authority for exact source/receipt attribution and the remaining search-time
  and BC–Utah limitations. Physical acceptance of this follow-up is pending.
- Device lane: optimized `ReleaseDev`, `com.mayday.dirt.dev`, DEV services only.

## Current production boundary

The ordinary iOS `Release` configuration is correctly isolated from DEV:

- Bundle identity is `com.mayday.dirt` and display name is `DIRT`.
- It selects the production Supabase and routing-service hosts.
- It currently selects `fabric-v4-20260909-02`, not the new 70-region fabric.
- It must not inherit `DIRT_DEVELOPMENT` or
  `DIRT_PRE_RELEASE_TESTER_UNLOCK`.

This means a production archive today would not be a coherent test of the new
continental release. No production pointer, hosted service, App Store archive,
or TestFlight upload has been changed by this preparation.

## Ready-to-execute sequence after DEV physical acceptance

1. Promote the already published immutable 70-region objects and discovery
   manifests to the production release namespace, then independently download
   and hash-verify them. Do not rebuild or substitute pack bytes.
2. Update the production catalog selection to that exact promoted release and
   verify the production routing/fuel/POI service reads the same release.
3. Create a production source identity binding the production catalog, service
   deployment, full-70 release receipt, and Git checkpoint.
4. Run the production catalog/download/reuse/routing checks, including the
   California-to-Arizona route, with production credentials and a disposable
   production test account where applicable.
5. Increment the production build number from its historical value, build a
   signed `Release` archive, and verify that its bundle is `com.mayday.dirt`,
   its services/catalog are production, and tester bypass symbols are absent.
6. Complete the applicable outstanding TestFlight gates in
   [APP-STORE-LAUNCH-CHECKLIST.md](APP-STORE-LAUNCH-CHECKLIST.md), then validate
   and upload the archive only under Richard's explicit production authorization.

The Release DEV build and the future production archive remain separate signed
products. Passing the former does not authorize or silently create the latter.
