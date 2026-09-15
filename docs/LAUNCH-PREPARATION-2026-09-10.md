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
- Updated the launch health checker from the legacy root catalog to the app's V4 release fabric-v4-20260909-02. Five checker tests passed. Strict/deep verification passed Auth, route/fuel/POI health, 63-region catalogs, 315 advertised object availability/size checks and Shortbread. That historical run recorded a fuel-chain health failure; it is not current routing status. Evidence: `.build/launch-preparation-20260910/production-health.txt`.
- No new archive, upload or final submission in this session.

### Next application work / release gates
1. Complete routing qualification against the current routing source of truth before launch; this checklist is not a separate routing backlog.
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

## Routing launch dependency

Routing architecture, current qualification gaps, and repair priority are maintained only in [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md). Historical server repair logs remain in Git and raw evidence; this launch record does not prescribe a routing engine or certify current regional behavior.

## CarPlay follow-up

Apple requested additional screenshots illustrating CPManeuver instruction variants. Richard supplied landscape app screenshots for the response. These are app screenshots, not evidence of an implemented CarPlay template or an approved entitlement. Final App Review submission/public release remains deferred.

## CarPlay approval and account configuration — September 14

Apple assigned the CarPlay entitlement to the developer account (Case-ID 22137173). At Richard’s request, CarPlay Navigation was enabled and verified on production App ID `com.mayday.dirt`. The new App Store profile **DIRT Production CarPlay App Store 2026-09-14** was generated and downloaded. Xcode installation/signing and the CarPlay app implementation remain unverified/uncompleted by this setup session. DEV App ID unchanged; no archive, upload, or submission. See [CarPlay setup record](CARPLAY-FOUNDATION-2026-09-10.md) for exact identifiers, scope, and remaining work. Earlier pending-approval entries are superseded.
