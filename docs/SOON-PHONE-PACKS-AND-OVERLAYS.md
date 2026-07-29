# DIRT — Soon tracker (phone packs + overlays)

Living checklist so “Soon” in the PACKS UI and Layers never loses meaning.
Updated: 2026-07-28.

## Phone routing packs (`graph.v2` + `geometry.v1` on CDN)

Tester focus this sprint: **NS, ON, BC, AB**.

| Region | Phone pack on CDN | Notes |
| --- | --- | --- |
| Nova Scotia (`ns`) | **Live** | ~20 MB graph + ~77 MB geometry |
| Ontario (`on`) | **Live** | ~25 MB graph + ~29 MB geometry |
| British Columbia (`bc`) | **Live** | ~34 MB graph + ~91 MB geometry |
| Alberta (`ab`) | **Live** | ~45 MB graph + ~39 MB geometry |
| New Brunswick (`nb`) | Soon | Server longhaul exists; phone pack not published |
| Prince Edward Island (`pe`) | Soon | Server longhaul exists |
| Québec (`qc`) | Soon | Large; publish after tester wave |
| Manitoba (`mb`) | Soon | |
| Saskatchewan (`sk`) | Soon | |
| Newfoundland and Labrador (`nl`) | Soon | |
| Yukon (`yt`) | Soon | |
| Northwest Territories (`nt`) | Soon | |
| Nunavut (`nu`) | Soon | |
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
| ON | `app/data/on-gov-*` | Yes | **Ready** — MNRF capillary (~110k); needs Vercel deploy |
| BC | `app/data/bc-gov-*` | Yes | **Ready** — FTEN capillary (~45k); needs Vercel deploy |
| AB | `app/data/ab-gov-*` | Yes | **Ready** — Access Roads (~210k); needs Vercel deploy |
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
