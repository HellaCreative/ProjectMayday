# DIRT — Soon tracker (phone packs + overlays)

Living checklist so “Soon” in the PACKS UI and Layers never loses meaning.
Updated: 2026-07-28.

## Phone routing packs (`graph.v2` + `geometry.v1` on CDN)

Tester focus this sprint: **NS, ON, BC, AB**.

| Region | Phone pack on CDN | Notes |
| --- | --- | --- |
| Nova Scotia (`ns`) | **Live** | ~21 + ~81 MB |
| New Brunswick (`nb`) | **Live** | Fresh OSM + Forest Roads (~17 + ~21 MB) |
| Prince Edward Island (`pe`) | **Live** | OSM-only (~1.5 + ~1.4 MB) |
| Québec (`qc`) | **Live** | OSM-only (~39 + ~58 MB) |
| Ontario (`on`) | **Live** | Fresh OSM + MNRF (~73 + ~83 MB) |
| Manitoba (`mb`) | **Live** | OSM-only (~9 + ~9 MB) |
| Saskatchewan (`sk`) | **Live** | OSM-only (~16 + ~12 MB) |
| Alberta (`ab`) | **Live** | Fresh OSM + Access Roads (~45 + ~39 MB) |
| British Columbia (`bc`) | **Live** | Fresh OSM + FTEN (~34 + ~91 MB) |
| Newfoundland and Labrador (`nl`) | **Live** | OSM-only (~6 + ~8 MB) |
| Yukon (`yt`) | Soon | North — no Geofabrik extract this pass |
| Northwest Territories (`nt`) | Soon | North |
| Nunavut (`nu`) | Soon | North |
| United States (all states) | Soon | Catalog only; no packs |

CDN: `https://dirt-mayday.vercel.app/app/data/packs/v1/manifest.json`  
Publish: `node scripts/publish-packs-cdn.js <ids…>` then Vercel deploy (geometry allowed).

## Province network overlays (map purple/blue secondary network)

iOS `NetworkOverlayManager` currently wires **NS / NB / QC** chunk manifests only.

| Province | Overlay on server | iOS lens | Status |
| --- | --- | --- | --- |
| NS | `app/data/ns-gov-*` | Yes | Live |
| NB | `app/data/nb-gov-*` | Yes | Live |
| QC | `app/data/qc-gov-*` | Yes | Live |
| ON | `app/data/on-gov-*` | Yes | **Live** — MNRF capillary (~110k) |
| BC | `app/data/bc-gov-*` | Yes | **Live** — FTEN capillary (~45k) |
| AB | `app/data/ab-gov-*` | Yes | **Live** — Access Roads (~210k) |
| PE / MB / SK / NL / territories | No | No | Soon |

When Mayday ships `*-gov-chunks` + manifest for ON/BC/AB, add entries to `NetC.overlays` and Layers toggles.

## Related product Soons (not packs)

| Item | Status |
| --- | --- |
| Soft-stitch snap parity | **Done** — virtual endpoints + same-edge along-edge + soft-stitch stubs |
| On-device geographic loop prune | **Done** — `OnDevicePathPruning.swift` (find-path-v2 parity) |
| Auto-download next region (field harden) | **Done** — quiet one-at-a-time while nav; End Nav cancel; pack-ready toast |
| Mid-trip Plan: active-leg-only recalc | **Done** — preserve later stages; avoid only on active hop |
| Cloud `rider_alerts` + peer HUD | **Done** — distress + HUD Report → production insert; peer map/HUD |
| Groups Supabase Realtime | **Done** — private `group:{id}` presence + broadcast; poll fallback |

## How to update this file

When a province pack deploys: set **Live** and note approximate MB.  
When an overlay ships: set **Live** and link the manifest path.  
Never delete rows — move status only.
