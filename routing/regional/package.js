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

  const nodeLookup = new Map();
  const nodes = [];
  const edges = [];
  const accessCounts = {};
  const surfaceCounts = {};
  const sourceCounts = {};

  function addNode(coord) {
    const key = nodeKey(coord);
    let id = nodeLookup.get(key);
    if (id != null) return id;
    id = nodes.length;
    nodeLookup.set(key, id);
    nodes.push([Number(coord[0]), Number(coord[1])]);
    return id;
  }

  for (const feature of features) {
    const policyAccess = accessForPolicy(feature.accessClass);
    if (policyAccess === "motorized_excluded") continue;
    const coords = feature.geometry && feature.geometry.coordinates;
    if (!coords || coords.length < 2) continue;
    const a = addNode(coords[0]);
    const b = addNode(coords[coords.length - 1]);
    if (a === b) continue;

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
    lineage: options.lineage || null,
    conflation: options.conflationReport || null,
    nodes,
    edges
  };

  return graph;
}

function writeRegionalGraph(graph, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const json = JSON.stringify(graph);
  const gz = zlib.gzipSync(Buffer.from(json), { level: 9 });
  const graphPath = path.join(outDir, "graph.v1.json.gz");
  const metaPath = path.join(outDir, "graph.v1.meta.json");
  fs.writeFileSync(graphPath, gz);
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
    jsonBytes: Buffer.byteLength(json),
    gzBytes: gz.length,
    lineage: graph.lineage,
    conflation: graph.conflation
      ? {
          featureCount: graph.conflation.featureCount,
          stats: graph.conflation.stats,
          freeSpaceConnectors: graph.conflation.freeSpaceConnectors
        }
      : null
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  return { graphPath, metaPath, meta };
}

module.exports = {
  buildRegionalGraph,
  writeRegionalGraph,
  SURFACE,
  STRUCTURE,
  ACCESS,
  ACCESS_NAME,
  SURFACE_NAME,
  STRUCTURE_NAME
};
