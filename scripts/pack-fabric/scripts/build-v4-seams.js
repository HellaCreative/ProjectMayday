#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { decodeGraphV4 } = require("../routing/lib/pack-v4");
const { validatePackManifestV2, SEAM_CAPABILITY } = require("../routing/lib/pack-manifest-v2");
const { seamCandidates, assertSeamLegal, edgeProofKey } = require("../routing/lib/legal-topology/seams");
const { REGION_NEIGHBOURS } = require("../routing/regional/merge");

const FABRIC = path.join(__dirname, "..");

function parseArgs(argv) {
  const options = {
    root: path.join(FABRIC, "app", "data", "packs", "v4"),
    output: path.join(FABRIC, "routing", "schema", "cross-pack-topology.v2.json")
  };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--root") options.root = path.resolve(argv[++i]);
    else if (argv[i] === "--output") options.output = path.resolve(argv[++i]);
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  return options;
}

function shaFile(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function loadPack(root, id) {
  const dir = path.join(root, id);
  const manifestPath = path.join(dir, "pack-manifest.v2.json");
  const graphPath = path.join(dir, "graph.v4.bin");
  const geometryPath = path.join(dir, "geometry.v1.bin");
  const fuelPath = path.join(dir, "fuel.v1.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  validatePackManifestV2(manifest);
  for (const [key, file] of [["graph", graphPath], ["geometry", geometryPath], ["fuel", fuelPath]]) {
    const stat = fs.statSync(file);
    if (stat.size !== manifest[key].bytes || shaFile(file) !== manifest[key].sha256) {
      throw new Error(`${id} ${key} does not match its manifest`);
    }
  }
  const geometry = fs.readFileSync(geometryPath);
  return { manifest, pack: decodeGraphV4(fs.readFileSync(graphPath), geometry) };
}

function uniquePairs() {
  const rows = [];
  const seen = new Set();
  for (const [left, neighbors] of Object.entries(REGION_NEIGHBOURS)) {
    if (left.length !== 2) continue;
    for (const right of neighbors) {
      const pair = [left, right].sort();
      const key = pair.join("|");
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push(pair);
    }
  }
  return rows.sort((a, b) => a.join("|").localeCompare(b.join("|")));
}

function selectProofs(rows) {
  // A display shortlist is not a topology. A latitude cap (or one row per
  // way) can discard the only crossing joining a routable component. Retain
  // every distinct proven node/edge connection; route selection may rank it
  // later against the actual endpoints.
  const unique = new Map();
  for (const row of rows) {
    if (![row.edge.accessForward, row.edge.accessReverse].some((code) => code === 0 || code === 1)) continue;
    const key = `${row.osmNodeId}|${edgeProofKey(row.edge)}`;
    if (!unique.has(key)) unique.set(key, row);
  }
  return [...unique.values()].sort((a, b) =>
    Number(a.coordinate[1]) - Number(b.coordinate[1]) ||
    Number(a.coordinate[0]) - Number(b.coordinate[0]) ||
    String(a.osmNodeId).localeCompare(String(b.osmNodeId)) ||
    edgeProofKey(a.edge).localeCompare(edgeProofKey(b.edge))
  );
}

function publicRow(row, localEdgeId, remoteEdgeId) {
  return {
    coordinate: row.coordinate,
    gapMeters: Number(row.coordinateGapMeters.toFixed(3)),
    osmNodeId: row.osmNodeId,
    osmWayId: row.osmWayId,
    localEdgeId,
    remoteEdgeId,
    proof: row.proof,
    edge: row.edge,
    barrierDecision: row.barrierDecision,
    restrictions: row.restrictions
  };
}

function writeRegionSidecars(root, doc) {
  const releaseIds = new Set();
  for (const id of Object.keys(doc.regions).sort()) {
    const manifestPath = path.join(root, id, "pack-manifest.v2.json");
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    validatePackManifestV2(manifest);
    releaseIds.add(manifest.fabricReleaseId);
    if (manifest.sourceEpoch !== doc.sourceEpoch) throw new Error(`${id}: seam source epoch mismatch`);
  }
  if (releaseIds.size !== 1) throw new Error("fabric mixes release identities");
  doc.fabricReleaseId = [...releaseIds][0];

  for (const id of Object.keys(doc.regions).sort()) {
    const dir = path.join(root, id);
    const seamPath = path.join(dir, "cross-pack-seams.v2.json");
    const sidecar = {
      schemaVersion: "dirt-cross-pack-seams.v2",
      fabricReleaseId: doc.fabricReleaseId,
      sourceEpoch: doc.sourceEpoch,
      regionId: id,
      neighbors: doc.regions[id].neighbors
    };
    fs.writeFileSync(seamPath, JSON.stringify(sidecar, null, 2) + "\n");
    const manifestPath = path.join(dir, "pack-manifest.v2.json");
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    manifest.capabilities = [...new Set([...(manifest.capabilities || []), SEAM_CAPABILITY])];
    manifest.seams = {
      name: "cross-pack-seams.v2.json",
      bytes: fs.statSync(seamPath).size,
      sha256: shaFile(seamPath)
    };
    validatePackManifestV2(manifest, { requireSeams: true });
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const doc = {
    schemaVersion: "dirt-cross-pack-topology.v2",
    generatedAt: new Date().toISOString(),
    sourceEpoch: null,
    regions: {},
    pairs: []
  };
  const cache = new Map();
  const get = (id) => {
    if (!cache.has(id)) cache.set(id, loadPack(options.root, id));
    return cache.get(id);
  };
  for (const id of Object.keys(REGION_NEIGHBOURS).filter((id) => id.length === 2).sort()) {
    doc.regions[id] = { neighbors: {} };
  }
  for (const [leftId, rightId] of uniquePairs()) {
    const left = get(leftId);
    const right = get(rightId);
    if (left.manifest.sourceEpoch !== right.manifest.sourceEpoch) {
      throw new Error(`${leftId}/${rightId} source epoch mismatch`);
    }
    if (doc.sourceEpoch == null) doc.sourceEpoch = left.manifest.sourceEpoch;
    if (doc.sourceEpoch !== left.manifest.sourceEpoch) throw new Error("fabric mixes source epochs");
    const proofs = selectProofs(seamCandidates(left.pack, right.pack));
    if (!proofs.length) throw new Error(`no legal V4 seam for ${leftId}/${rightId}`);
    for (const proof of proofs) assertSeamLegal(left.pack, right.pack, proof);
    doc.regions[leftId].neighbors[rightId] = proofs.map((row) =>
      publicRow(row, `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`, `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`)
    );
    doc.regions[rightId].neighbors[leftId] = proofs.map((row) =>
      publicRow(row, `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`, `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`)
    );
    doc.pairs.push({ left: leftId, right: rightId, proofs: proofs.length });
    console.log(`${leftId}/${rightId}: ${proofs.length} legal seams`);
    // Bound memory to the current pair; pack reads are deterministic and the
    // factory values safety over retaining continent-sized binary buffers.
    cache.delete(leftId);
    cache.delete(rightId);
  }
  writeRegionSidecars(options.root, doc);
  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  fs.writeFileSync(options.output, JSON.stringify(doc, null, 2) + "\n");
  console.log(JSON.stringify({ output: options.output, pairs: doc.pairs.length, sourceEpoch: doc.sourceEpoch }, null, 2));
}

if (require.main === module) {
  try { main(); } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main, parseArgs, uniquePairs, selectProofs, writeRegionSidecars };
