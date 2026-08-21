# Pack rebuild 2026-08

Live OSM-only candidates for all regions except frozen Nova Scotia (`ns-osm-20260820-01`).
Follows `docs/09-OSM-PACK-QUALITY-STANDARD.md` steps 1–10. No promotion.

**Branch:** `feature/pack-rebuild-2026-08` (from `feature/routing-itinerary-rebuild` @ d196992 — `main` lacks pack-fabric scripts)
**Worktree:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt-pack-rebuild` (isolates Codex itinerary WIP on `Dirt`)
**Checkpoint:** `e9c6f8a`

## Blocker (applies to every non-NS region)

Step 10 `audit-region-routes.js` requires deliberate fixtures in
`scripts/pack-fabric/routing/registry/acceptance-routes.json`. That file currently
contains **only `ns`**. BC (and every later region) fails immediately with:

`No deliberate acceptance routes registered for bc`

Per hard rule 3: **no pack-fabric code/data change applied**. Proposed minimal
change (human or follow-up approval): extend `acceptance-routes.json` with a
3-route matrix per region (long / urban-chord / short), thresholds patterned on
NS, using known pairs from `analyze-profile-routes.js` where available.

### Proposed BC fixture (not applied)

```json
"bc": {
  "fuelMinimum": 1500,
  "routes": [
    {
      "id": "long-chilliwack-crowsnest",
      "from": { "lat": 49.162, "lon": -121.951, "label": "Chilliwack" },
      "to": { "lat": 49.633, "lon": -114.694, "label": "Crowsnest (BC side)" },
      "minimumDirtPercent": 70,
      "minimumDirtAllowUnknownPercent": 80,
      "balancedTolerance": 10,
      "maximumCleanDirtPercent": 2,
      "maximumDirtBackwardPercent": 30
    },
    {
      "id": "urban-abbotsford-merritt",
      "from": { "lat": 49.0504, "lon": -122.3045, "label": "Abbotsford" },
      "to": { "lat": 50.111, "lon": -120.786, "label": "Merritt" },
      "minimumDirtPercent": 70,
      "minimumDirtAllowUnknownPercent": 80,
      "balancedTolerance": 10,
      "maximumCleanDirtPercent": 2,
      "maximumDirtBackwardPercent": 25
    },
    {
      "id": "short-hope-princeton",
      "from": { "lat": 49.385, "lon": -121.442, "label": "Hope" },
      "to": { "lat": 49.459, "lon": -120.506, "label": "Princeton" },
      "minimumDirtPercent": 70,
      "minimumDirtAllowUnknownPercent": 80,
      "balancedTolerance": 10,
      "maximumCleanDirtPercent": 2,
      "maximumDirtBackwardPercent": 25
    }
  ]
}
```

Thresholds are provisional (NS used 80/90); tune after a local dry-run before
candidate upload. Same registry work is required for AB, WA, and every later
region before step 10 can pass.

Local BC binaries remain on disk in the worktree (`routing/data/regions/bc/` and
staged under `app/data/packs/v1/bc/`) but were **not** uploaded as a candidate.

## Regions

```
region: bc   release-id: bc-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 0d8cb68a6fb32e244eef2ae2fc9d237d248701c7eea1c7e286c70f2ad8644fa2
steps 1–7: ok | failed at 10: no deliberate acceptance routes registered for bc
audit contradictions: 0
non-OSM edges: 0
stitches: 25450  free-space: 0
largest permissive component: 70.97% of edges (meta; 646384 / 910813 native before stitch; final edges 936263)
urban cores: 33 hard / 145 scored
seams built: (none yet)           seams deferred: bc-ab, bc-wa (neighbours not rebuilt); any *-ns skipped (NS frozen)
route acceptance: 0/0 — blocked before matrix (missing fixtures)
candidate uploaded: NO   promoted: NO
commit: (this report)   tag: (none — no candidate)
local graph.v2.bin: 58180223 bytes sha256 f7168ad3a2e4686394e0eca52d0c722aa5470641450d3eefa91f4db4d8eb98a9
local geometry.v1.bin: 72013632 bytes sha256 61b3e6d85438df429a3a17c00ee210b2f01bbed8c1944606cd4793ca376a1a78
local fuel.v1.json: 427984 bytes / 2111 stations
```

## Session stop

Stopped at BC region boundary after steps 1–9 locally completed and step 10
blocked. Did not start AB/WA. Did not run `ship-routing.js --candidate` or
`--promote`. Did not touch NS artifacts.

### Promote commands (for later, after fixtures + candidate upload + physical OK)

```
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-01 --pack bc --live --assert
```

(Not executable until a candidate actually exists on R2.)
