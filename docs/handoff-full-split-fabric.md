# Overnight handoff — finish fabric-v4-20260917-02

Written: 2026-09-17 ~20:35 America/Halifax. Stopped so a cloud agent can continue.
Authority: `docs/ROUTING-SOURCE-OF-TRUTH.md`. This file is operational state, not a new routing spec.

## Mission

Finish publishing the **full national DIRT Dev catalog** with huge-region splits so the phone can install packs everywhere, not only inside Ontario.

Candidate: `scripts/pack-fabric/routing/candidates/fabric-v4-20260917-02/` (gitignored).
Sequence: **neighbour fix → 147 catalog seams → thin four split pairs → seal completeFabric → R2 → point Dev → one Play SHA → `docs/play-full-split-fabric.md`.**

Richard presses Play. Do not run the iOS app for him.

## Hard rules

- Checkout: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`
- Work branch: **`cursor/full-split-fabric-36e0`** (tip `c835f4b`)
- Speed foundation **MUST stay**: `09b355a` / `e885805` (PR #24). Do not revert engine commits.
- Never ship a **partial-only** catalog. `fabric-v4-20260917-01` (on-s/on-n only) already broke pack prompts outside Ontario.
- Production **`fabric-v4-20260909-02` is untouched.** Do not upload to `v4/releases/`.
- `no git add -A`. Never stage `scripts/pack-fabric/routing/pbf-cache/`.
- Never stage `GroupsSheet.swift` or `RoutingModels.swift`. No `pbxproj` / build-number edits.
- Never `git fetch`. Do not switch to `cursor/map-lakes-ferry-attractions-9767` to do this job.
- Do not drop or pop unrelated stashes (lakes UI, look-and-feel, GroupsSheet).

## Current laptop git (do not wreck this)

The workspace was left on **`cursor/map-lakes-ferry-attractions-9767`** with **uncommitted look-and-feel / sheet edits**. Those are not this job.

`--seal-only` and the thin-sidecar merge fix are **committed on this branch** (not stash). Do not pop lakes stashes.

Lakes look-and-feel WIP is stashed separately. DO NOT POP:

- `lakes UI preserve for fabric closeout` (RootView / sheets / HUD)
- `lakes map WIP preserve while finishing fabric-v4-20260917-02` (MapLibre/POI/docs)

**Startup:**

1. If the laptop is on `cursor/map-lakes-ferry-attractions-9767` with dirty files, stash them as a **new** stash. Do not `stash drop`.
2. `git checkout cursor/full-split-fabric-36e0`
3. Confirm `git merge-base --is-ancestor 09b355a HEAD` and `e885805`.
4. Confirm `assemble-full-split-fabric.js` has `--seal-only` and `thin-subregion-seams.js` merges existing `neighbors`. If HEAD is still `c835f4b` without those, stop and re-read git log.

Lakes `AppConfig` currently pins Dev to **production `fabric-v4-20260909-02`**. Fabric branch already pins Dev to **`fabric-v4-20260917-02`**. Keep the fabric pin.

## What is already done (on disk, gitignored)

- 67 pack directories exist; catalog ids match `catalogRegionIds()`:
  `ab,ak,al,ar,az,bc,ca-n,ca-s,co,ct,de,fl,ga,hi,ia,id,il,in,ks,ky,la,ma,mb,md,me,mi,mn,mo,ms,mt,nb,nc,nd,ne,nh,nj,nl-island,nl-lab,nm,ns,nt,nu,nv,ny,oh,ok,on-n,on-s,or,pa,pe,qc-n,qc-s,ri,sc,sd,sk,tn,tx,ut,va,vt,wa,wi,wv,wy,yt`
- No leftover parent packs `on` / `qc` / `ca` / `nl`.
- WA graph repaired earlier (size 144809561, matches production).
- AZ graph was restamped to `fabric-v4-20260917-02` / `geofabrik-capture-20260917T015809Z` but its **manifest was still production**. Manifest + text files were refreshed. `AZ_LOAD_OK` before the last seams run.
- Splits built: `on-s`/`on-n`, `qc-s`/`qc-n`, `ca-s`/`ca-n`, `nl-island`/`nl-lab`. Nova Scotia is **not** split.
- `release.json` is still `local-partial-candidate`, `completeFabric: false`, `regionCount: 6` (only the newly built halves listed). That is stale metadata, not the pack set. Seal rewrites it to 67 + topology.

## What failed (blocker)

Last seams run started `2026-09-17T18:51:51Z`, ran ~115 minutes, **121/148 pairs succeeded**, then:

```
nl-island/nl-lab: 18412 legal seams
nl-island/ns: 2 legal seams
nl-island/qc-n: 12 legal seams
Error: no legal V4 seam for nl-island/qc-s
SEAMS_EXIT:1
```

Log: `scripts/pack-fabric/routing/candidates/fabric-v4-20260917-02/logs/seams.log`

`build-v4-seams.js` writes `cross-pack-topology.v2.json` **only at the end**. There is **no topology file**. The 121 pairs are **not saved**. A rerun is required.

`--regions` for that run was the real 67-id catalog (`ca-n`/`ca-s`, not legacy `ca`). Do **not** reuse `/tmp/catalog-regions.txt` — an earlier leftover listed 2-letter `ca,on,qc,nl` and would look for missing `packs/ca`.

## First code fix (do this before rerunning seams)

`nl-island` ↔ `qc-s` is a **false neighbour**. Island↔QC-north proved 12 seams; island↔NS proved 2 (ferry). Island↔QC-south has no legal road/ferry proof. Corridor remains `nl-island → ns` and `nl-island → nl-lab → qc-n`.

Remove **both directions** in lockstep:

1. `scripts/pack-fabric/routing/regional/merge.js` `REGION_NEIGHBOURS`
   - `"qc-s"`: drop `"nl-island"` (keep `"nl"` if present for legacy)
   - `"nl-island"`: drop `"qc-s"`
2. `Dirt/Routing/OnDevice/GraphPackStore.swift` `roadReachableNeighbours` — same two edits.

Then:

```
node -e 'const {catalogRegionIds}=require("./scripts/pack-fabric/routing/registry/geofabrik"); const {uniquePairs}=require("./scripts/pack-fabric/scripts/build-v4-seams"); const cat=catalogRegionIds(); const p=uniquePairs(cat); console.log(cat.length, p.length, p.filter(x=>x.includes("nl-island")&&x.includes("qc-s")).length);'
```

Expect **67 catalog ids, 147 pairs, 0 nl-island/qc-s**.

Optional but strongly recommended: checkpoint `build-v4-seams.js` so a later crash does not throw away another two hours (append each finished pair; resume). Not required if you can afford a full 147-pair rerun (~2h on this disk).

## Seams command (catalog only)

```
CAND=scripts/pack-fabric/routing/candidates/fabric-v4-20260917-02
REGIONS=$(node -e 'process.stdout.write(require("./scripts/pack-fabric/routing/registry/geofabrik").catalogRegionIds().join(","))')
# assert 67, contains ca-n, does NOT contain exact token ca/on/qc/nl
stdbuf -oL -eL node scripts/pack-fabric/scripts/build-v4-seams.js \
  --root "$CAND/packs" \
  --output "$CAND/cross-pack-topology.v2.json" \
  --regions "$REGIONS"
```

Wait for a JSON line with `"pairs": 147` (or 148 if you skipped the neighbour removal — do not skip). `SEAMS_EXIT:0`. File `cross-pack-topology.v2.json` must exist.

## Thin + seal

`thin-subregion-seams.js` **merges** the thinned split pair into existing sidecar `neighbors`. Do not revert that. Overwriting the whole `neighbors` object would delete mi/ny/qc-s/etc. from `on-s`.

Thin pairs (after full topology):

- `on-s,on-n`
- `qc-s,qc-n`
- `ca-s,ca-n`
- `nl-island,nl-lab`

Then seal without recopying 67 graphs:

```
node scripts/pack-fabric/scripts/assemble-full-split-fabric.js \
  --release fabric-v4-20260917-02 --seal-only
```

`--seal-only` is on this branch. After seal:

- `release.json` `status: local-candidate-sealed`
- `completeFabric: true`
- `regionCount: 67`
- `topology.sha256` matches the topology file
- topology `fabricReleaseId` is `fabric-v4-20260917-02`

## R2 (candidate prefix only)

```
node scripts/pack-fabric/scripts/ship-v4-candidate.js \
  --candidate fabric-v4-20260917-02 --pack --verify
```

Public base: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/v4/candidates/fabric-v4-20260917-02/`

Must refuse `--promote` / `--live`. Do not write `v4/releases/`.

Verify `manifest.json` lists all 67 ids including halves, not parents.

## Point Dev + Play SHA

Fabric branch already has:

```
v4CandidateReleaseId = "fabric-v4-20260917-02"
v4CandidateBaseURL = packCDNBaseURL/v4/candidates/fabric-v4-20260917-02
v4ProductionBaseURL = .../v4/releases/fabric-v4-20260909-02
```

`DirtTests.swift` on fabric already expects that pin.

One Play SHA on `cursor/full-split-fabric-36e0` that includes:

- speed ancestry `09b355a` / `e885805`
- neighbour list fix
- thin merge + `--seal-only`
- Dev pin at 20260917-02
- `docs/play-full-split-fabric.md`

Do not include pbf-cache, GroupsSheet, RoutingModels, pbxproj, lakes UI, or landscape HTML experiments.

Play doc must tell Richard:

- PACKS should list every region plus ON/QC/CA/NL halves (not parent `on`/`qc`/`ca`/`nl`)
- Pin anywhere → install prompt
- Production catalog unchanged
- He presses Play

## Known landmines

- `build-v4-seams` default **without** `--regions` uses 2-letter `REGION_NEIGHBOURS` keys → looks for missing `packs/ca`.
- `uniquePairs` already skips a neighbour if either side is not in `--regions`. Legacy `on`/`qc`/`ca`/`nl` in the neighbour lists are OK **as leftover names** if they are not selected. A **selected** pair with zero proofs is a hard fail.
- Same-length restamp of `fabricReleaseId` / `sourceEpoch` inside `graph.v4.bin`. If a manifest SHA drifts, refresh identities; do not recopy production over a restamped graph without restamping again (AZ was that bug).
- Concurrent assemble + seams previously caused “graph does not match its manifest”. Do not recopy packs while seams are running.

## Done / not done

| Step | State |
| --- | --- |
| Speed foundation under fabric line | Done (`c835f4b` parents include `e885805`) |
| 67 packs assembled on disk | Done |
| Catalog-only seams | **Failed** at `nl-island/qc-s`; no topology |
| Thin split sidecars | Not started |
| Seal completeFabric | Not started |
| R2 candidate upload | Not started |
| Dev pin | On fabric branch; not on lakes HEAD |
| Play SHA + play doc | Not started |
| Production 20260909-02 | Untouched |
