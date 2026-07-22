"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { surfaceForCosting, accessForPolicy } = require("../schema/enums");

/**
 * Build a compact offline routing graph from canonical edges.
 * Maintains router-compatible enums (including legacy access surface alias).
 */

const SURFACE = {
  paved: 0,
  gravel: 1,
  access: 2,
  track: 3,
  unknown: 4,
  resource: 2,
  double_track: 3
};
const STRUCTURE = {
  none: 0,
  bridge: 1,
  tunnel: 2,
  ford: 3,
  ferry: 4,
  blocked_passage: 5,
  unknown: 6
};
const ACCESS = {
  motorized_verified: 0,
  motorized_permissive: 1,
  motorized_unknown: 2,
  motorized_restricted: 3,
  motorized_excluded: 4,
  restricted: 3,
  excluded: 4
};

const ACCESS_NAME = {
  0: "motorized_verified",
  1: "motorized_permissive",
  2: "motorized_unknown",
  3: "motorized_restricted",
  4: "motorized_excluded"
};
const SURFACE_NAME = {
  0: "paved",
  1: "gravel",
  2: "access",
  3: "track",
  4: "unknown"
};
const STRUCTURE_NAME = {
  0: "none",
  1: "bridge",
  2: "tunnel",
  3: "ford",
  4: "ferry",
  5: "blocked_passage",
  6: "unknown"
};

function nodeKey(c) {
  return c[0].toFixed(5) + "," + c[1].toFixed(5);
}

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

/**
 * Reconcile provincial capillary endpoints onto existing fabric nodes when
 * surveys disagree by a few meters at a real junction. Not a free-space
 * connector and not island↔island gap spanning — no new edges are invented.
 */
const ENDPOINT_SNAP_METERS = 18;
const SNAP_CELL = 0.0002; // ~22 m

function isCapillaryFeature(feature) {
  const role = feature.meta && feature.meta.conflationRole;
  if (role === "supplement") return true;
  if (role === "backbone") return false;
  const src = String(feature.sourceName || "");
  // OSM / NRN are fabric even when tagged resource/track.
  if (/OpenStreetMap|^NRN\b|National Road/i.test(src)) return false;
  if (/Forest Roads|NSTDB|Topographic|FTEN|MNRF|Multi-Usage|Access Roads/i.test(src)) return true;
  const s = feature.surfaceClass;
  return s === "track" || s === "resource" || s === "access" || s === "double_track";
}

function bboxOf(nodes) {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const n of nodes) {
    minX = Math.min(minX, n[0]);
    minY = Math.min(minY, n[1]);
    maxX = Math.max(maxX, n[0]);
    maxY = Math.max(maxY, n[1]);
  }
  if (!Number.isFinite(minX)) return null;
  return [minX, minY, maxX, maxY];
}

function computeComponents(nodeCount, edges) {
  const parent = Array.from({ length: nodeCount }, (_, i) => i);
  function find(a) {
    while (parent[a] !== a) {
      parent[a] = parent[parent[a]];
      a = parent[a];
    }
    return a;
  }
  function union(a, b) {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  }
  for (const e of edges) {
    if (e.ac === ACCESS.motorized_excluded) continue;
    union(e.a, e.b);
  }
  const rootToId = new Map();
  let next = 0;
  const edgeComponents = edges.map((e) => {
    const root = find(e.a);
    if (!rootToId.has(root)) rootToId.set(root, next++);
    return rootToId.get(root);
  });
  return { edgeComponents, componentCount: rootToId.size };
}

/**
 * @param {object} options
 * @param {Array} options.features canonical edges
 * @param {string} options.province
 * @param {string} [options.regionId]
 * @param {object} [options.lineage]
 * @param {object} [options.conflationReport]
 */
function buildRegionalGraph(options = {}) {
  const features = options.features || [];
  const province = options.province || "NS";
  const regionId = options.regionId || province.toLowerCase();
  const snapMeters =
    options.endpointSnapMeters != null ? Number(options.endpointSnapMeters) : ENDPOINT_SNAP_METERS;

  const nodeLookup = new Map();
  const nodes = [];
  const edges = [];
  const accessCounts = {};
  const surfaceCounts = {};
  const sourceCounts = {};
  const snapGrid = new Map();
  let endpointSnaps = 0;

  function snapCellKey(c) {
    return Math.floor(c[0] / SNAP_CELL) + ":" + Math.floor(c[1] / SNAP_CELL);
  }

  function rememberSnapCell(id) {
    const c = nodes[id];
    const key = snapCellKey(c);
    let bucket = snapGrid.get(key);
    if (!bucket) {
      bucket = [];
      snapGrid.set(key, bucket);
    }
    bucket.push(id);
  }

  function addNodeExact(coord) {
    const key = nodeKey(coord);
    let id = nodeLookup.get(key);
    if (id != null) return id;
    id = nodes.length;
    nodeLookup.set(key, id);
    nodes.push([Number(coord[0]), Number(coord[1])]);
    rememberSnapCell(id);
    return id;
  }

  /** Capillary only: reuse a nearby existing node (usually OSM fabric). */
  function addNodeSnapped(coord) {
    const key = nodeKey(coord);
    const exact = nodeLookup.get(key);
    if (exact != null) return exact;
    if (!(snapMeters > 0)) return addNodeExact(coord);

    const ll = [Number(coord[0]), Number(coord[1])];
    const cx = Math.floor(ll[0] / SNAP_CELL);
    const cy = Math.floor(ll[1] / SNAP_CELL);
    let best = null;
    let bestD = snapMeters + 1;
    for (let dx = -1; dx <= 1; dx += 1) {
      for (let dy = -1; dy <= 1; dy += 1) {
        const bucket = snapGrid.get(cx + dx + ":" + (cy + dy));
        if (!bucket) continue;
        for (const id of bucket) {
          const d = haversineMeters(ll, nodes[id]);
          if (d < bestD) {
            bestD = d;
            best = id;
          }
        }
      }
    }
    if (best != null && bestD <= snapMeters) {
      endpointSnaps += 1;
      // Alias this rounded key so later exact matches land on the same join.
      nodeLookup.set(key, best);
      return best;
    }
    return addNodeExact(coord);
  }

  function addFeatureEdge(feature, snapEndpoints) {
    const policyAccess = accessForPolicy(feature.accessClass);
    if (policyAccess === "motorized_excluded") return;
    const coords = feature.geometry && feature.geometry.coordinates;
    if (!coords || coords.length < 2) return;
    const add = snapEndpoints ? addNodeSnapped : addNodeExact;
    const a = add(coords[0]);
    const b = add(coords[coords.length - 1]);
    if (a === b) return;

    const costSurface = surfaceForCosting(feature.surfaceClass);
    const accessCode = ACCESS[policyAccess] != null ? ACCESS[policyAccess] : ACCESS.motorized_unknown;
    const surfaceCode = SURFACE[costSurface] != null ? SURFACE[costSurface] : SURFACE.unknown;
    const structureCode =
      STRUCTURE[feature.structureType] != null ? STRUCTURE[feature.structureType] : STRUCTURE.none;

    accessCounts[policyAccess] = (accessCounts[policyAccess] || 0) + 1;
    surfaceCounts[costSurface] = (surfaceCounts[costSurface] || 0) + 1;
    sourceCounts[feature.sourceName] = (sourceCounts[feature.sourceName] || 0) + 1;

    edges.push({
      i: feature.edgeId,
      a,
      b,
      m: Math.max(1, Math.round(Number(feature.distanceMeters) || 0) || 1),
      s: surfaceCode,
      t: structureCode,
      ac: accessCode,
      rt: feature.roadTrackClass || "unknown",
      c: feature.componentId != null ? Number(feature.componentId) : -1,
      conf: feature.sourceConfidence || "medium",
      seasonal: !!feature.seasonal,
      src: feature.sourceName,
      desc: (feature.meta && feature.meta.sourceDescription) || "",
      rid: feature.sourceFeatureId || "",
      lin: feature.lineageId || "",
      role: (feature.meta && feature.meta.conflationRole) || "",
      g: coords.map((c) => [Number(c[0]), Number(c[1])])
    });
  }

  // Fabric first (exact nodes), then capillary with near-miss endpoint snap.
  const fabric = [];
  const capillary = [];
  for (const feature of features) {
    if (isCapillaryFeature(feature)) capillary.push(feature);
    else fabric.push(feature);
  }
  for (const feature of fabric) addFeatureEdge(feature, false);
  for (const feature of capillary) addFeatureEdge(feature, true);

  const { edgeComponents, componentCount } = computeComponents(nodes.length, edges);
  for (let i = 0; i < edges.length; i += 1) edges[i].c = edgeComponents[i];

  // Boundary nodes: degree-1 nodes near bbox edge (for future cross-region joins).
  const degree = Array.from({ length: nodes.length }, () => 0);
  for (const e of edges) {
    degree[e.a] += 1;
    degree[e.b] += 1;
  }
  const bbox = bboxOf(nodes);
  const boundaryNodes = [];
  if (bbox) {
    const padX = (bbox[2] - bbox[0]) * 0.02;
    const padY = (bbox[3] - bbox[1]) * 0.02;
    for (let i = 0; i < nodes.length; i += 1) {
      if (degree[i] !== 1) continue;
      const [x, y] = nodes[i];
      if (
        x <= bbox[0] + padX ||
        x >= bbox[2] - padX ||
        y <= bbox[1] + padY ||
        y >= bbox[3] - padY
      ) {
        boundaryNodes.push(i);
      }
    }
  }

  const lineage = options.lineage ? { ...options.lineage } : {};
  lineage.endpointSnap = {
    meters: snapMeters,
    snappedEndpoints: endpointSnaps,
    note:
      "Provincial capillary endpoints within snap meters reuse existing fabric nodes (survey near-miss joins). No free-space edges."
  };

  const graph = {
    version: 1,
    schemaVersion: "canada-regional-1",
    regionId,
    province,
    generatedAt: new Date().toISOString(),
    bbox,
    enums: { SURFACE, STRUCTURE, ACCESS, ACCESS_NAME, SURFACE_NAME, STRUCTURE_NAME },
    nodeCount: nodes.length,
    edgeCount: edges.length,
    componentCount,
    boundaryNodeCount: boundaryNodes.length,
    boundaryNodes,
    accessCounts,
    surfaceCounts,
    sourceCounts,
    lineage,
    conflation: options.conflationReport || null,
    nodes,
    edges
  };

  return graph;
}

function writeRegionalGraph(graph, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const graphPath = path.join(outDir, "graph.v1.json.gz");
  const metaPath = path.join(outDir, "graph.v1.meta.json");
  const tmpJson = path.join(outDir, "graph.v1.json.tmp");

  // Chunked write avoids JSON.stringify string-length limits on large packs.
  const fd = fs.openSync(tmpJson, "w");
  function ws(s) {
    fs.writeSync(fd, s);
  }
  ws("{");
  const scalars = { ...graph };
  const nodes = scalars.nodes;
  const edges = scalars.edges;
  delete scalars.nodes;
  delete scalars.edges;
  for (const k of Object.keys(scalars)) {
    ws(JSON.stringify(k) + ":" + JSON.stringify(scalars[k]) + ",");
  }
  ws('"nodes":[');
  for (let i = 0; i < nodes.length; i += 1) {
    if (i) ws(",");
    ws(JSON.stringify(nodes[i]));
  }
  ws('],"edges":[');
  for (let i = 0; i < edges.length; i += 1) {
    if (i) ws(",");
    ws(JSON.stringify(edges[i]));
  }
  ws("]}");
  fs.closeSync(fd);

  const jsonBytes = fs.statSync(tmpJson).size;
  const { spawnSync } = require("child_process");
  const z = spawnSync("gzip", ["-c", "-6", tmpJson], {
    maxBuffer: 1024 * 1024 * 1024
  });
  if (z.error || z.status !== 0) {
    const buf = zlib.gzipSync(fs.readFileSync(tmpJson), { level: 6 });
    fs.writeFileSync(graphPath, buf);
  } else {
    fs.writeFileSync(graphPath, z.stdout);
  }
  fs.unlinkSync(tmpJson);
  const gzBytes = fs.statSync(graphPath).size;

  const meta = {
    generatedAt: graph.generatedAt,
    schemaVersion: graph.schemaVersion,
    regionId: graph.regionId,
    province: graph.province,
    bbox: graph.bbox,
    nodeCount: graph.nodeCount,
    edgeCount: graph.edgeCount,
    componentCount: graph.componentCount,
    boundaryNodeCount: graph.boundaryNodeCount,
    accessCounts: graph.accessCounts,
    surfaceCounts: graph.surfaceCounts,
    sourceCounts: graph.sourceCounts,
    jsonBytes,
    gzBytes,
    lineage: graph.lineage,
    conflation: graph.conflation
      ? {
          stats: graph.conflation.stats || null,
          freeSpaceConnectors: graph.conflation.freeSpaceConnectors || 0
        }
      : null
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  return { graphPath, metaPath, meta };
}

module.exports = {
  buildRegionalGraph,
  writeRegionalGraph,
  ENDPOINT_SNAP_METERS,
  isCapillaryFeature,
  SURFACE,
  STRUCTURE,
  ACCESS,
  ACCESS_NAME,
  SURFACE_NAME,
  STRUCTURE_NAME
};
