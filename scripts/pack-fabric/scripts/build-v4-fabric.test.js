"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("node:os");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { graphHeapMiB, verifyRegion } = require("./build-v4-fabric");

test("V4 graph worker cannot claim the host's entire physical memory", () => {
  const physicalMiB = Math.floor(os.totalmem() / (1024 * 1024));
  assert.ok(graphHeapMiB() <= Math.floor(physicalMiB * 0.62));
  assert.ok(graphHeapMiB() >= 2048);
});

test("release labels cannot conceal stale source bytes or missing city data", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "fabric-proof-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const paths = { packRoot: path.join(root, "packs"), riderRoot: path.join(root, "rider") };
  const dir = path.join(paths.packRoot, "ns"), riderDir = path.join(paths.riderRoot, "ns");
  fs.mkdirSync(dir, { recursive: true }); fs.mkdirSync(riderDir, { recursive: true });
  const source = { sourceSha256: "a".repeat(64), sourceBytes: 1234, osmTimestamp: "2026-09-18T00:00:00Z" };
  const lock = { fabricEpoch: "same-label", regions: { ns: source } };
  const write = (file, doc) => fs.writeFileSync(file, JSON.stringify(doc));
  const identity = name => {
    const bytes = fs.readFileSync(path.join(dir, name));
    return { name, bytes: bytes.length, sha256: crypto.createHash("sha256").update(bytes).digest("hex") };
  };
  fs.writeFileSync(path.join(dir, "graph.v4.bin"), "graph");
  fs.writeFileSync(path.join(dir, "geometry.v1.bin"), "geometry");
  write(path.join(dir, "fuel.v1.json"), { schema: "fuel.v1", regionId: "ns", stations: [{ id: 1 }],
    sourceUpdatedAt: source.osmTimestamp, sourceSha256: source.sourceSha256 });
  write(path.join(riderDir, "rider-services.v1.json"), { schema: "rider-services.v1", regionId: "ns",
    elements: ["campground", "lodging", "liquor"].map(category => ({ tags: { "dirt:category": category } })),
    counts: { campground: 1, lodging: 1, liquor: 1 }, sourceUpdatedAt: source.osmTimestamp, sourceSha256: source.sourceSha256 });
  const manifest = { schema: "pack-manifest.v2", fabricReleaseId: "fabric-v4-20260919-01", regionId: "ns",
    capabilities: ["legal-topology.v1"], sourceEpoch: lock.fabricEpoch, timezone: "America/Halifax",
    graph: identity("graph.v4.bin"), geometry: identity("geometry.v1.bin"), fuel: identity("fuel.v1.json") };
  write(path.join(dir, "pack-manifest.v2.json"), manifest);
  const report = { counts: { nodes: 2, edges: 1 }, unprovenStitches: 0,
    provenance: { ...source, sourceEpoch: lock.fabricEpoch, urbanCores: [], settlements: [],
      urbanSourceIdentity: { sha256: source.sourceSha256 } } };
  const reportFile = path.join(dir, "legal-topology-report.json");
  write(reportFile, report);
  assert.equal(verifyRegion(paths, "ns", manifest.fabricReleaseId, lock).fuelStations, 1);
  const riderFile = path.join(riderDir, "rider-services.v1.json");
  const rider = JSON.parse(fs.readFileSync(riderFile));
  rider.elements.pop(); rider.counts.liquor = 0;
  write(riderFile, rider);
  assert.equal(verifyRegion(paths, "ns", manifest.fabricReleaseId, lock).riderServices.counts.liquor, 0);
  rider.counts.liquor = 1; write(riderFile, rider);
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock), /count does not match payload/);
  delete rider.counts.liquor; write(riderFile, rider);
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock), /count does not match payload/);
  rider.counts.liquor = 0; write(riderFile, rider);

  report.provenance.factoryCommit = "original-build";
  report.provenance.factoryRecipe = { sha256: "c".repeat(64) };
  write(reportFile, report);
  // An unrelated app commit no longer rebuilds identical factory output.
  assert.equal(verifyRegion(paths, "ns", manifest.fabricReleaseId, lock,
    { factoryCommit: "later-app-change", recipe: { sha256: "c".repeat(64) } }).fuelStations, 1);
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock,
    { recipe: { sha256: "d".repeat(64) } }), /different factory recipe/);
  // Legacy packs have no recipe receipt: retain their original strict check.
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock,
    { factoryCommit: "later-app-change" }), /different factory commit/);
  report.provenance.sourceSha256 = "b".repeat(64);
  write(reportFile, report);
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock), /actual source sourceSha256/);
  report.provenance.sourceSha256 = source.sourceSha256;
  delete report.provenance.urbanCores;
  write(reportFile, report);
  assert.throws(() => verifyRegion(paths, "ns", manifest.fabricReleaseId, lock), /city\/town/);
});
