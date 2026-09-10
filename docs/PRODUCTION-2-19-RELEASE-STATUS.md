# Production 2 (19) — release status

September 9–10, 2026. User authorized completing tests, archive, App Store Connect upload and review submission. No simulator was started.

## App artifact

Archive: `.build/archives/DIRT-Production-2-19-Final.xcarchive`.
Bundle `com.mayday.dirt`, version2, build19; DEV source build34.
Source release-target commit582fcb1, app fixes51353d2/6b42d63/72e87d6.
The working tree also contains pre-existing development changes; it was not reset or represented as a clean release checkout.

Archive completed. `verify-ios-archive.sh` passed bundle resources/privacy manifest, signatures, app and MapLibre dSYM matching. Executable contains release02 and not release01. MapLibre device-platform metadata finalizer passed. Distribution export/upload has NOT completed.

## Tests

Physical white iPhone: prior planner/V4 suites32 passed, subscription gates5 passed, national budget/watchdog5 passed, latest planner suite22 passed including same-endpoint profile geometry replacement. Some planner tests overlap the earlier run; these are suite results, not a unique-test total. No visual acceptance is inferred from model tests.

Logs: `/tmp/dirt-production19-archive.log`, `/tmp/dirt-production19-verify.log`, `/tmp/dirt-production19-export.log`.
Latest planner result: `.build/release-validation/Logs/Test/Test-DIRT Dev-2026.09.09_22-28-43--0300.xcresult`.

## Published packs

All63regions /465objects in immutable `fabric-v4-20260909-02` published and checked. App DEV/Production download targets aligned. Catalog SHA256 `7b30e90d77349fdce7d245692c38106853c305ae7573d751c914b8c4535b8ebb` independently fetched and checked.
Pack evidence: `scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/publication/handoff.json`.
Both public aliases now serve all63 regions on source23d8f2563702c5004cc0942a340007149e03ec09 and release02. Public production NS zero-wander Dirt passed2.65s and WA defaults passed33.30s.

## Current external blockers

Export failed with Xcode `No Accounts` and `No signing certificate "iOS Distribution" found`. Read-only identity check finds only Apple Development signing. Mac locked; App Store Connect UI inaccessible. User has been asked to unlock. No password bypass, certificate revocation or account removal attempted.

App Store group localization, same subscription service level, current build selection, screenshots and review metadata still require App Store Connect access. Catalog products are saved; purchase/restore in TestFlight has not yet been verified. See `TESTFLIGHT-SUBSCRIPTION-CATALOG-2026-09-09.md` and prepared `APP-STORE-SUBMISSION-COPY-2026-09-09.md`.

Website factual corrections prepared but not published (SiteGround publishing access not configured); see `WEBSITE-FACTUAL-REPAIR-2026-09-09.md`.

## Completed server repair

Continuous wander distance-cost fix passed60/60 supplied route combinations. Zero no longer forces paved; surface profile remains independent. Both DEV and production now run national scope on release02, source23d8f2563702c5004cc0942a340007149e03ec09. National proved zero-refill path preserves legal access, restrictions and fuel escape; Atlantic excludes it.

California full cold candidate pool passed76.6seconds on4GiB. Final app/server national budget90seconds, client transport100seconds, watchdog105seconds; Atlantic20/23/28 unchanged. Final physical policy test compiled but launch was blocked by the locked white iPhone; eight assertions against extracted actual policy/watchdog source passed instead. Earlier physical tests used the60-second draft, so are not represented as final90-second device validation.

Final archive and archive verification passed. Logs: `/tmp/dirt-production19-final-archive.log`, `/tmp/dirt-production19-final-verify.log`. The earlier archive without `-Final` is superseded. Signing/account blockers above still prevent distribution export, upload and submission.
