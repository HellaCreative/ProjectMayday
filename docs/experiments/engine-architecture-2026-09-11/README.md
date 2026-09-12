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

