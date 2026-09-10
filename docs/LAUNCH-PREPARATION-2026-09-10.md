# Launch preparation — September 10, 2026

## Release instruction

Continue preparation and application testing. Do not submit for App Review or release today. User will provide final screenshots and possibly an animated walkthrough. Subscription price mismatch belongs to application testing; do not change pricing as part of website preparation.

## Completed and verified

- App Store Connect privacy answers published: six data categories, app functionality, linked to identity, no tracking, based on APP-PRIVACY-DATA-MAP.md.
- Disabled Apple Silicon Mac and Apple Vision Pro availability and saved in App Store Connect. Supported launch devices are iPhone and iPad; physical iPad qualification remains open.
- Published eight factual website updates to SiteGround: home, data, download, features, privacy, subscriptions, support, terms. All eight returned HTTP 200 and matched prepared files byte-for-byte. Evidence: `.build/website-launch-20260910/published-verification.json`. Website source is `/Users/richardsmith/SandBox01/MAYDAY-HTML/Untitled`.
- Hover now delegates dirtmoto.app to elliott.ns.cloudflare.com and raphaela.ns.cloudflare.com. Registry authority confirmed the change. Existing website/email DNS records compared equal before changing delegation. Evidence: `.build/domain-setup-20260910/dns-comparison.json`. Recursive caches may still show old nameservers.
- Production Supabase now has the existing DEV group authorization hardening and private helper migrations. Applied versions: 20260910120756 harden_identity_group_access; 20260910121106 move_group_authorization_helpers_private. These map to source migrations 20260904133000 and 20260904133100 respectively.
- Also promoted the existing expand_rider_statuses migration: production previously rejected riding and other newer statuses. Legacy available/breakdown remain accepted.
- Production three-user authorization matrix passed after these migrations; transaction rolled back and zero fixture users remained. Covers unrelated group/profile/location isolation, restricted writes, alert resolution, incident ownership, private Realtime, and deleted-group access. DEV authorization and account-deletion matrices also passed.
- Corrected authorization test's incident visibility assertion to count its fixtures rather than unrelated real shared incident reports.

## Still open

- Subscription localized display price versus purchase sheet; restoration, expiry, navigation access tests. Subscription levels and review assets still need dashboard reconciliation.
- Regional crossings and rider preference behavior remain application testing/repair work; this preparation does not qualify them.
- Sign in with Apple token revocation during account deletion is not yet implemented. Current deletion RPC and local logout are not proof of Apple token revocation.
- Group abuse reporting/blocking review remains; private-group access controls alone do not implement moderation.
- Third-party licence provenance/distribution questions remain, notably SVWD03 style/sprites. Do not mark all content rights cleared merely because notices are available.
- Final iPhone/iPad screenshots, final device tests, final archive containing approved changes, review notes and final App Store submission remain open.
- Security advisor: five authenticated SECURITY DEFINER RPC warnings correspond to intentional account/group operations, reviewed through permission tests; leaked-password protection warning remains (verify auth-provider configuration before deciding applicability).
- Launch operations runbook (support, service alerts, rollback, release monitoring) to be finalized closer to launch.

## Dashboard interruption

Mac locked during the R2 custom domain flow. User was asked to unlock it. Local and Supabase API work continued; no dashboard actions after the lock are claimed complete.

## After unlock: domain setup completed
Both packs.dirtmoto.app and tiles.dirtmoto.app are active and verified. The previous map-domain/activation interruption above is resolved. Versioned Shortbread archive cache rule is active; mutable manifests excluded. Existing distributed app addresses retained; no app endpoint migration performed. See CLOUDFLARE-DOMAIN-SETUP-2026-09-10.md. Website HTTP 200 and MX records verified.

## Font notice follow-up
Noto Sans Regular glyph provenance resolved from the licence adjacent to the actual hosted font files. SIL OFL 1.1 notice added to app working tree, with pinned source and hash in MAP-FONT-PROVENANCE-2026-09-10.md. Not yet archived/uploaded.

## Apple deletion clarification
APPLE-ACCOUNT-DELETION-AUDIT-2026-09-10.md records Apple’s documented manual fallback and the missing credential-revocation observer/state check. Existing deletion and manual Settings guidance remain functional; automatic revocation is not implemented. No blanket compliance claim is made.

## Credential monitor implementation
Apple credential state monitoring is implemented in the working tree, including persisted sharing disablement and same-session guards. Six standalone policy assertions passed; final unsigned production compile passed (/tmp/dirt-apple-revocation-final-build.log). A real Apple revocation on a designated test device remains required. No archive or upload in this pass. See APPLE-ACCOUNT-DELETION-AUDIT-2026-09-10.md.

## 15:15 UTC dashboard follow-up
Attempted subscription service-level reconciliation in App Store Connect; macOS is locked again and automatic unlock failed. No subscription settings changed. Wait for owner unlock before retrying dashboard work; avoid repeated lock notifications. Existing price-display testing and final-submission hold remain unchanged.

## Latest unlocked-session reconciliation
- Subscription service levels saved and verified: Monthly and Yearly both level 1. No pricing change.
- CarPlay navigation request text filled in the signed-in developer form; screenshots and explicit agreement acceptance remain. No entitlement request submitted.
- Updated the launch health checker from the legacy root catalog to the app's V4 release fabric-v4-20260909-02. Five checker tests passed. Strict/deep verification passed Auth, route/fuel/POI health, 63-region catalogs, 315 advertised object availability/size checks and Shortbread. The production fuel-chain endpoint returns HTTP 500; overall health remains failed. Evidence: `.build/launch-preparation-20260910/production-health.txt`.
- No new archive, upload or final submission in this session.

### Next application work / release gates
1. Diagnose the production fuel-chain startup failure, then verify actual fuel planning. Regional crossings and rider preferences remain separate physical test cases.
2. Complete subscription localized-price/restore/expiry tests; keep current prices.
3. Group access isolation is hardened; abuse reporting, blocking and moderation remain app/backend work, not completed by those security migrations.
4. Verify Apple credential-revocation behavior on a designated test device, and iPad behavior.
5. Close style/sprite distribution rights and the exact Pixabay asset-source record. General terms and notices do not identify the downloaded audio or settle modified GPL artwork distribution.
6. Final navigation/App Store/subscription screenshots; operational mailbox/alert ownership and backup/restore evidence; final approved archive and review submission after Richard lifts the hold.

The Mac-lock interruption is resolved. Dashboard access is no longer the blocker.

## CarPlay request submitted — owner confirmation
Richard uploaded the navigation screenshots, accepted the CarPlay terms and received Apple’s submission acknowledgement. The request is now awaiting Apple review. Earlier unsubmitted/draft status is superseded. Entitlement approval and CarPlay implementation are not yet complete.

## Owner-recorded startup audio
Richard supplied his own KTM recording; the active app resource and attribution replace the Pixabay sample. The earlier exact-Pixabay-source requirement is superseded for the next build. This does not close the separate map style/sprite rights question. No new archive uploaded.

## Fuel health correction and regional investigation
The earlier blanket fuel-service failure interpretation is superseded: GET /api/fuel-chain eagerly loaded obsolete compatibility topology only to obtain a version string. Real POST requests dispatch through the new engine; a supplied NS fixture completed identically on DEV and production (249500.109 m, zero stops). Metadata extraction fix af96ca97d31760ae53bae5f7e1a870ba3e311d80 is live on both aliases and both health endpoints return 200 with that identity. Twelve focused health/dispatch tests passed. No fuel-selection algorithm changed in that fix.

Richard confirms fuel works within NS and between NS/NB, with failures involving PE, NL, QC and ME. A controlled within-PE fuel request completed (70983 m); NS-to-PE returned adventure_search_incomplete. Regional selection omits NB from NS/PE because direct ferry adjacency wins the fewest-region search. A separate bridge-region candidate is under test; no regional fix is yet claimed. Evidence: .build/fuel-health-evidence. Exact owner failing trip details requested.


## Regional fuel investigation continuation — September 10

Production and stable DEV remain on health-only fix af96ca97 at this checkpoint.
Private candidate source: `.build/fuel-health-repair`, current a5fe920fbf0bbf0c7b49f857319010d89c0cdd8b.
No root application changes, archive, upload, or device installation in this pass.

Controlled fresh-route checks on candidate 599b6f4 passed NS→PE (409.751 km,
one refill), NB→ME (165.842 km), NS→NL (444.398 km), and NS regression
(249.500109 km, zero refills, same as live baseline). These are synthetic
endpoints, not the owner's still-unprovided exact failing trips. All main
surface candidates completed, with mapped fuel access correctly provisional.
232 adventure tests pass, including passing pumps, multi-refill range,
starting tank, legal destination escape, detour fallback, and projected edge
splits. Station-split pieces must not be mistaken for repeated physical roads.

NB→QC passed warm under a 20-second stress budget but failed cold. This is
NOT yet an app timeout reproduction: root FuelPlanningWindowPolicy already
requests 90 seconds outside Atlantic and 100 seconds transport. Native-window
cold verification is being run before drawing a product conclusion.

Private flag DIRT_PASSING_REFILL_ADVISORY=candidate-v1 opts fresh routes beyond
NS/NB into the standard three-objective pool and passing-station fuel witness.
It adds no detour and makes no global fewest-refill claim across tied roads.
Required stops and prior histories keep integrated search. NS/NB-only behavior
is unchanged. Android parity is documented in the isolated source; native
parity/device acceptance and production promotion remain open.
Evidence: `.build/fuel-health-evidence/regional-candidate-20260910`.


### DEV regional fuel candidate now available

Promoted the exact tested a5fe920fbf0bbf0c7b49f857319010d89c0cdd8b deployment
`pack-fabric-99zme7th1-goricksmith-7678s-projects.vercel.app` to
`pack-fabric.vercel.app`. Health identity verified. Production remains
health-only af96ca97, also verified. No pack or mobile build was published.

Cold NB→QC with the actual native 90-second/one-stop window completed all
three objectives; the earlier 20-second cold failure was a stress-test result,
not the native-window result. Final candidate NS→PE also complete under20s.
Native physical acceptance remains open, especially longer multi-window rides,
forced fuel replacements, existing itinerary history, and the owner's exact
failing routes. This is DEV test readiness, not national release qualification.
Rollback DEV alias target:
`pack-fabric-6vtqnuanx-goricksmith-7678s-projects.vercel.app` (af96ca97).


## Owner NS→QC replay repair — available on DEV

Owner log `dirt-app-debug-2026-09-10T182737Z.txt` (2/34, DEV) identified
unsupported forwardFeeler=true on the real cross-region request, followed by
fuel-unverified advisory geometry (1,643.8 km) with no pumps. Usable range180km.
Candidate eacb5b0 accepts only combined forward windows (routeFirstPlan=true,
allowPartialWindow=true,windowMaxStops=1); unrelated unsupported controls remain
rejected. Candidate f606ad9 retries label-limited regional dirt alternatives
with existing stronger guidance, same deadline/cap/constraints. Owner first
window then returned one pump within180km. A sequential replay reached three
pumps, then failed on parallel-edge arrival direction at the third pump.
Candidate0647a8b resolves direction from preceding ordered approach history;
235 tests passed and failed fourth-window replay now returns the next pump.
Sequential replay reached the Quebec destination in 10 windows with 10 fuel
stops over 1,514,036 m. Every individual fuel leg stayed within 180 km.
Replay preserved ordered recent edge history, arrival direction and excluded
previous pumps; it retained the stricter one-stop window inside Quebec too.
This verifies the server sequence, not physical-device acceptance.
Promoted exact tested 0647a8b deployment to stable DEV pack-fabric.vercel.app;
health confirms the commit. Production health remains af96ca97 unchanged.
DEV rollback: pack-fabric-99zme7th1-goricksmith-7678s-projects.vercel.app (a5fe920).
No new app archive or upload. Evidence in `.build/fuel-health-evidence/owner-qc-20260910`.


### Physical DEV follow-up at 19:28 UTC

App 2 (34) confirms server 0647a8b; no native rebuild required.
NS→QC destination 46.15605369715979,-70.65032958984375 failed fuel
search at 90,998ms (adventure_search_incomplete), then returned 1,380,415m
advisory geometry after another 74,553ms with no verified fuel coverage.
NS→NB then completed with three pumps in 8.2 seconds.
NS→QC destination 46.500475,-71.134677 completed with eight pumps and
nine legs in approximately three minutes; six single-stop windows, then
a three-leg final QC window. Every request used 180,000m usable range
(200km configured, 10% reserve), not 220km. This confirms real-device
cross-region continuation success but leaves a destination-dependent
search deadline failure and long total latency open. Production promotion
remains pending these findings. Evidence: device-followup-192835.txt.


### Quebec timeout and search reuse repair — live DEV

Stable DEV now6054217 (pack-fabric-jlw7l3dbb). Rural endpoints beyond
unavoidable town access now receive full reverse exposure bounds. Request-local
reuse avoids computing identical exposure arrays for each candidate. Fuel range,
legal turns, city avoidance and surface ranking preserved. 238 tests passed.
Both owner destinations completed with eight stops and every leg<=180km; full
replays224.2s/234.2s versus273.8s/277.8s before shared-bound reuse. Earlier
0647a8b failed the first destination at90s and returned uncovered advisory road.
NS→NB regression preserves exact geometry and three pumps. These are automated
server replays, not new physical-device acceptance; long-trip latency remains
a limitation. Production remains af96ca97. No map pack rebuild, native change,
archive or upload. Evidence .build/fuel-health-evidence/qc-performance-20260910.
RollbackDEV: pack-fabric-mpytcgr5z-goricksmith-7678s-projects.vercel.app.


## Regional fuel repair published to DEV — 139a173

Stable DEV https://pack-fabric.vercel.app now serves commit 139a173 from
https://pack-fabric-gez7gslte-goricksmith-7678s-projects.vercel.app.
Verified production remains af96ca97d31760ae53bae5f7e1a870ba3e311d80.
Rollback DEV: https://pack-fabric-jlw7l3dbb-goricksmith-7678s-projects.vercel.app (6054217).

242 automated tests passed. Full native-shaped continuation replays on the
published deployment:
- NS→deep Quebec Dirt: 5 stops, 1,534,453 m, 200.4 seconds.
- NS→deep Quebec Clean: 4 stops, 1,504,369 m, 253.6 seconds.
- NS→Bangor Clean: 3 stops, 1,146,053 m, 48.1 seconds.
Every leg fits 378 km usable; each continuation carries arrival history and
excluded pumps; final destination reached. NS/NB regression preserves exact
geometry and three pump identities.

Far-north Quebec-only route returns mapped_fuel_range_gap at 378 km usable.
A private 600 km usable diagnostic reaches the same endpoint with four stops;
this changes no rider setting and does not certify real station availability.
Earlier failed private candidate exposed an out-of-memory continuation;
final complete replays pass after fixed-path fuel proof is enabled for legal
continuations. No map, native binary, App Store upload or production promotion.
Physical DEV acceptance and later native parity remain open.

Source is the isolated worktree Dirt/.build/fuel-health-repair, commit139a173.
Do not deploy the unrelated dirty root checkout over this repair.
