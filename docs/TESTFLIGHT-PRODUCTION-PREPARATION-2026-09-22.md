# DIRT production TestFlight preparation — September 22, 2026

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
