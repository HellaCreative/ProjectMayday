# Play: full-split fabric (`fabric-v4-20260917-02`)

Binary: **`PLACEHOLDER`** on `cursor/play-full-split-fabric-1885`. Richard presses Play.

## Catalog

Dev AppConfig points at full candidate **`fabric-v4-20260917-02`** (CA + US, **67 regions**, `completeFabric: true`).

- Includes halves: `on-s`/`on-n`, `qc-s`/`qc-n`, `ca-s`/`ca-n`, `nl-island`/`nl-lab`
- Does **not** ship parent packs `on` / `qc` / `ca` / `nl`
- Production **`fabric-v4-20260909-02`** is untouched
- Speed foundation kept (`09b355a` / `e885805`)
- Never the ON-only partial `fabric-v4-20260917-01`

Public base:

`https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/v4/candidates/fabric-v4-20260917-02/`

## R2 verified (before Play)

| Object | HTTP |
| --- | --- |
| `release.json` | **200** (sealed, completeFabric true, regionCount 67) |
| `cross-pack-topology.v2.json` | **200** |
| Sample manifests `ns`, `on-s`, `ca-s`, `nl-lab`, `tx` | **200** |

## What this unlocks

Province↔state travel testing with install prompts everywhere — not Ontario-only. Prior partial `fabric-v4-20260917-01` broke pack prompts outside ON; this catalog is the full national set.

## Play

1. Play **`PLACEHOLDER`**.
2. Open PACKS: every region should list, plus ON/QC/CA/NL halves (no parent `on`/`qc`/`ca`/`nl`).
3. Pin anywhere in CA or US → install prompt for the covering pack(s).
4. Build a province↔state route (e.g. NS→ME, ON-south→NY, QC-south→VT, BC→WA). Confirm route builds.
5. If install/prompt looks wrong outside Ontario, stop and send debug — do not keep testing on a partial catalog.

## Notes

- Island Newfoundland routes via NS ferry and/or Labrador → QC-north; there is no direct `nl-island`↔`qc-s` seam.
- Production release path is unchanged until Richard asks to promote.
- Not Apple-ready; this is Play-only.
