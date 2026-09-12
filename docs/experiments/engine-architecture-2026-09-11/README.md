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

## 2026-09-12 fuel-window lower-bound repair

The next White-device log showed that pack routing itself was healthy but the
fuel planner still entered its generic target-aware reachability flood with
`forceStop=0`. It spent the full 20-second window before falling back to an
unverified road route, even when the destination's straight-line lower bound
already exceeded the 180 km usable range. This was a planner control-flow
failure, not a missing station or a device-speed limit.

Checkpoint `a378d22` makes the bounded one-pump path trigger whenever that
lower bound exceeds the first-leg cap. The destination remains a direction
filter for station ordering; it is no longer used to justify an expensive
reachability search before the first pump. Short legs whose lower bound fits
the cap retain the direct on-device route fast path. The next device log
should include `fuel fast-path trigger reason=range-lower-bound` followed by a
`fuel fast candidate` and a committed pump, rather than
`fuel_window_budget_exceeded`.

The focused simulator verification after this change passed 51 tests across
FuelAssist, ItineraryBuilder, and the real V4 on-device benchmark suites. The
updated DIRT Dev app was built and installed on the authorized White iPhone
16 (UDID `B1A97A1C-5418-5143-9134-42260494B443`); automated launch was denied
only because iOS reported the phone locked.

## 2026-09-12 destination-escape deferral

The 21:27 White log also showed a separate destination-escape probe returning
the conservative full-tank value (`arrivalLimit=0`) before the first pump
search. That probe added up to 2.5 seconds and made a short or final leg enter
the same bounded planner that had just timed out. The pack source now defers
that probe and treats fuel as a sequence of local, route-proven pump hops. A
zero derived arrival cap is also ignored for the pack source's direct final-hop
check, while the original request value remains available to diagnostics and
legacy sources.

Checkpoint `12978df` adds the behavior and a regression test. The itinerary
suite passes 41 tests. The next White log should show
`fuel destination escape deferred source=pack reason=next-pump-sequence`, then
the lower-bound fast path and a committed pump; it should not show a 20-second
fuel-window fallback for a route that has stations in the installed pack.

## 2026-09-12 bounded pump qualification

The first bounded implementation used a 75% air-distance trigger for the
direct destination proof. That still spent a route search on four near-edge
windows after a pump (95–130 km of straight-line distance remained), even
though the Dirt graph could not carry those hops within 180 km. The result was
correct but took 14.8–15.8 seconds for the full NS itinerary.

The candidate now uses a 50% trigger for both the direct proof and the pack
fuel lower bound. A destination that is well inside half the remaining tank is
still proved directly; otherwise the planner immediately qualifies the next
forward pump. The phone path keeps a 16-station geographic cohort and proves
at most three local candidates, with a balanced connector fallback only for a
station approach that strict Dirt cannot legally reach.

Measured on the serial simulator with immutable `fabric-v4-20260909-01` NS
pack bytes:

| Case | Result |
| --- | --- |
| First fuel pump, NS Dirt | 1.13 s route proof; 20.9 km graph hop; proven pump |
| Full NS Dirt itinerary, 551.6 km | 6.62 s total; 9 proven pump stops; 10 built legs; final hop 0.26 s |
| Itinerary behavior tests | 41 tests passed |
| Pack acquisition/source tests | 19 tests passed |
| Fuel and real-pack benchmark tests | 13 tests passed |

There were no advisory or unverified fuel statuses in the full itinerary, and
the logs show only `source=pack` with no routing network request. The old
12-second assertion remains valid; the measured total is now below it by more
than five seconds. The candidate is ready for one authorized White-device
build and a physical NS pack confirmation.

The first NS→NB fuel-chain run then found a mapped pump whose forecourt was
outside the normal 550 m rider-pin snap radius. The planner correctly refused
to invent a route, but it stopped before trying the next pump. Pump approaches
now use the V4 tap-radius ceiling (2 km) while rider pins retain their normal
snap policy. This keeps the stop tied to a real nearby graph edge and lets the
candidate continue when a fuel POI is mapped at a driveway or forecourt.

The current NS→NB pack integration now completes with the seam and fuel chain
together:

| Case | Result |
| --- | --- |
| NS→NB Dirt, automatic fuel | 11.45 s total; 11 proven pumps; 12 built legs |
| First cross-region pump | 1.21 s; 78.3 km graph hop; 19 m endpoint gap |
| Seam crossing | 0.91 s; 72.4 km graph hop; 1 canonical seam attempt |

No advisory fallback or unverified tail was emitted. The test uses only the
current NS and NB pack bytes and remains serial on one simulator destination.

Checkpoint `801e20a` contains the bounded forecourt snap and the NS→NB fuel
integration regression. The corresponding White build is version 2 (15),
installed from `/tmp/Dirt-EngineArchitecture-DeviceBuild8` on device
`B1A97A1C-5418-5143-9134-42260494B443`.
