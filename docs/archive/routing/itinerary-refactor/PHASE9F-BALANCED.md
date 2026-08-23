# Phase 9f — Balanced short-route investigation

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

## Finding

The Musquodoboit–Sherbrooke search was not failing because the 40 km extra-distance ceiling was too tight. The search produced nominal ratio labels near 50%, but path-coherence pruning removed geographic loops from those labels. Selecting the bucket before that pruning made the reported route collapse to a materially different surface ratio.

Balanced now materializes and prunes each destination candidate first, then chooses the coherent route whose measured dirt share is closest to 50%. If no coherent candidate reaches 45–55%, the response includes `balancedMiss`, the absolute percentage-point distance from 50.

## Fixed-pin result

- Physical reference: 55.1 km, 40% dirt (`balancedMiss=10`).
- Closest coherent candidate inside the unchanged 40 km budget: 73.6 km, 58% dirt (`balancedMiss=8`).
- Extra distance: 18.5 km.

There is no 45–55 coherent candidate in the explored envelope for these pins. Returning 58% is therefore the honest closest-bucket result; the benchmark remains red by design because assertions are not auto-relaxed.
