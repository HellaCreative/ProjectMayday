# DIRT — Product Stabilization Build Plan

Status: active operating plan
Owner: Richard Smith with Codex as primary engineering agent
Purpose: prevent circular repairs, preserve known-good behavior, and determine
the next highest-value work whenever the rider asks, “What should we work on
now?”

## Current checkpoints

- Client checkpoint: `1a282f6` — Phase 11 fuel-map visibility
- Live packs: rebuilt by Cursor; exact manifest/candidate checkpoint must be
  recorded before pack validation begins
- Downloadable packs: not promoted from the rebuilt live packs
- Current activity: physical-device validation on White

## Operating rules

1. Freeze known-good checkpoints. Record the client commit and live-pack
   manifest used by every physical test.
2. Evidence comes before runtime editing. Each device failure receives a short
   defect report covering observed behavior, expected behavior, reproduction,
   probable subsystem, proposed correction, affected files, and regression
   risk.
3. Codex and Cursor receive non-overlapping ownership, branches/worktrees, and
   file boundaries. Neither edits the other lane while work is active.
4. Every repair adds a regression test or fixed benchmark case that reproduces
   the original failure.
5. No opportunistic redesign, cleanup, pack change, routing-weight adjustment,
   or unrelated file change inside a defect repair.
6. Each work package is one focused commit with its verification evidence.
7. Integration happens in a declared order. All gates run again after the
   commits are combined.
8. Live packs remain the online source of truth. Downloadable packs are promoted
   only after their matching live packs pass the release gate.

## Defect intake and work split

For each device-test session, Codex first produces one reviewable defect report.
No repair begins until Richard approves the proposed direction.

After approval, Codex produces two bounded work packages when parallel work is
useful:

- **Cursor lane:** normally pack validation, cross-region seams, release gates,
  benchmark tooling, or another isolated subsystem with explicit no-touch
  boundaries.
- **Codex lane:** normally the iOS planner, fuel interaction, route presentation,
  navigation, and integration verification.

Every work package must state:

- branch or worktree;
- permitted files;
- forbidden files/subsystems;
- exact defect and acceptance criteria;
- required automated tests and benchmarks;
- required device validation;
- commit message; and
- integration order.

## Stabilization sequence

### Gate 1 — Route creation is trustworthy

- [ ] Short single-region routes complete reliably.
- [ ] Long single-region routes complete within the agreed time budget.
- [ ] Cross-region routes complete without overlap or seam mis-selection.
- [ ] Endpoint snapping selects a profile-eligible edge and reports an honest
      failure when none exists.
- [ ] Long or cross-region rider legs deliberately use the agreed Clean-first
      strategy where authorized.
- [ ] Fuel chains build forward and linearly across the full itinerary.
- [ ] Fuel stops produce rider-visible stages, not hidden substructure.
- [ ] Fuel stops can be inspected and replaced without rebuilding upstream work.
- [ ] From Here → Plan a Route preserves the built itinerary without an
      unnecessary rebuild.
- [ ] Add, move, insert, renumber, and delete waypoint operations are reliable.
- [ ] Clear Route / Start Anew is always available when a route exists.
- [ ] Profile and Allow Unknown changes affect only their intended rider leg or
      fuel hop.
- [ ] Existing fixes remain covered by automated regression tests.

### Gate 2 — Permanent routing validation matrix

Fixed geographic cases:

- [ ] Short Nova Scotia route.
- [ ] Long Nova Scotia route.
- [ ] Nova Scotia → New Brunswick → Quebec.
- [ ] British Columbia → Alberta.
- [ ] British Columbia → Washington.

Required matrix dimensions:

- [ ] Dirt, Balanced, Direct, and Clean.
- [ ] Fuel ranges of 150, 250, and 400 km.
- [ ] Allow Unknown off, plus on where applicable.
- [ ] Online with live packs.
- [ ] Offline with installed packs.
- [ ] Waypoint insertion, movement, deletion, and renumbering.
- [ ] Fuel-stop inspection and replacement.
- [ ] Fixed seeds and coordinates produce deterministic comparisons.
- [ ] Every routing change publishes a before/after benchmark table.

### Gate 3 — Pack release

- [ ] Record the exact rebuilt live-pack manifest and candidate IDs.
- [ ] Validate every live pack structurally.
- [ ] Validate fuel sidecars and station counts.
- [ ] Validate inter-region seam connectivity and ownership.
- [ ] Run the permanent routing matrix against live packs.
- [ ] Complete physical acceptance on representative regions.
- [ ] Promote matching downloadable packs only after the live version passes.
- [ ] Verify offline routing against each promoted downloadable pack.

### Gate 4 — Navigation hardening

- [ ] Corridor map layers and regional routing packs are available before Start.
- [ ] The active ride survives cellular loss and recovery.
- [ ] Offline rerouting around a blocked section succeeds.
- [ ] Backtrack-and-reroute behavior is safe and understandable.
- [ ] Navigation state survives interruption and app restoration.
- [ ] Cues, route progress, arrival, and off-route detection are correct.
- [ ] Incident/gate reporting is captured offline and synchronized later.
- [ ] Fuel continuity reflects progress during an active ride.
- [ ] Route gaps are visible in navigation and exported GPX.

### Gate 5 — Onboarding and product polish

- [ ] Onboarding explains DIRT’s adventure-routing purpose clearly.
- [ ] Permission requests occur only with meaningful context.
- [ ] First route creation is understandable without instruction.
- [ ] Pack and offline preparation behavior is explained honestly.
- [ ] Empty, loading, failure, and recovery states are concise and useful.
- [ ] Accessibility, Reduce Motion, layout, and device-size checks pass.

## “What should we work on now?” decision rule

When asked, choose the first applicable item below:

1. A newly observed blocker that prevents further testing.
2. A regression in behavior previously declared working.
3. An unresolved Gate 1 route/fuel correctness issue.
4. Missing automated coverage for a repaired Gate 1 defect.
5. Completion of the permanent Gate 2 matrix.
6. Live-pack validation and downloadable-pack promotion.
7. Navigation hardening.
8. Onboarding and product polish.

Do not skip forward because a later feature is more appealing. A lower gate can
start only when the earlier gate is sufficiently stable for meaningful testing.

## Device-feedback rule

If one test produces a severe blocker, stop the remaining test script. Preserve
the screenshot, debug log, coordinates, mode, profile, fuel range, connectivity,
client commit, and live-pack manifest. Diagnose that blocker before asking the
rider to spend time testing dependent behavior.

