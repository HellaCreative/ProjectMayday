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
