# Phase 6 diagnosis — Nova Scotia Dirt objective

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

The two coordinates from `195931Z` were replayed on 2026-08-20 against the
checked-in Nova Scotia OSM live-pack artifacts with unknown access disabled.
This was done before changing routing behavior.

| Leg | Result | Dirt | Distance | Time | Pops | Corridor | Settlement marker | Fallback reason | Dirt clipped outside corridor |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: |
| `44.76549,-63.33983 → 45.66744,-62.34420` | complete | 88% | 311,647 m | 483 ms | 21,207 | 50,000 m | false | none | 3,124,093 m |
| `45.66744,-62.34420 → 46.10471,-60.20740` | complete | 87% | 347,986 m | 345 ms | 18,490 | 50,000 m | true | none | 719,359 m |

The historical 79%/25% failure does not reproduce on the current NS artifact and
router: both legs already exceed the 70% Dirt requirement and complete well under
three seconds. Leg 2 still sets `settlementFallbackUsed`, but diagnostics prove no
fallback replaced its Dirt result: `fallbackReason` is null and the selected
pre-fallback result is the same 87% route. The marker currently means that the
selected route crossed a settlement while paying the settlement penalty; its old
warning text incorrectly describes that as a last-resort fallback.

Phase 6b therefore needs to make settlement fallback an actual two-step gate:
first search with the settlement wall, relax it only after a proved `noPath`, and
mark low-scoring Dirt results without replacing them. The corridor diagnostic also
shows substantial eligible dirt outside the selected 50 km band, but widening is
not required to pass these two acceptance legs.
