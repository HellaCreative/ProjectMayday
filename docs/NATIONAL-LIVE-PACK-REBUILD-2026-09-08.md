# National live pack rebuild — September 8, 2026

Richard authorized rebuilding the remaining Canada/U.S. packs for live testing,
with particular attention to province–province, province–state and state–state
connections. Downloadable activation and phone installs are deferred until live
acceptance. Actual production remains outside the authorized DEV publication.

## Running build

- Candidate: `fabric-v4-20260908-03`.
- Build started: September 8, 2026; precise timestamp and process ID in `run.json`.
- Initial process ID: 74411. Check the process and log before claiming it remains active.
- Fixed factory worktree: `.build/national-live-factory`, detached at `a4589c2`.
- Source epoch: `geofabrik-capture-20260907T123015Z`, same locked source used for the accepted canaries. Each extractor verifies its source hash and timestamp before use.
- 58 regions rebuilding: AB, AK, AL, AR, AZ, BC, CA, CO, CT, DE, FL, GA, HI, IA, ID, IL, IN, KS, KY, LA, MA, MB, MD, ME, MI, MN, MO, MS, MT, NC, ND, NE, NH, NJ, NM, NT, NU, NV, NY, OH, OK, ON, OR, PA, RI, SC, SD, SK, TN, TX, UT, VA, VT, WA, WI, WV, WY, YT.
- Preserve accepted NS, NB, PE, NL and QC graph, geometry, fuel and service bytes from `fabric-v4-20260908-02`.
- All 58 source paths and sizes and administrative polygons passed preflight. First active build is Alberta; service extraction completed and road extraction began before handoff.

Evidence and live process log:
`scripts/pack-fabric/routing/candidates/fabric-v4-20260908-03/{run.json,build.log,progress.json}`.
Progress is written after each region verifies, so an absent progress file while
Alberta builds does not mean the job never started. Build process runs independently
of the chat. Do not run another factory against this candidate concurrently or
change the detached factory checkout while it builds.

## Verification and publication sequence

1. Finish each region using the frozen factory. Verify graph/geometry/fuel manifests, legal topology and source identities, and campground/lodging/liquor outputs. Preserve lossless encoding; never trim source records or legal rules to meet a size target.
2. Assemble all 63 regions using the exact accepted five outputs and new 58 outputs, preserving honest per-region factory provenance. The current 58-region build deliberately produces a partial release and DOES NOT generate the final national seams or publish it automatically.
3. Generate full national border/ferry records and verify each expected adjacent pair, including both directions and all three requested border categories. Stored shared-road evidence and actual live route connectivity are separate checks. Nonadjacent journeys must traverse appropriate intermediate packs; do not invent a direct border.
4. Upload the complete versioned DEV candidate to R2 and verify readback identities before directing stable DEV to it. Coordinate with Routing Final Refinement so its service deployment does not replace this release's region configuration. Current stable DEV remains on the accepted five-region release until qualification.
5. Run live connection checks across varied locations, road directions and representative long chains. Distinguish data faults from the documented live crossing-selection defect. Provide physical live tests to Richard; do not call national acceptance from artifact checks alone.
6. Create/activate the downloadable release only after Richard accepts the live results. No phone downloads or installations during this run.

## Resource handling

Initial disk space is about 20 GiB; factory enforces its existing 16 GiB floor
before each region and deletes only verified per-region generated intermediates.
Do not lower that floor to force progress. If space interrupts the run, identify
reclaimable generated scratch files explicitly, preserve locked source PBFs and
sealed accepted releases, and resume verified regions without rebuilding them.

## Routing agent boundary

Prompt: `docs/ROUTING-FINAL-REFINEMENT-PROMPT.md`.
The build is now underway, so the separate routing agent may investigate and
implement live JS refinements within its isolated worktree. It must not change
factory inputs or outputs. Known fuel failure near Montreal belongs to live
border endpoint selection; no pack-factory alteration was established by that
investigation. Routing corrections must not silently become factory changes.

## 14:54 UTC progress and resource check

Six regions verified: AB, AK, AL, AR, AZ, BC. California is actively building.
Disk fell below the between-region 16 GiB floor while California held about
5 GiB of active extraction scratch. Rechecked graph/geometry/fuel/seam hashes
for all available accepted Atlantic/Quebec candidate outputs, then removed
only their old generated legal/services scratch (about 2.9 GiB). All locked
source PBFs, sealed outputs and California's current work are preserved.
Cleanup record: candidate03/canary-scratch-cleanup.json. Disk remained about
14 GiB during the active build; do not describe the resource constraint as
fully resolved. California scratch should be reclaimed by the factory only
after its output verifies, and the existing floor still applies before the
next region.

Routing Final Refinement reports the shared seam-membership selection fault
reproduced and corrected locally, with 65 targeted tests and 18 regression
requests passing; long reverse routing remains under investigation. No new
routing preview has been accepted or deployed by this task.
