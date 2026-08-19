#!/usr/bin/env node
"use strict";

/**
 * Pack-time near-miss joins: adventure tips (track / resource / local, permissive)
 * onto the nearest through-road node within JOIN_M.
 *
 * Does NOT stitch motorized_unknown (Allow unknown stays the legal gate).
 * Adds short undirected edges; does not merge nodes (keeps original geometry).
 *
 * Usage:
 *   node scripts/stitch-adventure-tips.js routing/data/regions/bc/graph.v1.json.gz
 *   node scripts/stitch-adventure-tips.js --pack-v2 routing/data/regions/bc/graph.v1.json.gz
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { writePacksFromV1, v2PathsForV1Path } = require("../routing/lib/pack-v2");

const JOIN_M = Number(process.env.STITCH_JOIN_M || 150);
const ADVENTURE_RT = new Set([
  "track",
  "double_track",
  "resource",
  "recreation",
  "local"
]);

function haversineMeters(lon1, lat1, lon2, lat2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function enumIndex(list, name, fallback) {
  if (!Array.isArray(list)) return fallback;
  const i = list.indexOf(name);
  return i >= 0 ? i : fallback;
}

function inflateGraph(filePath) {
  const raw = fs.readFileSync(filePath);
  if (raw.length >= 2 && raw[0] === 0x1f && raw[1] === 0x8b) {
    return JSON.parse(zlib.gunzipSync(raw).toString("utf8"));
  }
  return JSON.parse(raw.toString("utf8"));
}

function nodeLonLat(data, nodeCoords, i) {
  if (nodeCoords) return [nodeCoords[i * 2], nodeCoords[i * 2 + 1]];
  const n = data.nodes[i];
  return [Number(n[0]), Number(n[1])];
}

function buildNodeCoords(data) {
  const nodeCount = data.nodeCount || (data.nodes && data.nodes.length) || 0;
  const coords = new Float64Array(nodeCount * 2);
  if (Array.isArray(data.nodes) && data.nodes.length === nodeCount) {
    for (let i = 0; i < nodeCount; i += 1) {
      coords[i * 2] = Number(data.nodes[i][0]);
      coords[i * 2 + 1] = Number(data.nodes[i][1]);
    }
    return coords;
  }
  const seen = new Uint8Array(nodeCount);
  for (const edge of data.edges || []) {
    const g = edge.g || [];
    if (!g.length) continue;
    if (edge.a >= 0 && edge.a < nodeCount && !seen[edge.a]) {
      coords[edge.a * 2] = Number(g[0][0]);
      coords[edge.a * 2 + 1] = Number(g[0][1]);
      seen[edge.a] = 1;
    }
    if (edge.b >= 0 && edge.b < nodeCount && !seen[edge.b]) {
      const last = g[g.length - 1];
      coords[edge.b * 2] = Number(last[0]);
      coords[edge.b * 2 + 1] = Number(last[1]);
      seen[edge.b] = 1;
    }
  }
  return coords;
}

function stitchAdventureTips(data, joinM = JOIN_M) {
  const edges = data.edges || [];
  const nodeCount = data.nodeCount || (data.nodes && data.nodes.length) || 0;
  const accessNames = (data.enums && data.enums.ACCESS_NAME) || [];
  const surfaceNames = (data.enums && data.enums.SURFACE_NAME) || [];
  const unknownAc = enumIndex(accessNames, "motorized_unknown", 2);
  const restrictedAc = enumIndex(accessNames, "motorized_restricted", 3);
  const excludedAc = enumIndex(accessNames, "motorized_excluded", 4);
  const permissiveAc = enumIndex(accessNames, "motorized_permissive", 1);
  const accessSurface = enumIndex(surfaceNames, "access", enumIndex(surfaceNames, "resource", 2));

  const degree = new Int32Array(nodeCount);
  const adventureDegree = new Int32Array(nodeCount);
  const throughPermissive = new Uint8Array(nodeCount);

  for (const edge of edges) {
    const a = edge.a;
    const b = edge.b;
    if (a < 0 || b < 0 || a >= nodeCount || b >= nodeCount) continue;
    degree[a] += 1;
    degree[b] += 1;
    const ac = Number(edge.ac);
    if (ac === unknownAc || ac === restrictedAc || ac === excludedAc) continue;
    throughPermissive[a] = 1;
    throughPermissive[b] = 1;
    const rt = String(edge.rt || "").toLowerCase();
    if (ADVENTURE_RT.has(rt)) {
      adventureDegree[a] += 1;
      adventureDegree[b] += 1;
    }
  }

  const coords = buildNodeCoords(data);
  const cell = 0.0015; // ~165 m
  const throughGrid = new Map();
  function key(lon, lat) {
    return `${Math.floor(lon / cell)}:${Math.floor(lat / cell)}`;
  }
  const throughNodes = [];
  for (let i = 0; i < nodeCount; i += 1) {
    if (degree[i] < 2 || !throughPermissive[i]) continue;
    throughNodes.push(i);
    const k = key(coords[i * 2], coords[i * 2 + 1]);
    const bucket = throughGrid.get(k);
    if (bucket) bucket.push(i);
    else throughGrid.set(k, [i]);
  }

  const ring = Math.max(1, Math.ceil(joinM / 55) + 1);
  const seenPair = new Set();
  const stitches = [];

  for (let tip = 0; tip < nodeCount; tip += 1) {
    if (degree[tip] !== 1 || adventureDegree[tip] < 1) continue;
    if (!throughPermissive[tip]) continue;
    const lon = coords[tip * 2];
    const lat = coords[tip * 2 + 1];
    const gx = Math.floor(lon / cell);
    const gy = Math.floor(lat / cell);
    let best = -1;
    let bestM = joinM + 1;
    for (let dx = -ring; dx <= ring; dx += 1) {
      for (let dy = -ring; dy <= ring; dy += 1) {
        const bucket = throughGrid.get(`${gx + dx}:${gy + dy}`);
        if (!bucket) continue;
        for (const other of bucket) {
          if (other === tip) continue;
          const m = haversineMeters(lon, lat, coords[other * 2], coords[other * 2 + 1]);
          if (m < bestM && m >= 2) {
            bestM = m;
            best = other;
          }
        }
      }
    }
    if (best < 0) continue;
    const lo = Math.min(tip, best);
    const hi = Math.max(tip, best);
    const pair = `${lo}:${hi}`;
    if (seenPair.has(pair)) continue;
    seenPair.add(pair);
    stitches.push({ tip, through: best, meters: bestM });
  }

  const aLon = (i) => coords[i * 2];
  const aLat = (i) => coords[i * 2 + 1];
  for (const s of stitches) {
    edges.push({
      i: `pack-stitch-${s.tip}-${s.through}`,
      a: s.tip,
      b: s.through,
      m: Math.max(1, Math.round(s.meters)),
      g: [
        [aLon(s.tip), aLat(s.tip)],
        [aLon(s.through), aLat(s.through)]
      ],
      s: accessSurface,
      ac: permissiveAc,
      t: 0,
      conf: "medium",
      rt: "resource",
      src: "Pack tip stitch"
    });
  }

  data.edges = edges;
  data.edgeCount = edges.length;
  if (!data.lineage) data.lineage = {};
  data.lineage.adventureTipStitch = {
    meters: joinM,
    stitchedTips: stitches.length,
    throughNodes: throughNodes.length,
    note: "Permissive track/resource/local tips joined to nearest through-road node. motorized_unknown is not stitched."
  };
  return {
    stitchedTips: stitches.length,
    throughNodes: throughNodes.length,
    edgeCount: edges.length,
    joinM
  };
}

function main() {
  const args = process.argv.slice(2);
  const packV2 = args.includes("--pack-v2");
  const file = args.find((a) => !a.startsWith("--"));
  if (!file) {
    console.error("Usage: stitch-adventure-tips.js [--pack-v2] <graph.v1.json.gz>");
    process.exit(1);
  }
  const abs = path.resolve(file);
  console.log(`inflate ${abs}`);
  const data = inflateGraph(abs);
  const started = Date.now();
  const stats = stitchAdventureTips(data, JOIN_M);
  console.log(JSON.stringify({ ...stats, stitchMs: Date.now() - started }));

  if (packV2) {
    const paths = v2PathsForV1Path(abs);
    const meta = writePacksFromV1(data, paths.graph, paths.geom);
    console.log(JSON.stringify({ packed: true, ...meta, outGraph: paths.graph, outGeom: paths.geom }));
    const metaPath = abs.replace(/graph\.v1\.json\.gz$/i, "graph.v1.meta.json");
    if (fs.existsSync(metaPath)) {
      const metaJson = JSON.parse(fs.readFileSync(metaPath, "utf8"));
      metaJson.lineage = metaJson.lineage || {};
      metaJson.lineage.adventureTipStitch = data.lineage.adventureTipStitch;
      metaJson.edgeCount = data.edgeCount;
      fs.writeFileSync(metaPath, JSON.stringify(metaJson, null, 2) + "\n");
    }
    return;
  }

  const out = abs.replace(/\.json\.gz$/i, ".stitched.json.gz");
  fs.writeFileSync(out, zlib.gzipSync(Buffer.from(JSON.stringify(data))));
  console.log("wrote", out);
}

if (require.main === module) {
  main();
}

module.exports = { stitchAdventureTips, JOIN_M };
