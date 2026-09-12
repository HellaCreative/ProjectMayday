# Private DIRT Dev app integration

## Latest device evidence

The private app selector is now pack-first for covered routes. With the NS and
NB packs installed, an online route should report `selected=pack` and
`selectionReason=installed-packs`; an HTTP fuel request is no longer expected
for that covered case. This is the evidence boundary for distinguishing the
phone engine from the earlier 16-second live/server diagnostic.

Pack acquisition now exposes approved byte totals in the consent copy. After a
first location fix, the current primary region can be offered once for
onboarding; a route that crosses regions asks for the missing published packs
as one explicit, size-labelled decision. The home offer is a preparation step,
not a route build, and the private worktree remains the only affected checkout.

The on-device fuel flood now prepares each pump's snap metadata before graph
expansion and tracks pump projection endpoints as search targets. It may finish
early only when all target projections are settled, while unresolved targets
still force the complete bounded flood. This is intended to remove repeated
geometry work without silently reducing fuel coverage.

The owner-provided diagnostic for the NS→NB, 200 km fuel-range route completed
in about 16 seconds from the phone UI, but it selected the live source and made
HTTP fuel requests. It therefore confirms the current online product path, not
on-device scalability. The isolated Dev probe remains the device-only gate.

Checkpoint `5d72d0f` adds two private-only preparation changes: exact fuel
reachability receives only pumps belonging to the active regional graph, and
fuel snap metadata is retained in a bounded 4,096-entry LRU. This avoids
cross-border false candidates and repeated geometry projection while preserving
the complete station list for later regional hops. The build succeeded and was
installed on White; the accepted app and published packs are unchanged.

The intended product flow is now explicit: location permission identifies the
home region, its pack is offered during onboarding, and a route spanning more
regions presents the required pack IDs and byte sizes before an explicit
download. Device-only planning must surface an estimate and bounded memory
warning for long plans; it must not silently switch to the live endpoint.

This is an isolated Dev candidate on branch
`experiment/engine-architecture-20260911`. It activates the bounded native
fuel-snap cache and cooperative pump-loop cancellation inside the real
`OnDeviceRouter`, while retaining the existing matcher as an in-branch rollback
path. It does not modify the accepted app checkout, Production, published
packs, or stable Dev.

The DIRT Dev simulator build succeeded for the existing iPhone 17 destination.
The arm64 DIRT Dev build also succeeded and signed with the local development
profile for White/iPhone 16. The build was installed as `com.mayday.dirt.dev`.
The first NS→NB fuel probe began on White but produced no profile result after
five minutes; it was terminated cleanly. That run exposed an unbounded
cross-pack fuel search, so the private candidate now enforces the request
window budget at each expensive phase and propagates cancellation into detached
graph searches. The follow-up full matrix completed all three profiles and
recognized `regions=ns,nb`, but the fuel reachability flood consumed 32.794s
(Cleanest), 35.296s (Dirt), and 37.936s (Balanced) before candidate selection.
Each response was the explicit `fuel_window_budget_exceeded` result with
1,003–1,127 matched pumps and no committed stop.

Focused tests reported 49 passes and one existing itinerary assertion failure:
`atlanticDevRequestsCombinedFuelGeometry` expects optional `forwardFeeler` to
be `false`, while the request contains `nil`. The candidate diff only changes
`OnDeviceRouter.swift`, so this request-shape failure is outside the integration
change and must be resolved or separately baselined before promotion.

This app candidate is a preparation/timing test. It is not yet a certified
fuel route: the 22-case continuity gate, physical pump access, larger-region
parity and Dirt/Balanced completion remain separate qualification work. The
road seam is loaded and discoverable; the current on-device fuel planner does
not meet a 20-second cross-region window on White.
# Route-build pack gate (private candidate)

The app now evaluates regional coverage before starting a canonical route
build. It samples long waypoint spans, presents the required published packs
and their exact combined download size, and waits for an explicit decision.
Accepting installs verified packs and retries the pending build; declining
uses the existing online fallback path and records the offline warning. The
gate is covered by the 16-test PackFirstRoutingTests suite. A home-region
offer is still presented after the first authorized location fix and does not
start routing by itself.
