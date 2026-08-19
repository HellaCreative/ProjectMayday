# On-device routing (Phase C)

Prefetch `graph.v2` packs at Start Navigation; mid-ride recalc prefers
the phone when a pack is loaded.

| File | Role |
| --- | --- |
| `GraphPackStore.swift` | Manifest + download + cache |
| `GraphV2Pack.swift` | Binary CSR decode (parity with `pack-v2.js`) |
| `OnDeviceProfileCosts.swift` | Same surface weights as `profile-costs.js` |
| `OnDeviceRouter.swift` | Dijkstra + nearest-node snap |

**Wired for offline mid-ride:** automatic recalculate, Report → Find a way around, Report → Return to network. Backtrack is local geometry (always offline). End stage is local.

**Offline packs UI:** Route sheet → **PACKS** (left of recenter) → download province brains for no-signal rides. Live routing works without a pack. Auto-download next region is off unless you turn it on.

**CDN:** `AppConfig.packCDNBaseURL` (Cloudflare R2 `manifest.json`).

**Limits (honest):** nearest-node snap (not full edge snap); single active region pack at a time for search; geometry sidecar not required for search. Cross-province / missing-pack hops use live `/api/route` while online — phone pack stitch is not built.

See [09-STACK-ECONOMICS.md](../../../docs/09-STACK-ECONOMICS.md).
