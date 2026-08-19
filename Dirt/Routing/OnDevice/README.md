# On-device routing

Riders download `graph.v2` + `geometry.v1` from PACKS (R2). Mid-ride recalc
uses the phone when that pack is installed.

| File | Role |
| --- | --- |
| `GraphPackStore.swift` | Manifest + download + cache |
| `GraphV2Pack.swift` | Binary CSR decode (parity with `pack-v2.js`) |
| `OnDeviceProfileCosts.swift` | Same surface weights as `profile-costs.js` |
| `OnDeviceRouter.swift` | Dijkstra + snap |
| `CrossPackSeam.swift` | Two adjacent installed packs |

Live `/api/route` works without a pack (same R2 files). Auto-download next
region is off unless the rider turns it on. Start Nav does **not** fetch a
routing pack.

**Limits:** nearest-node snap; one pack per hop; two adjacent installed packs
chain on-device. Missing pack + online → live.

See [../../../../AGENTS.md](../../../../AGENTS.md) and [docs/02-ROUTING.md](../../../../docs/02-ROUTING.md).
