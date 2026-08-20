#!/usr/bin/env node
"use strict";

/**
 * Derive a pack seam from topology shared by two independently built OSM packs.
 *
 * A seam is accepted only when both packs contain the same OSM way id and the
 * same quantized OSM vertex. No border sample, named crossing, nearest-road
 * bridge, or free-space connector is created here.
 *
 * Usage:
 *   node scripts/build-cross-pack-seams.js bc ab
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const readline = require("readline");
const { classify } = require("../routing/adapters/osm-roads");
const { syncCrossPackTopology } = require("./sync-cross-pack-topology");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const MAX_ANCHORS = 96;

function readGraph(id) {
  const file = path.join(REGIONS, id, "graph.v1.json.gz");
  if (!fs.existsSync(file)) throw new Error(`Missing ${file}`);
  return JSON.parse(zlib.gunzipSync(fs.readFileSync(file)).toString("utf8"));
}

function coordKey(c) {
  return `${Number(c[0]).toFixed(5)},${Number(c[1]).toFixed(5)}`;
}

function isOsm(edge) {
  return /openstreetmap/i.test(String(edge.src || "")) && edge.rid != null;
}

function permissibleConnectivity(nodeCount, edges) {
  const parent = new Int32Array(nodeCount);
  const size = new Int32Array(nodeCount);
  for (let i = 0; i < nodeCount; i += 1) { parent[i] = i; size[i] = 1; }
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
    if (size[ra] < size[rb]) { const swap = ra; ra = rb; rb = swap; }
    parent[rb] = ra;
    size[ra] += size[rb];
  }
  for (const edge of edges || []) {
    if (Number(edge.ac) <= 1) union(Number(edge.a), Number(edge.b));
  }
  let giant = 0;
  for (let i = 1; i < nodeCount; i += 1) {
    if (parent[i] === i && size[i] > size[giant]) giant = i;
  }
  return { find, giant };
}

function edgeRecords(graph) {
  const connectivity = permissibleConnectivity(graph.nodeCount || graph.nodes.length, graph.edges || []);
  const byWay = new Map();
  for (const edge of graph.edges || []) {
    if (!isOsm(edge) || Number(edge.ac) > 1 || connectivity.find(Number(edge.a)) !== connectivity.giant || !Array.isArray(edge.g) || edge.g.length < 2) continue;
    const wayId = String(edge.rid);
    let rows = byWay.get(wayId);
    if (!rows) {
      rows = [];
      byWay.set(wayId, rows);
    }
    rows.push(edge);
  }
  return byWay;
}

function candidates(leftGraph, rightGraph) {
  const leftByWay = edgeRecords(leftGraph);
  const rightByWay = edgeRecords(rightGraph);
  const out = [];
  const seen = new Set();

  for (const [wayId, leftEdges] of leftByWay) {
    const rightEdges = rightByWay.get(wayId);
    if (!rightEdges) continue;
    const rightVertices = new Map();
    for (const edge of rightEdges) {
      for (const c of edge.g) rightVertices.set(coordKey(c), { c, edge });
    }
    for (const leftEdge of leftEdges) {
      for (const c of leftEdge.g) {
        const key = coordKey(c);
        const right = rightVertices.get(key);
        if (!right || seen.has(key)) continue;
        seen.add(key);
        out.push({
          coordinate: [Number(c[0]), Number(c[1])],
          osmWayId: wayId,
          localEdgeId: String(leftEdge.i),
          remoteEdgeId: String(right.edge.i),
          localAccess: Number(leftEdge.ac),
          remoteAccess: Number(right.edge.ac),
          localSurface: Number(leftEdge.s),
          remoteSurface: Number(right.edge.s),
          localRoadClass: String(leftEdge.rt || "unknown"),
          remoteRoadClass: String(right.edge.rt || "unknown"),
          gapMeters: 0
        });
      }
    }
  }
  return out;
}

function distanceSq(a, b) {
  const midLat = ((a[1] + b[1]) * Math.PI) / 360;
  const dx = (a[0] - b[0]) * Math.cos(midLat);
  const dy = a[1] - b[1];
  return dx * dx + dy * dy;
}

/** Keep geographic coverage rather than 96 consecutive vertices on one road. */
function spread(rows, limit = MAX_ANCHORS) {
  if (rows.length <= limit) return rows;
  const selected = [rows[0]];
  const remaining = rows.slice(1);
  while (selected.length < limit && remaining.length) {
    let bestIndex = 0;
    let bestDistance = -1;
    for (let i = 0; i < remaining.length; i += 1) {
      let nearest = Infinity;
      for (const pick of selected) {
        nearest = Math.min(nearest, distanceSq(remaining[i].coordinate, pick.coordinate));
      }
      if (nearest > bestDistance) {
        bestDistance = nearest;
        bestIndex = i;
      }
    }
    selected.push(remaining.splice(bestIndex, 1)[0]);
  }
  return selected;
}

function reverseAnchor(row) {
  return {
    ...row,
    localEdgeId: row.remoteEdgeId,
    remoteEdgeId: row.localEdgeId,
    localAccess: row.remoteAccess,
    remoteAccess: row.localAccess,
    localSurface: row.remoteSurface,
    remoteSurface: row.localSurface,
    localRoadClass: row.remoteRoadClass,
    remoteRoadClass: row.localRoadClass
  };
}

function lineStrings(geometry) {
  if (!geometry) return [];
  if (geometry.type === "LineString") return [geometry.coordinates || []];
  if (geometry.type === "MultiLineString") return geometry.coordinates || [];
  return [];
}

async function readSequence(file) {
  const byWay = new Map();
  const input = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of input) {
    const record = line.replace(/^\x1e/, "").trim();
    if (!record) continue;
    const feature = JSON.parse(record);
    const props = feature.properties || {};
    const result = classify(props);
    if (!result.ok || result.accessClass === "motorized_unknown") continue;
    const wayId = String(props["@id"] || props.id || feature.id || "").replace(/^w/, "");
    if (!wayId) continue;
    const rows = byWay.get(wayId) || [];
    for (const coords of lineStrings(feature.geometry)) {
      if (!Array.isArray(coords) || coords.length < 2) continue;
      rows.push({
        coords,
        access: 1,
        surface: result.surfaceClass,
        roadClass: result.roadTrackClass
      });
    }
    if (rows.length) byWay.set(wayId, rows);
  }
  return byWay;
}

async function candidatesFromSequences(leftFile, rightFile) {
  const [leftByWay, rightByWay] = await Promise.all([
    readSequence(leftFile),
    readSequence(rightFile)
  ]);
  const out = [];
  const seen = new Set();
  for (const [wayId, leftRows] of leftByWay) {
    const rightRows = rightByWay.get(wayId);
    if (!rightRows) continue;
    const rightVertices = new Map();
    for (const row of rightRows) {
      for (const c of row.coords) rightVertices.set(coordKey(c), { c, row });
    }
    for (const left of leftRows) {
      for (const c of left.coords) {
        const key = coordKey(c);
        const right = rightVertices.get(key);
        if (!right || seen.has(key)) continue;
        seen.add(key);
        out.push({
          coordinate: [Number(c[0]), Number(c[1])],
          osmWayId: wayId,
          localEdgeId: "",
          remoteEdgeId: "",
          localAccess: left.access,
          remoteAccess: right.row.access,
          localSurface: left.surface,
          remoteSurface: right.row.surface,
          localRoadClass: left.roadClass,
          remoteRoadClass: right.row.roadClass,
          gapMeters: 0
        });
      }
    }
  }
  return out;
}

async function streamGraphComponents(file, wantedWays) {
  const metaPath = file.replace(/graph\.v1\.json\.gz$/i, "graph.v1.meta.json");
  const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
  const parent = new Int32Array(meta.nodeCount);
  const size = new Int32Array(meta.nodeCount);
  for (let i = 0; i < meta.nodeCount; i += 1) { parent[i] = i; size[i] = 1; }
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
    if (size[ra] < size[rb]) { const swap = ra; ra = rb; rb = swap; }
    parent[rb] = ra;
    size[ra] += size[rb];
  }
  const wayEndpoints = new Map();
  const source = fs.createReadStream(file).pipe(zlib.createGunzip());
  source.setEncoding("utf8");
  const marker = '"edges":[';
  let search = "";
  let found = false;
  let value = "";
  let depth = 0;
  let inString = false;
  let escaped = false;
  let done = false;
  for await (const chunk of source) {
    let text = chunk;
    if (!found) {
      search += text;
      const at = search.indexOf(marker);
      if (at < 0) { search = search.slice(-Math.max(marker.length, 64)); continue; }
      text = search.slice(at + marker.length);
      search = "";
      found = true;
    }
    for (let i = 0; i < text.length; i += 1) {
      const ch = text[i];
      if (depth === 0) {
        if (ch === "]") { done = true; break; }
        if (ch !== "{") continue;
        value = "{";
        depth = 1;
        inString = false;
        escaped = false;
        continue;
      }
      value += ch;
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{" || ch === "[") depth += 1;
      else if (ch === "}" || ch === "]") depth -= 1;
      if (depth === 0) {
        const edge = JSON.parse(value);
        value = "";
        if (Number(edge.ac) > 1) continue;
        const a = Number(edge.a);
        const b = Number(edge.b);
        union(a, b);
        const wayId = String(edge.rid == null ? "" : edge.rid);
        if (wantedWays.has(wayId)) {
          const endpoints = wayEndpoints.get(wayId) || [];
          endpoints.push(a, b);
          wayEndpoints.set(wayId, endpoints);
        }
      }
    }
    if (done) break;
  }
  let giant = 0;
  for (let i = 1; i < meta.nodeCount; i += 1) {
    if (parent[i] === i && size[i] > size[giant]) giant = i;
  }
  return {
    wayOnGiant(wayId) {
      return (wayEndpoints.get(wayId) || []).some((node) => find(node) === giant);
    }
  };
}

function writeSidecar(id, neighborId, anchors) {
  const file = path.join(REGIONS, id, "cross-pack-seams.v1.json");
  let data = {
    schemaVersion: "cross-pack-seams.v1",
    regionId: id,
    generatedAt: new Date().toISOString(),
    method: "same-osm-way-and-vertex",
    neighbors: {}
  };
  if (fs.existsSync(file)) {
    data = JSON.parse(fs.readFileSync(file, "utf8"));
    data.schemaVersion = "cross-pack-seams.v1";
    data.regionId = id;
    data.generatedAt = new Date().toISOString();
    data.method = "same-osm-way-and-vertex";
    data.neighbors = data.neighbors || {};
  }
  data.neighbors[neighborId] = anchors;
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  return file;
}

function build(leftId, rightId) {
  const leftGraph = readGraph(leftId);
  const rightGraph = readGraph(rightId);
  const all = candidates(leftGraph, rightGraph).filter(
    // Seam anchors must work with Allow unknown OFF for every profile.
    (row) => row.localAccess <= 1 && row.remoteAccess <= 1
  );
  if (!all.length) {
    throw new Error(
      `${leftId}<->${rightId}: no shared routable OSM way vertex; pack boundary/extract must be repaired`
    );
  }
  all.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
  const anchors = spread(all);
  const leftFile = writeSidecar(leftId, rightId, anchors);
  const rightFile = writeSidecar(rightId, leftId, anchors.map(reverseAnchor));
  return {
    pair: [leftId, rightId],
    sharedRoutableVertices: all.length,
    anchors: anchors.length,
    osmWays: new Set(anchors.map((row) => row.osmWayId)).size,
    maxGapMeters: Math.max(...anchors.map((row) => row.gapMeters)),
    files: [leftFile, rightFile]
  };
}

function writePair(leftId, rightId, all) {
  if (!all.length) {
    throw new Error(
      `${leftId}<->${rightId}: no shared routable OSM way vertex; pack boundary/extract must be repaired`
    );
  }
  all.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
  const anchors = spread(all);
  const leftFile = writeSidecar(leftId, rightId, anchors);
  const rightFile = writeSidecar(rightId, leftId, anchors.map(reverseAnchor));
  return {
    pair: [leftId, rightId],
    sharedRoutableVertices: all.length,
    anchors: anchors.length,
    osmWays: new Set(anchors.map((row) => row.osmWayId)).size,
    maxGapMeters: Math.max(...anchors.map((row) => row.gapMeters)),
    files: [leftFile, rightFile]
  };
}

async function buildFromSequences(leftId, rightId, leftFile, rightFile) {
  const all = await candidatesFromSequences(leftFile, rightFile);
  const wantedWays = new Set(all.map((row) => row.osmWayId));
  const [leftGraph, rightGraph] = await Promise.all([
    streamGraphComponents(path.join(REGIONS, leftId, "graph.v1.json.gz"), wantedWays),
    streamGraphComponents(path.join(REGIONS, rightId, "graph.v1.json.gz"), wantedWays)
  ]);
  const connected = all.filter((row) =>
    leftGraph.wayOnGiant(row.osmWayId) && rightGraph.wayOnGiant(row.osmWayId)
  );
  return writePair(leftId, rightId, connected);
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const leftId = String(args[0] || "").toLowerCase();
  const rightId = String(args[1] || "").toLowerCase();
  if (!leftId || !rightId) {
    console.error("Usage: build-cross-pack-seams.js <left-region> <right-region>");
    process.exit(1);
  }
  const leftSeqAt = args.indexOf("--left-seq");
  const rightSeqAt = args.indexOf("--right-seq");
  const work = leftSeqAt >= 0 && rightSeqAt >= 0
    ? buildFromSequences(leftId, rightId, args[leftSeqAt + 1], args[rightSeqAt + 1])
    : Promise.resolve(build(leftId, rightId));
  work
    .then((result) => {
      result.liveTopologyIndex = syncCrossPackTopology();
      console.log(JSON.stringify(result, null, 2));
    })
    .catch((error) => { console.error(error); process.exit(1); });
}

module.exports = { build, buildFromSequences, candidates, candidatesFromSequences, spread };
