# Private DIRT Dev app integration

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
graph searches. A replacement build is installed, but the phone is currently
locked and iOS will not launch it until White is unlocked.

Focused tests reported 49 passes and one existing itinerary assertion failure:
`atlanticDevRequestsCombinedFuelGeometry` expects optional `forwardFeeler` to
be `false`, while the request contains `nil`. The candidate diff only changes
`OnDeviceRouter.swift`, so this request-shape failure is outside the integration
change and must be resolved or separately baselined before promotion.

This app candidate is a preparation/timing test. It is not yet a certified
fuel route: the 22-case continuity gate, physical pump access, larger-region
parity and Dirt/Balanced completion remain separate qualification work. The
full NS→NB device result is still pending the unlocked rerun.
