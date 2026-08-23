# Phase 9g — Approved Halifax fallback

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

The Phase 9e settlement escape was approved and applied to the final
proved-no-path adventure fallback. That fallback now relaxes the smaller
settlement wall and retains the scored settlement penalty while the urban-core
escape remains explicit and prohibitively scored.

## Benchmark result

The full fixed-pin comparison remains 56/65 green, with zero green-to-red
regressions. None of the six Dirt, Balanced, or Direct Halifax unknown-off rows
became routable. Their failure times remain below the applicable limits.

This establishes that the approved settlement-wall change is safe but is not,
by itself, the cause of those no-route results. Dirt with Allow Unknown enabled
continues to complete at 87% dirt, while Clean unknown-off completes. Any next
change should therefore diagnose profile-specific snapping or unknown-access
connectivity before broadening access policy.
