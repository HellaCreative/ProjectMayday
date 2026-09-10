# National live pack rebuild — September 8, 2026

Richard authorized rebuilding the remaining Canada/U.S. packs for live testing,
with particular attention to province–province, province–state and state–state
connections. Downloadable activation and phone installs are deferred until live
acceptance. Actual production remains outside the authorized DEV publication.

## Current status — September 9 DEV activation underway

- Richard authorized all 63 regions LIVE in DEV and downloadable in DEV, preserving frozen routing. Earlier live-only/download deferral is superseded.
- Candidate `fabric-v4-20260909-01` completes the metadata correction from sealed03. All63 locked OSM place extracts and regional revisions passed local checks; roads/legal/geometry/fuel/services preserved. NS graph unchanged; NB exact accepted supplemental areas embedded once.
- Isolated worktree `.build/national-dev-release`, frozen routing base f2da612. 223 local tests pass and six accepted itinerary geometries/fuel-stop identities match exactly. National connection/fuel ownership data integration retained.
- Full immutable upload/readback is RUNNING; use candidate01 upload-run.json/upload.log and priority Atlantic upload log. Do not restart an active uploader. Live alias remains f2da612 until qualification.
- Remaining: hosted file and border checks, stable DEV activation, coordinated AppConfig catalog URLs with the app agent, and download identity verification. No phone install or automatic transfers; no production.
- No further cache cleanup: earlier cleanup removed dependency cache files from the app agent's active DerivedData folder. Agent informed; it is restoring packages. All source/OSM/sealed packs/test records preserved.

## Original build setup

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

## Build22 physical regression fixtures received

Routing agent reports NS canary physically fast/good with fuel. Export
/Users/richardsmith/Downloads/dirt-app-debug-2026-09-08T200606Z.txt records QC
fuel match_failed in segment2/3 and US fuel timeout / road safety-limit failure.
Exact inputs reconstructed in candidate03/build22-{qc,us}-{fuel,route}-request.json.
Keep these in combined acceptance checks, in addition to generic border cases.

Confirmed MA destination42.42887651518565,-72.66903969731547 is selected as NY
by primaryRegionForPoint and resolveGraphRequest with a single point. /api/fuel
calls fuel-data.loadFuelForLocations -> resolveGraphRequest directly, whereas
route uses regional/endpoint-resolver. This coarse ownership mismatch explains
NY fuel data and is not corrected merely by enabling03. Routing agent notified
to coordinate fix ownership before either task edits shared fuel selection.
No such fix deployed yet. BC/ID reverse result is complete on0365c5f; forward
FUNCTION_INVOCATION_FAILED remains an open failure.

## Separate NS/NB acceptance preview

Routing owner supplied reviewed2d4e394. Created isolated .build/atlantic-acceptance-preview from b9f263d and cherry-picked to94597816b960b3baeb33cf008340700d8a3589ae; git diff against2d4e394 empty. Preview https://pack-fabric-74jbm96f6-goricksmith-7678s-projects.vercel.app READY. ns-nb-v1 enabled; all five stable regions retain02, no national03 integration. Stable alias unchanged. Cross six-case live fuel verifier running; results in candidate03/atlantic-acceptance-live. Routing owner independently checks NS baseline. National upload continues separately (379 individual files verified, TX graph verified at latest snapshot).

Single-point fuel national correction b090ac2 is isolated in national-live-canary and not included in this acceptance preview. It adds existing complete63-region boundary record and admin ownership for single-point pump lookup;11 focused local tests pass, hosted verification pending.

### NS/NB acceptance live on stable DEV

All6 hosted cross-profile/direction fuel checks passed. Server times forward Dirt15.339s, Balanced5.807s, Clean5.601s; reverse Dirt5.904s, Balanced5.864s, Clean13.449s. Routing owner independently verified exactNSbaseline3profiles, NB-only andAllowUnknown crosschecks. Preview error-level logs30min returned no entries. Aliased exact74jbm deployment/source94597816b960b3baeb33cf008340700d8a3589ae to pack-fabric.vercel.app; public/api/route confirms source and ns-nb-v1. Stable keeps all5regions02; no national03 activation. Routing owner will independently verify public routing and coordinate physical handoff.

Activation guard: preserve BOTH NS02 and NB02 with current stable945978/ns-nb-v1 during physical acceptance. Old national preview0365/b090 source must not replace current stable. Next national integration must incorporate reviewed current routing and retain both overrides. Recorded candidate03/national-activation-guard.json. Routing owner independently confirmed public crossUnknown success, fullwindow/range/escape/geometry, source945978.

City-classification completeness gap found:62/63 national candidate graphs have null urbanCores/settlements, NS alone populated. This feature was not established by prior verification. See NB-URBAN-CLASSIFICATION-INVESTIGATION-2026-09-08.md. No live/pack change; national candidate not qualified for city-avoidance completeness.

## National upload completed; separate refinement preview ready

Upload final summary: candidate03 regionCount63, objectCount446, verifiedtrue, productionUntouchedtrue. All component objects uploaded and exact readback verified, including full national topology. This establishes publication/integrity, not city-classification completeness or national live activation. City metadata omission62regions remains open.

Isolated refinement preview https://pack-fabric-dnwrkggyn-goricksmith-7678s-projects.vercel.app READY, source0e26691098ed6289ee3e85222488532c881ad221 (945978 plus reviewed464864f+a13f820). Worktree atlantic-refinement-preview. NB sidecar exact SHA f0ff6558341b52ea7a869458c709aba8872808677445dc5e1c8bb81e1d989b9f verified. Prior five02/ns-nb-v1 env preserved. Ten focused integration tests pass locally; routing owner runs exactphoneClean/Dalhousie hosted replay. No stable alias change.

Preview0e266 withheld: hosted geometry/fuel passed but Dalhousie used20s with6optional trials. Reviewedcd1dcd04 narrows to one shared trial. New isolated preview https://pack-fabric-mpatek5gc-goricksmith-7678s-projects.vercel.app READY, source6ace2323f6a6051a9f3761db55973d7548fc087e; service subtree equals routingowner cd1dcd04, unchanged5regions02/ns-nb-v1. Devicecase hosted timing verifier running under candidate03/atlantic-bounded-device-live. Stable945978 preserved pending results.

Bounded preview6ace232 hosted devicecase verifier passed: Dalhousie15.456sserver,958.049km72.34%dirt4.095kmrepeat4stops; Clean7.572sserver704.381km3stops. Bothcompletewindow/range/escape/geometry and02 identities pass. Clean still391.296kmprimary+106.955kmtrunk; not backroad-quality acceptance. Evidence atlantic-bounded-device-live. Routing owner notified; stable unchanged.

Stable DEV now exactmpatek5gc/source6ace2323f6a6051a9f3761db55973d7548fc087e after routingowner6hostedcross pass,24localmatrix pass andNS3exactbaseline. Publichealth confirms source/ns-nb-v1. BothNS/NB02 andotherstable02 overrides retained, no national03/prod/phone action. Scope fuel-detour retest andCleanrequestgate; Cleanbackroadquality remainsopen, coldDalhousie15.456s. Routingowner independently verifies publicroute and provides existingbuild23 handoff.

Reviewed routing86f3c02 integrated onto stable6ace232 in isolatedpreview asdf0827e60e9c04a625fd3b3155fae87220c93113; runtime/API exact to86f3c02, doc history conflict preserved. Previewoi3q1ndqg deploying with unchanged5regions02/ns-nb-v1.28localresource/livecanary checks pass. Routingowner owns4case hostedtiming verification; no alias move. This responds to movedwaypoint physicalfailures, not a packmutation.

Stable DEV now exactoi3q1ndqg/sourcedf0827e60e9c04a625fd3b3155fae87220c93113 after routingowner4actualhostedcases+criticalshortreverse,24localcases,8pinsweep,166unitchecks and finalNS comparison. Publichealth confirms source/ns-nb-v1; nationalguard updated. BOTHNS/NB02 retained; no production/phone action. Routingowner independentlypublicreplays failedmovedpin before handoff.

Immediate rollback: routingowner lateNB-only24matrix exposed162kmunknownforward dirt-30 label_limit200k, selectedDirt48%. Restored exactmpatek5gc/source6ace232 tostableDEV; publichealth verifiedsource/ns-nb-v1, BOTH02 retained. df0827 remainspreview only, physicalhandoffheld. Previouscrosschecks did not establish NB-onlyqualification. No production/phone action.

Privatebudgetcandidate reviewed05eecb0f cherry-picked ontodf0827 as67425f53c32f26bf81911331931462389205bc2b; runtime/API exactmatch. Preview5bnn5yit5 deploying, same5regions02/ns-nb-v1.7focusedlivecanary tests pass including incompletepool diagnostic. Routingowner verifies criticalNBshort then4actualcases; stable6ace232 held. Completedsearch does not resolve separate48.49%dirt qualityflag.

Stable DEV now5bnn5yit5/source67425f53c32f26bf81911331931462389205bc2b after routingowner criticalNB162unknown hostedall6candidatescomplete,4actualhostedcases,24NB400kand24crossmatrix plus167tests. Publichealth confirms source/ns-nb-v1; guard updated, BOTH02/env unchanged. NBshort48.49%dirt remainsqualityflag evenwhenallsearchescomplete. Routingowner publicverifiesbeforephysicalhandoff. No prod/phone action.

## BC/ID500 root cause confirmed —22:21UTC follow-up

ExactVercellog requestcq6zh-1788898062190-d5ef00326c8e onoldcombinedmx6lycw8s/source0365c5f reports instance killed because it ran out of available memory. Reverse60704m complete uses actualID03+BC03 identities, not single-pack halo. This500is a confirmed service resource failure; forward crossing remains unqualified. No routing or pack changes made; lateststable67425 remains protected. Evidence bc-id-failure-diagnosis.json plus originalrequest/response.

Privatecontinuitypreview9c15324e6ace23df668c6061e2d4ba2a04b99bc8 =stable67425+reviewedd14a5a7; runtime/API exactmatch. Previewr2w1bfpj7 deployingsame5regions02/ns-nb-v1.5continuitytests pass locally. Routingowner runs exactNSshortdiversion andregionalhostedchecks. Stable67425 andBOTH02 unchanged; no packmutation.

StableDEV nowexactr2w1bfpj7/source9c15324e6ace23df668c6061e2d4ba2a04b99bc8 after routingowner6hostedcases passed(allcandidatefuelcomplete,range,escape,geometry). Publichealth confirms source/ns-nb-v1. BOTH02/env unchanged;guardupdated;no prod/phone actions. NSshortdiversion559.326km68.061%dirt0repeat3stops9.591s; joined7.5–15.1s remainslatencyflag. Cleanbackroads andCapeUnknown4.962kmrepeat remainopen. Routingowner independentlypublicverifies NSrequest beforehandoff.

PrivateCleanpreview6d61061e2e0c51a48f5f389a5743d68e9a4549a3 =stable9c15324+reviewed44c482a4; runtime/API exactmatch. Previewix86t3csj deploying same5regions02/ns-nb-v1.3localpavedbackroadtests pass. Routingowner handleshostedverification; stable9c15324 andBOTH02 retained. No packmutation.

Cleanpreview6d61061 withheld after hostedNS pavedcandidate label_limit. Newreviewed9ab7e485 applied as8be23e95a91c7ebe8a02bf20a6917f57ad42a4b7 with runtime/API exactmatch; conflictedbenchverifier replaced with exactreviewedsource. Sameenv/BOTH02/ns-nb-v1, stable9c15324 preserved. Newprivatepreviewdeploying; routingowner verifiesNSClean plusactualcases.

StableDEV activatedexact1krqzezwv/source8be23e95a91c7ebe8a02bf20a6917f57ad42a4b7 after routingowner6hostedchecks +175focused/48regional; checkedDirt/Balancedgeometry/stopsunchanged. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved. NBactualClean955.802km99.999%paved0repeat4stops;primary/trunk199.020km vs497.986baseline. NSClean757.037km99.88%paved0repeat3stops.162kmreversecrossClean2.104kmfuelreturn remainsflag; qualityawaitsrider. No production/phone changes; routingowner independentlypublicverifiesClean.

## Updated national private integration —23:15UTC follow-up

Created .build/national-current-preview from accepted8be23e95, plus existing verifiednationalindex50200f0/0365c5f andfuelownershipb090ac2, yielding2938ed55755cf9212975b8f56330dddc48e19ebf. Preview https://pack-fabric-nmrvgdxix-goricksmith-7678s-projects.vercel.app READY. All63regionsenabled; BOTHNS/NB02+ns-nb-v1 protected, otherregions03. No stableactivation orreplacementengineexpansion.15focusedfuel/boundary/canarychecks pass.

Hosted/api/fuel exactMAdevicepoint nowMA03 with2446stations; NS02 returns671, NB02 returns705. Allresponses exactsource2938ed5 andfuelSHA matches sealedlocalbytes. Thus wrongNYselection corrected privately; fuel-routeplanning and nationalacceptance not claimed. Evidence national-current-fuel requests/responses/summary.json; deploy config national-current-deploy-run.json. Citymetadata gap and nationalresourcequalification remainopen.

23:33UTC nationalprivatecheck: source2938ed5 BC->IDcomplete60748m23.58sHTTPincludingCLI, reverse60704m3.53s. BothactualBC03/ID03graph/geometryidentities matchsealedbytes (forwardSHAasserted); nothalo. EarlierOOM not provenfixed bysingle successfulpair, firstlatencystillopen. Evidence national-current-bc-id-{response,reverse-response,summary}.json. No stable/packchanges.

Privatefinalfuelpreview edc55fdb42af4bb3c4dd6972ecdaabf8e4ba88c5 =stable8be23+reviewedfa08b4e; runtime/API exactmatch. Preview3wcw1w2vh deploying,same5regions02/ns-nb-v1.34fuel/resource tests pass. Routingowner hostsnewfinalfuelregression;stable8be23 unchanged. No nationalactivation/packmutation/phone actions.

StableDEV activatedexact3wcw1w2vh/sourceedc55fdb42af4bb3c4dd6972ecdaabf8e4ba88c5 after routingownerhostedqualification. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved. Finalfuel586.973km99.512%paved0repeat3stops/allcandidatesfuelescapechecks;18.975sfirst/10.983srepeat remainslatencyflag. NSClean0repeat and3NBDirtacceptedrefs unchanged. No production/phone/pack changes. Routingowner independentlypublicverifiesbeforehandoff.

Privatewaypointpreview04b195e0e1dc9e2deacb1171a661beb252f0f050 =stableedc55+reviewedc883880; runtime/API exactmatch. Previewqq00yvmyf deploying,same5regions02/ns-nb-v1.28arrival/livecanary/projected/v4tests pass. Routingowner hostsfullwaypointqualification;stableedc55/BOTH02 retained. No packmutation/nationalactivation/phone changes.

Waypointpreview04b195e withheld after hostedfinalleg comparisondeadline. Reviewed69f25cc8 applied as47bc06a28c8e946570e45e78990757713cf32385; runtime/API exactmatch. Preview7fwv34r5w deploying,same5regions02/ns-nb-v1.10localcanarychecks pass; routingowner fullhostedqualification pending. Stableedc55/BOTH02 remainprotected.

Hardesthostedwaypoint legstilltimedout on47bc06a; nofalsecompletion,stableunchanged. Follow-up710375b2 applied as0716b5e0e89a867d6027c91f168031d0f5376011 withruntime/API exactmatch; privatepreview32245lheo deploying same5regions02/ns-nb-v1.11canarytests pass; routingowner hostedqualification pending.

0716b5e fullhosteditineraries completedcoresearch but Inverness16.9kmrepeat failedquality; stableunchanged. Reviewedf9eaae48 applied asfc2c42e42506cc127f340aa66fc5895643cec6cf,runtime/API exactmatch. Privatecircuitpreview deploying,same5regions02/ns-nb-v1. Routingowner verifiesexplicitcircuitregression beforeanyalias.

fc2c42e circuitassertionfailed; stableheld. Reviewed0f96359c arrivalaliasmemoryfix applied asa518fd385ac2e6d794e29c1b445f96daba17e816 runtime/API exactmatch; private9pibwupnx deployingsame5regions02/ns-nb-v1.3arrivalhistorytestspass;routingowner hostedcircuitqualification pending.

StableDEV activatedexact9pibwupnx/sourcea518fd385ac2e6d794e29c1b445f96daba17e816 after routingownerfullInverness/YarmouthBalanced6primarylegs andmixed162km3legs+6acceptedregressions/182tests. Invernessfinalcircuitzero; allnewengine/fullpool/fuelcarry/escapechecks. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved. Hardestleg19.756s andYarmouthpriorlegoverlap remainflags. No production/GitHub/phonepackchanges; routingowner publicchainedverification follows.

Privatewaypointarea1c806472abab64278c2cebda4cd18afddb8f2bc5 =accepteda518fd38+reviewed5af1733, runtime/API exactmatch. Previewl9frcmx1g deploying,same5regions02/ns-nb-v1.22waypoint/fromheretests pass. Stablea518fd38/BOTH02 retained; routingowner hostedqualification pending; no packmutation/nationalactivation.

StableDEV activatedexactl9frcmx1g/source1c806472abab64278c2cebda4cd18afddb8f2bc5 after routingowner30hostedresponses:18area/stylechecks+6itinerarylegs+6acceptedregressions. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved. Prior9pibwupnx/a518fd retainedforrollback. No production/GitHub/native/packchanges; routingowner independentlypublicverifies.

Privatepumpguard7944b89ddabcd4df5ac60e5495cbe66ef087b9f7 =accepted1c806+reviewed18cb8f9; runtime/API match(exceptunrelatedtestfixture). Preview95glsdjaz deployingsame5regions02/ns-nb-v1.22fromheretests passincludingmappedpumpnoexpansion. Stable1c806 retained;routingowner hostedqualification pending.

StableDEV activatedexact95glsdjaz/source7944b89ddabcd4df5ac60e5495cbe66ef087b9f7 after routingowner9hosted(area6+Yarmouth3),18localarea/3Yarmouth/186focused+22topology. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved. Rollback1c806/l9frcmx1g anda518fd retained. Nootherenv/pack/production/GitHub/nativechanges; routingowner independentlypublicverifies6area/styles.

Privatewidearrival93826d3137c6c8fb05eba3e8f86ad145de2c293f =accepted7944+revieweddd2ff41; runtime/API matches(testfixtureonlydiff). Previewaurvxp6er deployingsame5regions02/ns-nb-v1.23fromheretests passincludingwidearrivaljoin. Stable7944 retained;routingowner exact3legcoarse/Yarmouthhostedqualification pending. No packmutation/nationalactivation.

StableDEV activatedexactaurvxp6er/source93826d3137c6c8fb05eba3e8f86ad145de2c293f after routingowner6hostedprimarylegs(originalcoarse3+Yarmouth3),187focused/localitineraries. Fullpools/fuelcarry/joins/escape andzerowithinlegrepeat pass. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved.7944/95glsdjaz rollbackretained. Nootherenv/pack/production/GitHub/nativechanges; routingowner publicactual3legsverification follows.

Privatefreshrefinementbc639776757ebed32fe839f106b5a54578910d9b =accepted93826d+reviewed3d6553b; runtime/API matches(unrelatedtopologytestfixtureonlydiff). Deployingsame5regions02/ns-nb-v1;stable93826d/BOTH02 retained. Routingowner hostsunknown162kmfuelrepeat targetandacceptedregressions beforepublication. No packmutation/nationalactivation.

Rejectedbc639776 neveractivated: targetimproved butnearDalhousie repeatedroad/timeworsened. Privatefollowup56308d4f9d45d74c72be1065f87213e68725f819 =bc639776+8eb0cce+23bd403 addsstrictcomparison/sharedwinnerguard. Runtime/API match(testfixtureonlydiff);2winnerguardtests pass. Previewq194y7yik deployingsame5regions02/ns-nb-v1;stable93826d retained. Routingowner hostedqualification pending.

StableDEV activatedexactq194y7yik/source56308d4f9d45d74c72be1065f87213e68725f819 after routingowner15hostedchecks+controlledcomparison/strict471mguard/target3491mremoval/189tests/mixed180km3legs. Publichealth confirms source/ns-nb-v1;guardupdated;BOTH02/env preserved,93826d/aurvxp6er rollbackretained. IntermittentClean20sdeadline reproducedonoldstableandnewprivate; NOTfixedbythisrelease. No production/native/GitHub/packchanges; routingowner publictarget3+strictNBverification follows.

Privateloadtiming42f158025d12805ecb716317fc931ccad20fd6f0 =stable56308d4+reviewed9ca48b7; runtime/API matches(testfixtureonlydiff). Preview3qcxx4vn1 deployingsame5regions02/ns-nb-v1.2regionloadingtestspass. Routingowner investigatesintermittentCleandeadline; nofixclaimed,stable56308d4 retained. No packmutation/nationalactivation.

42f1580 coldCleanstillunknown20s; data/join8.583s+search11.417s. Warmcompletes; concurrencyalone notqualifiedfix. Diagnostic65e0b99 applied asc1558c64f5df0d36f1bedcfc40333edfe2ba23e7, runtime/API matches(testfixtureonlydiff). Privatejointimingdeploy same5regions02/ns-nb-v1; routingowner firstcoldrequest pending;stable56308d4 retained.

Joinallocation45bd1c8d applied as1219bd43b1ce6cb4466d3b7aa953b67247e7c7eb, cleanstatus/runtimeexactasserted. Eligibleprivatepreview8yw9uif1f same5regions02/ns-nb-v1. Premature9hu2dmlj4 attemptstartedbeforedocconflictresolved, stoppedandINVALID(oldsourceidentity);neveruse/promote. Recordsaborted-* retained. Stable56308d4 unchanged;routingownerfirstcoldcheck pending.

Privatefreshfuelfirst82ac4c1878cacc6a45c0ea9e8c2e6abbe578d1f9 =1219bd4+reviewed67bc6306;cleanstatus/adventureruntime/API exactasserted. Includesunpublishedjoin/loadoptimizations; stable56308d4/BOTH02 retained. Routingowner firstcoldCleanreserved;nohostedcalls frompacktask,noaliaspromotion.

82ac4c1 firstcoldCleancompleted18.159s,data5.143s(join3.651scachemiss),search13.013s; accepted0repeat/fuelstopsconfirmedbyroutingowner. Requestedsecondprivate deploymentexactsame82ac4c1/env forindependentcoldrepeat. Cleanstatus/source/envchecked; no hostedcalls bypacktask;stable56308d4 unchanged.

Private reversepreparation7117e36bd8f5fd9a19a9344874c356c9a0221ee9 =82ac4c1+reviewed20db1213;cleanstatus/adventureruntime/API exactasserted. Same5regions02/ns-nb-v1;stable56308d4 retained. Routingownerfirstcoldrequestreserved;nohostedcalls bypacktask. Previoussecondcold82ac4c1 failure keepsperformanceworkunqualified.

7117e36 firstcoldCleanpasses perroutingowner; seconduntouchedprivate exactsamecode/config deployedforindependentcoldrepeat. No hostedcallsfrompacktask;stable56308d4/BOTH02 unchanged.

Private sharedendpointlookup6cb27706cf0aa07d040c35ae278ecae984f754f2 =7117e36+reviewed52c95b34;cleanstatus/adventureruntime/API exactasserted. Same5regions02/ns-nb-v1;stable56308d4 retained. Routingownerfirstcoldreserved;nohostedroutingfrompacktask. Performanceexperimentnotqualifiedyet.

6cb2770 firstcoldCleanpasses19.378s(586.972545km/3pumps/zero repeat/fullpool). Seconduntouchedprivate exactsamecode/config requestedforindependentcoldrepeat;nohostedcallsfrompacktask;stable56308d4/BOTH02 unchanged.

StableDEV activatedEXACTpx2p5tl27/source6cb27706cf0aa07d040c35ae278ecae984f754f2 after16hostedchecks(2cold+baseline6+device4+hooks1+target3),192adventure+22topology. Independentcold19.378/19.435s leaves<1s margin; nouniversaltimeoutfixclaimed.6baselinegeometry/stopIDsexact56308d4. Publichealthsource/ns-nb-v1 verified;5regions02/envpreserved;guardupdatedrollback56308d4/q194y7yik. No rebuild/runtime drift,production/native/GitHubchange. Publicroutingverification byroutingowner pending.

## Private continuation recovery review — September 9

Routing owner requested private qualification of cfc8c3d. Published preview https://pack-fabric-bz4kvcmdt-goricksmith-7678s-projects.vercel.app, exact source 4da3822dd7d37f6dde7720d61668aba1d7e883f8, with identical reviewed adventure/API runtime. All five accepted regions remain release02, canary ns-nb-v1. First hosted route reserved for routing owner. Stable remains 6cb2770; no pack changes or national activation. Deployment evidence: candidate03/atlantic-continuation-retry-deploy-run.json and deploy-atlantic-continuation-retry.log.

## Verified continuation recovery published to DEV — September 9

At routing owner request after 19 hosted checks and 193+22 local tests, stable DEV now points to exact qualified bz4kvcmdt, source 4da3822dd7d37f6dde7720d61668aba1d7e883f8/runtime cfc8c3d. No rebuild. Public service identity and ns-nb-v1 verified. All five accepted region02 settings retained. Rollback is 6cb2770/px2p5tl27. Saved continuation failure recovered; six baseline geometries and fuel-stop IDs unchanged. Fresh reverse Inverness failure remains open. Routing owner performs independent public route checks. No packs changed, no national activation, production/native/GitHub untouched.

## Private connected-start recovery review — September 9

At routing owner request, private preview qu663xg1q is READY, source f2da612ae73dd175123430391010b48f0d9408a7/runtime 0496982. Exact reviewed adventure/API runtime verified before deployment. Same five region02 settings and ns-nb-v1; first route request reserved for routing owner. Stable4da3822 unchanged; no pack defect established and no pack changes. Candidate03 records: atlantic-start-recovery-deploy-run.json and deploy-atlantic-start-recovery.log.

## Verified starting-road recovery published to DEV — September 9

At routing owner request after 22 hosted checks and 197+22 local tests, stable DEV now points to exact qualified qu663xg1q, source f2da612ae73dd175123430391010b48f0d9408a7/runtime 0496982. No rebuild. Public service identity and ns-nb-v1 verified. Same five region02 settings retained. Rollback is 4da3822/bz4kvcmdt. Near/wide start cases passed all three styles, with independently checked snap distances inside allowed radii. Six baseline geometries and fuel-stop IDs unchanged. Routing owner independently checks public routes. No packs changed or national activation; production/native/GitHub untouched.

## Hosted corrected-pack baseline — September 9

Private7wh8xsg7c source3e407603c646967264d2a7091512eb0e76955765 passed all6 accepted Inverness/Yarmouth legs with EXACT geometry and fuel-stop identities. Service source and every graph/geometry/fuel SHA independently matched fabric-v4-20260909-01. Evidence ns-nb-hosted-comparison.json. Atlantic priority publication/readback complete; full national upload still running, stable unchanged. National border check plan covers9pairs/both directions with actual pack identity assertions and is pending file availability. App agent restored build dependencies after the cleanup incident and qualified separate optional preferences; integrate only on explicit coordination, never overwrite its work.

## First national corrected-pack border pair verified

On private source3e40760, Alberta–British Columbia completed both directions using BOTH actual corrected regional packs with exact graph/geometry identities. Forward297422m/20.121s including CLI; reverse296538m/3.583s. This is connection/data-loading evidence, not new route-quality acceptance. Evidence candidate01/national-border-results/ab-bc*. Upload continues,11 regions complete at last read; no stable/catalog activation.

## International and state border verification — corrected candidate

BC–ID passed both directions with actual corrected packs and exact identities:60748m/25.828s and60704m/4.596s including CLI. AL–GA first forward request received no response within70s; preserved as al-ga-first-attempt-* and runtime logs (begin record only, no reported error). Reverse completed27567m/21.387s; forward retry completed27555m/34.811s, both exactpack identities. This establishes connectivity, NOT cold-start reliability or a resolved timeout. Preserve the first failure and investigate service loading/resource behavior before claiming national reliability. No routing algorithm, stable alias or catalog changed. Upload continues.


## Immediate DEV activation — 2026-09-09T13:20:50.164491+00:00

Richard explicitly directed publication now and repairs as failures arise. Stable DEV now points to national source `3e40760`, candidate `fabric-v4-20260909-01`. Uploads continue; regions without complete remote files are not available yet. Download catalog and app configuration remain in progress. The first Alabama–Georgia request exhausted server memory (HTTP 500); this remains an open repair rather than an activation blocker. Production is unchanged. Details and rollback are recorded in candidate `dev-activation.json`.


## National DEV publication complete — 2026-09-09T15:17:14.424679+00:00

All63 regional packs, both catalogs, and the shared border audit file are published. All446 remote objects passed exact byte/checksum readback, including252 files referenced by the download catalog. DEV remains on the coordinated routing source993258b; production and phone installation unchanged. Publication is complete, not national routing acceptance. Latest stable checks: ON→QC passes, reverse no_route; BC–WA both directions confirmed server memory exhaustion; NY–VT and VT–NH both directions pass; NY–PA both directions exceed70seconds. Earlier AL–GA memory failure remains open. Full results and publication record are in candidate09/publication-completion.json and national-stable-border-results.


Runtime repair ownership clarification: Routing Final Refinement acknowledged the evidence but explicitly declined repair ownership because its current request was simulator shutdown. These failures remain open, unassigned, and unresolved; no runtime repair is underway. Durable list: candidate09/open-runtime-repairs.json. Do not launch simulators unless Richard asks.
