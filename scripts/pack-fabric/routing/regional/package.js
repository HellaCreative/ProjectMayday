"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { surfaceForCosting, accessForPolicy } = require("../schema/enums");
const {
  gradeBucketFromFeature,
  coordKey5,
  nodeKeyGraded,
  gradesCompatible
} = require("../lib/grade-bucket");

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

/**
 * Coordinates touched by ≥2 features (endpoint or interior vertex).
 * Those vertices must become graph nodes so T-junctions connect.
 * Does not invent vertices where geometries cross without sharing a point.
 */
function computeJunctionKeys(features) {
  const touch = new Map();
  for (const feature of features) {
    const coords = feature.geometry && feature.geometry.coordinates;
    if (!coords || coords.length < 2) continue;
    const seen = new Set();
    for (const c of coords) {
      const key = coordKey5(c);
      if (seen.has(key)) continue;
      seen.add(key);
      touch.set(key, (touch.get(key) || 0) + 1);
    }
  }
  const junctions = new Set();
  for (const [key, count] of touch) {
    if (count >= 2) junctions.add(key);
  }
  return junctions;
}

function largestComponentEdgeShare(edgeComponents, edgeCount) {
  if (!edgeCount) return { largest: 0, pct: 0 };
  let maxId = 0;
  for (const c of edgeComponents) if (c > maxId) maxId = c;
  const size = new Uint32Array(maxId + 1);
  for (const c of edgeComponents) size[c] += 1;
  let largest = 0;
  for (let i = 0; i < size.length; i += 1) {
    if (size[i] > largest) largest = size[i];
  }
  return { largest, pct: (100 * largest) / edgeCount };
}

function isCapillaryFeature(feature) {
  const role = feature.meta && feature.meta.conflationRole;
  if (role === "supplement") return true;
  if (role === "backbone") return false;
  const src = String(feature.sourceName || "");
  // OSM / NRN are fabric even when tagged resource/track.
  if (/OpenStreetMap|^NRN\b|National Road/i.test(src)) return false;
  if (/Forest Roads|NSTDB|Topographic|FTEN|MNRF|Multi-Usage|Access Roads|Digital Road Atlas|\bDRA\b|FFA Resource Roads/i.test(src)) return true;
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

function bearingDeg(from, to) {
  const dLon = Number(to[0]) - Number(from[0]);
  const dLat = Number(to[1]) - Number(from[1]);
  let a = (Math.atan2(dLon, dLat) * 180) / Math.PI;
  if (a < 0) a += 360;
  return a;
}

function angleDeltaDeg(a, b) {
  let d = Math.abs(a - b) % 360;
  if (d > 180) d = 360 - d;
  return d;
}

function isStructureGrade(grade) {
  return grade === "bridge" || grade === "tunnel" || String(grade || "").startsWith("layer:");
}

/**
 * Merge graded nodes at the same XY when a ground edge and a structure edge
 * form a near-straight continuation (bridge abutment). Leave perpendicular
 * pairs split so overpasses do not invent turns.
 *
 * Rewires edge endpoints onto the surviving ground node. Does not compact the
 * node array (orphans are harmless for routing).
 */
function mergeGradeAbutments(nodes, nodeGrades, edges) {
  const byXY = new Map();
  for (let id = 0; id < nodes.length; id += 1) {
    const xy = coordKey5(nodes[id]);
    let bucket = byXY.get(xy);
    if (!bucket) {
      bucket = [];
      byXY.set(xy, bucket);
    }
    bucket.push(id);
  }

  const incident = Array.from({ length: nodes.length }, () => []);
  for (let ei = 0; ei < edges.length; ei += 1) {
    const e = edges[ei];
    incident[e.a].push(ei);
    incident[e.b].push(ei);
  }

  function outboundBearing(edge, nodeId) {
    const g = edge.g;
    if (!g || g.length < 2) return null;
    if (edge.a === nodeId) return bearingDeg(g[0], g[Math.min(1, g.length - 1)]);
    if (edge.b === nodeId) return bearingDeg(g[g.length - 1], g[Math.max(0, g.length - 2)]);
    // After prior merges the geometric end may still match this XY.
    const n = nodes[nodeId];
    const start = g[0];
    const end = g[g.length - 1];
    const d0 = Math.hypot(start[0] - n[0], start[1] - n[1]);
    const d1 = Math.hypot(end[0] - n[0], end[1] - n[1]);
    if (d0 <= d1) return bearingDeg(g[0], g[Math.min(1, g.length - 1)]);
    return bearingDeg(g[g.length - 1], g[Math.max(0, g.length - 2)]);
  }

  let merges = 0;
  const remap = Array.from({ length: nodes.length }, (_, i) => i);

  function findMap(a) {
    while (remap[a] !== a) {
      remap[a] = remap[remap[a]];
      a = remap[a];
    }
    return a;
  }

  for (const ids of byXY.values()) {
    if (ids.length < 2) continue;
    const groundIds = ids.filter((id) => !isStructureGrade(nodeGrades[id]));
    const structIds = ids.filter((id) => isStructureGrade(nodeGrades[id]));
    if (!groundIds.length || !structIds.length) continue;

    for (const sid of structIds) {
      let shouldMerge = false;
      for (const gid of groundIds) {
        for (const sei of incident[sid]) {
          const sBear = outboundBearing(edges[sei], sid);
          if (sBear == null) continue;
          for (const gei of incident[gid]) {
            const gBear = outboundBearing(edges[gei], gid);
            if (gBear == null) continue;
            // Continuation: outbound bearings nearly opposite (straight through).
            if (angleDeltaDeg(sBear, gBear) >= 140) {
              shouldMerge = true;
              break;
            }
          }
          if (shouldMerge) break;
        }
        if (shouldMerge) break;
      }
      if (!shouldMerge) continue;
      const target = findMap(groundIds[0]);
      const from = findMap(sid);
      if (from === target) continue;
      remap[from] = target;
      merges += 1;
    }
  }

  if (!merges) return 0;
  for (const e of edges) {
    e.a = findMap(e.a);
    e.b = findMap(e.b);
  }
  return merges;
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
  /** Parallel to nodes[] — grade bucket used when the node was created. */
  const nodeGrades = [];
  /** coordKey5 → set of grade buckets already present at that XY. */
  const xyBuckets = new Map();
  const edges = [];
  const accessCounts = {};
  const surfaceCounts = {};
  const sourceCounts = {};
  const snapGrid = new Map();
  let endpointSnaps = 0;
  let gradeSeparatedCoincident = 0;
  let endpointSnapRejectedGrade = 0;

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

  function noteXyBucket(coord, grade) {
    const xy = coordKey5(coord);
    let set = xyBuckets.get(xy);
    if (!set) {
      set = new Set();
      xyBuckets.set(xy, set);
    }
    for (const other of set) {
      if (other !== grade) {
        gradeSeparatedCoincident += 1;
        break;
      }
    }
    set.add(grade);
  }

  function addNodeExact(coord, gradeBucket) {
    const grade = gradeBucket || "ground";
    const key = nodeKeyGraded(coord, grade);
    let id = nodeLookup.get(key);
    if (id != null) return id;
    noteXyBucket(coord, grade);
    id = nodes.length;
    nodeLookup.set(key, id);
    nodes.push([Number(coord[0]), Number(coord[1])]);
    nodeGrades.push(grade);
    rememberSnapCell(id);
    return id;
  }

  /** Capillary only: reuse a nearby existing node (usually OSM fabric). */
  function addNodeSnapped(coord, gradeBucket) {
    const grade = gradeBucket || "ground";
    const key = nodeKeyGraded(coord, grade);
    const exact = nodeLookup.get(key);
    if (exact != null) return exact;
    if (!(snapMeters > 0)) return addNodeExact(coord, grade);

    const ll = [Number(coord[0]), Number(coord[1])];
    const cx = Math.floor(ll[0] / SNAP_CELL);
    const cy = Math.floor(ll[1] / SNAP_CELL);
    let best = null;
    let bestD = snapMeters + 1;
    let sawIncompatibleNear = false;
    for (let dx = -1; dx <= 1; dx += 1) {
      for (let dy = -1; dy <= 1; dy += 1) {
        const bucket = snapGrid.get(cx + dx + ":" + (cy + dy));
        if (!bucket) continue;
        for (const id of bucket) {
          const d = haversineMeters(ll, nodes[id]);
          if (d > snapMeters) continue;
          if (!gradesCompatible(grade, nodeGrades[id])) {
            sawIncompatibleNear = true;
            continue;
          }
          if (d < bestD) {
            bestD = d;
            best = id;
          }
        }
      }
    }
    if (best != null && bestD <= snapMeters) {
      endpointSnaps += 1;
      // Alias this graded key so later exact matches land on the same join.
      nodeLookup.set(key, best);
      return best;
    }
    if (sawIncompatibleNear) endpointSnapRejectedGrade += 1;
    return addNodeExact(coord, grade);
  }

  function addFeatureEdge(feature, snapEndpoints, junctionKeys) {
    const policyAccess = accessForPolicy(feature.accessClass);
    if (policyAccess === "motorized_excluded") return;
    const coords = feature.geometry && feature.geometry.coordinates;
    if (!coords || coords.length < 2) return;
    const grade = gradeBucketFromFeature(feature);
    const add = snapEndpoints ? addNodeSnapped : addNodeExact;

    const splitIdx = [0];
    for (let i = 1; i < coords.length - 1; i += 1) {
      if (junctionKeys.has(coordKey5(coords[i]))) splitIdx.push(i);
    }
    splitIdx.push(coords.length - 1);

    const costSurface = surfaceForCosting(feature.surfaceClass);
    const accessCode = ACCESS[policyAccess] != null ? ACCESS[policyAccess] : ACCESS.motorized_unknown;
    const surfaceCode = SURFACE[costSurface] != null ? SURFACE[costSurface] : SURFACE.unknown;
    const structureCode =
      STRUCTURE[feature.structureType] != null ? STRUCTURE[feature.structureType] : STRUCTURE.none;

    for (let s = 0; s < splitIdx.length - 1; s += 1) {
      const startIdx = splitIdx[s];
      const endIdx = splitIdx[s + 1];
      if (startIdx === endIdx) continue;
      const segCoords = coords.slice(startIdx, endIdx + 1);
      if (segCoords.length < 2) continue;

      const a = add(segCoords[0], grade);
      const b = add(segCoords[segCoords.length - 1], grade);
      if (a === b) continue;

      let segMeters = 0;
      for (let i = 1; i < segCoords.length; i += 1) {
        segMeters += haversineMeters(segCoords[i - 1], segCoords[i]);
      }

      accessCounts[policyAccess] = (accessCounts[policyAccess] || 0) + 1;
      surfaceCounts[costSurface] = (surfaceCounts[costSurface] || 0) + 1;
      sourceCounts[feature.sourceName] = (sourceCounts[feature.sourceName] || 0) + 1;

      edges.push({
        i: splitIdx.length > 2 ? `${feature.edgeId}-s${s}` : feature.edgeId,
        a,
        b,
        m: Math.max(1, Math.round(segMeters) || 1),
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
        // Phase B2 leaf fields — intermediate JSON only (not packed to .bin yet).
        surfaceLeaf: feature.surfaceLeaf != null && feature.surfaceLeaf !== "" ? feature.surfaceLeaf : null,
        roadClassLeaf: feature.roadClassLeaf || "unknown",
        tracktype: feature.tracktype != null && feature.tracktype !== "" ? feature.tracktype : null,
        smoothness: feature.smoothness != null && feature.smoothness !== "" ? feature.smoothness : null,
        layer: Number.isFinite(Number(feature.layer)) ? Number(feature.layer) : 0,
        structureLeaf:
          feature.structureLeaf != null && feature.structureLeaf !== "" ? feature.structureLeaf : null,
        accessLeaf: feature.accessLeaf != null && feature.accessLeaf !== "" ? feature.accessLeaf : null,
        atv: feature.atv != null && feature.atv !== "" ? feature.atv : null,
        atvDesignated: !!feature.atvDesignated,
        g: segCoords.map((c) => [Number(c[0]), Number(c[1])])
      });
    }
  }

  const junctionKeys = computeJunctionKeys(features);
  const fabric = [];
  const capillary = [];
  for (const feature of features) {
    if (isCapillaryFeature(feature)) capillary.push(feature);
    else fabric.push(feature);
  }
  const featuresBeforeSplit = fabric.length + capillary.length;
  for (const feature of fabric) addFeatureEdge(feature, false, junctionKeys);
  for (const feature of capillary) addFeatureEdge(feature, true, junctionKeys);

  // Abutment heal: bridge/tunnel endpoints that continue a ground road at the
  // same XY must share a node. Perpendicular crossings stay split (overpass).
  const abutmentMerges = mergeGradeAbutments(nodes, nodeGrades, edges);

  const { edgeComponents, componentCount } = computeComponents(nodes.length, edges);
  for (let i = 0; i < edges.length; i += 1) edges[i].c = edgeComponents[i];
  const largestShare = largestComponentEdgeShare(edgeComponents, edges.length);
  console.log(
    `[${regionId}] T-junction split: features=${featuresBeforeSplit} junctionKeys=${junctionKeys.size} ` +
      `edges=${edges.length} (was 1/feature before split) nodes=${nodes.length} ` +
      `components=${componentCount} largest=${largestShare.largest} (${largestShare.pct.toFixed(2)}% of edges)`
  );

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
  lineage.junctionSplit = {
    junctionKeys: junctionKeys.size,
    featuresBeforeSplit,
    edgesAfterSplit: edges.length,
    largestComponentEdges: largestShare.largest,
    largestComponentPct: Number(largestShare.pct.toFixed(2)),
    note: "Split OSM (and capillary) polylines at vertices shared by ≥2 features so T-junctions share a node. No free-space connectors."
  };
  lineage.endpointSnap = {
    meters: snapMeters,
    snappedEndpoints: endpointSnaps,
    note:
      "Provincial capillary endpoints within snap meters reuse existing fabric nodes (survey near-miss joins). No free-space edges. Grade-incompatible snaps are rejected."
  };
  lineage.gradeSeparation = {
    gradeSeparatedCoincident,
    endpointSnapRejectedGrade,
    abutmentMerges,
    note:
      "Node keys are lon,lat|gradeBucket for exact joins; capillary snap is grade-gated. Bridge/tunnel endpoints that continue a ground road at the same XY are merged (abutments). Perpendicular crossings stay split (overpasses)."
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
    largestComponentEdges: largestShare.largest,
    largestComponentPct: Number(largestShare.pct.toFixed(2)),
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
    largestComponentEdges: graph.largestComponentEdges,
    largestComponentPct: graph.largestComponentPct,
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
  gradeBucketFromFeature,
  SURFACE,
  STRUCTURE,
  ACCESS,
  ACCESS_NAME,
  SURFACE_NAME,
  STRUCTURE_NAME
};
