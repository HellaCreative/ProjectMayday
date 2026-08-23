# Replay a device itinerary log

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

1. Export the app debug log and keep only lines containing `itinerary action=`.
2. Paste the shortest sequence that reproduces the issue into a multiline fixture
   in `DirtTests/Itinerary/LogReplayTests.swift`. Keep the complete `before=[…]` and
   `after=[…]` fields; timestamps and unrelated routing lines are unnecessary.
3. Add the expected final waypoint coordinates and generation beside the fixture.
4. Run `RoutePlannerModelItineraryTests` and `LogReplayTests` on a physical device.

The replay parser derives canonical actions from each before/after coordinate
transition, runs the same `ItineraryReducer` used by the app, and checks the model
invariants after every line. A failure therefore identifies the first action that
cannot reproduce the logged state, normally in under five minutes from export to
test.
