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


```
region: qc   release-id: qc-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: ca15d1709dabcee69eeb4f2bd79cb53a7987bbe05571083def18cb58d3359ec9
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 12827  free-space: 0
largest permissive component: 95.62% of edges
urban cores: 29 hard / 186 scored
seams built: on-qc           seams deferred: qc-nb, qc-nl
route acceptance: 8/15 — red: long-gatineau-gaspe dirt/direct no route; dirt-allow-unknown + balanced safety limit; urban-laval-longueuil dirt 0%<15%; dirt-allow-unknown 9%<25%; balanced 0% off 50/50
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/qc-osm-20260821-01   promoted: NO
tag: pack-qc-osm-20260821-01
note: ON re-cut on-osm-20260821-02 after ON–QC seam
```


```
region: nb   release-id: nb-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 0626ad15cf001e83ef9b30b160c63d155da92f0093f13784b865642490eeaf9e
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 2802  free-space: 0
largest permissive component: 95.92% of edges
urban cores: 5 hard / 46 scored
seams built: qc-nb           seams deferred: nb-ns (NS frozen); nb-pe pending
route acceptance: 15/15
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/nb-osm-20260821-01   promoted: NO
tag: pack-nb-osm-20260821-01
note: QC re-cut qc-osm-20260821-02 after QC–NB seam
```


```
region: pe   release-id: pe-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 87601a175a08d544e19f16cc69b59cb7be5211e6016f9e97046eeb239f83d25f
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 973  free-space: 0
largest permissive component: 98.62% of edges
urban cores: 1 hard / 12 scored
seams built: nb-pe           seams deferred: none
route acceptance: 14/15 — red: short-montague-georgetown/balanced 22% off 50/50
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/pe-osm-20260821-01   promoted: NO
tag: pack-pe-osm-20260821-01
```


```
region: nl   release-id: nl-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 2eabe993c7e5fec7ee1b328e894ab23935b9f444543878275763a5c6c10a99e8
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 4741  free-space: 0
largest permissive component: 89.34% of edges
urban cores: 3 hard / 343 scored
seams built: qc-nl (96 anchors / 44 OSM ways / 0 m gap — Fermont–Labrador City R389/TLH 500)
route acceptance: 12/15 — red: long-port-aux-basques-st-johns dirt/balanced/direct no route (allow-unknown completes)
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/nl-osm-20260821-02   promoted: NO
tag: pack-nl-osm-20260821-02
note: QC–NL was wrongly deferred as ferry-only. Labrador land corridors share OSM topology with QC (Fermont: 559 shared way IDs / 8135 quantized verts; Blanc-Sablon R138/R510: 8 / 564). Prior seam failure: NL pack giant is Newfoundland island (~119k nodes); Labrador is 2nd component (~8.8k). build-cross-pack-seams now uses the largest component touching shared candidate ways. QC re-cut qc-osm-20260821-03. Blanc vertices qualify but spread selected Fermont density.
```


```
region: yt   release-id: yt-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 6ad12035926125c9c7c3b66e5b45dd22e61488af4c0ffa822f258312040eafa4
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 610  free-space: 0
largest permissive component: 81.27% of edges
urban cores: 1 hard / 9 scored
seams built: bc-yt           seams deferred: yt-nt
route acceptance: 8/15 — red: long-watson-lake-dawson all 5 profiles no route; short dirt 28%<40%; dirt-allow-unknown 30%<50%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/yt-osm-20260821-01   promoted: NO
tag: pack-yt-osm-20260821-01
note: BC re-cut bc-osm-20260821-04 after BC–YT seam
```


```
region: nt   release-id: nt-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 64be5b7f4d9047c9efdd9b3917d25b47338608b03560feef6762785af92e8e1f
steps 1–7: ok (urban pack now allows 0 hard cores; 12 settlements)
audit contradictions: 0     non-OSM edges: 0
stitches: 367  free-space: 0
largest permissive component: 76.03% of edges
urban cores: 0 hard / 12 scored
seams built: (none)           seams deferred: yt-nt (no shared routable OSM vertex)
route acceptance: (prior matrix; fuel now present — 49 stations)
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/nt-osm-20260821-02   promoted: NO
tag: pack-nt-osm-20260821-02
note: -01 replaced after zero-cores fix + proper step 6/7 + fuel
```


```
region: nu   release-id: nu-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: 8f10f6fe96b11c15b425540aa9090c49d4da8889357ee468722b92c83e84ae5a
steps 1–7: ok (urban pack 0 hard cores / 54 settlements — no empty-sidecar workaround)
audit contradictions: 0     non-OSM edges: 0
stitches: 306  free-space: 0
largest permissive component: 8.30% of edges
urban cores: 0 hard / 54 scored
seams built: (none)           seams deferred: mb-nu, nt-nu (no shared land OSM vertex)
route acceptance: (prior matrix retained for red-row history)
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/nu-osm-20260821-02   promoted: NO
tag: pack-nu-osm-20260821-02
note: -01 workaround superseded after zero-cores fix
```


```
region: ns   release-id: ns-osm-20260821-02   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: e2b9c773416988d1e74bb97f2f46aa2c935cd674db734726f5c4e227c50dd627
steps 1–7: ok
audit contradictions: 0     non-OSM edges: 0
stitches: 5127  free-space: 0
largest permissive component: 98.77% of edges
urban cores: 3 hard / 57 scored
seams built: nb-ns (96 anchors, 0 m gap)           seams deferred: none
route acceptance: 14/15 — red: long-yarmouth-sydney/dirt-allow-unknown 88%<90%
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260821-02   promoted: NO
tag: pack-ns-osm-20260821-02
note: replaces frozen ns-osm-20260820-01; NB re-cut as nb-osm-20260821-04 after NB–NS seam
```

```
region: nb   release-id: nb-osm-20260821-04   (updated after NB–NS seam)
seams built: qc-nb, nb-pe, nb-ns
candidate: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/nb-osm-20260821-04
tag: pack-nb-osm-20260821-04
```



```
region: id   release-id: id-osm-20260821-01   geofabrik ts: 2026-08-20T20:20:51Z   pbf sha: d0c711f742acb7d000eed487e6fd7061ccef4a38ae4882a3c3c494f027041b91
steps 1–7: ok (fuel after US slug map)
audit contradictions: 0     non-OSM edges: 0
stitches: 8267  free-space: 0
largest permissive component: 97.62% of edges
urban cores: 140 hard / 49 scored
seams built: wa-id, bc-id           seams deferred: id-mt, id-or, id-nv, id-ut, id-wy (US later)
route acceptance: 13/15 — red: long-lewiston-idaho-falls/cleanest 21%>Clean max; short-mccall-cascade/cleanest 39%>Clean max
candidate uploaded: https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/id-osm-20260821-01   promoted: NO
tag: pack-id-osm-20260821-01
note: WA re-cut wa-osm-20260821-03; BC re-cut bc-osm-20260821-05 after ID seams
```

## Session status

**Canada complete including NS rebuild.** **US states next.** — resume from tag `pack-nu-osm-20260821-01` with order `id`, `mt`, `or`, then A–Z remainder; add Geofabrik slug mappings per state as needed.

### Latest live candidates (promote when physical OK)

```
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-05 --pack bc --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote ab-osm-20260821-02 --pack ab --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote wa-osm-20260821-03 --pack wa --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote sk-osm-20260821-02 --pack sk --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote mb-osm-20260821-02 --pack mb --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote on-osm-20260821-02 --pack on --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote qc-osm-20260821-03 --pack qc --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote nb-osm-20260821-04 --pack nb --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote pe-osm-20260821-01 --pack pe --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote nl-osm-20260821-02 --pack nl --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote ns-osm-20260821-02 --pack ns --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote id-osm-20260821-01 --pack id --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote yt-osm-20260821-01 --pack yt --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote nt-osm-20260821-01 --pack nt --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote nu-osm-20260821-01 --pack nu --live --assert
```


```
node scripts/pack-fabric/scripts/ship-routing.js --promote sk-osm-20260821-01 --pack sk --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote bc-osm-20260821-03 --pack bc --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote ab-osm-20260821-02 --pack ab --live --assert
node scripts/pack-fabric/scripts/ship-routing.js --promote wa-osm-20260821-03 --pack wa --live --assert
```

## Claude disk / shard / bench notes (2026-08-21)

- Post-ship scrub: delete OPL/extracted-roads/source pbf/`graph.v1.json.gz` and region copies of `graph.v2.bin`/`geometry.v1.bin`; keep packs + urban/seam sidecars + reports. Wired into `/tmp/dirt-finish-us-state.sh` via `/tmp/dirt-scrub-region.sh`. Swept all shipped regions except in-flight FL; poi cache ~11G → ~0.6G.
- Sharded Map patch PE verify vs `pe-osm-20260821-01`: `graph.v2.bin` and `geometry.v1.bin` **byte-identical**; `fuel.v1.json` same size, different SHA (fuel non-determinism — not a shard regression). Pre-CA regions do **not** need re-cut for the shard patch.
- `npm run bench:ns` re-run against promoted stable NS (`…/ns`); baseline committed `cec508d` (38/65 green).

## Session complete (2026-08-22)

- **Canada:** 13 provinces/territories **promoted** on stable R2 (`bc` through `nu`, including `ns-osm-20260821-02`).
- **US:** all **51** states + DC uploaded as **live-candidates** (`ALL_US_COMPLETE` 2026-08-21T20:24:08Z). Not promoted — physical OK still required per region.
- **Live deploy:** `node scripts/pack-fabric/scripts/ship-routing.js --live --assert` succeeded on Pro (`dpl_9xbXdzxymwKt8LawfCGUrVgqQiAH`). `R2_REGION_BASE_OVERRIDES` set for **51** live-candidate US regions; promoted Canada resolves from stable R2 with no override.
- **Ship helper:** `--live` now auto-builds overrides from release records (latest release per region; skip override when latest is promoted). Per-state Vercel deploys no longer required.
- **Assert:** lockstep check updated to fetch candidate URLs for live-candidate regions (e.g. WA `-04`).
- **Log:** `scripts/pack-fabric/routing/data/reports/pack-rebuild-2026-08/live-deploy-final.log`

### Fuel backfill (2026-08-22)

Four US candidates had shipped **without** `fuel.v1.json` (acceptance `packed fuel 0`). Rebuilt OSM fuel and re-candidate’d:

| Region | Stations | Candidate |
| --- | ---: | --- |
| me | 1012 | `me-osm-20260821-02` |
| nh | 982 | `nh-osm-20260821-02` |
| nv | 1857 | `nv-osm-20260821-03` |
| wy | 572 | `wy-osm-20260821-02` |

Live redeployed with updated overrides; lockstep assert green. Acceptance theme triage: `scripts/pack-fabric/routing/data/reports/pack-rebuild-2026-08/ACCEPTANCE-TRIAGE.md`.

### US promote commands (do not run until physical OK)

Run individually after device testing:

```
node scripts/pack-fabric/scripts/ship-routing.js --promote <release-id> --pack <code> --live --assert
```

Latest release id per US state is the highest `-osm-20260821-NN` in `routing/data/releases/`.
