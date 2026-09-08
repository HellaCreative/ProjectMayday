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

## Still required before offering this as an iPhone canary

Check source-to-pack road/access/dirt details, fuel and layers; exercise internal
Nova Scotia journeys; validate the Swift reader against these exact packs; ship
and verify a matched DEV canary and install it on the phone. Do not claim a
finished product from the eight crossing results. Quebec follows Atlantic
physical acceptance, as Richard requested.
