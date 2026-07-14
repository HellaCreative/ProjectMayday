# DIRT. Routing Architecture

> **Product goal:** Plot a route from A to B where the rider defines the road-surface mix — e.g. maximize dirt, minimize pavement, avoid singletrack.

This is a **routing engine**, not a trail viewer. The current map app is a useful visual foundation. The architecture below is what turns it into the product.

---

## One-sentence verdict

Keep the visual language and the tag→surface classification. Replace live Overpass viewport fetches with a **pre-built routable graph** and a **cost-profile routing engine** (Valhalla). The map is the display surface; the product is the routing brain behind it.

---

## What to keep from the current chassis

| Asset | Why it survives |
|-------|-----------------|
| Dark rally-dash + amber aesthetic | Real product language |
| Surface classification (tracktype → Service / ATV / Single) | Becomes edge cost inputs |
| Legal-access parsing | Route eligibility filter |
| Basemap + overlay hierarchy (Paved / Service / ATV / Single) | Route visualization language |

## What to replace

| Current | Problem | Replace with |
|---------|---------|--------------|
| Live Overpass per viewport | No topology, no region graph | Pre-processed NS (then Canada) graph |
| Isolated GeoJSON LineStrings | Trails don't "connect" | Nodes + edges with shared endpoints |
| Auto-scan on pan | Viewer mental model | Load region once, route over it |
| Client A* sketch | Fragile, incomplete | Valhalla (or GraphHopper) custom profiles |

---

## Recommended stack: Valhalla

**Why Valhalla over GraphHopper / OSRM:**

- Custom **costing models** per edge (surface, tracktype, highway class)
- "Avoid pavement / prefer dirt" is a config profile, not a custom pathfinder
- Mature motorcycle / bicycle costing as starting points
- Self-hostable; tile-based graph builds from OSM PBF

**GraphHopper** is a solid alternative if Valhalla ops are too heavy early on.  
**OSRM** is fast but rigid on custom costs — poor fit for surface-mix routing.

---

## Architecture

```
┌──────────────────────────────┐
│ Data sources                 │
│ OSM PBF (Geofabrik NS)       │
│ NS Topographic / resource    │
│ Canada forestry roads (later)│
└──────────────┬───────────────┘
               │ one-time / scheduled build
               ▼
┌──────────────────────────────┐
│ Graph builder                │
│ • Extract ways + nodes       │
│ • Tag → surface class        │
│ • Build Valhalla tiles       │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Valhalla routing service     │
│ Custom cost profiles:        │
│   dirt_max / mixed / easy    │
└──────────────┬───────────────┘
               │ /route API
               ▼
┌──────────────────────────────┐
│ DIRT. map UI                 │
│ Drop A + B → route polyline  │
│ Surface breakdown bar        │
│ Mix slider (re-cost + re-run)│
└──────────────────────────────┘
```

---

## Surface classes → edge costs

These map 1:1 to the legend the rider sees:

| Class | OSM signals | Rider meaning | Cost when "prefer dirt" |
|-------|-------------|---------------|-------------------------|
| **Paved** | motorway, primary, secondary, paved | Highway / street | High |
| **Service** | track grade1–2, service, forestry | Truck / logging road | Low–medium |
| **ATV** | track grade3–4, unpaved unclassified | Quad / intermediate | Low |
| **Single** | path, bridleway, track grade5 | Narrow / hard | Configurable (often high to avoid) |

The slider ("minimize pavement / maximize trail") reweights these costs and re-runs the same A→B query.

---

## Build order

### 1. Region graph (Nova Scotia first)
- Download `nova-scotia-latest.osm.pbf` from Geofabrik
- Build Valhalla tiles for NS bounding box
- Host Valhalla (Docker on a small VPS, or managed later)
- Verify: route between two known points returns geometry

### 2. Cost profile
- Map `highway` + `tracktype` + `surface` into the four classes above
- Expose profiles: `dirt_max`, `mixed`, `easy` (less single, more service/paved)
- Return per-leg surface stats for the breakdown UI

### 3. A→B UI (on current map chassis)
- Tap origin, tap destination (or long-press)
- Draw route polyline
- Show: distance, estimated time, **% Paved / Service / ATV / Single**
- That surface breakdown is the product moment

### 4. Mix slider
- Re-run route with different costs
- Cheap once Valhalla profiles exist

### 5. Expand data
- Merge NS Open Data resource roads into graph build
- Add Canada forestry layers where OSM is thin
- Then other provinces

---

## What NOT to do next

- Don't invest more in "scan everything in viewport" as the core architecture
- Don't write a custom A* over live GeoJSON — topology and costing will fight you
- Don't treat Canada Open Data shapefiles as a live browser API — bake them into the graph build

---

## Parallel track: viewer UX (still useful)

While the routing brain is built, the map viewer can stay as:

1. **Legend** — Paved / Service / ATV / Single (toggle visibility)
2. **Source toggles** — OSM / NS / Canada (see where data comes from)
3. **Classification QA** — confirm Lake Charlotte etc. look right before graph build

This validates the cost taxonomy riders will use in routing.

---

## Immediate next engineering steps

1. Fix and ship viewer legend + source toggles (display layer)
2. Spin up Valhalla + NS PBF in Docker; prove one A→B route
3. Wire `/api/route?from=&to=&profile=` through Vercel → Valhalla
4. Add drop-two-pins UI + surface breakdown
5. Add mix slider

---

*Updated from product audit: routing-first reframing, July 2026.*
