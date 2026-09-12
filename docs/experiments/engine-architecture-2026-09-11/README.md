# On-device routing architecture checkpoint

Date: 2026-09-12  
Worktree: `engine-architecture` under the SIDECAR Live project  
Environment: private DEV candidate only; no production pack or hosted route was changed.

## Pack identity

The approved private V4 candidate is `fabric-v4-20260909-01` (63 regions).
The phone diagnostic supplied on 2026-09-12 used
`fabric-v4-20260908-01/ns/graph.v4.bin`, so those phone results were from a
stale four-region install. The NS graph/geometry/fuel bytes happen to be the
same between the two releases; the NB graph and the cross-pack seam sidecars
are different. The DEV route path now checks the installed release directory
offline and reports a stale-pack acquisition error instead of silently routing
on the predecessor. It does not fetch a manifest while a route is running.

## Changes in this checkpoint

- Ranked cross-pack seam anchors by operational topology. The previous first
  anchors were one-edge motorway stubs; the selected NS→NB seam is a connected
  service-road fabric (`osmWayId=149676172`, endpoint degrees 2/3 and 3/3).
- Added a short packed-leg direct route proof before the fuel planner. A leg
  whose straight-line lower bound fits the usable fuel budget is routed once,
  then committed with its actual graph distance. This removes the old
  destination-escape/fuel-window search from ordinary 60–70 km phone legs.
- Kept the full ordinary Dirt corridor at 60 km, but use a measured 40 km
  envelope for the bounded fast phone search. A 20–30 km envelope caused a
  failed bounded search followed by a slower fallback; 40 km retained the
  connected Yarmouth corridor with materially fewer expansions.
- Added route diagnostics for pack release, checksums when the catalog is
  available, search milliseconds, pops, corridor and objective.

## Measurements

The real V4 pack benchmark loads immutable local bytes from
`$DIRT_PACK_ROOT` and never calls the routing service. Results below are on the
serial iOS Simulator destination `CC6035EE-9C03-48A2-ACBA-DDE3B068642A`.

| Case | Result |
| --- | --- |
| NS→NB operational seam, Dirt | 1.19–1.22 s, 286.2 km, 64% Dirt; legal seam anchor |
| NS→NB seam, Clean | 0.76 s, 214.0 km |
| NS→NB seam, Balanced | 0.93–1.03 s, 233.8 km |
| NS→Yarmouth, Dirt, 40 km fast envelope | 2.04–2.05 s, 561.9 km, 51% Dirt, ~42k pops |
| NS→Yarmouth, Dirt, 60 km fast envelope | 2.50 s, 570.5 km, 52% Dirt, ~63k pops |
| NS→Yarmouth, Dirt, 30 km fast envelope | 3.93 s, 521.1 km, 58% Dirt, ~96k pops (rejected) |
| NS→Yarmouth, Clean | 1.10–1.30 s, 382.2 km |
| NS→Yarmouth, Balanced | 1.94–1.95 s, 406.7 km |

The 40 km candidate is a performance choice, not a road deletion: a wider
ordinary planning envelope remains available, and an unloaded area remains
discoverable through the normal pack acquisition path.

## Verification commands

From this worktree:

```text
xcodebuild test -project Dirt.xcodeproj -scheme 'DIRT Dev' \
  -destination 'platform=iOS Simulator,id=CC6035EE-9C03-48A2-ACBA-DDE3B068642A' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:DirtTests/ItineraryBuilderTests \
  -only-testing:DirtTests/OnDeviceProfileCostsTests
```

Expected result at this checkpoint: 53 tests in 2 suites pass.

```text
DIRT_PACK_ROOT=/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs \
  xcodebuild test -project Dirt.xcodeproj -scheme 'DIRT Dev' \
  -destination 'platform=iOS Simulator,id=CC6035EE-9C03-48A2-ACBA-DDE3B068642A' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:DirtTests/OnDevicePackBenchmarkTests
```

Expected result: 3 real-pack benchmark tests pass. The benchmark asserts that
the local NS pack manifest is the approved `fabric-v4-20260909-01` candidate.

## Recovery

This is an isolated worktree. To discard the candidate, reset or remove this
worktree only; the SIDECAR Live primary project and published packs are not
modified. To reproduce the old phone state, install the predecessor release
under its version directory; the DEV route guard will intentionally report it
as stale until the approved candidate is installed.

## 2026-09-12 on-device confirmation

The authorized iPhone 16 (device label `white`) ran DIRT Dev bundle version
`2 (15)` against the installed `fabric-v4-20260909-01` pack. Automatic fuel
planning was off for this run, so these are pure on-device route measurements.

| Case | Result |
| --- | --- |
| NS short leg, 70.8 km, Dirt | 88 ms, 3,544 pops, 30% Dirt, committed |
| NS long leg, 603.3 km, Dirt | 2,020 ms, 85,074 pops, 67% Dirt, committed |
| NS long leg, 546.7 km, Dirt, unknown access allowed | 1,297 ms, 77% Dirt, committed |
| NS long leg, 550.4 km, Dirt, unknown access allowed | 1,529 ms, 89% Dirt, committed |
| NS long leg, 592.0 km, Dirt, unknown access allowed | 1,731 ms, 81% Dirt, committed |

The device log identifies the current NS pack as
`ns@fabric-v4-20260909-01/91a10b49`. Earlier cross-region attempts were
cancelled while the user replaced the active pin; they did not show a stale
pack or a missing phone capability. Cross-region routing now keeps both
decoded packs resident for one request, avoids swapping the active UI pack at
each seam candidate, and records a shared elapsed deadline. This is
checkpoint `1b37439` (`Bound cross-region pack decoding`).

Focused verification after that change: 56 tests in 3 suites passed. Broad
verification: 297 tests in 35 suites passed. The remaining device validation
is automatic fuel planning on the current pack; no new phone build is being
requested until that path has a local integration result.

## 2026-09-12 cross-region seam repair

The next White-device log isolated the NS→NB failure. Both current packs were
installed and selected, but the chain reported `seamAttempts=0` and `noPath`
after roughly 4.4 seconds. NB's seam sidecar is 7.9 MiB because it also
contains its Maine, Quebec, PEI, and other border records. The route was
parsing that complete document before it could try the small NS↔NB proof.

The candidate now decodes both graph/geometry files in parallel, then loads
only the smaller neighboring seam sidecar for the requested crossing. It
verifies each canonical anchor's OSM way against the current remote graph and
does not invent a connector from coordinate proximity. Ordinary same-region
routes do not parse any seam sidecar. A focused real-pack test now succeeds:

| Case | Result |
| --- | --- |
| NS→NB, Dirt, current V4 packs | 2.47 s total; 1 seam attempt; 1.22 s NS hop; 0.89 s NB final hop; 771.5 km; 58% Dirt |

The route itself is now correct and deterministic under the bounded search;
the pack route now allows a 3.5 s cross-region budget (same-region remains
2.2 s) so that this two-hop proof is not cancelled just before completion.
The remaining device check is to confirm the same `seamAttempts=1` result on
White. The focused suite is green (4 tests); the full suite must remain green
before installing this candidate.
