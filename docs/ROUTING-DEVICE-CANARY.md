# Onward fuel-search retest — existing build23

Candidate source df0827e60e9c04a625fd3b3155fae87220c93113. Public activation and
verification are recorded at the end of ROUTING-REBUILD-PROGRESS.md.

Rebuild the last failed Porters Lake→New Brunswick destination (47.743529,
-64.911236), Dirt, Allow Unknown OFF, fuel ON, same225km usable range. Then move
the destination again. Create fresh routes; saved geometry intentionally stays
unchanged. No Xcode installation or pack download is needed.

Expected exact replay about885km/64%dirt,4fuel stops,1.6km repeated road instead
of82.2km. The three actual pins and five nearby route positions were checked.
This replaces the earlier one-pump repair with approach-retrace priority during
fuel search. Earlier958km/SunnyCorner-specific instructions below are historical.

Remaining flags: cold search13.2s in private test; Clean back-road preference
unfinished; some NSunknown-path retrace remains; physical/navigation/offline
acceptance is not established by automated route-building checks.

# Dalhousie fuel-detour retest — existing build23

Hosted candidate6ace2323f6a6051a9f3761db55973d7548fc087e passed exact device
replays and six hosted cross-direction/style checks. Stable DEV switch/public
verification is recorded in ROUTING-REBUILD-PROGRESS.md when complete.

Create a NEW From Here route Porters Lake→Dalhousie, Dirt, Allow Unknown OFF,
fuel ON, same vehicle range (225km usable). Do not load the old saved geometry.
Expected local/hosted replay near958km/72%dirt, four fuel stops, last at Irving
Sunny Corner instead of XTR Trout Brook. Repeated road falls65.610→4.095km;
remaining retrace is still subject to physical route-quality review.
No Xcode install or pack download is needed for this server-only update.

Scope: fuel-detour correction and Clean staying on the replacement engine.
Clean paved-back-road preference remains OPEN (large primary/trunk share).
First cold Dalhousie server build15.456s; subsequent six hosted reference cases
7.337–8.403s. These are individual measurements, not percentile guarantees.
Fuel entrance/exit/current availability remains provisional, navigation/offline
parity not qualified by this route-building test.

# NS/NB physical route-building preview — build 23

Current expansion: Nova Scotia, New Brunswick and trips crossing between them. Quebec/US replacement-engine integration remains deferred. The earlier NS-only instructions below describe the preserved baseline.

## Next test

Use DIRT Dev 2 (23) on White, with connectivity on. Build from Porters Lake to northern NB at latitude47.762610, longitude-65.856301 (or a rider-selected NB destination). Tested full range250km with10%reserve gives225km usable. Compare Dirt, Balanced and Clean; test Allow Unknown on Dirt, then fuel off/on. NS/NB DEV requests up to12 prebuilt fuel hops, so it consumes the integrated geometry rather than separately routing every fuel leg.

Acceptance checks: plausible continuous crossing, interesting style-appropriate roads, sensible fuel stops, responsive completion; save/reopen preserves the ride. This is route-building review. Physical station access/current pump availability and offline rerouting/navigation remain unqualified; no routing-pack download is required for this online test.

Hosted preview94597816b960b3baeb33cf008340700d8a3589ae at pack-fabric-74jbm96f6-goricksmith-7678s-projects.vercel.app passed6cross cases (bothdirections,3profiles,225kmusable), additional crossUnknown and NB-only checks, and exact3styleNS regression. All returned full fuel windows with in-range hops, contiguous geometry and destination escape. Local final24case cross matrix and24NB matrix passed;162focusedJS/38nativeitinerarytests pass. Hosted cross times5.6–15.3s; extra unknown6.7s/NB3.6s. Do not advertise local subsecond timing as hosted performance.

NS/NB both pinned to fabric-v4-20260908-02; flagns-nb-v1. Stable alias confirmation and actual device installation are recorded in the progress log after completion.

---

# Replacement routing: first physical-device review

The first canary uses the installed **DIRT Dev** app's existing controls. It is
an online route-building review on accepted Nova Scotia candidate02 data. It is
not navigation/fuel-access qualification or the completed replacement feature set.

## Reproduce the live comparison

1. Open DIRT Dev with connectivity and create a fresh route. Use From here if
   starting near Porters Lake, or Plan a route with two rider pins.
2. Reference start: 44.76484, -63.34023. Reference destination in southwest Nova
   Scotia: 43.47454, -65.60197. Pins must lie on the intended roads; nearby pin
   placements can change the result.
3. Set full fuel range to 300 km and reserve to 10% (270 km usable), with Allow
   unknown off. Compare Dirt, Balanced and Clean using those same pins.
4. Check route shape, fuel-stop placement, build responsiveness, and whether the
   three styles feel meaningfully different. Save/reopen the completed route to
   check that it stays unchanged. Do not use this pass to qualify navigation.

The verified HTTP comparison returned approximately:

| Style | Route | Known dirt | Planned fuel stops |
| --- | ---: | ---: | ---: |
| Dirt | 597 km | 61% | 3 |
| Balanced | 501 km | 52% | 2 |
| Clean | 351 km | 0% | 1 |

Clean contains 98.5% known pavement; the rest is unknown surface. These results
are specific to the exact pins/settings and the current bounded candidate pool.
They are not promises of a global optimum or final riding quality. Fuel arithmetic
stays within supplied usable range, but station entrance/exit geometry and current
operation remain unverified. The app-compatible API carries provisional evidence
and a DEV warning; the existing UI does not yet have a dedicated access-confidence
control. Treat displayed fuel stops as locations to review, not verified access.

## Scope and identity

Only supported two-pin, single-region NS requests on candidate02 use the new
engine. Cross-region, mandatory/replacement fuel constraints, existing approach
history, avoided roads and other unsupported controls retain the existing engine.
A comparison involving those controls is not a replacement-engine acceptance test.
The canary is off unless the deployment sets DIRT_ADVENTURE_CANARY=ns-v1.

Verified preview: pack-fabric-42ltrerz7-goricksmith-7678s-projects.vercel.app.
Source: ecf746ef8497df49c996c0853fe84743de331f7f.
Stable DEV at https://pack-fabric.vercel.app now serves those exact bytes.
Independent public readback and all three profile/fuel checks passed.
Service contract stays dirt-routing.r0.v1; replacement responses identify
adventure-shared-candidates / adventure-preview-v1. No phone install, downloaded
pack change, production publication or national candidate03 switch is required.

## Agreed UI work still outstanding

The current planner has From here, Plan a route and Saved, with existing profile
and fuel settings. Loop is a new ride-creation flow, not another saved-route list.
Its direction and approximate distance/time controls, first-fuel behavior, and
variety need implementation. Exploration controls for destination rides need a
clear range and meaning supported by the engine. Per-fuel-leg overrides must be
scoped to their primary rider leg; they are not implemented by this canary.

Navigation still needs explicit actual refuel confirmation, missed/closed pump
recovery, estimated remaining-range display and the end-navigation summary agreed
in the specification. A station projection must not silently become a confirmed
refill. Named-location search is another distinct future control.

UI changes will use Impeccable and preserve the existing map-first planner,
DIRT orange/ink tokens, native control expectations and touch sizing. The current
controls are sufficient for this first engine comparison; adding unfinished
controls now would imply functionality this canary does not provide.

## Zoomed-out rider waypoint search — 9 September 2026, local qualification

Rider area placement keeps the existing nearby snap choice, then expands only when no connected endpoint pair is found. The fallback scales with map zoom (28 screen points), capped at 20 km; explicit match limits and street-level precision remain unchanged. Candidate roads must meet access rules and share a road component with the start, and the normal directed route and fuel search still must complete. This is an area-selection tolerance, not a fabricated connection. Fixed fuel station matching remains 150 m. Existing arrival history cannot be moved to another road. Successful route geometry supplies the snapped destination to the existing app pin update.

Local evidence: 185 focused tests and 18 real NS/NB fuel-supported area-placement cases across Dirt, Balanced, and Clean passed. The benchmark fixtures include eligible roads 2.2–17.4 km from the selected area point. Private hosted verification and stable DEV publication are pending; current stable remains a518fd385ac2e6d794e29c1b445f96daba17e816 on both Atlantic 02 packs. No native app or pack changes. Android must reproduce this rider-area selection behavior when parity work resumes.

Whole-itinerary overlap remains open: current native requests carry only the most recent 30 km / 256 road IDs. The service cannot reliably avoid earlier roads that were not included. Do not equate zero repetition within a primary leg with zero overlap across the whole itinerary.

Follow-up fixed-service guard: rider anchors within the app’s 150 m mapped-pump recognition radius retain the existing narrow endpoint search; they do not use coarse area expansion. This closes the distinction between a general area pin and a rider-selected pump even when the request carries coordinates without a station ID. 186 focused tests pass including this case. Stable area source 1c806472 passed six independent public area/style checks; the fixed-service follow-up is local pending hosted qualification.

Fixed-pump follow-up hosted qualification: source 7944b89ddabcd4df5ac60e5495cbe66ef087b9f7 / private pack-fabric-95glsdjaz passed nine requests (six coarse area/style cases and full three-leg Yarmouth). Local 18 area cases and full Yarmouth also pass; Yarmouth geometry remains exactly accepted. Runtime worktree18cb8f9; 186 adventure +22 topology tests pass. Publication requested, public verification pending.

## Qualified stable DEV — waypoint area search and mapped-pump guard

Stable https://pack-fabric.vercel.app now resolves to https://pack-fabric-95glsdjaz-goricksmith-7678s-projects.vercel.app, source **7944b89ddabcd4df5ac60e5495cbe66ef087b9f7**. Independent public six-case NS/NB area/style verification passed with exact source and BOTH fabric-v4-20260908-02 identities, after the local/private qualification above. Runtime worktree commit18cb8f9. Evidence: /tmp/dirt-fixed-poi-public/summary.json and per-request files. No reinstall, native changes, phone pack download, production change, or GitHub push. Physical acceptance of the wider snap remains pending the rider’s morning tests.

Overnight continuation: automation overnight-atlantic-routing-refinement is active every15minutes through the 08:00 Halifax September9 handoff. Continue varied styles, unknown-access settings, fuel ranges and moved-pin/primary-leg cases; do not repeat completed qualification without a new reason. Preserve this qualified stable source unless a replacement passes local and hosted checks. Whole-itinerary overlap beyond the native 30km/256edge history is still unresolved; do not claim it fixed. Native parity and a bounded whole-itinerary context contract remain subsequent integration work.

## Exact device log replay — 01:59–02:01 UTC September9

The supplied log uses a518fd (before wider snapping), with a repeatedly failing destination43.566279,-65.491539. Public7944b89d now completes the original coarse placement in6.032s and the first moved-start case in3.930s; destination projection is2391m away. Street-zoom12.5 still rejects that original off-road destination; after moving it onto the road, the logged final case completes in2.628s. Cancellations while adding/moving pins are expected superseded requests, not engine failures.

A new regression checks continuation from a wide-snapped waypoint when native still sends its original coordinates. Expand discovery of the exact supplied arrival edge within the allowed area radius; never switch arrival to another road. 187 adventure tests pass including a two-leg encoded-map proof with identical geometry join. The full original four-anchor device itinerary atzoom6.6 passes locally in all three primary legs with fuel carry and destination escape. Reproduce with bench/replay-multi-waypoint.js, REBUILD_MULTI_CASE=coarsepins REBUILD_MULTI_ZOOM=6.6. Live follow-up pending private/public qualification.

Remaining integration boundary: native must persist resolved coordinates/placement precision per waypoint so zooming into an unrelated edit does not shrink a previously placed area pin’s tolerance. Current requests supply one map zoom for all endpoints; this is not corrected by guessing previous user state on the service.

Wide-arrival private qualification: exact93826d3137c6c8fb05eba3e8f86ad145de2c293f at pack-fabric-aurvxp6er passed six primary legs (actual coarsepins and accepted Yarmouth), all full candidate pools, fuel carry, geometry joins, destination escape, and zero selected within-leg repeated road distance. Coarsepins server times8.357/2.061/16.217s; Yarmouth7.662/2.947/14.268s. Public promotion requested; follow-up evidence in /tmp/dirt-wide-arrival-hosted-{coarse,yarmouth}.

Qualified stable DEV now **93826d3137c6c8fb05eba3e8f86ad145de2c293f**, exact deployment https://pack-fabric-aurvxp6er-goricksmith-7678s-projects.vercel.app behind https://pack-fabric.vercel.app. Independent public replay of the original four coarse device pins passes all three primary legs with exact source/BOTH02 identities, full pools, fuel carry, joins and escape. Evidence /tmp/dirt-wide-arrival-public/coarsepins-complete.json. Runtime dd2ff41. Rollback7944b89d retained. No native/phone/pack/production/GitHub changes. Overnight follow-ups must use this new stable baseline, not earlier7944. The per-waypoint zoom/coordinate persistence issue and longer itinerary overlap remain open for app integration; neither is claimed fixed by this service handoff.

## Overnight batch 02:56 UTC — new combinations, stable unchanged

Nine new local primary legs pass with zero selected within-leg repeat: coarsepins Dirt/Balanced/Clean162km (unknown off), Inverness allClean225km, Yarmouth Balanced/Dirt/Balanced180km. Fuel carry, joins, full pools and destination escape pass. Evidence /tmp/dirt-overnight-coarse-mixed162, /tmp/dirt-overnight-inverness-clean225, /tmp/dirt-overnight-yarmouth-mixed180.

New reproduced failure: coarsepins Dirt/Balanced/Clean162km with Allow Unknown enabled passes legs1–2, but Clean leg3 fails endpoint_no_legal_snap, locally and on public93826d. Last arrival edges include verified paved117m, unknown unpaved432m (w280666072:42895:88884), unknown unpaved204.23m (w280666207:88884:88883). Clean correctly forces unknown access off under existing contract; arrival identity is then ineligible, leaving no departure. This is an access-policy handoff problem, not a fuel shortage or a reason to enable unknown roads globally for Clean. Reproduce with REBUILD_MULTI_CASE=coarsepins REBUILD_MULTI_ZOOM=6.6 REBUILD_MULTI_UNKNOWN=1 REBUILD_MULTI_PROFILES=dirt,balanced,cleanest REBUILD_MULTI_USABLE=162000. Evidence /tmp/dirt-overnight-coarse-unknown162 and /tmp/dirt-overnight-hosted-unknown162.

Control: Dirt/Balanced/Balanced with unknown enabled completes all3 locally, proving the Clean transition distinction, but leg1 has3491m repeated road and leg3 has291.77m. These are completions, not full ride-quality passes. Evidence /tmp/dirt-overnight-coarse-unknown-balanced162. Next investigation: locate the3491m circuit in the selected Dirt candidate and inspect existing fuel approach refinement. For Clean handoff, investigate a bounded departure back over previously supplied unknown-road history to the known network, with directional/turn/fuel proof and no global access relaxation; do not implement unqualified permission exceptions. The prior leg may need shared waypoint planning instead.

Only benchmark parameter support changed (REBUILD_MULTI_UNKNOWN); no service/runtime deployment or native change. Stable remains93826d3137c6c8fb05eba3e8f86ad145de2c293f/BOTH02. Existing zoom-persistence and full-itinerary context limitations remain. Continue from these new findings rather than replaying the already-qualified baseline next tick.

## Overnight fresh-route fuel repetition refinement — local

The3491m repeated-road case was not receiving the optional shared-pool refinement because it was a fresh route. Enabling the existing refinement alone still hit its400000-label cap. For optional fresh Dirt objectives only, a heuristic weight3 focuses the search enough to remove all3491m, retaining about79.58%known dirt (previous79.78%). Existing time/work/label limits and continuation heuristic stay unchanged. All profiles refine the same potential-winner pool. A candidate is replaced only if repetition strictly decreases without increased urban/avoidance exposure; a failed or non-improving refinement preserves the original fuel-proved route. No saved geometry changes.

187 focused tests pass. The coarsepins unknown162km Dirt/Balanced/Balanced fixture removes the first-leg repeat; add REBUILD_MULTI_FIRST_REPEAT_FREE=1 to make that a regression assertion. The final291.77m repeat remains unresolved and is not claimed removed. Clean-after-unknown departure remains a separate open issue. Stable93826d unchanged pending final local and hosted qualification.
