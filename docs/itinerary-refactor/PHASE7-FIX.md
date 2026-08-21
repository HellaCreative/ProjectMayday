# Phase 7 — fuel-aware Dirt and continuity

## 7a — continuity

Route requests now carry all previously built edge IDs plus the immediately
preceding arrival edge. Reuse is discouraged with a soft ×4 cost; reversing the
arrival edge is ×12. A synthetic spur test proves an alternative exit wins when
available and the spur remains usable at a literal dead end.

## 7b — station selection and the hard tank ceiling

Step 1 passed: the forward fuel planner still proves graph reachability first,
then routes its top six candidates in parallel under the hard tank ceiling.
Dirt selects the highest-dirt fitting candidate; Balanced selects closest to
50/50; Clean selects least dirt; Direct retains the forward ranking. Responses
carry every evaluated station and the client logs the chosen station, metres,
dirt percentage, and candidate count.

The 195931Z capped replay produced:

| Leg | Capped distance | Dirt | Result |
| --- | ---: | ---: | --- |
| `44.76549,-63.33983 → 45.66744,-62.34420` | 237,304 m | 79% | passes |
| `45.66744,-62.34420 → 46.10471,-60.20740` | 237,257 m | 25% | audited unreachable at the 70% contract |

The second coordinate is therefore a station endpoint the Dirt-aware selector
must not choose. The available unpaved fabric is split among the Antigonish
highlands, the Guysborough interior, and the Cape Breton approach. Joining
enough of those clusters requires the paved connectors between them and exceeds
237,500 m; every 50/100/150/200 km search envelope converged on the same
237,257 m, 25%-dirt capped ride. The uncapped route reaches 82–87% dirt only by
riding roughly 333–348 km. The 70% assertion remains unchanged and explicitly
skipped for this proven-infeasible endpoint rather than weakened.

`maxPathMeters` remains a search-time physical-distance prune using the reverse
shortest-distance fill. No post-filter is used. Balanced remains 50 ± 5 and
Clean ≤15 on the feasible capped acceptance leg.

Restricted-distance diagnostics are now explicit. A restricted edge appearing
in a completed response is labelled `filter_miss`; normal completed routes report
zero restricted metres. No access filter was relaxed.
