# DirtTests lockstep & fixture audit

Explored 2026-09-14. Source: `/Volumes/SIDECAR/LIVE/MAYDAYIOS/Dirt/DirtTests/`.

## Test framework (not XCTest)

The target uses **Swift Testing** (`import Testing`), not XCTest:

| Pattern | Usage |
|---------|--------|
| `@Test` / `@Test("name")` | Test functions on `struct` types |
| `@Suite("…")` / `@Suite(.serialized)` | Grouping (e.g. GraphV4, PackFirstRouting) |
| `#expect(…)` | Assertions (optional message: `"msg route=\(id)"`) |
| `Issue.record(…)` | Soft failure / skip signal |
| `#require(…)` | Unwrap or fail |
| `@MainActor` | UI/async tests |
| `@testable import Dirt` | App module under test |

No `XCTestCase` subclasses. CI/Xcode still run via `DirtTests.xctest` bundle.

## How lockstep tests work

Three tiers:

### 1. Golden JSON fixtures (JS generates, Swift consumes)

JS scripts under `scripts/pack-fabric/scripts/` write expected outputs; Swift tests load JSON and compare.

| Phase | Generator | Fixture | Swift test | What is compared |
|-------|-----------|---------|------------|------------------|
| D | `generate-graph-v3-lockstep-fixture.js` | `ns-graph.v3.lockstep.json` + `ns-graph.v3.candidate.bin` | `GraphV3DecodeLockstepTests` | Per-edge decode: surfaceLeaf, roadClassLeaf, tracktype, smoothness, layer, structureLeaf, accessLeaf, accessClass, atvDesignated; aggregate accessClassCounts, atvDesignatedKm |
| E1 | `generate-dirt-percent-lockstep-fixture.js` | `ns-graph.v3.dirt-percent.lockstep.json` | `GraphV3DirtPercentLockstepTests` | `SurfaceFamilyStats.honestPercents` on fixed edge-index bags vs JS dirt/paved/unknown/gravel % |
| E2 | `generate-clean-path-lockstep-fixture.js` | `ns-graph.v3.clean-path.lockstep.json` | `GraphV3CleanPathLockstepTests` | Full Clean route via `OnDeviceRouter.routeCleanLockstep(…)` vs JS `findPathV2` edge ID sequence + dirt% |

**Flow:**

1. JS runs decoder/router on NS v3 pack (`DirtTests/Fixtures/DirtLocalPacks/ns/` or `scripts/pack-fabric/routing/data/regions/ns/`).
2. Writes JSON with deterministic samples (every 500th edge, synthetic routes, fixed A→B coordinates).
3. Swift loads same pack bytes, recomputes, asserts equality.

**Clean-path lockstep detail:** JS fixture includes precomputed snap state so Swift skips its own snap:

- `from` / `to` [lon, lat]
- `startEdgeIndex`, `endEdgeIndex`
- `startCoord`, `endCoord`, `startAlongM`, `endAlongM`
- Expected `edgeIds`, `dirtPercent`, `edgeIndexes`

Swift calls `routeCleanLockstep(…)` which injects `EdgeSnap` and runs Clean search with `pavedOnly`, `cityWall`, etc.

### 2. Inline constant parity (no JSON)

Swift tests assert values documented to match specific JS modules:

| Test file | JS reference | Compared |
|-----------|--------------|----------|
| `StructureLockstepTests` | `routing/lib/structure.js` | Structure codes, crossing labels, water-crossing rules |
| `FerryLockstepTests` | `routing/lib/ferry.js` | Ferry seconds, relax step cost, surface stats excluding ferry denominator |

These call production Swift APIs (`OnDeviceProfileCosts`, `GraphV2Pack`, `SurfaceFamilyStats`) directly.

### 3. V4 topology parity (hardcoded expectations + mini packs)

`GraphV4PackTests` / `GraphV4SnapTests` load small binary fixtures and compare routing outcomes to values known from JS legal-topology tests (e.g. forecourt way sequences `[10,20,21]`). Not driven by lockstep JSON files.

## Reusable routing comparison infrastructure

| Asset | Location | Role |
|-------|----------|------|
| `routeCleanLockstep(…)` | `OnDeviceRouter.swift` | Clean-profile path gate with JS-provided snap; filters stitch edge IDs before compare |
| `SurfaceFamilyStats.honestPercents` | app | Dirt/paved stats parity with JS `surface-family.js` |
| `OnDeviceProfileCosts.*` | app | Cost/ferry/structure parity helpers |
| `fixtureURL(_:)` pattern | each test file | Bundle → `#filePath/Fixtures/` fallback |
| JS generators | `scripts/pack-fabric/scripts/generate-*-lockstep-fixture.js` | Regenerate golden JSON after JS changes |
| `assert-live-pack-lockstep.js` | pack-fabric | Live pack vs production service (Node, not Swift) |

**Pack load pattern:**

```swift
let pack = try GraphV2Pack(data: Data(contentsOf: graphURL))
pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geomURL))
let router = OnDeviceRouter(pack: pack)
```

## Fixture inventory (`DirtTests/Fixtures/`)

### Lockstep JSON (3)

| File | Contents |
|------|----------|
| `ns-graph.v3.lockstep.json` | 884 edge samples, undirectedEdgeCount 212041, accessClassCounts, atvDesignatedKm |
| `ns-graph.v3.dirt-percent.lockstep.json` | 3 routes: `every-791` (269 edges), `atv-designated` (460), `first-2000` (2000) |
| `ns-graph.v3.clean-path.lockstep.json` | 2 Clean A→B routes with full snap + edge ID paths (101 and 303 edges) |

### Pack binaries

| Path | Used by |
|------|---------|
| `ns-graph.v3.candidate.bin` (~15 MB) | GraphV3DecodeLockstepTests |
| `DirtLocalPacks/ns/graph.v3.bin` + `geometry.v1.bin` | Clean-path lockstep, balanced regression |
| `legal-topology-canary.graph.v4.bin` + `.geometry.v1.bin` | V4 decode, carriageway, snap |
| `legal-topology-forecourt*.graph.v4.bin` (+ geom) | Forecourt routing vs JS |
| `legal-topology-restrictions.graph.v4.bin` (+ geom) | Turn restrictions, endpoint access |
| `yarmouth-harbour.graph.v4.bin` (+ geom) | Harbour snap connectivity |
| `oneway-canary.graph.v3.bin` (+ geom) | One-way legality |

Fallback pack path for dirt-percent: `scripts/pack-fabric/routing/data/regions/ns/graph.v3.bin`.

Fixtures sync into test bundle via `PBXFileSystemSynchronizedRootGroup` on `DirtTests/`.

## Other files reviewed (non-lockstep)

- **Phase1RoutingCharacterTests** — unit tests for dirt-run repricing, wander/corridor, `considerRelax`, sparse labels, fog neighborhood, session seed. No JS fixture.
- **OnDeviceProfileCostsTests** — pure Swift cost/corridor/major-highway tests + `CrossPackSeamTests` for region/seam logic.
- **StructureLockstepTests / FerryLockstepTests** — inline JS parity (see above).

## Xcode scheme for tests

**Use `DIRT Dev`** (`Dirt.xcodeproj/xcshareddata/xcschemes/DIRT Dev.xcscheme`).

- TestAction includes `DirtTests` and `DirtUITests`, Debug config.
- `DIRT Production` has **empty** `<Testables>` — do not use for unit tests.

Example:

```bash
xcodebuild test -scheme "DIRT Dev" -destination 'platform=iOS Simulator,name=iPhone 16'
```
