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

## Routing pause communicated by its owner task

Richard paused Routing Final Refinement implementation/testing for a discussion
of engine complexity, scoring, boundaries and speed. That agent's changes are
isolated and uncommitted; no preview or publication occurred. Do not deploy,
incorporate or test those changes while paused. The separately authorized pack
build continues. At this check PID 74411 remains active, six regions verified,
California has constructed its graph and is still processing. Free disk is
about 11 GiB during this large build; the resource constraint remains open.

## 16:41 UTC status and recovery

User requested an overdue update. Found 44/58 verified, through Pennsylvania;
initial process had stopped at 15:31:21 UTC before Rhode Island because only
15.7 GiB was free against the unchanged 16 GiB floor. No completion or live
publication occurred. Free space recovered to about 19 GiB; resumed the exact
saved command from the same detached factory commit, PID 13440, recorded in
run.json. Completed outputs are reverified and reused. Rhode Island extraction
and graph processing are active. Fourteen regions remained at restart.

Created thread heartbeat `track-national-live-pack-rebuild`, every 15 minutes,
to catch meaningful progress, interruptions and completion and continue the
authorized pack workflow. This replaces reliance on user prompts for status.
Full national assembly, cross-border checks and live DEV publication remain
outstanding; do not call the 44 local artifact passes live acceptance.

## 17:11 UTC heartbeat

Found 50/58 verified through Texas. Build stopped at 16:50:57 UTC before Utah
at 15.7 GiB free; no process remained. Space recovered to 19 GiB, so resumed
the unchanged command/factory as PID 23934. Utah subsequently verified (51/58)
and Virginia started. Existing disk floor and sealed outputs preserved.

Prepared candidate03/assemble-national.cjs (syntax checked, not yet executed).
After all 58 complete, run it from the fixed factory checkout using Node. It
reverifies all new outputs against the fixed factory commit, copies the accepted
five with unchanged data and original provenance, regenerates all national
border/ferry records, verifies all 63, and seals release.json for upload. It
refuses incomplete progress and does not publish anything. Capture output to
assembly.log. Then use the existing ship-v4-candidate.js --root candidate03
--candidate fabric-v4-20260908-03 --pack --verify workflow for versioned R2
publication/readback, before live activation and runtime connection checks.

## 17:28 UTC heartbeat — all regional builds complete

All 58 regions verified at 17:17:51 UTC. National assembly began. It exposed an
incorrect validation requiring even registry-isolated HI/NU to have a neighbor.
Fixed coverage validation in dc04086; all five seam tests pass, including rejection
of missing required neighbors. No graph bytes, OSM records or legal rules changed.

Fixed factory checkout remains a4589c2 for verifying all 58 build provenances.
Connection assembly uses separate detached .build/national-live-assembly at
dc04086. Candidate03/assemble-national.cjs now points to that seam builder and
records assemblyCommit separately from factoryCommit. Assembly resumed PID 32778;
check assembly-run.json and assembly.log. Initial failed stack trace remains in
the appended log as evidence. No national live publication yet.

## 17:56 UTC heartbeat — national serialization limit

The assembler completed the expected pair loop, generated all regional seam
sidecars, then failed JSON.stringify of the indented full national index with
RangeError: Invalid string length. Regional sidecars total about 513 MiB; the
national representation adds indentation beyond JS's string-size limit. No
missing pair or legal-proof error was reported by this run. Publication has
not happened.

Assembly-only commit 9ace710 writes the national index as compact JSON,
preserving all fields/records. All five seam tests pass. Detached assembly
checkout advanced to that commit; fixed road factory remains a4589c2. Rerun
started, current PID in assembly-run.json, log appended to assembly.log.
Do not claim live acceptance from these data checks. Urban population-scaled
boxes were separately identified to Richard as derived approximations embedded
in metadata; no urban/routing alteration is authorized or included by this run.

## 18:12 UTC heartbeat — assembled, upload started

National assembly passed: all 63 regions verified, 138 adjacent region pairs.
Preserved five data hashes match accepted02. Release03 is now locally sealed.
Started ship-v4-candidate.js --pack --verify with 6144 MiB heap; current PID
46623 and saved command in upload-run.json, output upload.log. This publishes
only versioned DEV candidate objects and reads them back; stable alias and
phone/download catalogs are unchanged. Verify actual process, per-object
verification lines and final summary before claiming upload completion.

National compact audit topology is 336 MiB. Before live deployment, address
its deployment size deliberately: do not blindly copy the full audit JSON into
the current 3.8 MiB bundled index location. Preserve complete audit data on R2;
any runtime projection or loading change must retain all candidate connections,
coordinates, source identities and direction/access semantics and be verified
against the full index. This is pack-delivery integration, not permission to
incorporate the other agent's paused routing algorithms. No live qualification
yet; runtime border tests remain outstanding.

## 18:33 UTC heartbeat — upload progressing and service index prepared

Upload PID 46623 active, 43 verified objects at check, California multipart
geometry uploading. No upload failure at this check. Continue until final
verified summary; do not restart an active upload.

Prepared isolated .build/national-live-service from b3cb2fa, with a compressed
runtime projection retaining every one of 770,848 connection rows. All 138 pairs
compared in both directions under both access settings, allCandidates=true:
552 full deep-equality selection comparisons pass against the full audit index.
Projection 123,704,776 bytes JSON / 9,818,275 bytes gzip; loader readback 63 regions,
138 pairs. Evidence candidate03/runtime-index-verification.json and script
prepare-runtime-index.cjs. No paused routing algorithm changes included.
Worktree integration doc describes exact retained fields and remaining gates.

Richard reiterated stable DEV activation after all verification. Still pending:
finish R2 upload/readback, deploy isolated national service preview with all63
regions/03 overrides and empty connection revision, run live connection and
canary checks, coordinate stable alias activation. Production/downloads unchanged.

## 18:50 UTC heartbeat — preview preparation while upload continues

Upload PID 46623 active, 70 VERIFIED objects, Florida graph multipart underway.
Started isolated national preview deployment PID 61058 from ef34451 (b3cb2fa
routing plus verified compressed national index), with all63 region IDs,
candidate03 base overrides, empty connection revision and chain cache enabled.
No stable alias change. Preview is
https://pack-fabric-dfwc961be-goricksmith-7678s-projects.vercel.app
(check deploy-preview.log for READY before testing). Saved preview-run.json and
preview-url.txt. Regions not yet uploaded are not testable against this preview;
do not confuse their missing candidate objects with pack failures. Test already
verified uploaded regions first, then all required national boundaries and
accepted canaries after full upload. Routing task informed; no paused changes
incorporated. Full stable activation remains gated by readback and live checks.

## 19:07 UTC heartbeat — early live checks

Upload PID 46623 active, 105 verified files, Illinois graph multipart underway.
Ran six read-only preview road requests against ef34451 and uploaded03 regions.
AB–BC and reverse both complete and report both pack identities (297,422 /
296,538 m); command wall times ~25/27 seconds include CLI overhead and are not
an app latency measurement or route-quality acceptance. AK/BC near Hyder–Stewart
both complete (~4.4 km) but report BC only: these are halo-covered geographical
border crossings, NOT proof of an actual AK/BC pack handoff. Need another
cross-country test sufficiently outside the shared coverage before qualification.
AL–GA both directions were still running at this note; inspect live-al-ga*.json
and logs for final result. Inputs/results are candidate03/live-* files. No
stable alias change, no production/download activation.

AL–GA and reverse returned no response within the 60-second transport limit
(curl exit 28). These are FAILED early live checks, not accepted connections.
Inspect preview runtime logs before repeating; requests may continue server-side
up to configured function duration. Stable activation remains blocked on
understanding/resolving this and completing required live coverage.

## 19:24 UTC heartbeat — live memory failure isolated

Upload still active, reached 162 verified files during this turn. Preview logs
runtime-1924.ndjson explicitly show Vercel killed both AL/GA calls for out-of-memory.
The full projection being resident was an avoidable national lookup allocation;
region road/geometry records were not reported missing. Do not call this fixed
until replay passes.

Integration b349c47 splits the identical projection into 63 gzip files loaded
on demand with three-region retention. All regions equal the prior projection
on two passes (126 comparisons), including cache eviction/reload. Earlier 552
full-audit selection comparisons remain applicable. New preview is READY:
https://pack-fabric-f5at3mn6k-goricksmith-7678s-projects.vercel.app
Deployment record preview-lazy-run.json / deploy-preview-lazy.log. Replays of
AL/GA and reverse started, output lazy-al-ga*.json/log. Inspect their results
and serviceBuild before claiming success. Stable DEV remains b3cb2fa/02;
old preview ef34451 is not eligible for activation.

Both previously OOM AL/GA requests now complete on b349c47: forward 2,008 m,
reverse 1,754 m. This verifies those failing live requests after the lookup
memory change, not all national routes. Broader live coverage and upload
completion are still required before stable activation.
Both AL/GA replay identities are GA-only halo coverage, so retain a separate
requirement for a genuine two-pack state/state handoff outside shared halos.

## Routing task resumed — coordinated canary publication

Routing agent reports Richard authorized replacement implementation to proceed
until a physical test is available, superseding its earlier pause. Its isolated
worktree is .build/routing-rebuild; it is preparing a single-region preview.
I confirmed stable GET still b3cb2fa/accepted02. Directed that agent to use this
accepted five-region data, not incomplete03, and send exact verified preview,
commit/config/results before coordinating a stable move. National ownership
remains here. Once a new routing canary is approved/published, preserve that
baseline during later national activation; do not overwrite it with old b3cb2fa
algorithms just to publish03. Current national preview remains b349c47/03 and
not stable-qualified. Upload still active through Michigan. No stable change
made by this coordination message.

## Routing canary preview awaiting final supplemental checks

Routing task submitted READY preview
https://pack-fabric-42ltrerz7-goricksmith-7678s-projects.vercel.app
(source ecf746ef8497df49c996c0853fe84743de331f7f), using accepted02 five-region
environment plus DIRT_ADVENTURE_CANARY=ns-v1. Agent reports three app-compatible
fuel requests passed with correct NS02 hashes. It is still checking shorter
range and /route; requested non-canary/cross-province fallback evidence and
precise provisional fuel-access limitation. Do NOT alias yet. Await that final
message, then coordinate exact-preview stable alias/readback/smoke. Preserve
this canary baseline during eventual03 integration; do not publish b349c47 over
it. No stable change occurred in this coordination turn.

## Stable DEV routing canary published — new baseline

After routing agent's final supplemental/fallback checks passed, aliased exact
preview42ltrerz7 to pack-fabric.vercel.app. New stable source is
**ecf746ef8497df49c996c0853fe84743de331f7f**, accepted02 five-region settings plus
DIRT_ADVENTURE_CANARY=ns-v1. Public GET readback and app-compatible Balanced fuel
smoke both confirm exact source. Fuel response complete, 2 stops, NS02 accepted
hashes; per-stage distances 229512 / 257324 / 13908 m within270km. Evidence
stable-canary-health.json and stable-canary-fuel.json. Routing agent notified to
independently check public endpoint and hand off physical review. Fuel access
and current operation remain unverified; this is route-building review only.

IMPORTANT: national preview b349c47 is now an older algorithm baseline; do not
alias it over this canary. Integrate national lookup/config onto the current
verified canary source, coordinate its NS02-only eligibility versus identical
preserved NS bytes under03 before activation, and rerun checks. National03
upload/verification is still separate and NOT activated. Production/downloads
unchanged.

Routing agent independently confirmed public stable Dirt/Balanced/Clean pass,
3/2/1 stops, bounded contiguous hops and NS02 identities. IMPORTANT confirmed
eligibility guard: live-canary.js explicitly requires fabric-v4-20260908-02;
changing NS URL to03 would disable replacement and use old engine even with
ns-v1. Preserve NS02 for current physical review. Before national activation,
either retain that accepted per-region override with truthful identity and
validate mixed release connection compatibility, or coordinate and qualify
an explicit guard update. Do not loosen guard or silently switch behavior.

## 20:04 UTC heartbeat — combined current canary + national preview

Upload PID46623 active;294 VERIFIED objects through NY, Ohio underway.
Prepared .build/national-live-canary from EXACT stable ecf746e, cherry-picked
only national lookup integrations. Combined source0365c5f9f29c036f5ce571549f2580f3263d6529.
All3 live-canary gate tests pass. Preview deploying (preview-combined-run.json,
deploy-combined.log). All63 enabled, NS override retains accepted02, other62
use03; ns-v1 enabled and connection revision empty. No canary guard relaxation.
No later unverified routing agent HEAD incorporated. Stable still ecf746e/02.

Next: once preview ready verify exact source and app-compatible NS canary,
then genuine state/state and province/state requests beyond shared halos,
e.g. AL/GA points farther from border and BC/ID regional towns; assert response
contains both region identities rather than counting a halo-only success.
Continue uploaded-region checks while upload finishes. Final publication must
use combined canary baseline, NOT old national-only b349c47.
