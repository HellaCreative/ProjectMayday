#!/usr/bin/env node
"use strict";

// Assemble a new candidate from sealed, common-epoch inputs. Immutable road
// data is reused; every seam touching a replaced graph comes from the replacement
// seal. Qualification is deliberately not transferred to the new candidate.
const fs = require("node:fs"), path = require("node:path");
const { hashFile } = require("./prepare-common-source-lock");
const { BufferedJSONFile } = require("./buffered-json-file");
const { readTopologySealMetaSync } = require("./topology-meta");
const { verifyRegion } = require("./build-v4-fabric");
const read = p => JSON.parse(fs.readFileSync(p, "utf8"));
const save = (p, v) => fs.writeFileSync(p, JSON.stringify(v, null, 2) + "\n");
const identity = p => ({ name: path.basename(p), bytes: fs.statSync(p).size, sha256: hashFile(p) });
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function assertFile(file, expected) {
  const actual = identity(file);
  if (!expected || actual.bytes !== expected.bytes || actual.sha256 !== expected.sha256)
    throw new Error(`Changed sealed input: ${file}`);
  return actual;
}
function assertUnchangedNeighbor(original, replacement) {
  for (const key of ["graph", "geometry", "fuel"]) {
    if (!same(original.packManifest[key], replacement.packManifest[key]))
      throw new Error(`${original.id}: replacement seam was built against different ${key} bytes`);
  }
  if (!same(original.riderServices, replacement.riderServices))
    throw new Error(`${original.id}: replacement changes an unselected Rider Services sidecar`);
}
function replaceSeams(original, replacement, replaced, releaseId) {
  if (replacement && (original.regionId !== replacement.regionId || original.sourceEpoch !== replacement.sourceEpoch))
    throw new Error("replacement seam region/epoch mismatch");
  const keys = new Set([...Object.keys(original.neighbors), ...Object.keys(replacement?.neighbors || {})]);
  const neighbors = {}, roadNeighbors = [];
  for (const id of [...keys].sort()) {
    const affected = replaced.has(original.regionId) || replaced.has(id);
    const selected = affected ? replacement : original;
    if (!selected || !Object.hasOwn(selected.neighbors, id))
      throw new Error(`missing selected seam proof ${original.regionId}>${id}`);
    neighbors[id] = selected.neighbors[id];
    if (selected.roadNeighbors.includes(id)) roadNeighbors.push(id);
  }
  return { ...original, fabricReleaseId: releaseId, neighbors, roadNeighbors };
}
function assemble({ source, replacement, root, releaseId, replace }) {
  if (fs.existsSync(root)) throw new Error("destination already exists; preserve and inspect it");
  if (!/^fabric-v4-\d{8}-\d{2}$/.test(releaseId)) throw new Error("invalid release ID");
  const old = read(path.join(source, "release.json")), update = read(path.join(replacement, "release.json"));
  if (old.status !== "local-candidate-sealed" || !old.completeFabric ||
      !["local-candidate-sealed", "local-partial-candidate"].includes(update.status) ||
      releaseId === old.releaseId || releaseId === update.releaseId)
    throw new Error("require sealed inputs and a new release identity");
  const ids = old.regions.map(r => r.id).sort(), replaced = new Set(replace);
  if (!replace.length || replaced.size !== replace.length || replace.some(id => !ids.includes(id) || !update.regions.some(r => r.id === id)))
    throw new Error("invalid replacement region set");
  if (update.regions.some(r => !ids.includes(r.id))) throw new Error("replacement outside original catalog");
  for (const [dir, seal] of [[source, old], [replacement, update]]) {
    assertFile(path.join(dir, "source-lock.json"), seal.sourceLock);
    assertFile(path.join(dir, "cross-pack-topology.v2.json"), seal.topology);
  }
  const lock = read(path.join(source, "source-lock.json")), updateLock = read(path.join(replacement, "source-lock.json"));
  if (old.sourceEpoch !== update.sourceEpoch || lock.fabricEpoch !== old.sourceEpoch ||
      updateLock.fabricEpoch !== old.sourceEpoch || !same(lock.commonSource, updateLock.commonSource))
    throw new Error("incompatible source epochs");
  const topology = readTopologySealMetaSync(path.join(source, "cross-pack-topology.v2.json"));
  const updateTopology = readTopologySealMetaSync(path.join(replacement, "cross-pack-topology.v2.json"));
  for (const [meta, seal] of [[topology, old], [updateTopology, update]]) {
    if (meta.fabricReleaseId !== seal.releaseId || meta.sourceEpoch !== seal.sourceEpoch ||
        !same(meta.regionIds, seal.regions.map(r => r.id).sort())) throw new Error("topology seal mismatch");
  }
  for (const row of update.regions) if (!replaced.has(row.id)) {
    assertUnchangedNeighbor(old.regions.find(r => r.id === row.id), row);
    if (!same(lock.regions[row.id], updateLock.regions[row.id])) throw new Error(`${row.id}: neighbor source lock changed`);
  }
  const pairKey = p => [p.left, p.right].sort().join("/");
  const affected = p => replaced.has(p.left) || replaced.has(p.right);
  const originalAffected = topology.pairs.filter(affected).map(pairKey).sort();
  const newAffected = updateTopology.pairs.filter(affected).map(pairKey).sort();
  if (!same(originalAffected, newAffected)) throw new Error("replacement changes neighboring pair coverage; explicit review required");
  const pairs = topology.pairs.map(p => affected(p) ? updateTopology.pairs.find(q => pairKey(p) === pairKey(q)) : p);
  // Verify both source trees before creating output. Reports retain original
  // recipe and source provenance; changing a release ID is not rebuilding data.
  for (const [dir, seal, sourceLock] of [[source, old, lock], [replacement, update, updateLock]]) {
    for (const row of seal.regions) {
      const verified = verifyRegion({ packRoot: path.join(dir, "packs"), riderRoot: path.join(dir, "rider-services") },
        row.id, seal.releaseId, sourceLock, { requireSeams: true, recipe: row.factoryRecipe, factoryCommit: seal.factoryCommit });
      if (!same(verified, row)) throw new Error(`${row.id}: input record no longer matches seal`);
    }
  }
  fs.mkdirSync(root, { recursive: true });
  const combinedLock = { ...lock, regions: { ...lock.regions } };
  for (const id of replace) combinedLock.regions[id] = updateLock.regions[id];
  save(path.join(root, "source-lock.json"), combinedLock);
  const createdAt = new Date().toISOString(), records = [];
  const writer = new BufferedJSONFile(path.join(root, "cross-pack-topology.v2.json"));
  writer.write(JSON.stringify({ schemaVersion: topology.schemaVersion, fabricReleaseId: releaseId,
    sourceEpoch: old.sourceEpoch, generatedAt: createdAt }).slice(0,-1) + ',"regions":{');
  try {
    for (const id of ids) {
      const dir = path.join(root, "packs", id), riderDir = path.join(root, "rider-services", id);
      const input = replaced.has(id) ? replacement : source;
      const record = (replaced.has(id) ? update : old).regions.find(r => r.id === id);
      fs.mkdirSync(dir, { recursive: true }); fs.mkdirSync(riderDir, { recursive: true });
      for (const file of ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "legal-topology-report.json"])
        fs.linkSync(path.join(input, "packs", id, file), path.join(dir, file));
      fs.linkSync(path.join(input, "rider-services", id, "rider-services.v1.json"), path.join(riderDir, "rider-services.v1.json"));
      const oldSeams = read(path.join(source, "packs", id, "cross-pack-seams.v2.json"));
      const newSeams = update.regions.some(r => r.id === id) ? read(path.join(replacement, "packs", id, "cross-pack-seams.v2.json")) : null;
      const seams = replaceSeams(oldSeams, newSeams, replaced, releaseId);
      save(path.join(dir, "cross-pack-seams.v2.json"), seams);
      const manifest = { ...record.packManifest, fabricReleaseId: releaseId, seams: identity(path.join(dir, "cross-pack-seams.v2.json")) };
      save(path.join(dir, "pack-manifest.v2.json"), manifest);
      records.push({ ...record, packManifest: manifest });
      if (records.length > 1) writer.write(",");
      writer.write(JSON.stringify(id) + ":" + JSON.stringify({ neighbors: seams.neighbors }));
      console.log(`[${records.length}/${ids.length}] ${id}: verified data reused; affected seams replaced`);
    }
    writer.write('},"pairs":' + JSON.stringify(pairs) + '}\n');
  } finally { writer.close(); }
  const release = { ...old, releaseId, createdAt, regions: records,
    sourceLock: identity(path.join(root, "source-lock.json")),
    topology: { ...identity(path.join(root, "cross-pack-topology.v2.json")), pairs: pairs.length },
    assemblyProvenance: { replacedRegions: replace, source: identity(path.join(source, "release.json")),
      replacement: identity(path.join(replacement, "release.json")), script: identity(__filename) } };
  save(path.join(root, "release.json"), release);
  return release;
}
if (require.main === module) {
  const args = process.argv.slice(2), options = {};
  for (let i=0; i<args.length; i+=2) {
    if (!["--source", "--replacement", "--root", "--release-id", "--replace"].includes(args[i]) || !args[i+1]) throw new Error("invalid arguments");
    options[args[i].slice(2)] = args[i+1];
  }
  const release = assemble({ source: path.resolve(options.source), replacement: path.resolve(options.replacement),
    root: path.resolve(options.root), releaseId: options["release-id"], replace: options.replace.split(",") });
  console.log(JSON.stringify({ releaseId: release.releaseId, regions: release.regions.length, pairs: release.topology.pairs, qualified: false }));
}
module.exports = { assemble, replaceSeams, assertUnchangedNeighbor };
