> Historical assessment and superseded proposals. The current plan is RECOVERY-ASSESSMENT-AND-PLAN-2026-09-08.md. Retained as evidence, not execution instructions.

# DIRT recovery assessment and repair plan — September 8, 2026

Status: assessment and proposed work only. Richard has paused implementation. This review has not changed application code, packs, deployment, or the installed app, and has not run new routing tests.

## Assessment

There are confirmed faults in both the V4 border-connection data and the code that uses V4. There are also unresolved questions about which roads the V4 migration made usable, and separate service failures and excessive repeated route searching. Treating the packs as accepted and tuning individual routes was the wrong starting point.

The evidence does not support either “all the packs are correct” or “compression destroyed all the packs.” V4 construction changed road eligibility and connections. Compression subsequently changed how those results were stored. Those are different changes and require different evidence.

The recovery unit must be a demonstrated cause and everywhere that cause applies. Named journeys provide examples and later confirmation; they must not define the limits of a repair.

### Owner's clarified factory intent

Richard clarified the intended sequence during this review: prove the Nova Scotia pack internally, prove Nova Scotia–New Brunswick together, and turn the understood corrections into a repeatable factory covering roads, fuel, legal details and layers. V4 was intended to reproduce that complete result across regions. California's size then led to compression across the entire set, widening the change and the requalification burden.

The recovery must restore that sequence. The Atlantic reference is where the shared process is understood and proved; geographically different checks establish whether the process generalizes. Neither one successful Atlantic journey nor dozens of individually patched borders establish a sound factory.

Large-pack handling is a separate capacity qualification. Prefer the smallest affected scope. Do not now undo compression everywhere: storage corruption has not been demonstrated, and another blanket conversion would add another variable. Determine whether a correction is needed, retain proven existing files where possible, and apply any new size-related change only to the packs that need it unless evidence establishes a shared defect. Both supported storage forms must be read correctly.

## What the history establishes

| Period | Recorded result | What it establishes |
| --- | --- | --- |
| August | Several useful routing and interaction checkpoints; also recurring fuel, profile and border problems | Existing functionality is worth preserving. No historical checkpoint proves every region worked. |
| September 3 | White build 2 (13), source `94b467a`, documented physical acceptance with identified V3 reference packs | Strongest documented recent comparison point for route creation, fuel and editing. It is a specific accepted combination of code and data. |
| September 5–6 | Regional V3 acceptance work dropped or replaced some failing journeys | Broader service and route problems existed before the national V4 release. Later passing reports did not resolve removed failures. |
| September 6 | Legal-direction/Highway 104 work, checkpoint `71aa7fd`, plus NS V4 work | Useful reference for the direction correction. It is not evidence of national V4 acceptance. |
| September 7 | All 63 V4 regions built and sealed; connections catalogued; graphs compacted; loading and memory changes made | Substantial production work completed. File creation, preservation and upload evidence do not establish usable complete journeys. |
| September 7 evening | Large routing evolution change, then two reverts | The attempted evolution was not qualified. Its intended product behaviour and its failed implementation must remain separate. |
| September 8 | Connection corrections for four region pairs, reader and routing repairs; build 18 physically rejected; build 19 rollback also rejected | Narrow automated passes did not establish recovery. The rollback retained V4 compatibility work and current V4 data, so it was not a return to the September 3 accepted system. |
| Current recorded state | Build 20/source `609df6e` installed; middle NB section repaired but the full Maine replay still fails | Partial correction only. No physical acceptance of build 20 is recorded. |

Sources: [September 3 freeze](ROUTING-FREEZE-2026-09-03.md), [recovery history](ROUTING-RECOVERY-2026-09-07.md), [active device record](ACTIVE-ROLLBACK-DEVICE-19.md), [build 18 physical failure](PHYSICAL-TEST-2026-09-08-BUILD-18.md), [build 19 diagnosis](BUILD-19-PACK-AND-HANDOFF-DIAGNOSIS.md), and Git history.

## What works, what fails, and what remains unknown

| Area | Honest status |
| --- | --- |
| Creating a line within a region | Some actual requests complete. This proves limited connectivity, not acceptable Dirt selection. |
| Fuel placement | Richard observed stops being placed. Complete-chain quality, sensible placement and acceptable speed are not established by that observation. |
| Sending Allow Unknown | The physical log shows it reached the service enabled. The entire effect on available roads and the chosen route remains unqualified. |
| Province/state connections | Confirmed data-selection and region-selection faults. Some controlled crossings work; complete national coverage is unqualified. |
| Dirt, Balanced and Clean | Physically rejected on the reported journeys. A favourable whole-journey statistic does not disprove a bad visible leg. |
| Direction handling | Focused checks exist. Preserve this work while verifying all V4 consumers use the same interpretation. |
| V4 file production | The local release records 63 regions and 138 neighbouring pairs. This is an inventory, not a riding acceptance result. |
| Compression | The implementation removes a redundant road-identifier table and shifts the remaining stored sections. The release records about 8.80 GB reduced to 6.16 GB. This supports a storage-preservation design; it does not prove V3-to-V4 behaviour was preserved or every reader is correct. |
| Dirt roads in Cape Breton | Existing inspection found substantial known unpaved roads, including unknown-access roads, in the approximate Cape Breton area. Presence does not establish that those roads join into the requested journey. |
| Georgia–Montana HTTP 500 | User-observed failure. Its specific server exception has not been established from the supplied logs. Do not attribute it to the Maine connection failure merely because both cross regions. |
| Online versus offline | The rejected build 18 requests used the live service with no installed road packs. They do not qualify offline routing. |
| Map layers and established interaction features | Separate earlier acceptance exists, including September 5 Rider Services. Preserve these; do not rebuild them because routing failed. Their historical acceptance is not a new verification of the current build. |

## Causes and gaps to repair

### 1. The border builder could omit useful crossings

The original V4 builder reduced connections to one record per source road, sorted geographically, then retained the first 128. A valid list could consequently consist of island crossings while omitting mainland connections. “Every listed crossing is valid” answered the wrong question: it did not establish that needed crossings were listed.

This is demonstrated in the QC–Ontario recovery and the remaining Maine–NB failure. The builder's selection function has since been corrected in the working repository, but the published connection revision repaired only QC–ON, DE–NJ, NT–YT and OR–WA. Correcting the builder does not retroactively correct the other published files.

A second issue is selection during routing: a geographically convenient crossing can still belong to roads that do not connect to the actual start and destination. A check that only asks whether the largest road networks touch misses other legitimate networks and island journeys.

Repair scope: every neighbouring pair, every materially distinct connected road network, both travel directions, and the code choosing among crossings. Preserve actual road identity and turn/access rules when joining regions. Do not join nearby lines simply because they appear to touch.

Evidence: [recovery history](ROUTING-RECOVERY-2026-09-07.md); `scripts/pack-fabric/scripts/build-v4-seams.js`, original version at `5dbdf66` and current version.

### 2. Correct data can still be used incorrectly

The NS–Maine reproduction attempted the middle section with the wrong region. Using NB for that same section succeeded; the next section then exposed a different, disconnected crossing. Repairing the first error could not repair the second.

V4 also introduced directional access values that differ from the older combined access field. Recent fixes corrected readers/search paths that used the wrong interpretation. Route search, fuel search, endpoint matching, reverse searches and border traversal all need the same meaning. A reader successfully opening a file is insufficient.

Repair scope: shared-border ownership and all V4-consuming paths on the service and phone, including changing regions and releasing/reloading packs. Build 20 contains some of these corrections; review and preserve them rather than blindly reapplying them.

### 3. The migration changed usable roads, not just storage

V4 replaced the earlier extraction/build process, preserved original road identities, added direction/turn/barrier rules, and removed permissive joins between nearby disconnected roads. It also changed the handling of ATV permission versus motorcycle restrictions. These are functional changes.

The V4 barrier classifier treats an ambiguous gate as closed. That is separate from unknown road access. The sealed NS build report lists 1,144 ambiguous-gate decisions. This count does not measure lost route kilometres or prove those decisions are wrong; it establishes a material policy worth examining. A road can exist and have unknown access enabled while a gate still cuts its connection.

Repair scope: compare source roads through extraction, classification, packing, compression and decoding. Explain missing roads, broken intersections and changed eligibility separately. Quantify what the new rules removed or blocked. Compare the old and new rule tables explicitly, including uncertain gates and ATV tags. Do not silently restore old permissions or tighten them further to make tests pass.

Begin with a lightweight inventory of existing files and build records across all 63 regions; this is not 63 separate repair projects. Establish the complete source-to-rider comparison on Nova Scotia and Nova Scotia–New Brunswick. Turn each demonstrated cause into a factory-wide requirement, then examine its whole impact area. Rebuild only data shown to require rebuilding. Preserve the original V4 release and accepted V3 reference data.

Sources: [V3 build history](NS-V3-BUILD-HISTORY.md), [V3 data authority](PACK-DATA-V3-AUTHORITY.md), [V4 data authority](PACK-DATA-V4-AUTHORITY.md), [factory contract](PACK-FACTORY.md), sealed release `scripts/pack-fabric/routing/candidates/fabric-v4-20260907-01/release.json`, and `routing/lib/legal-topology/barriers.js`.

### 4. Service crashes and excessive time need their own diagnosis

Commit `ad419a7` explicitly removed the NY–VT acceptance journey after Dirt with Allow Unknown crashed the service after loading New York. Commit `7181b64` removed an Idaho journey after a time limit was reached. Their replacement passing reports contain no resolution of those causes.

The current Georgia–Montana error cannot yet be assigned to loading, memory, a code exception, a missing file, route search or another cause. Capture the actual server failure before choosing a fix. Existing later memory/loading changes may have addressed some older faults; their presence is not proof that this one is gone.

The build 18 Cape Breton log does establish repeated work: 17 profile searches across two fuel windows over roughly 36 seconds. It also shows the full-route search was skipped when the destination exceeded the available tank range. That behaviour predates the September 7 evolution. It is a reason to examine fuel construction, not proof that all poor dirt selection comes from fuel.

Repair scope: pack loading, retained memory, repeated searches, request continuation and complete-trip orchestration across small and large regions. Check first-use and cached requests and more than one active request. Set user-visible speed targets from measured results; 20/30-second ceilings are failure limits, not successful response-time targets. Do not promise Google-like timing before measuring the corrected system.

### 5. Route choice must be judged against the rider's objective

After usable roads and connections are established, trace why accessible dirt is rejected: eligibility, disconnected roads, geographic search limits, town/highway avoidance, candidate ranking, or fuel placement. Each reason requires a different repair.

Dirt aims toward 100% and chooses the strongest feasible dirt route. Balanced seeks the closest feasible 50/50 mix. Clean prefers pavement and must establish why any unpaved fallback was necessary. An emitted fallback label does not prove the fallback was justified.

Allow Unknown must actually expand eligible road choices where unknown access is the limiting condition. Keep already-found good candidates when expanding the search, and show why added roads help or do not help. Do not inflate Dirt percentages by counting unknown surface as confirmed dirt. Older documents disagree about surface accounting, so compare actual roads and consistent statistics as well as displayed percentages.

Fuel should preserve a good selected route where feasible and make necessary departures understandable. Repeated searches to pumps must not silently turn Dirt into a mostly paved journey.

## Proposed repair order and checkpoints

| Step | Work package | Evidence required before advancing |
| --- | --- | --- |
| 1. Establish the recovery comparison | Record the exact current app/service/packs and preserve failed examples. Use September 3's accepted code plus its exact V3 data as the historical comparison; retain the legal-direction checkpoint separately. Reconcile contradictory current-status documents. | One release/status sheet that distinguishes accepted, failed, partial and untested. No assumption that rolling back code alone restores the accepted product. |
| 2. Re-establish the complete Atlantic reference | Reconstruct what NS and NS–NB acceptance covered and what changed afterward. Trace roads, fuel, legal details and layers through source, build, storage and service/phone use. Inventory other regions without starting individual repairs. | A cause-based report identifying the departure from the intended factory and the evidence still missing. Clear distinction between pack defects, consumer defects and route-selection defects. |
| 3. Repair and prove the factory process | Correct demonstrated shared causes and prove the Atlantic reference through complete journeys. Separately qualify California and other genuinely large packs for loading, memory and storage behaviour. Apply the corrected process to the affected set and verify all neighbouring pairs plus geographically varied regional chains. | A reproducible factory with explicit acceptance for roads, fuel, legal details, layers and cross-region continuity; separate evidence for large-pack handling. Phone and service agree on the same data. A passing border fragment or first fuel window is insufficient. |
| **Device checkpoint A** | Supply a matched candidate for border reliability once the broad checks pass. | Clearly say borders are the acceptance target and Dirt quality is still open. Richard tests freely, not only the engineer's selected pins. No claim that both priorities are finished. |
| 4. Repair dirt availability and selection | Correct access/reader problems identified in step 2, then search/ranking and fuel interaction on the established network. Preserve legal-direction work. | Distinct mode outcomes, effective unknown-access behaviour, consistent statistics, sensible fuel stops and materially improved Dirt on the affected class of journeys. No narrow percentage threshold substitutes for the riding objective. |
| **Device checkpoint B** | Supply the candidate addressing both original priorities. | Richard can plot cross-region journeys and judge Dirt/Unknown behaviour, including Cape Breton and unfamiliar locations. Stop stacking changes if this candidate is rejected. |
| 5. Finish speed and regression protection | Remove demonstrated repeated work and loading costs while preserving accepted outcomes. Check edits, pump replacement, saved routes and offline rerouting where the changes can affect them. | Measured whole-trip response times and no loss of the accepted connections, profile character or established interactions. Subsequent device check before declaring recovery accepted. |

This is a dependency order, not a demand to rebuild all packs before any phone checkpoint. An Atlantic reference candidate should receive a physical checkpoint before a wider corrective rollout; broader examples then challenge whether the factory generalizes. If the evidence shows existing road files are sound and only connection descriptions need correction, preserve the expensive road builds and repair those descriptions. If road generation is wrong, fix that shared cause before compensating in route search. A size problem in one region is not automatic permission to transform every region.

## Checks follow causes, not place names

| Failure class | Coverage |
| --- | --- |
| Useful border crossings omitted | All neighbouring region pairs; dispersed crossings; small and large road networks; overlaps; mainland/island alternatives; legal travel in both directions. |
| Wrong region chosen | Points inside regions, on shared boundaries, and routes with one or multiple intermediate regions. Verify every section uses the intended data. |
| Crash while switching/loading regions | Different pack sizes, first and repeated requests, consecutive regional loads, concurrent requests and long chains. Require the same observed failure trigger to disappear; do not infer a cure from HTTP success elsewhere. |
| Roads lost or closed during migration | Every region's source/build accounting, with cause-based road comparisons for clipping, identity, access, gates, turns and structures. |
| Allow Unknown has no useful effect | Cases where unknown access should add connected dirt, cases where it cannot, and separate barrier/surface cases. Check service and phone interpretation. |
| Dirt choice degraded by fuel or search | Short and long journeys, dense and sparse fuel, inland and coastal geography, with and without fuel and unknown access; preserve useful alternative paths. |

NY–VT, NY–PA, VT–NH–ME, NS–NB–ME and Georgia–Montana are geographic examples within that coverage. Exact historical coordinates remain useful reproductions. They are not the specification and passing them alone is not completion. Do not remove the failure class when a chosen example is difficult.

## How progress will be reported

Each update should state the demonstrated cause, its wider impact, what remains uncertain, and the next checkpoint. Keep a visible list of unresolved failure classes. Distinguish file checks, automated journeys and physical acceptance every time.

Do not call a work package complete because tests pass, a commit says “qualified,” files are sealed, or the app installs. Completion requires evidence for the affected behaviour at its declared scope. A service exception is not proof that no road exists; a route timeout is not proof that no fuel chain exists.

A wholesale rewrite is not justified by the evidence currently available. It would retain bad pack assumptions unless those were resolved first, and risk discarding accepted interactions and fuel behaviour. Once the pack and consumer boundaries are understood, replace a bounded subsystem if its demonstrated failures make repair less reliable than replacement.

## Review limits

This assessment uses the product and navigation records, V3/V4 authorities, factory and evolution documents, recovery and physical-test records, historical routing audits and handoffs, relevant Git changes, and existing release/report files. The documentation inventory contains 83 project Markdown files; inventorying them is not a claim that every historical assertion has been independently verified. Some older documents contain superseded policy and partial or conflicting status statements.

This is not a new full binary-integrity audit or fresh physical acceptance. The complete cause of the low Cape Breton dirt result and the Georgia–Montana server error remains open. Those uncertainties are explicit work in the plan, not reasons to resume speculative tuning.
