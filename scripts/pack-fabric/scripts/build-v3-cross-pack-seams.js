#!/usr/bin/env node
"use strict";

/**
 * Prove a v3↔v3 seam from shared quantized vertices without rewriting the
 * older pack. Corridor is the overlapping admin-polygon boxes, not a
 * hardcoded isthmus.
 *
 * Shared vertices on disconnected clip fragments are not seams. Each pack
 * keeps only vertices on a primary routable component that intersects this
 * corridor (the pack giant, plus any other corridor component at least 5% as
 * large). That keeps the QC–Labrador highway at Fermont even though
 * Newfoundland island is the NL pack giant, and drops logging spurs that
 * share a quantized vertex with a dead Labrador fragment.
 *
 *   node scripts/pack-fabric/scripts/build-v3-cross-pack-seams.js pe nb
 */
const fs = require("fs");
const path = require("path");
const https = require("https");
const { decodeGraphV2, decodeGeometryV1, unpackAccess } = require("../routing/lib/pack-v2");
const { spread } = require("./build-cross-pack-seams");
const { pointInBbox, seamCorridor } = require("../routing/lib/region-polygons");

const FABRIC = path.join(__dirname, "..");
const REGIONS = path.join(FABRIC, "routing", "data", "regions");
const PACKS = path.join(FABRIC, "app", "data", "packs", "v1");
const INDEX_PATH = path.join(FABRIC, "routing", "schema", "cross-pack-topology.v1.json");
const CDN = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const FROZEN = new Set(["ns", "nb"]);
/** Keep corridor components at least this fraction of the largest one. */
const PRIMARY_COMPONENT_FRACTION = 0.05;

function coordKey(c) {
  return `${Number(c[0]).toFixed(5)},${Number(c[1]).toFixed(5)}`;
}

function localPackFiles(id) {
  const names = ["graph.v3.bin", "geometry.v1.bin"];
  for (const root of [path.join(REGIONS, id), path.join(PACKS, id)]) {
    const graph = path.join(root, names[0]);
    const geom = path.join(root, names[1]);
    if (fs.existsSync(graph) && fs.existsSync(geom)) return { graph, geom };
  }
  return null;
}

function fetchHttps(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return fetchHttps(res.headers.location).then(resolve, reject);
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} ${url}`));
        }
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => resolve(Buffer.concat(chunks)));
      })
      .on("error", reject);
  });
}

async function loadPack(id, { preferRemote = false } = {}) {
  if (!preferRemote) {
    const local = localPackFiles(id);
    if (local) {
      return {
        id,
        source: local.graph,
        pack: decodeGraphV2(fs.readFileSync(local.graph)),
        geom: decodeGeometryV1(fs.readFileSync(local.geom))
      };
    }
  }
  const base = `${CDN.replace(/\/$/, "")}/${id}`;
  const graphUrl = `${base}/graph.v3.bin`;
  const graphBuf = await fetchHttps(graphUrl);
  const geomBuf = await fetchHttps(`${base}/geometry.v1.bin`);
  return {
    id,
    source: graphUrl,
    pack: decodeGraphV2(graphBuf),
    geom: decodeGeometryV1(geomBuf)
  };
}

function primaryComponentFloor(largestSize, fraction = PRIMARY_COMPONENT_FRACTION) {
  const n = Number(largestSize) || 0;
  if (n <= 0) return Infinity;
  return Math.max(1, Math.floor(n * fraction));
}

function permissiveComponents(loaded) {
  const { pack } = loaded;
  const n = pack.nodeCount;
  if (!pack.edgeFrom || !pack.edgeTo) {
    throw new Error(`${loaded.id || "pack"} missing edgeFrom/edgeTo; cannot prove a primary component`);
  }
  const parent = new Int32Array(n);
  const size = new Int32Array(n);
  for (let i = 0; i < n; i += 1) {
    parent[i] = i;
    size[i] = 1;
  }
  function find(value) {
    let root = value;
    while (parent[root] !== root) root = parent[root];
    while (parent[value] !== value) {
      const next = parent[value];
      parent[value] = root;
      value = next;
    }
    return root;
  }
  function union(a, b) {
    let ra = find(a);
    let rb = find(b);
    if (ra === rb) return;
    if (size[ra] < size[rb]) {
      const swap = ra;
      ra = rb;
      rb = swap;
    }
    parent[rb] = ra;
    size[ra] += size[rb];
  }
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    if (unpackAccess(pack.edgeAttrs[ei]) > 1) continue;
    const a = pack.edgeFrom[ei];
    const b = pack.edgeTo[ei];
    if (a < 0 || b < 0 || a >= n || b >= n) continue;
    union(a, b);
  }
  return { find, size };
}

function corridorPrimary(loaded, corridor) {
  const { pack, geom } = loaded;
  const components = permissiveComponents(loaded);
  let largest = 0;
  const seen = new Set();
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    if (unpackAccess(pack.edgeAttrs[ei]) > 1) continue;
    const line = geom.polyline(ei);
    if (!line || line.length < 2) continue;
    let hit = false;
    if (!corridor) hit = true;
    else {
      for (const c of line) {
        if (pointInBbox(Number(c[0]), Number(c[1]), corridor)) {
          hit = true;
          break;
        }
      }
    }
    if (!hit) continue;
    const a = pack.edgeFrom[ei];
    if (a < 0 || a >= pack.nodeCount) continue;
    const root = components.find(a);
    if (seen.has(root)) continue;
    seen.add(root);
    const componentSize = components.size[root];
    if (componentSize > largest) largest = componentSize;
  }
  const floor = primaryComponentFloor(largest);
  return {
    largest,
    floor,
    onPrimary(nodeId) {
      if (nodeId == null || nodeId < 0 || nodeId >= pack.nodeCount) return false;
      return components.size[components.find(nodeId)] >= floor;
    }
  };
}

function permissiveVertices(loaded, corridor) {
  const { pack, geom } = loaded;
  const primary = corridorPrimary(loaded, corridor);
  const byKey = new Map();
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    if (unpackAccess(pack.edgeAttrs[ei]) > 1) continue;
    if (!primary.onPrimary(pack.edgeFrom[ei]) || !primary.onPrimary(pack.edgeTo[ei])) continue;
    const line = geom.polyline(ei);
    if (!line || line.length < 2) continue;
    for (const c of line) {
      const lon = Number(c[0]);
      const lat = Number(c[1]);
      if (corridor && !pointInBbox(lon, lat, corridor)) continue;
      const key = coordKey(c);
      if (byKey.has(key)) continue;
      byKey.set(key, {
        coordinate: [lon, lat],
        edgeId: pack.edgeId(ei),
        access: unpackAccess(pack.edgeAttrs[ei]),
        surface: pack.edgeAttrs[ei] & 7
      });
    }
  }
  return { byKey, primary };
}

function writeSidecar(regionId, neighborId, anchors) {
  const dir = path.join(REGIONS, regionId);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "cross-pack-seams.v1.json");
  let data = {
    schemaVersion: "cross-pack-seams.v1",
    regionId,
    generatedAt: new Date().toISOString(),
    method: "same-quantized-vertex-v3",
    neighbors: {}
  };
  if (fs.existsSync(file)) {
    try {
      data = JSON.parse(fs.readFileSync(file, "utf8"));
      data.neighbors = data.neighbors || {};
    } catch (_) {
      /* replace */
    }
  }
  data.generatedAt = new Date().toISOString();
  data.neighbors[neighborId] = anchors;
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  return file;
}

function mergeLiveIndex(leftId, rightId, leftAnchors, rightAnchors) {
  const index = JSON.parse(fs.readFileSync(INDEX_PATH, "utf8"));
  index.generatedAt = new Date().toISOString();
  index.regions = index.regions || {};
  for (const [id, neighbor, anchors] of [
    [leftId, rightId, leftAnchors],
    [rightId, leftId, rightAnchors]
  ]) {
    const row = index.regions[id] || { neighbors: {}, urbanCores: [] };
    row.neighbors = row.neighbors || {};
    row.urbanCores = Array.isArray(row.urbanCores) ? row.urbanCores : [];
    row.neighbors[neighbor] = anchors;
    index.regions[id] = row;
  }
  fs.writeFileSync(INDEX_PATH, JSON.stringify(index, null, 2) + "\n");
  return INDEX_PATH;
}

function reverseAnchor(row) {
  return {
    ...row,
    localEdgeId: row.remoteEdgeId,
    remoteEdgeId: row.localEdgeId,
    localAccess: row.remoteAccess,
    remoteAccess: row.localAccess,
    localSurface: row.remoteSurface,
    remoteSurface: row.localSurface
  };
}

async function main(argv = process.argv.slice(2)) {
  const leftId = String(argv[0] || "").toLowerCase();
  const rightId = String(argv[1] || "").toLowerCase();
  if (!leftId || !rightId) {
    throw new Error("Usage: build-v3-cross-pack-seams.js <left-region> <right-region>");
  }
  const corridor = seamCorridor(leftId, rightId);
  const left = await loadPack(leftId, { preferRemote: FROZEN.has(leftId) });
  const right = await loadPack(rightId, { preferRemote: FROZEN.has(rightId) });
  if (!left.pack.hasLeaves || !right.pack.hasLeaves) {
    throw new Error("both packs must be v3 with leaves");
  }
  const leftVerts = permissiveVertices(left, corridor);
  const rightVerts = permissiveVertices(right, corridor);
  const shared = [];
  for (const [key, leftRow] of leftVerts.byKey) {
    const rightRow = rightVerts.byKey.get(key);
    if (!rightRow) continue;
    shared.push({
      coordinate: leftRow.coordinate,
      osmWayId: `vertex:${key}`,
      localEdgeId: leftRow.edgeId,
      remoteEdgeId: rightRow.edgeId,
      localAccess: leftRow.access,
      remoteAccess: rightRow.access,
      localSurface: leftRow.surface,
      remoteSurface: rightRow.surface,
      localRoadClass: "unknown",
      remoteRoadClass: "unknown",
      gapMeters: 0
    });
  }
  const summary = {
    pair: [leftId, rightId],
    leftSource: left.source,
    rightSource: right.source,
    corridor,
    leftPrimary: { largest: leftVerts.primary.largest, floor: leftVerts.primary.floor },
    rightPrimary: { largest: rightVerts.primary.largest, floor: rightVerts.primary.floor },
    sharedRoutableVertices: shared.length,
    anchors: 0,
    nsPackRewritten: false,
    frozenPacksUntouched: true
  };
  if (!shared.length) {
    summary.ok = false;
    summary.message = `${leftId}<->${rightId}: no shared primary-component vertex in the admin overlap`;
    console.log(JSON.stringify(summary, null, 2));
    return summary;
  }
  shared.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
  const anchors = spread(shared);
  const sidecarIds = [leftId, rightId].filter((id) => !FROZEN.has(id));
  if (!sidecarIds.length) {
    throw new Error(`refusing to write a seam sidecar into frozen packs '${leftId}' '${rightId}'`);
  }
  const sidecars = sidecarIds.map((id) => {
    const neighborId = id === leftId ? rightId : leftId;
    const rows = id === leftId ? anchors : anchors.map(reverseAnchor);
    return writeSidecar(id, neighborId, rows);
  });
  const indexPath = mergeLiveIndex(leftId, rightId, anchors, anchors.map(reverseAnchor));
  summary.ok = true;
  summary.anchors = anchors.length;
  summary.maxGapMeters = 0;
  summary.sidecar = sidecars[0];
  summary.sidecars = sidecars;
  summary.indexPath = indexPath;
  console.log(JSON.stringify(summary, null, 2));
  return summary;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
  });
}

module.exports = {
  PRIMARY_COMPONENT_FRACTION,
  corridorPrimary,
  main,
  permissiveVertices,
  primaryComponentFloor
};
