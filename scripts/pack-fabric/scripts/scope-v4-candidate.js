#!/usr/bin/env node
"use strict";

// Repackage a strict subset of a sealed fabric without rebuilding or changing
// road/source data. Qualification is deliberately not copied to the new release.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { BufferedJSONFile } = require("./buffered-json-file");
const { readTopologySealMetaSync } = require("./topology-meta");
const { verifyRegion } = require("./build-v4-fabric");

function identity(file) {
  const hash = crypto.createHash("sha256"), fd = fs.openSync(file, "r");
  const buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  try { for (;;) { const n = fs.readSync(fd, buffer); if (!n) break; hash.update(buffer.subarray(0, n)); } }
  finally { fs.closeSync(fd); }
  return { name: path.basename(file), bytes: fs.statSync(file).size, sha256: hash.digest("hex") };
}
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const save = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
function assertIdentity(file, expected) {
  const actual = identity(file);
  if (actual.bytes !== expected.bytes || actual.sha256 !== expected.sha256) throw new Error(`changed source artifact: ${file}`);
  return actual;
}
function scopeSeams(seams, selected, releaseId) {
  if (!selected.has(seams.regionId)) throw new Error("sidecar outside selected scope");
  return { ...seams, fabricReleaseId: releaseId,
    roadNeighbors: seams.roadNeighbors.filter(id => selected.has(id)),
    neighbors: Object.fromEntries(Object.entries(seams.neighbors).filter(([id]) => selected.has(id))) };
}
function scopeCandidate({ source, root, releaseId, exclude }) {
  if (!/^fabric-v4-\d{8}-\d{2}$/.test(releaseId)) throw new Error("invalid release ID");
  if (fs.existsSync(root)) throw new Error("destination already exists; preserve it and inspect its receipts");
  const original = read(path.join(source, "release.json"));
  if (original.status !== "local-candidate-sealed" || !original.completeFabric || original.releaseId === releaseId) throw new Error("require a distinct, complete sealed source");
  const ids = original.regions.map(r => r.id).filter(id => !exclude.includes(id)).sort();
  if (ids.length < 2 || !exclude.length || exclude.some(id => !original.regions.some(r => r.id === id))) throw new Error("invalid explicit exclusion");
  const selected = new Set(ids);
  assertIdentity(path.join(source, "source-lock.json"), original.sourceLock);
  assertIdentity(path.join(source, "cross-pack-topology.v2.json"), original.topology);
  const topology = readTopologySealMetaSync(path.join(source, "cross-pack-topology.v2.json"));
  if (topology.fabricReleaseId !== original.releaseId || topology.sourceEpoch !== original.sourceEpoch) throw new Error("source topology identity mismatch");
  const lock = read(path.join(source, "source-lock.json"));
  if (lock.fabricEpoch !== original.sourceEpoch) throw new Error("source epoch mismatch");
  fs.mkdirSync(root, { recursive: true });
  const scopedLock = { ...lock, regions: Object.fromEntries(ids.map(id => [id, lock.regions[id]])), regionCount: ids.length };
  save(path.join(root, "source-lock.json"), scopedLock);
  const pairs = topology.pairs.filter(p => selected.has(p.left) && selected.has(p.right));
  const writer = new BufferedJSONFile(path.join(root, "cross-pack-topology.v2.json"));
  const createdAt = new Date().toISOString();
  const records = [];
  writer.write(JSON.stringify({ schemaVersion: topology.schemaVersion, fabricReleaseId: releaseId,
    sourceEpoch: original.sourceEpoch, generatedAt: createdAt }).slice(0, -1) + ',"regions":{');
  try {
    for (const id of ids) {
      const old = original.regions.find(r => r.id === id);
      const oldDir = path.join(source, "packs", id), dir = path.join(root, "packs", id);
      const verified = verifyRegion({ packRoot: path.join(source, "packs"), riderRoot: path.join(source, "rider-services") }, id, original.releaseId, lock,
        { requireSeams: true, recipe: old.factoryRecipe, factoryCommit: original.factoryCommit });
      if (JSON.stringify(verified) !== JSON.stringify(old)) throw new Error(`${id}: source no longer matches seal`);
      fs.mkdirSync(dir, { recursive: true });
      // Only immutable data is shared. Metadata below always gets new files.
      for (const name of ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "legal-topology-report.json"]) fs.linkSync(path.join(oldDir, name), path.join(dir, name));
      const servicesDir = path.join(root, "rider-services", id);
      fs.mkdirSync(servicesDir, { recursive: true });
      fs.linkSync(path.join(source, "rider-services", id, "rider-services.v1.json"), path.join(servicesDir, "rider-services.v1.json"));
      const seams = scopeSeams(read(path.join(oldDir, "cross-pack-seams.v2.json")), selected, releaseId);
      if (seams.sourceEpoch !== original.sourceEpoch || seams.regionId !== id) throw new Error(`${id}: sidecar identity mismatch`);
      save(path.join(dir, "cross-pack-seams.v2.json"), seams);
      const manifest = { ...old.packManifest, fabricReleaseId: releaseId, seams: identity(path.join(dir, "cross-pack-seams.v2.json")) };
      save(path.join(dir, "pack-manifest.v2.json"), manifest);
      records.push({ ...old, packManifest: manifest });
      if (records.length > 1) writer.write(",");
      writer.write(JSON.stringify(id) + ':');
      writer.write(JSON.stringify({ neighbors: seams.neighbors }));
      console.log(`[${records.length}/${ids.length}] ${id}: source verified; immutable data reused`);
    }
    writer.write('},"pairs":' + JSON.stringify(pairs) + '}\n');
  } finally { writer.close(); }
  const release = { ...original, releaseId, status: "local-partial-candidate", createdAt,
    completeFabric: false, regionCount: ids.length, excludedRegions: [...exclude].sort(),
    scope: "Explicit DEV subset; excluded regions are unavailable until separately qualified.",
    reusedFrom: { releaseId: original.releaseId, release: identity(path.join(source, "release.json")) },
    sourceLock: identity(path.join(root, "source-lock.json")),
    topology: { ...identity(path.join(root, "cross-pack-topology.v2.json")), pairs: pairs.length }, regions: records };
  save(path.join(root, "release.json"), release);
  return release;
}
if (require.main === module) {
  const args = process.argv.slice(2), opts = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!["--source", "--root", "--release-id", "--exclude"].includes(args[i]) || !args[i + 1]) throw new Error("require --source --root --release-id --exclude");
    opts[args[i].slice(2)] = args[i + 1];
  }
  const release = scopeCandidate({ source: path.resolve(opts.source), root: path.resolve(opts.root), releaseId: opts["release-id"], exclude: opts.exclude.split(",") });
  console.log(JSON.stringify({ releaseId: release.releaseId, regions: release.regionCount, pairs: release.topology.pairs, qualified: false }));
}
module.exports = { scopeSeams, scopeCandidate };
