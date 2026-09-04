# DIRT navigation-preparation requalification — build 2 (14)

**Status:** automated candidate; physical Release-device acceptance pending

**Unchanged routing baseline:** `routing-rc1-2026-09-03`
(`94b467a11375e3ea3233c127b07af2ef039d0658`)

Build 2 (14) does not alter route selection, profiles, access eligibility,
fuel planning, pack formats, or the live routing service. It does harden the
Start Navigation handoff and on-ride progress tracking that the original freeze
document also placed inside its acceptance boundary. For that reason, the
routing engine remains frozen while this navigation-preparation candidate needs
a focused physical pass before it supersedes build 2 (13) for release.

## Candidate behavior

- Start prepares only the first visible stage's basemap corridor and the
  rider's current region; later stages and regions roll forward during the ride.
- Start, retry, cancel, and Begin Ride transitions are one-shot.
- A route replacement re-anchors progress to its new geometry.
- Cue-mode changes retain delivered cue identities instead of replaying them.
- Progress matching stays on a locally reachable part of loops, crossings, and
  parallel roads.
- Rejected off-route projections never advance distance or continuity anchors;
  a stationary fix cannot ratchet toward a later route arm.
- A genuinely moving rider can rejoin farther ahead, including after a longer
  background location gap.
- Offline tile HTTP listeners bind only to `127.0.0.1`; they are not exposed to
  Wi-Fi peers.

## Automated acceptance

- Navigation reliability suite covers fresh-session reroute throttling, cue
  deduplication, parallel arms, self-crossings, stage transitions, route
  replacement, background gaps, stationary off-route fixes, natural rejoin,
  and preparation-state transitions.
- The full iOS suite and unsigned Release package must pass on the final commit.
- The Release bundle verifier must confirm the privacy manifest and absence of
  development resources and tester bypass copy.

Build 2 (14) result: the full iOS unit/integration target passed 259/259, the
focused navigation suite passed, UI coverage passed after serializing the UI
target, the unsigned Release build and Xcode Release analysis passed, and the
37 MB Release bundle passed its automated audit. Physical acceptance below is
still intentionally open.

The focused navigation, subscription, group-safety, and core integration
suites passed again on iPhone 17 / iOS 26.5 Simulator after development/backend
isolation at commit `ac383bd`. This does not replace the White checklist.

## Physical acceptance required on White

- [ ] Start a short local route, cancel preparation, retry, and begin exactly
      one ride.
- [ ] End the ride and immediately start a second ride.
- [ ] Start a multi-province route and confirm only the first-stage tiles and
      current regional pack block entry into navigation.
- [ ] Ride a loop or nearby parallel road with ordinary GPS scatter and confirm
      progress stays on the current arm.
- [ ] Depart the line, remain stationary through reroute initiation, then rejoin
      ahead and confirm distance does not creep while stopped.
- [ ] Lock/unlock the screen and background/foreground the app during a ride.
- [ ] Confirm no Local Network permission prompt appears.

Record the build number, commit, device/iOS, route, diagnostic export, and result
for each item. Once these pass, mark this document accepted and tag the exact
commit as the navigation-preparation release candidate. Do not move the older
`routing-rc1-2026-09-03` tag.
