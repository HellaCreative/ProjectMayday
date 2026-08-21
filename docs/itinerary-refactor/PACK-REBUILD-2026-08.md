# Pack rebuild 2026-08

Live OSM-only candidates except frozen Nova Scotia (`ns-osm-20260820-01`).
Steps 1–10 per `docs/09-OSM-PACK-QUALITY-STANDARD.md`. No promotion.

**Branch/worktree:** `feature/pack-rebuild-2026-08` @ `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt-pack-rebuild`
**Live:** `dirt-mayday` with cumulative overrides always including NS.

## Regions

```
region: bc   release-id: bc-osm-20260821-03   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 0d8cb68a6fb32e244eef2ae2fc9d237d248701c7eea1c7e286c70f2ad8644fa2
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 25450  free-space: 0
largest permissive component: 70.97% of edges
urban cores: 33 hard / 145 scored
seams built: bc-ab, bc-wa           seams deferred: bc-id (US later); *-ns skipped
route acceptance: 13/15 — red: urban-abbotsford-merritt/dirt 65%<70%; urban-abbotsford-merritt/dirt 26.7% backward>25%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/bc-osm-20260821-03   promoted: NO
note: -01 then -02 (AB seam) then -03 (WA seam via --left-seq/--right-seq)
tag: pack-bc-osm-20260821-03
```

```
region: ab   release-id: ab-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 4d8b08d3e48a06fac87376acf21970e89245ea1ec6996a19071ecf21d3a55ebb
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 15522  free-space: 0
largest permissive component: 98.57% of edges
urban cores: 14 hard / 125 scored
seams built: bc-ab           seams deferred: ab-sk, ab-mt
route acceptance: 15/15 — pin note: short dest moved to Bragg Creek→Black Diamond (Longview/Turner Valley off-graph)
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ab-osm-20260821-02   promoted: NO
tag: pack-ab-osm-20260821-02
note: -01 superseded after AB–SK seam
```

```
region: wa   release-id: wa-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: a3b85feed0d7ccf98fc19624f879e11a2b360a5e4d1fff48fa50b07b39fdfa3e
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 16037  free-space: 0
largest permissive component: 96.43% of edges
urban cores: 58 hard / 159 scored
seams built: bc-wa (via --left-seq/--right-seq after Node string-limit on graph.v1)           seams deferred: wa-id, wa-or
route acceptance: 9/15 — red: urban-tacoma-everett/dirt 20%<30%; urban-tacoma-everett/balanced timeCap + 10% off 50/50; short-concrete-marblemount/dirt 1%<50%; dirt-allow-unknown 51%<60%; dirt < balanced
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/wa-osm-20260821-02   promoted: NO
note: wa-osm-20260821-01 uploaded pre-seam; superseded by -02 after BC–WA seam
tag: pack-wa-osm-20260821-02
```


```
region: sk   release-id: sk-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 11f2806d18e11f59d83c62894f4a301650834d2994ea7b20fed274740ff9ecee
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 8865  free-space: 0
largest permissive component: 99.45% of edges
urban cores: 4 hard / 157 scored
seams built: ab-sk           seams deferred: sk-mb, sk-nt
route acceptance: 15/15
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/sk-osm-20260821-01   promoted: NO
tag: pack-sk-osm-20260821-01
note: AB re-cut ab-osm-20260821-02 after AB–SK seam
```


```
region: mb   release-id: mb-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 226f75f37653193d1a3e860c841deadc46cee3d83faadc9b91eec79e39fb5676
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 2978  free-space: 0
largest permissive component: 98.00% of edges
urban cores: 2 hard / 163 scored
seams built: sk-mb           seams deferred: mb-on, mb-nu
route acceptance: 14/15 — red: long-brandon-thompson/dirt 47%<50%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/mb-osm-20260821-01   promoted: NO
tag: pack-mb-osm-20260821-01
note: SK re-cut sk-osm-20260821-02 after SK–MB seam
```


```
region: on   release-id: on-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 3791ca7e78ab94931dc761097ab194fd1c5089d58401049975f88d077aed6d93
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 11791  free-space: 0
largest permissive component: 97.60% of edges
urban cores: 52 hard / 271 scored
seams built: mb-on           seams deferred: on-qc
route acceptance: 12/15 — red: long-windsor-ottawa/dirt-allow-unknown safety limit; long-windsor-ottawa/balanced timeCap; urban-hamilton-oshawa/balanced timeCap
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/on-osm-20260821-01   promoted: NO
tag: pack-on-osm-20260821-01
note: MB re-cut mb-osm-20260821-02 after MB–ON seam
```

## Promote commands (not run)

```
node scripts/pack-fabric/scripts/ship-routing.js --promote sk-osm-20260821-01 --pack sk --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-03 --pack bc --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote ab-osm-20260821-02 --pack ab --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote wa-osm-20260821-02 --pack wa --live --assert
```
