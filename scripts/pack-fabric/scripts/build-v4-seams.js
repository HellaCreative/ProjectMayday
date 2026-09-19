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
    output: path.join(FABRIC, "routing", "schema", "cross-pack-topology.v2.json"),
    resume: false
  };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--root") options.root = path.resolve(argv[++i]);
    else if (argv[i] === "--output") options.output = path.resolve(argv[++i]);
    else if (argv[i] === "--resume") options.resume = true;
    else if (argv[i] === "--regions") {
      options.regions = [...new Set((argv[++i] || "").split(","))].sort();
      if (options.regions.length < 2 || options.regions.some(id => !REGION_NEIGHBOURS[id])) {
        throw new Error("--regions requires at least two recognized region IDs");
      }
    }
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  return options;
}

function checkpointPath(output) {
  return `${output}.partial`;
}

/**
 * Stream a topology document without JSON.stringify on the whole object.
 * CA-scale pair proofs (~500k+) exceed Node's max string length when stringified
 * in one shot; writing scalars + array elements incrementally stays under the limit.
 */
function writeTopologyDocument(file, doc) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const fd = fs.openSync(file, "w");
  const ws = (chunk) => {
    fs.writeSync(fd, chunk);
  };
  try {
    ws("{");
    ws(`"schemaVersion":${JSON.stringify(doc.schemaVersion)}`);
    ws(`,"generatedAt":${JSON.stringify(doc.generatedAt)}`);
    ws(`,"sourceEpoch":${JSON.stringify(doc.sourceEpoch)}`);
    if (Object.prototype.hasOwnProperty.call(doc, "fabricReleaseId")) {
      ws(`,"fabricReleaseId":${JSON.stringify(doc.fabricReleaseId)}`);
    }
    ws(`,"regions":{`);
    const regionIds = Object.keys(doc.regions || {}).sort();
    for (let r = 0; r < regionIds.length; r += 1) {
      const regionId = regionIds[r];
      if (r) ws(",");
      ws(`${JSON.stringify(regionId)}:{"neighbors":{`);
      const neighbors = (doc.regions[regionId] && doc.regions[regionId].neighbors) || {};
      const neighborIds = Object.keys(neighbors).sort();
      for (let n = 0; n < neighborIds.length; n += 1) {
        const neighborId = neighborIds[n];
        if (n) ws(",");
        ws(`${JSON.stringify(neighborId)}:[`);
        const rows = neighbors[neighborId] || [];
        for (let i = 0; i < rows.length; i += 1) {
          if (i) ws(",");
          ws(JSON.stringify(rows[i]));
        }
        ws("]");
      }
      ws("}}");
    }
    ws(`},"pairs":[`);
    const pairs = doc.pairs || [];
    for (let i = 0; i < pairs.length; i += 1) {
      if (i) ws(",");
      ws(JSON.stringify(pairs[i]));
    }
    ws("]}\n");
  } finally {
    fs.closeSync(fd);
  }
}

function loadCheckpoint(output) {
  const file = checkpointPath(output);
  if (!fs.existsSync(file)) return null;
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  if (doc.schemaVersion !== "dirt-cross-pack-topology.v2") {
    throw new Error(`checkpoint schema mismatch: ${file}`);
  }
  return doc;
}

function writeCheckpoint(output, doc) {
  writeTopologyDocument(checkpointPath(output), doc);
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
  return { manifest, pack: decodeGraphV4(fs.readFileSync(graphPath), geometry),
    geometry: require("../routing/lib/pack-v4").decodeGeometryV1(geometry) };
}

// The phone rejects different geometry for one shared source road. Make that a
// build failure instead of letting a candidate pass on matching labels alone.
function assertSharedRoadGeometry(left, right) {
  const key = (p, e) => `${p.osmWayIds[e]}:${p.osmNodeIds[p.edgeFrom[e]]}:${p.osmNodeIds[p.edgeTo[e]]}`;
  const indices = new Map();
  for (let e = 0; e < left.pack.edgeCount; e++) indices.set(key(left.pack, e), e);
  let shared = 0;
  for (let e = 0; e < right.pack.edgeCount; e++) {
    const k = key(right.pack, e), other = indices.get(k);
    if (other === undefined) continue;
    shared++;
    if (left.pack.edgeMeters[other] !== right.pack.edgeMeters[e] ||
        JSON.stringify(left.geometry.polyline(other)) !== JSON.stringify(right.geometry.polyline(e)))
      throw new Error(`shared road geometry mismatch ${left.manifest.regionId}/${right.manifest.regionId} ${k}`);
  }
  return shared;
}

function uniquePairs(regions = null) {
  const rows = [];
  const seen = new Set();
  for (const [left, neighbors] of Object.entries(REGION_NEIGHBOURS)) {
    if (regions && !regions.includes(left)) continue;
    for (const right of neighbors) {
      if (regions && !regions.includes(right)) continue;
      const pair = [left, right].sort();
      const key = pair.join("|");
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push(pair);
    }
  }
  return rows.sort((a, b) => a.join("|").localeCompare(b.join("|")));
}

function assertNeighborCoverage(regionIds, pairs) {
  for (const id of regionIds) {
    if (!Array.isArray(REGION_NEIGHBOURS[id])) throw new Error(`unknown region ${id}`);
    if (REGION_NEIGHBOURS[id].length && !pairs.some(pair => pair.includes(id))) {
      throw new Error(`selected region ${id} must have a neighbor in the selected set`);
    }
  }
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

function writeSeamSidecar(file, sidecar) {
  // Compact streamed write — pretty-printed CA-scale neighbor arrays exceed
  // JSON.stringify string limits the same way checkpoints do.
  const fd = fs.openSync(file, "w");
  const ws = (chunk) => {
    fs.writeSync(fd, chunk);
  };
  try {
    ws("{");
    ws(`"schemaVersion":${JSON.stringify(sidecar.schemaVersion)}`);
    ws(`,"fabricReleaseId":${JSON.stringify(sidecar.fabricReleaseId)}`);
    ws(`,"sourceEpoch":${JSON.stringify(sidecar.sourceEpoch)}`);
    ws(`,"regionId":${JSON.stringify(sidecar.regionId)}`);
    ws(`,"neighbors":{`);
    const neighborIds = Object.keys(sidecar.neighbors || {}).sort();
    for (let n = 0; n < neighborIds.length; n += 1) {
      const neighborId = neighborIds[n];
      if (n) ws(",");
      ws(`${JSON.stringify(neighborId)}:[`);
      const rows = sidecar.neighbors[neighborId] || [];
      for (let i = 0; i < rows.length; i += 1) {
        if (i) ws(",");
        ws(JSON.stringify(rows[i]));
      }
      ws("]");
    }
    ws("}}\n");
  } finally {
    fs.closeSync(fd);
  }
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
    writeSeamSidecar(seamPath, sidecar);
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
  const regionIds = options.regions || Object.keys(REGION_NEIGHBOURS).filter((id) => id.length === 2).sort();
  const pairs = uniquePairs(options.regions);
  assertNeighborCoverage(regionIds, pairs);

  let doc = {
    schemaVersion: "dirt-cross-pack-topology.v2",
    generatedAt: new Date().toISOString(),
    sourceEpoch: null,
    regions: {},
    pairs: []
  };
  const done = new Set();
  if (options.resume) {
    const prior = loadCheckpoint(options.output);
    if (prior) {
      doc = prior;
      for (const row of doc.pairs || []) {
        done.add([row.left, row.right].sort().join("|"));
      }
      console.log(JSON.stringify({
        resume: true,
        checkpoint: checkpointPath(options.output),
        completedPairs: done.size,
        remainingPairs: pairs.length - done.size
      }));
    } else {
      console.log(JSON.stringify({ resume: true, checkpoint: null, completedPairs: 0 }));
    }
  }
  for (const id of regionIds) {
    if (!doc.regions[id]) doc.regions[id] = { neighbors: {} };
  }

  const cache = new Map();
  const get = (id) => {
    if (!cache.has(id)) cache.set(id, loadPack(options.root, id));
    return cache.get(id);
  };
  let index = 0;
  for (const [leftId, rightId] of pairs) {
    index += 1;
    const key = [leftId, rightId].sort().join("|");
    if (done.has(key)) {
      console.log(`${leftId}/${rightId}: resume skip (${index}/${pairs.length})`);
      continue;
    }
    const left = get(leftId);
    const right = get(rightId);
    if (left.manifest.sourceEpoch !== right.manifest.sourceEpoch) {
      throw new Error(`${leftId}/${rightId} source epoch mismatch`);
    }
    if (doc.sourceEpoch == null) doc.sourceEpoch = left.manifest.sourceEpoch;
    if (doc.sourceEpoch !== left.manifest.sourceEpoch) throw new Error("fabric mixes source epochs");
    assertSharedRoadGeometry(left, right);
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
    console.log(`${leftId}/${rightId}: ${proofs.length} legal seams (${index}/${pairs.length})`);
    writeCheckpoint(options.output, doc);
    // Bound memory to the current pair; pack reads are deterministic and the
    // factory values safety over retaining continent-sized binary buffers.
    cache.delete(leftId);
    cache.delete(rightId);
    if (global.gc) global.gc();
  }
  if (doc.pairs.length !== pairs.length) {
    throw new Error(`topology incomplete: ${doc.pairs.length}/${pairs.length} pairs`);
  }
  writeRegionSidecars(options.root, doc);
  // National / split-pair proof data exceeds the JS string limit for one-shot
  // JSON.stringify; stream scalars + array elements the same way as checkpoints.
  writeTopologyDocument(options.output, doc);
  const partial = checkpointPath(options.output);
  if (fs.existsSync(partial)) fs.unlinkSync(partial);
  console.log(JSON.stringify({ output: options.output, pairs: doc.pairs.length, sourceEpoch: doc.sourceEpoch }, null, 2));
}

if (require.main === module) {
  try { main(); } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = {
  assertSharedRoadGeometry,
  assertNeighborCoverage,
  main,
  parseArgs,
  uniquePairs,
  selectProofs,
  writeRegionSidecars,
  writeTopologyDocument,
  writeCheckpoint
};
