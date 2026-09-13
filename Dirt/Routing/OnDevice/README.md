# On-device routing implementation index

This file identifies implementation components only. It does not define routing
product law, source-selection policy, pack acquisition, or current work priority.
The sole authority is
[docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md](../../../../docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

Riders download `graph.v2` + `geometry.v1` from PACKS (R2). Mid-ride recalc
uses the phone when that pack is installed.

| File | Role |
| --- | --- |
| `GraphPackStore.swift` | Manifest + download + cache |
| `GraphV2Pack.swift` | Binary CSR decode (parity with `pack-v2.js`) |
| `OnDeviceProfileCosts.swift` | Same surface weights as `profile-costs.js` |
| `OnDeviceRouter.swift` | Dijkstra + snap |
| `CrossPackSeam.swift` | Two adjacent installed packs |

Current limitations must be verified from code and tests before planning a
repair. Do not infer current policy from historical behaviour.

See [../../../../AGENTS.md](../../../../AGENTS.md).

## Routing recovery — September 7, 2026

The failed routing evolution commits `e92584d` and `106f5a5` were reverted
locally. Product intent remains in `docs/ROUTING-EVOLUTION-SPEC-2026-09-07.md`,
with recovery clarifications taking precedence. The prior implementation is
not qualified for launch. Sealed DEV V4 `fabric-v4-20260907-01` and catalogs
remain read-only; no V3 substitution, pack rebuild, or production publication.
Routing search, costs, variety seeds, forward progress, retrace handling, and
fuel-replacement ranking are one JavaScript/Swift contract. Implement behavioral
changes together and verify both runtimes; automated passes do not replace
White-device acceptance. Android must reproduce the accepted rider outcome,
but no Android implementation or qualification is claimed here.
