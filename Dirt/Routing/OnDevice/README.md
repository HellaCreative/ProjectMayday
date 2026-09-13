# On-device routing implementation index

Routing behavior, fuel, data acquisition, pack identity, current work, and
qualification are defined only in
[the routing source of truth](../../../docs/ROUTING-SOURCE-OF-TRUTH.md).
This file identifies components, not another routing contract.

| File | Component |
| --- | --- |
| `GraphPackStore.swift` | Pack acquisition, retained data, and regional orchestration |
| `GraphV2Pack.swift` | Packed graph reader; the filename is not a current format declaration |
| `OnDeviceProfileCosts.swift` | Native profile cost implementation |
| `OnDeviceRouter.swift` | Native endpoint matching and route search |
| `CrossPackSeam.swift` | Recorded cross-pack connections |

See [AGENTS.md](../../../AGENTS.md) for general repository guidance.
