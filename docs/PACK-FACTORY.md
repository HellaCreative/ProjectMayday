# DIRT Pack Factory

**Status:** canonical regional-pack production and release contract

**Frozen routing mould:**
`94b467a11375e3ea3233c127b07af2ef039d0658`
(`routing-rc1-2026-09-03`)

Pack Factory replicates the accepted OSM-only V3 regional fabric. It creates
data; it does not tune routing. A Pack Factory run is complete only when the
exact tested bytes have an immutable release record, are promoted through the
guarded ship path, are selected by LIVE and PACKS, and pass the region-scoped
identity assertion.

Cursor's Pack Factory skill may orchestrate this process, but this repository is
the product authority. If a skill, chat memory, or older document conflicts with
this file, follow this file and the source documents below.

## Authority order

1. `AGENTS.md`
2. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`
3. `docs/ROUTING-FREEZE-2026-09-03.md`
4. this document
5. `docs/PACK-DATA-V3-AUTHORITY.md` for the exact binary/data model
6. checked-in builders, registries, tests, and guarded ship scripts

Old phase reports and handoffs are evidence only. They do not authorize a
different schema, source, taxonomy, release path, or route objective.

## The reference product

The frozen V3 set is `ns`, `nb`, `pe`, `nl`, `qc`, and `on`. Their immutable
release IDs and accepted hashes are recorded in the freeze document. Those
regions are read-only reference moulds during ordinary factory work.

Every new region contains:

- `graph.v3.bin` — OSM-only routable graph with lossless V3 leaves;
- `geometry.v1.bin` — geometry paired with that exact graph;
- `fuel.v1.json` — packed OSM fuel stations for route proof; and
- an immutable `dirt-pack-release.v1` record containing names, byte counts, and
  SHA-256 hashes.

The live service and the phone download the same promoted objects from R2.
There is no live-only graph, downloadable-only graph, or longhaul substitute.

## Frozen input and data laws

- Use the region registered in `routing/registry/geofabrik.js` and clip the
  current Geofabrik OSM extract to the OSM administrative polygon.
- Foundational packs are OSM-only. Do not add a provincial or commercial
  supplement, even if an adapter exists on disk.
- Preserve raw surface, road-class, tracktype, smoothness, layer, structure, and
  access leaves. Families are derived at read time. Never bucket away leaf data
  during the build.
- Keep surface and access independent. Unknown surface is not dirt; unknown
  access is not permission. Clean forces unknown access off.
- Include the accepted track/path/ATV/ferry membership and topology laws from
  the V3 authority. Do not add cycleways or synthetic connectors.
- Dictionary cardinality fails closed above 255. Do not truncate, wrap, merge,
  or silently remap a region to make it fit.
- Cross-region seams use the neutral OSM fabric. A region build must not modify
  the bytes of an already accepted neighbour.
- Use a fresh immutable release ID for changed bytes. Never reuse a release ID
  with different checksums.

## One-region factory loop

Work on one region at a time. A batch may prepare several local candidates, but
candidate deployment, acceptance, and promotion remain individually auditable.

### 1. Preflight

- Confirm the branch and a clean or deliberately checkpointed tree.
- Confirm the frozen reference hashes have not changed.
- Confirm the region exists in the Geofabrik registry.
- Add deliberate acceptance routes for the region before claiming quality.
- Record the OSM source slug/snapshot provenance and the neighbouring seams that
  must be exercised.

### 2. Build graph and geometry

From the repository root:

```sh
node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-region-graph-v3.js <region>
```

`--reuse-extract` is permitted only when the exact cached extract provenance is
recorded. The builder must report V3 output, edge/node counts, and dictionary
cardinalities. It must stage `graph.v3.bin` and `geometry.v1.bin` under
`scripts/pack-fabric/app/data/packs/v1/<region>/`.

### 3. Build fuel

Create the matching OSM fuel extract and sidecar using the registered Geofabrik
slug and country:

```sh
bash scripts/pack-fabric/scripts/extract-osm-fuel.sh <geofabrik-slug> <canada|us>
node scripts/pack-fabric/scripts/pack-region-fuel.js <region>
```

Fuel absence is not inferred from viewport markers or Overpass. The packed
sidecar is the proof source used by LIVE and offline planning.

### 4. Validate locally

At minimum:

```sh
npm test
node scripts/pack-fabric/scripts/audit-region-routes.js <region> \
  --out scripts/pack-fabric/routing/data/reports/<region>-route-acceptance.json
```

The acceptance fixture must cover Dirt, Dirt with Allow Unknown, Balanced, and
Clean; representative urban avoidance; at least one seam where applicable;
ferry behaviour where applicable; and zero-, one-, and multi-stop fuel cases
that make geographic sense for the region. Exact routes may differ by region,
but the frozen route laws may not.

Reject the candidate if it:

- returns less dirt for Dirt than Balanced on a representative connected ride;
- crosses a major urban core as a shortcut without the explicit last-resort
  fallback;
- treats unknown access as allowed when Allow Unknown is off;
- invents a connector, crosses water without a ferry, or breaks a seam;
- loses graph/geometry pairing or omits required fuel data;
- exhausts a dictionary or changes an accepted region's bytes; or
- requires a routing-cost/search change to make the pack look acceptable.

If the last item occurs, stop and report it as a routing-candidate decision. Do
not hide an engine change inside Pack Factory.

### 5. Record and upload the immutable candidate

Create the immutable release record and upload its exact objects without
deploying LIVE yet:

```sh
node scripts/pack-fabric/scripts/ship-routing.js \
  --candidate <release-id> --pack <region>
```

This command writes the release record. Add the region exactly once to both V3
registries so the live loader requests `graph.v3.bin`:

- `scripts/pack-fabric/routing/schema/v3-regions.json`
- `scripts/pack-fabric/routing/data/v3-regions.json`

Commit the registry/fixture/report/release work so the live deployment has a
real source identity. The binary files and raw extracts are normally
gitignored; their immutable checksums live in the release record.

### 6. Point LIVE at the recorded candidate

```sh
node scripts/pack-fabric/scripts/ship-routing.js \
  --candidate <release-id> <region> --live
```

Without `--pack`, this re-verifies the staged files against the recorded hashes
and deploys LIVE with a region-only candidate override. The approved download
catalog remains unchanged. Record the returned service build and graph,
geometry, and fuel identities.

### 7. Candidate acceptance

Run the fixed local and live region audit, seam probes, fuel cases, and any
relevant shared regression suites. A new geography may add a regression; it may
not turn an existing green reference test red. For a rider-visible or high-risk
region, complete the physical acceptance pass before promotion.

### 8. Promote the exact bytes

After acceptance, verify that the staged bytes still match the release record,
then promote:

```sh
node scripts/pack-fabric/scripts/ship-routing.js \
  --promote <release-id> --pack <region>
```

Deploy LIVE from the committed tree without the candidate override, then prove
that LIVE and the downloadable object are identical:

```sh
node scripts/pack-fabric/scripts/ship-routing.js --live
node scripts/pack-fabric/scripts/ship-routing.js --assert --region <region>
```

`--assert` always requires one explicit `--region`. Bare `--pack` is forbidden.
The ship script merges only the promoted region into the remote catalog; never
publish the checked-in seed manifest as a replacement for the public catalog.

### 9. Close the record

The handoff for each region must state:

- region and immutable release ID;
- OSM source slug/snapshot provenance;
- graph, geometry, and fuel byte counts and SHA-256 values;
- dictionary cardinalities and graph/node counts;
- local and LIVE acceptance results;
- seam and fuel cases run;
- deployed `serviceBuild` and `serviceContract`;
- region-scoped lockstep assertion result; and
- any honest limitation that remains.

“Built locally,” “uploaded,” or “looks right” is not done.

## Factory completion gate

A region is complete only when all of these are true:

- exact V3 artifacts exist and decode in both JS and Swift-compatible readers;
- the immutable release record matches the tested bytes;
- candidate tests passed without changing the frozen routing engine;
- the exact candidate bytes were promoted;
- both V3 registries contain the region;
- production LIVE was redeployed from committed source;
- `--assert --region <region>` passed; and
- the result is recorded for Android/PACKS consumers.

If any gate fails, leave the current promoted region untouched and report the
candidate as incomplete. Never repair a failed promotion by weakening the
router or overwriting the public catalog.
