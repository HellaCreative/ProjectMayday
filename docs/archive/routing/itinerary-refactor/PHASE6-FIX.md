# Phase 6b — Dirt objective fix

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

The new acceptance test passed after step 1, so steps 2–5 were not applied.

Adventure profiles now search with settlement walls first. The router relaxes a
settlement wall only when every bounded attempt returns `noPath`; a timeout or pop
cap cannot trigger fallback. A completed Dirt route is returned as found even when
its dirt percentage is low, with `lowDirt=true` below 70%, rather than being
silently replaced.

Final checked-in Nova Scotia results with unknown access disabled:

| Case | Dirt | Distance | Time | Fallback |
| --- | ---: | ---: | ---: | --- |
| Dirt leg 1 | 88% | 311,647 m | 467 ms | none |
| Dirt leg 2 | 82% | 332,767 m | 385 ms | none |
| Balanced leg 2 | 47% | 243,350 m | 459 ms | none |

All are below the three-second ceiling. The two Dirt legs exceed 70%, and the
Balanced case remains within 50 ± 5. Because step 1 passed, no new ellipse,
convex reward, or prior-edge backtrack penalty was introduced in this phase.
