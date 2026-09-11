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
After White was unlocked, it launched cleanly: StoreKit loaded, the map style
loaded, and the app root appeared. No route has been executed from this app
build yet.

Focused tests reported 49 passes and one existing itinerary assertion failure:
`atlanticDevRequestsCombinedFuelGeometry` expects optional `forwardFeeler` to
be `false`, while the request contains `nil`. The candidate diff only changes
`OnDeviceRouter.swift`, so this request-shape failure is outside the integration
change and must be resolved or separately baselined before promotion.

This app candidate is a preparation/timing test. It is not yet a certified
fuel route: the 22-case continuity gate, physical pump access, larger-region
parity and Dirt/Balanced completion remain separate qualification work.
