# Cursor pack and release-identity audit

**Date:** 2026-08-22  
**Repository:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`  
**Branch:** `feature/routing-itinerary-rebuild`  
**Authority:** `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` §§3, 4, 8, 9, 12  
**Scope:** read-only. No pack rebuild, upload, promotion, or Git commit. Public CDN `HEAD`/`GET manifest.json` and one live `/api/route` identity probe were used to read currently published bytes; pack binaries were not installed.

Verdict up front: **production live NS and the downloadable NS objects are the same promoted revision (`ns-osm-20260821-02`).** This Dirt worktree’s staged/local NS graph is the older `ns-osm-20260820-01`. The NS benchmark records the 02 CDN URL but, on this machine, `graphPathForRegion` would load the local 20-01 `graph.v2.bin` first. The client is still live-first while online (SoT §4 pack-first is not implemented).

---

## 1. Git commit and worktree

| Field | Value |
| --- | --- |
| Root | `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` |
| Branch | `feature/routing-itinerary-rebuild` |
| Upstream | none |
| HEAD | `321282ef45065dac0dbf82988012794ccaa3bfc2` |
| Author / date | HellaCreative `<62033648+HellaCreative@users.noreply.github.com>` · `2026-08-22T22:01:28-03:00` |
| Subject | `docs: consolidate routing authority and archive review` |
| Working tree | **clean** (no staged, unstaged, or untracked files at audit start) |

Recent commits on this branch:

- `321282e` docs: consolidate routing authority and archive review
- `7cd5a40` checkpoint: known-good routing-itinerary-rebuild baseline (85-90%)
- `35ecdeb` docs: establish product and routing source of truth
- `1da4442` docs: record phase 11 production deployment (SoT §9 bench pin)

Gitignored pack binaries are present on disk under `scripts/pack-fabric/app/data/packs/v1/` and `scripts/pack-fabric/routing/data/regions/` (`.gitignore` lines 7–8, 13–14). They are not in HEAD.

---

## 2. Manifest / configuration sources vs actual consumers

| Source | Path / value | Who actually consumes it |
| --- | --- | --- |
| Public download catalog | `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json` (`version` `v1`, `generatedAt` `2026-08-22T23:20:12.000Z`, 63 regions) | **Downloadable PACKS path.** `AppConfig.packManifestURL` / `packFileURL` (`Dirt/Networking/AppConfig.swift` 35–42). `GraphPackStore.refreshCatalog` / `performDownload` (`GraphPackStore.swift` 108–114, 1089–1140). |
| Stable R2 objects | `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/{id}/graph.v2.bin` (+ `geometry.v1.bin`, `fuel.v1.json`) | **Production live `/api/route`** (no `R2_REGION_BASE_OVERRIDES` on the current dirt-mayday production env). `remoteGraphUrl` (`select.js` 384–391) + `graphCdnBaseUrlForRegion` (`select.js` 326–337). Observed `debug.graphMode=regional-remote`. Same URLs as PACKS downloads. |
| Immutable candidate prefix | `…/candidates/{releaseId}/{id}/…` plus `routing/data/releases/*.json` | **NS bench reporting** (`run-ns-bench.js` 15–42, 722–725). `--candidate` live override (`ship-routing.js` 257–261). Not used by current production (override absent). |
| Staged phone-pack tree | `scripts/pack-fabric/app/data/packs/v1/{id}/` + tracked `manifest.json` | **`--pack` / `--promote --pack` uploader** (`ship-routing.js` 31–31, 85–93, 200–217). **NS bench fuel file** (`run-ns-bench.js` 19–23, 25–30). Not used by the iOS client. Not used by production lambdas (`vercel.json` includeFiles is `routing/{lib,regional,schema}/**` only). |
| Gitignored regional build dir | `scripts/pack-fabric/routing/data/regions/{id}/graph.v2.bin` | **Local Node routing** via `graphPathForRegion` local-first (`select.js` 394–399). If this file exists, the R2 candidate override is never consulted for the graph path. Production does not ship this directory. |
| Release records | `scripts/pack-fabric/routing/data/releases/ns-osm-20260821-02.json` (promoted), `ns-osm-20260820-01.json` (still `live-candidate`) | Bench pin, `--candidate`/`--promote` verify (`ship-routing.js` 146–159). SoT §8 recorded identity. |
| SoT snapshot | `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` §8 | Human/process authority. Catalog `generatedAt` in SoT (`2026-08-21T14:26:33.708Z`) is **stale vs live catalog** (`2026-08-22T23:20:12.000Z`); NS checksums still match `ns-osm-20260821-02`. |
| OSM build report (gitignored) | `routing/data/reports/ns-nrn-supplement-build.json` | Historical local build of **20-01-era** fabric (`dateRetrieved` `2026-08-20T13:06:24.935Z`). Not a release record for 02. |
| Live API URLs | `AppConfig.routeURL` / `liveFuelURL` / `liveFuelChainURL` → `https://dirt-mayday.vercel.app/api/*` | **Client while online** (`RoutingSourcePolicy` returns `live` whenever `isOnline()` is true — `RoutingSource.swift` 449–463). |
| On-device pack store | Application Support `dirt-graph-packs/{manifest.version}/{id}/` | **Client while offline** (`RoutingSource.swift` 463 `pack` branch). Fresh PACKS downloads from the public catalog. Existing files are not replaced (`GraphPackStore.swift` 1130–1134). |
| Lockstep assert | `scripts/pack-fabric/scripts/assert-live-pack-lockstep.js` | Compares **local** `app/data/packs/v1/{bc,ab,wa}` sizes to R2 HEAD; POSTs a BC route. Does **not** assert NS. |

Hard-coded CDN base (same host everywhere that matters): `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev` in `AppConfig.swift` 35, `select.js` 317, `ship-routing.js` 36.

---

## 3. Nova Scotia and Atlantic regions

Atlantic Canada treated as currently in play: **NS** (SoT + bench), **NB / PE** (bbox overlap + chain neighbours), **NL** (promoted CA pack, QC neighbour). Maine is noted only as the NB overlap.

### 3.1 Nova Scotia

| Field | Live service (production) | Stable / downloadable catalog | Immutable candidate `ns-osm-20260821-02` | This worktree staged / regional-local |
| --- | --- | --- | --- | --- |
| Pack / release id | No candidate override. Serves stable `ns/` objects. Bytes match **`ns-osm-20260821-02`**. | **`ns-osm-20260821-02`** (SoT §8; release `status: "promoted"`) | `ns-osm-20260821-02` | **`ns-osm-20260820-01`** (checksum match to that still-`live-candidate` record) |
| Filenames | `graph.v2.bin`, `geometry.v1.bin`, `fuel.v1.json` | same | same | same (fuel also git-tracked) |
| `graph.v2.bin` | Live debug: 217057 edges, 193742 nodes, `schemaVersion=canada-regional-1`. Object `Content-Length` 13562309, ETag `76b958949525fe206d54f1a2fa545286` | sha256 `a9c5cb27eba2dc298344d9c80298881e1e0cfc0d40435d17cd9c4e210d1bef51` · 13562309 bytes | same sha256/bytes; same ETag as stable `ns/graph.v2.bin` | sha256 `20d1c4b79fbbc63ca164ffe683c3e057813c3ddad9f8b3a33d6b4a479c3bf555` · 13535078 bytes |
| `geometry.v1.bin` | HEAD 23395024 · ETag `daf0518503791e55597a6938a415c8ad` | sha256 `01e2741006ae4ee2e4324e2254ca21d6e5ced7cdc2f3c16d0c07688cc09decc6` | same in release JSON | sha256 `41659ed9374ea0f399bfff285a41dd3a5e3f5a9153dcae97fd1146dbffd66a63` · 23394912 bytes |
| `fuel.v1.json` | HEAD 143384 · ETag `fd4e273c4e55a8cba62fd6562b13a96f` | sha256 `999e1cbd5901b2bb28f7c09d7578abe2e7c69ad3e68c25b0b776c0172305fdd2` | same | sha256 `fab91d4030cb3098a9ff2c846abde1444f2496c25fc24ec12bc3a2f1dc866b3f` (HEAD git object + disk) |
| Schema | `canada-regional-1` (live `debug.graph.schemaVersion`) | packFormat `graph.v2` / geometryFormat `geometry.v1` / catalog `version` `v1` | `dirt-pack-release.v1` | gitignored `graph.v1.meta.json`: `canada-regional-1`, `generatedAt` `2026-08-20T13:06:30.266Z`, **217059 edges / 193747 nodes** (two edges and five nodes off live 02) |
| OSM identity | **Unknown** on the live object (no sha/extract timestamp in `/api/route` debug) | **Unknown** in catalog | Release JSON has **no** OSM timestamp | Geofabrik slug `geofabrik:nova-scotia`, URL `…/nova-scotia-latest.osm.pbf`, `dateRetrieved` `2026-08-20T13:06:24.935Z` in gitignored `ns-nrn-supplement-build.json`. Applies to the 20-01 local fabric, not proven for 02. |

Release JSON: `scripts/pack-fabric/routing/data/releases/ns-osm-20260821-02.json` (`promotedAt` `2026-08-21T12:33:50.688560Z`). Older record `ns-osm-20260820-01.json` remains `status: "live-candidate"`.

Live probe (this audit): `POST https://dirt-mayday.vercel.app/api/route` Halifax-area Dirt hop → `graphMode=regional-remote`, `regionIds=["ns"]`, `routingRevision=ride-objectives-v9-settlement-gated`. **No pack sha256 in the debug payload.**

### 3.2 New Brunswick, Prince Edward Island, Newfoundland and Labrador

No `routing/data/releases/{nb,pe,nl}-*.json` in this repo. SoT §8 says all 13 CA provinces/territories are promoted; it does not record Atlantic IDs other than NS.

| Region | Live candidate ID | Stable/downloadable (public manifest + HEAD) | This worktree `app/data/packs/v1/` | Fuel sidecar |
| --- | --- | --- | --- | --- |
| **nb** | None recorded. Production uses stable `nb/` (no override). | graph 9938483 / `0ac58aa73eff10acdfb204379d8d91e0fef0c241d6f2149b4630303bc355f9e1`; geometry 9270308 / `b7936f9be75232f3b41d6d215ec49608797dd95918c0f6778571c817ca2d69e0`; fuel 142574 / `ba62f1e7089b985243b0fdcb95937951456878682414dcfa7afc749ef36b9463`. Last-Modified 2026-08-21. | graph 16918631 / `b90f5cfb3148f0c977181472f4f98408a0b4e267aebae9e6c64136669ee636f2`; geometry 30516384 / `3cfbe4d101f32c8d88e2b33e41a97e56d36c808e57e179446390a6c41bd53d51` — **does not match CDN**. Matches committed local `manifest.json` 455–466. | CDN present. Local **missing**. |
| **pe** | None recorded. | graph 2668717 / `6a06c75b787cd023c9d3ef738a5d6577f3daa72d3171ac1b01dc3060ddca7c13`; geometry 2116644 / `17f96078a39eb0a1ea5e5497c0b21fa6a2f9f7175ed2f5e78dc79c8a7b1659c3`; fuel 27695 / `e6d2c006a51741e38034d21c10b1918af580063ee12fe9604fc9f1a071806223`. | graph 1474207 / `e17ce83f9baa852a96423b158afbcde854f365ea75ab8e3f25ed75ea89180ce5`; geometry 1423344 / `564d3014b9fecda077175e946d7bcf2fb1cf504b2409e0437a69f02697f9efc0` — **does not match CDN**. | CDN present. Local **missing**. |
| **nl** | None recorded. | graph 10446280 / `a2345f7d01e866b6ed09df66b45254cafb811f183fd7120f812da1b941a1b9d6`; geometry 9673940 / `b6fa0ee7e14bcc7ede36443a9b81d98145f6948a8fa53c62a8922123a4d2c1df`; fuel 84081 / `2efb089b3a544e095fc04eb194bad6a357bd99d6d952a4eaeb5ab36d65270eb6`. | graph 6469614 / `818ec66f388bd40a9b70267a370ae6bb886295e1f6939590166c71556ea294be`; geometry 15965112 / `49f193a3ced05e856da04ef4664d3dc48f2c767797074a2ea8959319d57846c4` — **does not match CDN**. | CDN present. Local **missing**. |

Schema for all three on the catalog: same global `packFormat` `graph.v2`. OSM extract identity: **Unknown** (no release JSON; gitignored reports exist only for ns/ab/bc/wa).

Committed local catalog `scripts/pack-fabric/app/data/packs/v1/manifest.json` has `generatedAt` `2026-08-20T13:13:33.284Z` and NS checksums of **20-01**. It is not what PACKS downloads.

---

## 4. Identical-bytes proof

| Pair | Verdict | Evidence |
| --- | --- | --- |
| Production live NS graph vs downloadable `ns/graph.v2.bin` | **Proven** | Production has no `R2_REGION_BASE_OVERRIDES`. `select.js` 326–337, 384–391 load `{cdn}/ns/graph.v2.bin`. Live debug `graphMode=regional-remote`, 217057 edges / 193742 nodes. Catalog sha256 `a9c5cb27…`, HEAD size 13562309. Candidate `ns-osm-20260821-02` graph has the **same ETag** as stable `ns/graph.v2.bin`. |
| Production live NS geometry/fuel vs downloadable | **Proven** (catalog + HEAD; live fuel uses the same `graphCdnBaseUrlForRegion` in `fuel-data.js` 14–16) | Manifest sha256s `01e27410…` / `999e1cbd…` match release `ns-osm-20260821-02.json` 16–25. HEAD sizes match. |
| NS bench (recorded `1da4442-20260822T160913Z.json`) vs 02 candidate URL | **Unknown** historically; **Divergent** if re-run in this worktree | Results claim `graphBase=…/candidates/ns-osm-20260821-02` (`1da4442-….json` 8; `run-ns-bench.js` 722–725). `graphPathForRegion` prefers `routing/data/regions/ns/graph.v2.bin` when present (`select.js` 394–399). That file is **20-01** (`20d1c4b7…`). Bench `mode` would be `regional-local` because `graph.v1.json.gz` exists (`select.js` 526–529). Fuel is the git-tracked **20-01** sidecar (`run-ns-bench.js` 19–30, sha `fab91d40…`) not CDN `999e1cbd…`. |
| Client online vs live NS bytes | **Proven** for the *service* hop; **not** pack-first | `RoutingSource.swift` 463: `return isOnline() ? live : pack`. Online planning hits `AppConfig.routeURL` (`AppConfig.swift` 11, `RoutingClient.swift` 32). SoT §4 pack-first is not this path. |
| Client PACKS install vs downloadable catalog | **Proven** for a *fresh* download; **Unknown/Divergent** if NS already on disk | `packFileURL` ignores version and uses `{cdn}/{id}/{file}` (`AppConfig.swift` 38–42). `performDownload` skips any existing file (`GraphPackStore.swift` 1130–1134) and does not verify sha256. `findGraphFileURL` also accepts any older version folder (`827–839`). |
| Client installed pack vs live 02 | **Unknown** on device | No on-device checksum gate. Default `publishedIds` includes `"ns"` before catalog load (`GraphPackStore.swift` 69). |
| This worktree `--pack ns` payload vs live/downloadable | **Divergent** | Staged NS files = 20-01. `shipPack` would PUT those bytes and **replace** the whole bucket manifest (`ship-routing.js` 200–217). |
| NB / PE / NL laptop staging vs downloadable | **Divergent** | §3.2: every graph/geometry checksum differs; local fuel missing. |
| SoT §8 catalog timestamp vs live catalog | **Divergent (metadata only)** | SoT `generatedAt` `2026-08-21T14:26:33.708Z` vs live `2026-08-22T23:20:12.000Z`. NS sha256 in SoT still matches live NS. |

`useLonghaulPacks` is hard-false (`select.js` 511). Live is not the thinned longhaul extract.

---

## 5. Stale overrides, hard-coded IDs, env, fallbacks

| Item | Location | Risk |
| --- | --- | --- |
| Local `graph.v2.bin` wins over `R2_REGION_BASE_OVERRIDES` | `select.js` 394–399 | Bench/dev can label CDN 02 while routing 20-01. Production is safe (file not included). |
| Hard-coded NS release `ns-osm-20260821-02` | `run-ns-bench.js` 15–17, 36–42 | Pins reporting to 02; does not force the loader to that prefix if a local v2 exists. |
| Leftover `ns-osm-20260820-01` `live-candidate` | `routing/data/releases/ns-osm-20260820-01.json` | Dirt `ship-routing.js` `--live` does **not** auto-collect leftover candidates (no `collectLiveCandidateOverrides`; line 268 passes `liveOverrides` only for `--candidate`). Still a human foot-gun and a stale identity in the repo. |
| `ROUTING_PREFER_LEGACY=1` | `select.js` 418, 444–450 | Single-region NS can load `__legacy_ns__`. Not set on production env (only Supabase keys as project env). |
| `ROUTING_GRAPH_PATH` / `ROUTING_GRAPH_URL` / `R2_PUBLIC_BASE` / `ROUTING_GRAPH_CDN_BASE` | `graph.js` 28–35, 349–355; `select.js` 313–318 | Fallback still mentions `ns/longhaul.v1.json.gz`. Comment on `graph.js` 31–32 still says regional is off until `ROUTING_USE_REGIONAL=1`, which is **stale vs** `useLonghaulPacks = false` (`select.js` 511). |
| `ROUTING_PACKS_V2` default off | `pack-v2.js` 55–59 | URLs ending in `graph.v2.bin` still decode v2 (`graph.js` `isPhonePackV2Path`). Confusing, not the live path. |
| `--pack` replaces entire `manifest.json` | `ship-routing.js` 210–216 | Comment says “merge”; implementation overwrites the bucket object from **local** 20-01-era catalog. Would desync 63 regions. |
| `--promote` verifies against **local** staged checksums | `ship-routing.js` 146–159, 262–264 | `--promote ns-osm-20260821-02 --pack ns` from this tree would **fail** (local ≠ 02) — a safety. Bare `--pack ns` would still publish 20-01. |
| Client live-first | `RoutingSource.swift` 449–463 | `packsCover` / `installed` are logged and ignored. Conflicts with SoT §4. Test `planModeUsesTheInstalledPackRegistry` only asserts the log line (`RoutePlannerModelItineraryTests.swift` 9–38). |
| Skip-if-exists + no sha check | `GraphPackStore.swift` 1130–1134, 1503–1506 (`sha256` decoded but unused in download) | Stale phone NS survives a CDN promotion. |
| Catalog version unused in file URL | `AppConfig.swift` 38–40 `_ = version` | Cannot cache-bust by bumping `manifest.version` alone for the HTTP object path. |
| Hard-coded `publishedIds = ["ns"]` | `GraphPackStore.swift` 69 | NS looks published before catalog fetch. |
| Lockstep assert | `assert-live-pack-lockstep.js` 20, 148–149 | Regions `bc,ab,wa` only; `edgeCount < 400000` would reject an NS-sized graph. Does not protect NS identity. |
| SoT §8 “later Cursor live candidates not in this repo” | SoT 367–374 | Still true: only two NS release JSON files. US/Atlantic candidate IDs are not in `routing/data/releases/`. |
| Production router vs this HEAD | Live `routingRevision=ride-objectives-v9-settlement-gated`; deploy historically from a dirty `feature/routing-itinerary-rebuild` tree (SoT §10 already records client/service mismatch). | Pack bytes can match while **search/fuel code** does not. Out of pack-identity scope but SoT §12.6. |

---

## 6. Seam and overlap tests (inventory, not fixes)

### Present

| Test | File | What it covers | What it does not |
| --- | --- | --- | --- |
| NS road inside PE rectangle → NS by eligible edge | `endpoint-resolver.test.js` 8–45 | Mock probes; PE listed before NS; `regionIds == ["ns"]` | Does not load packs or route NS–PE |
| Eligible primary does not probe every overlap | `endpoint-resolver.test.js` 48–66 | Charlottetown-ish point → `pe` only | No NB/NS/PE three-way coordinate |
| Seam index / urban wall / legId echo | `router-seam.test.js` | Synthetic BC–WA index, urban rejection | No Atlantic coordinates |
| Clean long-haul corridor points | `merge.test.js` 8–23 | Halifax→Vancouver chain; no city-core mids | Not an NS–NB or NB–PE routing test |
| Cross-pack seam ranking | `DirtTests/OnDeviceProfileCostsTests.swift` `CrossPackSeamTests` 282–333 | Synthetic BC–AB / BC–WA anchors | No NS/NB/PE anchors |
| 49th parallel pack id | same file 335–345 | Oroville WA vs BC | No Tantramar / Confederation Bridge / NB–ME |
| Build-time OSM way match | `build-cross-pack-seams.test.js` | Synthetic BC/WA edges | Atlantic |
| Smoke pairs | `smoke-cross-pack-routes.js` 15–25 | **bc-ab**, **bc-wa** only | No Atlantic pair |
| Neighbour graph | `merge.js` 173–177 | `nb: [qc,ns,pe]`, `ns: [nb]`, `pe: [nb]`, `nl: [qc]` | **NS has no direct PE neighbour** (bridge is NB–PE). Un-tested as a route. |
| Bbox overlap code (not tests) | `select.js` 216–243; `GraphPackStore.swift` 1310–1332 | NS/NB/PE and NB/PE split; NB/ME `select.js` 262 | Swift `primaryRegionId` has **no** DirtTest for Amherst, Cape Tormentine, or Confederation Bridge |

### Coverage gaps (Atlantic / CA–US that Gate 2 names)

- No automated route across **NS–NB** (Tantramar / Missaguash).
- No automated route across **NB–PE** (Confederation Bridge), despite `REGION_NEIGHBOURS` encoding it.
- No **NS–PE** overlap *routing* test (only bbox/eligible-edge mocks).
- No **NL–QC**, **NB–ME**, **NB–QC** Madawaska tests.
- No matrix case that loads **promoted CDN** NB/PE/NL bytes (laptop copies diverge).
- `assert-live-pack-lockstep.js` and `smoke-cross-pack-routes.js` ignore the Maritimes.
- SoT §11 “Eligible-edge endpoint resolver and NS/PEI overlap regression coverage” is true for the **mock** JS test, not for pack-backed Atlantic hops.

---

## 7. Immutable release gate vs current process

SoT §§4, 8, 9, 12 plus Gate 3 (§11).

| Requirement | Status | Notes |
| --- | --- | --- |
| OSM-only foundational fabric; overlays inactive | **Implemented and proven** in records for NS 20-01 local meta (`lineage.nrn.omitted=osm-only`). **Unverified** for 02 (no lineage in release JSON). | §3 |
| Live candidate is SoT while testing; immutable prefix | **Partial** | `--candidate` uploads `candidates/{id}/` without rewriting the download catalog (`ship-routing.js` 162–176). Production currently has **no** NS candidate override. |
| Promote exact graph + geometry + fuel bytes | **Implemented but unverified as a repeatable gate in this tree** | 02 is on stable keys and in the public manifest. This tree cannot re-promote 02 from local files (`verifyCandidateRecord` would fail). |
| After promote, live and downloadable are the same objects | **Implemented and proven for NS** | §4 table. |
| Ordinary consumer planning uses the installed approved revision (pack-first) | **Missing / Conflicting** | `RoutingSource.swift` 463 live-first. SoT §4 says not fully implemented. |
| Results identify source and pack revision | **Partial** | Cache key uses `lastManifestVersion` (`v1`), not file sha256. Live debug has `graphMode` / `schemaVersion` / `routingRevision`, **not** pack id or sha256. |
| Currency by immutable identity and checksums, not dates | **Partial** | Catalog stores sha256. Client download ignores them. Skip-if-exists is date- and presence-based. |
| Newer revision recommended, not forced; decline keeps old | **Missing** | No revision comparison UI; skip-if-exists keeps old without asking. |
| Do not change pack bytes and search in the same repair | **Process only** | SoT §12.3. Not enforced in `ship-routing.js` (`--pack --live` is one command). |
| Client and live deployed as a matched release | **Missing** | SoT §10: no contract/commit version on the service. This audit’s live `routingRevision` is a search label, not a git sha. |
| Candidate upload must not rewrite `manifest.json` | **Implemented** | `--candidate` path. |
| Promote must merge, not replace, the 63-region catalog | **Conflicting** | `shipPack` PUTs the local `manifest.json` wholesale (`ship-routing.js` 210–216). |
| Record candidate identities in-repo before calling a rebuild a baseline | **Partial / Missing** | NS 02 is recorded. SoT §8–9: later Cursor live candidates **not** in this repo. NB/PE/NL/US have no release JSON here. |
| `npm run bench:ns` against the **same** pinned pack | **Conflicting on this machine** | Script claims 02 URL; loader would use local 20-01 v2 + 20-01 fuel. Recorded table `1da4442` is 35/40 as SoT §9 states. |
| Lockstep live ↔ phone pack | **Partial** | Asserts BC/AB/WA local vs R2 sizes, not NS, and uses a BC edge-count floor. |
| Physical approval before calling packs approved | **Unverified** | SoT §10 still blocks fuel-device acceptance. |
| OSM extract timestamp in the release record | **Missing** | Geofabrik `-latest.osm.pbf` has no frozen hash/date in `ns-osm-20260821-02.json`. |

---

## 8. Five highest-risk issues (dependency order)

1. **Local graph path shadows the immutable candidate.** `graphPathForRegion` (`select.js` 394–399) loads gitignored `routing/data/regions/ns/graph.v2.bin` (`20d1c4b7…`, 20-01, 217059 edges in sidecar meta) before any R2 override. Until that file is gone or the loader prefers the recorded prefix, **NS bench identity on this laptop is not `ns-osm-20260821-02`**, even though results JSON print that URL (`run-ns-bench.js` 724). This poisons every “same pack” comparison in SoT §9.

2. **`--pack ns` from this tree would publish 20-01 and overwrite the 63-region catalog.** Staged `app/data/packs/v1/ns/*` and committed `manifest.json` are 20-01 / 2026-08-20. `shipPack` (`ship-routing.js` 200–217) PUTs those files and replaces `dirt-packs/manifest.json`. That is the inverse of SoT §4/§12 “current published packs remain untouched.” NB/PE/NL local binaries are also the wrong generation.

3. **Client will not use the promoted downloadable NS pack while online, and may keep a pre-02 copy offline.** `RoutingSource.swift` 463 is live-first. `GraphPackStore.swift` 1130–1134 never re-fetches an existing `graph.v2.bin`. Pack-first (SoT §4) and checksum currency are not implemented. A rider who installed NS before 02 still routes that older graph whenever the phone is offline.

4. **Release identity is incomplete outside one NS JSON file.** No OSM timestamp on 02. No NB/PE/NL/US release records in this repo (SoT §8 already flags unrecorded Cursor candidates). Live `/api/route` debug has no pack sha256. Catalog `generatedAt` in SoT §8 does not match the live catalog. You cannot prove later Atlantic or US “live candidates” from this repository.

5. **Atlantic seam/overlap coverage does not protect the packs that actually ship.** NS/PE overlap is a mock resolver test only. There is no pack-backed NS–NB, NB–PE, NL–QC, or NB–ME route test. Smoke/lockstep are BC/AB/WA. Laptop NB/PE/NL graphs are a different size generation than CDN, so even a new Atlantic test run locally would not be the promoted fabric.

---

## Files inspected

- `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`
- `docs/CURSOR-PACK-IDENTITY-AUDIT.md` (this report; created only)
- `.gitignore`
- `Dirt/Networking/AppConfig.swift`
- `Dirt/Networking/RoutingClient.swift` (via grep; `Dirt/Routing/RoutingClient.swift`)
- `Dirt/Routing/RoutingClient.swift`
- `Dirt/Routing/RoutingModels.swift`
- `Dirt/Routing/OnDevice/GraphPackStore.swift`
- `Dirt/Routing/OnDevice/CrossPackSeam.swift`
- `Dirt/Features/RoutePlanning/Itinerary/RoutingSource.swift`
- `DirtTests/Itinerary/RoutePlannerModelItineraryTests.swift`
- `DirtTests/OnDeviceProfileCostsTests.swift`
- `scripts/pack-fabric/vercel.json`
- `scripts/pack-fabric/scripts/ship-routing.js`
- `scripts/pack-fabric/scripts/assert-live-pack-lockstep.js`
- `scripts/pack-fabric/scripts/smoke-cross-pack-routes.js`
- `scripts/pack-fabric/scripts/build-cross-pack-seams.test.js`
- `scripts/pack-fabric/scripts/publish-packs-cdn.js` (grep)
- `scripts/pack-fabric/scripts/pull-packs-cdn.js` (grep)
- `scripts/pack-fabric/bench/run-ns-bench.js`
- `scripts/pack-fabric/bench/results/latest.md`
- `scripts/pack-fabric/bench/results/1da4442-20260822T160913Z.json`
- `scripts/pack-fabric/routing/regional/select.js`
- `scripts/pack-fabric/routing/regional/select-candidate.test.js` (grep)
- `scripts/pack-fabric/routing/regional/endpoint-resolver.js` (grep)
- `scripts/pack-fabric/routing/regional/endpoint-resolver.test.js`
- `scripts/pack-fabric/routing/regional/merge.js`
- `scripts/pack-fabric/routing/regional/merge.test.js`
- `scripts/pack-fabric/routing/lib/graph.js`
- `scripts/pack-fabric/routing/lib/fuel-data.js`
- `scripts/pack-fabric/routing/lib/pack-v2.js`
- `scripts/pack-fabric/routing/lib/router.js` (grep)
- `scripts/pack-fabric/routing/lib/router-seam.test.js` (grep)
- `scripts/pack-fabric/routing/data/releases/ns-osm-20260821-02.json`
- `scripts/pack-fabric/routing/data/releases/ns-osm-20260820-01.json`
- `scripts/pack-fabric/routing/data/reports/ns-nrn-supplement-build.json` (gitignored; read on disk)
- `scripts/pack-fabric/routing/data/regions/ns/graph.v1.meta.json` (gitignored; read on disk)
- `scripts/pack-fabric/app/data/packs/v1/manifest.json`
- Public `manifest.json` and `HEAD` of NS/NB/PE/NL objects on `pub-eb539dc7777942b889388ebb4b701697.r2.dev`
- Live `POST https://dirt-mayday.vercel.app/api/route` (identity only)

**Confirmation:** no files other than this new report were created or modified. Git was not committed. Packs were not rebuilt, uploaded, promoted, or installed. After writing the report, the only worktree change expected is the untracked file `docs/CURSOR-PACK-IDENTITY-AUDIT.md`.
