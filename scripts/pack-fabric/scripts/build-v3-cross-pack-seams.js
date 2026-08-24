#!/usr/bin/env node
"use strict";

/**
 * Prove an NS↔NB seam from two v3 packs without rewriting Nova Scotia.
 *
 * Reads live (or local) NS graph.v3.bin + local NB graph.v3.bin. A seam is a
 * quantized vertex that exists on a permissive edge in both packs. Writes:
 *   - regions/nb/cross-pack-seams.v1.json  (NB only)
 *   - routing/schema/cross-pack-topology.v1.json merge (live index, both directions)
 *
 * Usage:
 *   node scripts/pack-fabric/scripts/build-v3-cross-pack-seams.js ns nb
 */
const fs = require("fs");
const path = require("path");
const https = require("https");
const { decodeGraphV2, decodeGeometryV1, unpackAccess } = require("../routing/lib/pack-v2");
const { spread } = require("./build-cross-pack-seams");

const FABRIC = path.join(__dirname, "..");
const REGIONS = path.join(FABRIC, "routing", "data", "regions");
const PACKS = path.join(FABRIC, "app", "data", "packs", "v1");
const INDEX_PATH = path.join(FABRIC, "routing", "schema", "cross-pack-topology.v1.json");
const CDN = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";

const TANTRAMAR = { minLon: -64.55, minLat: 45.72, maxLon: -63.95, maxLat: 46.08 };

function coordKey(c) {
  return `${Number(c[0]).toFixed(5)},${Number(c[1]).toFixed(5)}`;
}

function inCorridor(c) {
  const lon = Number(c[0]);
  const lat = Number(c[1]);
  return lon >= TANTRAMAR.minLon && lon <= TANTRAMAR.maxLon && lat >= TANTRAMAR.minLat && lat <= TANTRAMAR.maxLat;
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
  const graphBuf = await fetchHttps(`${base}/graph.v3.bin`);
  const geomBuf = await fetchHttps(`${base}/geometry.v1.bin`);
  return {
    id,
    source: `${base}/graph.v3.bin`,
    pack: decodeGraphV2(graphBuf),
    geom: decodeGeometryV1(geomBuf)
  };
}

function permissiveVertices(loaded) {
  const { pack, geom } = loaded;
  const byKey = new Map();
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    if (unpackAccess(pack.edgeAttrs[ei]) > 1) continue;
    const line = geom.polyline(ei);
    if (!line || line.length < 2) continue;
    for (const c of line) {
      if (!inCorridor(c)) continue;
      const key = coordKey(c);
      if (byKey.has(key)) continue;
      byKey.set(key, {
        coordinate: [Number(c[0]), Number(c[1])],
        edgeId: pack.edgeId(ei),
        access: unpackAccess(pack.edgeAttrs[ei]),
        surface: pack.edgeAttrs[ei] & 7
      });
    }
  }
  return byKey;
}

function writeNbSidecar(neighborId, anchors) {
  const dir = path.join(REGIONS, "nb");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "cross-pack-seams.v1.json");
  const data = {
    schemaVersion: "cross-pack-seams.v1",
    regionId: "nb",
    generatedAt: new Date().toISOString(),
    method: "same-quantized-vertex-v3",
    neighbors: { [neighborId]: anchors }
  };
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

async function main() {
  const leftId = String(process.argv[2] || "ns").toLowerCase();
  const rightId = String(process.argv[3] || "nb").toLowerCase();
  const left = await loadPack(leftId, { preferRemote: leftId === "ns" });
  const right = await loadPack(rightId);
  if (!left.pack.hasLeaves || !right.pack.hasLeaves) {
    throw new Error("both packs must be v3 with leaves");
  }
  const leftVerts = permissiveVertices(left);
  const rightVerts = permissiveVertices(right);
  const shared = [];
  for (const [key, leftRow] of leftVerts) {
    const rightRow = rightVerts.get(key);
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
  if (!shared.length) {
    throw new Error(`${leftId}<->${rightId}: no shared permissive vertex in the Tantramar corridor`);
  }
  shared.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
  const anchors = spread(shared);
  const sidecar = writeNbSidecar(leftId, anchors.map(reverseAnchor));
  const indexPath = mergeLiveIndex(leftId, rightId, anchors, anchors.map(reverseAnchor));
  const summary = {
    pair: [leftId, rightId],
    leftSource: left.source,
    rightSource: right.source,
    sharedRoutableVertices: shared.length,
    anchors: anchors.length,
    maxGapMeters: 0,
    sidecar,
    indexPath,
    nsPackRewritten: false
  };
  console.log(JSON.stringify(summary, null, 2));
  return summary;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
  });
}

module.exports = { main };
