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

Routing search, costs, variety seeds, remaining-road forward progress, retrace
rejection, and fuel-replacement ranking are one contract with the JavaScript
engine under `scripts/pack-fabric/routing/lib/`. Change both runtimes together.
Same V4 graph and inputs must produce the same legal path; phone-only or
live-only search behaviour is a defect.

The current evolution qualification uses only sealed DEV V4 release
`fabric-v4-20260907-01`. The phone implementation may read those immutable
candidate bytes for tests, but must not rebuild or mutate them, substitute V3,
query runtime OSM, or activate them in production.

See [../../../../AGENTS.md](../../../../AGENTS.md).
