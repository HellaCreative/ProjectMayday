#!/usr/bin/env node
"use strict";

// Connection-only revisions reuse immutable graph, geometry, and fuel objects.
// Decode one regional graph at a time to avoid retaining two large packs.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { decodeGraphV4 } = require("../routing/lib/pack-v4");
const { edgeProof, edgeProofKey, restrictionProofs, haversineMeters } = require("../routing/lib/legal-topology/seams");
const { weakComponentIds } = require("../routing/lib/legal-topology/snap");
const { selectProofs } = require("./build-v4-seams");

function identity(file) {
  const bytes = fs.readFileSync(file);
  return { bytes: bytes.length, sha256: crypto.createHash("sha256").update(bytes).digest("hex") };
}
function load(root, id) {
  const dir = path.join(root, "packs", id);
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "pack-manifest.v2.json")));
  const file = path.join(dir, manifest.graph.name);
  const actual = identity(file);
  if (actual.bytes !== manifest.graph.bytes || actual.sha256 !== manifest.graph.sha256) throw new Error(`${id}: graph identity mismatch`);
  const pack = decodeGraphV4(fs.readFileSync(file));
  if (pack.provenance.sourceEpoch !== manifest.sourceEpoch) throw new Error(`${id}: source epoch mismatch`);
  return pack;
}
function nodeIds(root, id, filter) {
  const pack = load(root, id), ids = new Set();
  for (const raw of pack.osmNodeIds) {
    const key = String(raw);
    if (key !== "0" && (!filter || filter.has(key))) ids.add(key);
  }
  return ids;
}
function records(root, id, ids) {
  const pack = load(root, id), result = new Map();
  const components = weakComponentIds(pack, false), sizes = new Map();
  for (const c of components) sizes.set(c, (sizes.get(c) || 0) + 1);
  const barriers = new Map((pack.barriers || []).map(b => [String(b.osmNodeId), Number(b.decisionCode)]));
  for (let n = 0; n < pack.nodeCount; n += 1) {
    const key = String(pack.osmNodeIds[n]);
    if (!ids.has(key)) continue;
    const incident = [...new Set(pack.edgeUndirectedIndex.subarray(pack.nodeOffsets[n], pack.nodeOffsets[n + 1]))];
    if (result.has(key)) throw new Error(`${id}: ambiguous duplicate shared OSM node ${key}`);
    result.set(key, {
      coordinate: [pack.nodeCoords[n * 2], pack.nodeCoords[n * 2 + 1]],
      component: `${id}:${components[n]}`, componentSize: sizes.get(components[n]),
      barrierDecision: barriers.get(key) || 0,
      restrictions: restrictionProofs(pack, n, incident),
      edges: incident.map(e => edgeProof(pack, e))
    });
  }
  return result;
}
function proveRecords(left, right) {
  const rows = [];
  for (const [osmNodeId, a] of left) {
    const b = right.get(osmNodeId);
    if (!b) continue;
    const gap = haversineMeters(a.coordinate, b.coordinate);
    if (gap > 2 || a.barrierDecision !== b.barrierDecision || JSON.stringify(a.restrictions) !== JSON.stringify(b.restrictions)) continue;
    const keys = new Set(b.edges.map(edgeProofKey));
    for (const edge of a.edges) {
      if (!keys.has(edgeProofKey(edge))) continue;
      rows.push({ osmNodeId, osmWayId: edge.osmWayId, coordinate: a.coordinate,
        coordinateGapMeters: gap, barrierDecision: a.barrierDecision,
        componentPair: [a.component, b.component].sort().join("|"),
        networkSize: Math.min(a.componentSize || 0, b.componentSize || 0),
        restrictions: a.restrictions, edge, proof: "shared-osm-node-way-edge-legal-topology.v1" });
    }
  }
  return selectProofs(rows).map(row => ({
    coordinate: row.coordinate, gapMeters: Number(row.coordinateGapMeters.toFixed(3)),
    osmNodeId: row.osmNodeId, osmWayId: row.osmWayId,
    localEdgeId: `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`,
    remoteEdgeId: `${row.edge.osmWayId}:${row.edge.fromOsmNodeId}:${row.edge.toOsmNodeId}`,
    proof: row.proof, edge: row.edge, barrierDecision: row.barrierDecision, restrictions: row.restrictions,
    componentPair: row.componentPair, networkSize: row.networkSize
  }));
}
function provePair(root, leftId, rightId) {
  let ids = nodeIds(root, leftId); global.gc?.();
  ids = nodeIds(root, rightId, ids); global.gc?.();
  const left = records(root, leftId, ids); global.gc?.();
  const right = records(root, rightId, ids); global.gc?.();
  return proveRecords(left, right);
}
function writeJSON(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n", { flag: "wx" });
}
function revise({ source, output, revision, pairs }) {
  if (!/^connections-v4-\d{8}-\d+$/.test(revision)) throw new Error("invalid connection revision");
  source = fs.realpathSync(source); output = path.resolve(output);
  if (output === source || output.startsWith(source + path.sep) || fs.existsSync(output)) throw new Error("output must be a new directory outside the sealed source");
  const topology = JSON.parse(fs.readFileSync(path.join(source, "cross-pack-topology.v2.json")));
  topology.connectionRevision = revision;
  topology.generatedAt = new Date().toISOString();
  const evidence = [];
  for (const [left, right] of pairs) {
    const pair = topology.pairs.find(p => [p.left, p.right].sort().join("|") === [left, right].sort().join("|"));
    if (!pair) throw new Error(`unknown neighboring pair ${left}/${right}`);
    const proofs = provePair(source, left, right);
    if (!proofs.length) throw new Error(`no proven crossings ${left}/${right}`);
    evidence.push({ left, right, before: pair.proofs, after: proofs.length });
    topology.regions[left].neighbors[right] = proofs;
    topology.regions[right].neighbors[left] = proofs;
    pair.proofs = proofs.length;
    console.log(`${left}/${right}: ${proofs.length} proven connections`);
    global.gc?.();
  }
  const catalog = JSON.parse(fs.readFileSync(path.join(source, "manifest.json")));
  catalog.version = revision;
  catalog.connectionRevision = revision;
  for (const region of catalog.regions) {
    const sidecar = JSON.parse(fs.readFileSync(path.join(source, "packs", region.id, "cross-pack-seams.v2.json")));
    sidecar.connectionRevision = revision;
    sidecar.neighbors = topology.regions[region.id].neighbors;
    const file = path.join(output, region.id, "cross-pack-seams.v2.json");
    writeJSON(file, sidecar);
    const entry = region.files.find(f => f.name === "cross-pack-seams.v2.json");
    if (!entry) throw new Error(`${region.id}: missing catalog seam entry`);
    Object.assign(entry, identity(file));
  }
  writeJSON(path.join(output, "cross-pack-topology.v2.json"), topology);
  writeJSON(path.join(output, "manifest.json"), catalog);
  writeJSON(path.join(output, "revision.json"), {
    schema: "dirt-connection-revision.v1", connectionRevision: revision,
    fabricReleaseId: topology.fabricReleaseId, sourceEpoch: topology.sourceEpoch,
    sourceTopology: identity(path.join(source, "cross-pack-topology.v2.json")),
    topology: identity(path.join(output, "cross-pack-topology.v2.json")),
    catalog: identity(path.join(output, "manifest.json")), pairs: evidence,
    unchangedObjects: ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "Rider Services"]
  });
}
if (require.main === module) {
  const [source, output, revision, ...pairArgs] = process.argv.slice(2);
  if (!source || !output || !revision || !pairArgs.length) throw new Error("usage: node --expose-gc revise-v4-connections.js SOURCE OUTPUT REVISION qc:on [...]");
  revise({ source, output, revision, pairs: pairArgs.map(p => p.split(":")) });
}
module.exports = { proveRecords, revise };
