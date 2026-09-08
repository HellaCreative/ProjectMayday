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
