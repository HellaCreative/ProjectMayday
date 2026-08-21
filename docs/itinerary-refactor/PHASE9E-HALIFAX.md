# Phase 9e — through-Halifax diagnosis

Benchmark pins: `44.650000,-63.750000` to `44.700000,-63.300000`.

## Findings

- Point 1 is exactly on the inclusive west boundary of the built-in Halifax
  urban wall (`minLon = -63.75`) and inside its latitude range. The endpoint
  exemption is therefore active for that wall.
- Both pins match the live Nova Scotia OSM graph. Point 1 snaps 91 m to
  `osm-b59b1c1843f6`; point 2 snaps 277 m to `osm-fb058d9a5d6f`. This is not an
  off-graph or water pin, so the benchmark coordinates were not moved.
- Dirt, Balanced, and Direct return a proved `noPath`; on the measured build
  they return in 3.3 s, 1.0 s, and 0.6 s respectively. The former 18-second
  Balanced failure is no longer present.
- Clean completes only after its labelled settlement/unpaved fallback. This
  proves the endpoint wall exemption and graph connectivity work; the remaining
  difference is the adventure profiles' settlement-wall fallback sequence.

## Proposed one-line behaviour fix — requires sign-off

In the proved-no-path adventure fallback in `router.js`, change
`settlementWall: true` to `settlementWall: false` (retaining
`settlementFallback: true`) so Dirt, Balanced, and Direct get the same final
scored settlement escape that Clean already uses. This is deliberately not
applied in Phase 9e because the phase is diagnosis-only.
