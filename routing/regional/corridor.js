"use strict";

/**
 * Corridor clipping + national spine helpers for multi-province routing.
 * Never invents free-space connectors — only keeps real mapped edges.
 */

function toRad(deg) {
  return (deg * Math.PI) / 180;
}

function haversineMeters(a, b) {
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function distPointToSegmentMeters(p, a, b) {
  // Equirectangular local projection around segment midpoint.
  const lat0 = toRad((a[1] + b[1]) / 2);
  const x0 = a[0] * Math.cos(lat0);
  const y0 = a[1];
  const x1 = b[0] * Math.cos(lat0);
  const y1 = b[1];
  const xp = p[0] * Math.cos(lat0);
  const yp = p[1];
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len2 = dx * dx + dy * dy;
  let t = 0;
  if (len2 > 0) t = Math.max(0, Math.min(1, ((xp - x0) * dx + (yp - y0) * dy) / len2));
  const qx = x0 + t * dx;
  const qy = y0 + t * dy;
  const degDist = Math.sqrt((xp - qx) ** 2 + (yp - qy) ** 2);
  return degDist * 111320;
}

function corridorPolyline(locations) {
  return (locations || [])
    .map((loc) => {
      const lon = Number(loc.lon != null ? loc.lon : loc.lng);
      const lat = Number(loc.lat);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
      return [lon, lat];
    })
    .filter(Boolean);
}

function pointNearCorridor(point, line, bufferMeters) {
  if (line.length < 2) return false;
  for (let i = 1; i < line.length; i += 1) {
    if (distPointToSegmentMeters(point, line[i - 1], line[i]) <= bufferMeters) return true;
  }
  // Also keep points near endpoints.
  if (haversineMeters(point, line[0]) <= bufferMeters) return true;
  if (haversineMeters(point, line[line.length - 1]) <= bufferMeters) return true;
  return false;
}

function edgeNearCorridor(edge, line, bufferMeters) {
  const g = edge.g || [];
  if (!g.length) return false;
  // Sample endpoints + midpoint for speed.
  const samples = [g[0], g[Math.floor(g.length / 2)], g[g.length - 1]];
  return samples.some((p) => pointNearCorridor(p, line, bufferMeters));
}

/**
 * Keep edges near the route corridor. Rebuilds compact node index.
 */
function clipGraphToCorridor(graph, locations, bufferMeters = 120000) {
  const line = corridorPolyline(locations);
  if (line.length < 2) return graph;

  const keepEdges = (graph.edges || []).filter((e) => edgeNearCorridor(e, line, bufferMeters));
  const used = new Set();
  for (const e of keepEdges) {
    used.add(e.a);
    used.add(e.b);
  }
  const remap = new Map();
  const nodes = [];
  for (const oldId of used) {
    remap.set(oldId, nodes.length);
    nodes.push(graph.nodes[oldId]);
  }
  const edges = keepEdges.map((e) => ({
    ...e,
    a: remap.get(e.a),
    b: remap.get(e.b)
  }));

  // Preserve boundary nodes that survived.
  const boundaryNodes = [];
  for (const oldId of graph.boundaryNodes || []) {
    if (remap.has(oldId)) boundaryNodes.push(remap.get(oldId));
  }

  return {
    ...graph,
    regionId: (graph.regionId || "region") + ":corridor",
    nodeCount: nodes.length,
    edgeCount: edges.length,
    boundaryNodes,
    boundaryNodeCount: boundaryNodes.length,
    nodes,
    edges,
    clip: {
      bufferMeters,
      inputEdgeCount: graph.edgeCount,
      outputEdgeCount: edges.length
    }
  };
}

const SPINE_ROAD_TRACK = new Set(["freeway", "arterial", "collector"]);

function nearBboxEdge(coord, bbox, padFrac = 0.04) {
  if (!bbox || !coord) return false;
  const padX = (bbox[2] - bbox[0]) * padFrac;
  const padY = (bbox[3] - bbox[1]) * padFrac;
  const [x, y] = coord;
  return (
    x <= bbox[0] + padX ||
    x >= bbox[2] - padX ||
    y <= bbox[1] + padY ||
    y >= bbox[3] - padY
  );
}

function isSpineEdge(edge, graphBbox = null) {
  if (edge.rt && SPINE_ROAD_TRACK.has(String(edge.rt))) return true;
  const surface = edge.s;
  const meters = Number(edge.m) || 0;
  const g = edge.g || [];
  // Always keep border-touching connectors so provinces can stitch.
  if (
    graphBbox &&
    g.length >= 2 &&
    (nearBboxEdge(g[0], graphBbox) || nearBboxEdge(g[g.length - 1], graphBbox))
  ) {
    return surface === 0 || surface === 1 || surface === 2 || meters >= 200;
  }
  // Packs built before rt was stored: keep longer conventional connectors.
  return (surface === 0 || surface === 1) && meters >= 800;
}

function extractHighwayGraph(graph) {
  // Keep paved/gravel inventory only — drops tracks/resource unknowns that
  // explode graph size while preserving national road connectivity.
  const keepEdges = (graph.edges || []).filter((e) => e.s === 0 || e.s === 1);
  const used = new Set();
  for (const e of keepEdges) {
    used.add(e.a);
    used.add(e.b);
  }
  const remap = new Map();
  const nodes = [];
  for (const oldId of used) {
    remap.set(oldId, nodes.length);
    nodes.push(graph.nodes[oldId]);
  }
  const edges = keepEdges.map((e) => ({
    ...e,
    a: remap.get(e.a),
    b: remap.get(e.b),
    role: e.role || "highway"
  }));
  const boundaryNodes = [];
  for (const oldId of graph.boundaryNodes || []) {
    if (remap.has(oldId)) boundaryNodes.push(remap.get(oldId));
  }
  return {
    ...graph,
    regionId: (graph.regionId || "region") + ":highway",
    nodeCount: nodes.length,
    edgeCount: edges.length,
    boundaryNodes,
    boundaryNodeCount: boundaryNodes.length,
    nodes,
    edges
  };
}

module.exports = {
  clipGraphToCorridor,
  extractHighwayGraph,
  isSpineEdge,
  corridorPolyline,
  haversineMeters
};
