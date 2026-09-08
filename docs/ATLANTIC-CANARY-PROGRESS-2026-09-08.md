# Atlantic pack repair progress — September 8, 2026

## Current result

Local rebuilt packs complete eight basic crossing checks: Nova Scotia/New Brunswick,
New Brunswick/PEI, Nova Scotia/PEI, and Nova Scotia/Newfoundland, in both directions.
The original packs failed PEI → New Brunswick, PEI → Nova Scotia, and Nova Scotia →
Newfoundland for these requests. This is not physical acceptance, pack qualification,
or proof of Dirt/Balanced route quality. The first rebuilt NS → NB request took
12.6 seconds; the other seven took 0.1–0.6 seconds. Speed remains unresolved.

## Confirmed source translation fault

OSM toll collection nodes were converted to closed barriers by the shared V4
factory. Edges touching those nodes then lost their travel directions. Source
records include PEI nodes 1923039171 and 315017549, and North Sydney nodes
11401496412–11401496415. The source tags describe toll booths, without an explicit
closure in the records inspected. Compression did not cause this conversion.

Factory commits 2fb1b7b and ae8aa94 preserve passage through toll booths, including
explicit access=yes / motor_vehicle=yes. Explicit denial, locked, conditional,
and destination/customer-only cases do not gain unrestricted through passage.
The source-to-compact-pack tests cover roads, service roads, and ferries in both
directions. All 19 legal-topology tests pass.

## Reproducible local evidence

Candidate: scripts/pack-fabric/routing/candidates/fabric-v4-20260908-01.
It contains only NS, NB, PE, NL, built from the existing hash-locked source set.
Original candidate fabric-v4-20260907-01 is retained.

Evidence: scripts/pack-fabric/routing/candidates/atlantic-canary-20260908/evidence.
The original and rebuilt requests/results, summaries, integrity report, rebuild
log, and replay.cjs are retained there. Replay uses the build-20 recovery source
reader with local graph overrides and the rebuilt connection index. It does not
use the unfinished route experiments in the main working tree. This is a local
reader check, not a live-service or phone check.

The connection builder now accepts an explicit region subset and retains all
proven connections within it. Four connection-builder tests pass. The rebuilt
Atlantic connection index contains NB/NS, NB/PE, NL/NS and NS/PE. The release
remains labelled a partial local candidate, not a complete 63-region release.

## Current live handoff and fix tracking

Live DEV now uses source 7848ba6332da26d72b9070d5efd75d880db91629 at
https://pack-fabric.vercel.app. The verified deployment is
pack-fabric-5syq91ji0-goricksmith-7678s-projects.vercel.app. Its four Atlantic
regions use fabric-v4-20260908-01, including fuel and Rider Services.
All 33 candidate objects were uploaded and read back with matching checksums.
The three formerly failing crossing directions passed hosted preview checks.
Stable results are recorded in the evidence folder as *-stable.json and
stable-summary.json. Speed remains an open issue, as does dirt-route quality.

| Fix | Change | Evidence | Rider result |
| --- | --- | --- | --- |
| ATL-01 | Preserve OSM passage at toll collection points | Source tags, compact-pack tests, original/rebuilt crossing results | Richard reports toll/ferry pass; route quality excluded |
| ATL-02 | Retain every proven Atlantic pack connection | Four connection-builder tests and hosted crossing checks | Richard reports crossing pass; route quality excluded |
| ATL-03 | Select a reachable arrival before declaring a fuel gap | Exact failure replay; New Brunswick pump selected with low remaining fuel; 41 tests | Pending live retest |

This is now a LIVE-ONLY repair cycle per Richard's explicit direction. Swift
work and offline acceptance are deferred until live behavior is accepted. Track
subsequent JS changes here for later parity; do not make parity work delay live
tests. Quebec follows Atlantic acceptance.

Before Richard's stop instruction arrived, build 21 was installed on the white
iPhone and the four candidate packs were copied into its application cache.
The app was not launched by the agent. No further phone operation was performed
after the instruction. The existing routing policy chooses live when online,
regardless of whether packs are installed. No Swift routing behavior was changed
in build 21; its configuration points to the Atlantic candidate.

Test with internet connected: the four Atlantic connections in both directions,
then a familiar Nova Scotia Dirt route with unknown access off/on. Send the app
debug export and comments on failures, calculation time, and unexpected roads.
The dirt comparison is an observation of current behavior, not a claim that dirt
selection is repaired.

## ATL-03 live repair handoff

The two physical exports supplied by Richard on September 8 are the evidence
for the reported Atlantic crossing acceptance, with the remaining automatic-fuel
failure near the NS/NB boundary. NB fuel records were present. Fuel planning
selected an unreachable one-way arrival in the Nova Scotia part of the crossing
and declared a gap before advancing to NB.

Live fix 7848ba6 reuses the directed reachability search to choose a reachable
arrival among the existing legal snap candidates. Same pack files, permissions,
snap radius and fuel range. An exact replay now completes. With 50 km remaining
on that same approach, the planner selects Aulac Circle-K Irving in NB; with
333 km remaining it crosses without an unnecessary stop. Both passed hosted
preview checks. Forty-one fuel-planning tests passed.

Source and detailed evidence are in .build/atlantic-live-fuel on branch
recovery/atlantic-live-fuel, under scripts/pack-fabric/routing/candidates/
nb-fuel-20260908. This directory is an isolated checkout inside this repository
folder. Main's unfinished routing experiments were not deployed. Swift/phone
changes: none. Await Richard's same-route live retest with automatic fuel on.

Stable DEV checks completed on 7848ba6: original failed fuel request completed
in 3.66 seconds; the 50 km remaining-fuel case selected the NB station in
2.25 seconds. The live Balanced approach to that selected station also completed
at 41,282 m, within the 50,000 m remaining range. These are service checks;
Richard's app retest remains the acceptance step.

## Physical acceptance update — export 2026-09-08T124852Z

Richard confirms routes between all Atlantic provinces work both with and
without automatic fuel stops, including the corrected fuel planning. All
toggled layers were visible. Route quality is explicitly excluded from this
acceptance. The export records live service 7848ba6 with the same Atlantic
fabric-v4-20260908-01 objects. ATL-03 is accepted for this reported outcome.

One-way highway travel, correct use of ramps/underpasses, and no invented
connections where roads cross at different heights remain to be checked.
Passing those checks does not trigger another Atlantic rebuild. Rebuild only
if the pack data itself needs correction; fix live code if it misuses correct
data. Quebec and the remaining original packs are not qualified by this update.
