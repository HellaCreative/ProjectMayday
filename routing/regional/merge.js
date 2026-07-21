"use strict";

/**
 * Merge multiple regional graph payloads into one runtime-compatible graph.
 * Connects adjacent regions by unifying near-coincident boundary nodes
 * (no free-space connectors across unmapped land).
 */

const MATCH_METERS = 1500;

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

function cellKey(lon, lat, grid = 0.02) {
  return Math.floor(lon / grid) + ":" + Math.floor(lat / grid);
}

/**
 * @param {Array<object>} graphs raw graph JSON objects (not runtimes)
 * @returns {{ graph: object, report: object }}
 */
function mergeRegionalGraphs(graphs) {
  if (!Array.isArray(graphs) || graphs.length === 0) {
    throw new Error("mergeRegionalGraphs requires at least one graph");
  }
  if (graphs.length === 1) {
    return {
      graph: graphs[0],
      report: {
        regionIds: [graphs[0].regionId],
        boundaryMatches: 0,
        unmatchedBoundaryNodes: graphs[0].boundaryNodeCount || 0
      }
    };
  }

  const enums = graphs[0].enums;
  const nodes = [];
  const edges = [];
  const regionIds = [];
  const boundaryIndex = new Map(); // cell -> [{nodeId, lon, lat, regionId}]
  let boundaryMatches = 0;
  let boundaryCandidates = 0;

  function addOrMatchNode(coord, regionId, _isBoundary) {
    const lon = Number(coord[0]);
    const lat = Number(coord[1]);
    // Match ANY near-coincident node from another region — NRN borders are usually
    // through-roads (degree ≥ 2), not dead-end boundary stubs.
    const keys = [];
    for (let dx = -2; dx <= 2; dx += 1) {
      for (let dy = -2; dy <= 2; dy += 1) {
        keys.push(cellKey(lon + dx * 0.02, lat + dy * 0.02));
      }
    }
    let best = null;
    let bestDist = MATCH_METERS;
    for (const key of keys) {
      const bucket = boundaryIndex.get(key);
      if (!bucket) continue;
      for (const cand of bucket) {
        if (cand.regionId === regionId) continue;
        const d = haversineMeters([lon, lat], [cand.lon, cand.lat]);
        if (d < bestDist) {
          bestDist = d;
          best = cand;
        }
      }
    }
    if (best) {
      boundaryMatches += 1;
      return best.nodeId;
    }

    const id = nodes.length;
    nodes.push([lon, lat]);
    const key = cellKey(lon, lat);
    if (!boundaryIndex.has(key)) boundaryIndex.set(key, []);
    boundaryIndex.get(key).push({ nodeId: id, lon, lat, regionId });
    return id;
  }

  for (const g of graphs) {
    const regionId = g.regionId || g.province || "unknown";
    regionIds.push(regionId);
    const boundarySet = new Set(g.boundaryNodes || []);
    const remap = new Array(g.nodeCount);

    for (let i = 0; i < g.nodes.length; i += 1) {
      remap[i] = addOrMatchNode(g.nodes[i], regionId, boundarySet.has(i));
    }

    for (const e of g.edges) {
      const a = remap[e.a];
      const b = remap[e.b];
      if (a == null || b == null || a === b) continue;
      edges.push({
        ...e,
        a,
        b,
        i: e.i || `${regionId}:${edges.length}`,
        regionId
      });
    }
  }

  // Recompute simple component ids lightly (router uses adjacency more than c).
  const graph = {
    version: 1,
    schemaVersion: "canada-merged-1",
    regionId: regionIds.join("+"),
    province: regionIds.map((r) => String(r).toUpperCase()).join(","),
    generatedAt: new Date().toISOString(),
    bbox: null,
    enums,
    nodeCount: nodes.length,
    edgeCount: edges.length,
    componentCount: -1,
    boundaryNodeCount: 0,
    boundaryNodes: [],
    accessCounts: {},
    surfaceCounts: {},
    sourceCounts: {},
    lineage: { mergedRegions: regionIds },
    nodes,
    edges
  };

  return {
    graph,
    report: {
      regionIds,
      boundaryMatches,
      boundaryCandidates,
      matchLimitMeters: MATCH_METERS,
      freeSpaceConnectors: 0
    }
  };
}

/**
 * Ordered adjacency for loading corridor regions between endpoints.
 * Undirected neighbours based on shared land/ferry borders.
 */
const REGION_NEIGHBOURS = {
  // Land / contiguous borders only. Ferry-dependent links are omitted until
  // NRN ferry connection layers are ingested as routable edges.
  bc: ["ab", "yt", "nt"],
  ab: ["bc", "sk", "nt"],
  sk: ["ab", "mb", "nt"],
  mb: ["sk", "on", "nu"],
  on: ["mb", "qc"],
  qc: ["on", "nb", "nl"],
  nb: ["qc", "ns"],
  ns: ["nb"],
  pe: [],
  nl: ["qc"],
  yt: ["bc", "nt"],
  nt: ["yt", "bc", "ab", "sk", "nu"],
  nu: ["nt", "mb"]
};

function shortestRegionPath(from, to) {
  const start = String(from).toLowerCase();
  const end = String(to).toLowerCase();
  if (start === end) return [start];
  const queue = [[start]];
  const seen = new Set([start]);
  while (queue.length) {
    const path = queue.shift();
    const cur = path[path.length - 1];
    for (const nxt of REGION_NEIGHBOURS[cur] || []) {
      if (seen.has(nxt)) continue;
      const nextPath = path.concat(nxt);
      if (nxt === end) return nextPath;
      seen.add(nxt);
      queue.push(nextPath);
    }
  }
  return null;
}

function regionsForRoute(regionIds) {
  const unique = [...new Set((regionIds || []).map((r) => String(r).toLowerCase()))];
  if (unique.length <= 1) return unique;
  // Expand to include corridor between every consecutive pair in selection order,
  // and between first and last for 2-endpoint routes.
  const needed = new Set(unique);
  for (let i = 0; i < unique.length; i += 1) {
    for (let j = i + 1; j < unique.length; j += 1) {
      const path = shortestRegionPath(unique[i], unique[j]);
      if (!path) continue;
      for (const r of path) needed.add(r);
    }
  }
  return [...needed].sort();
}

/**
 * Waypoints that keep long east-west routes on the populated southern corridor
 * instead of a great-circle through remote northern bush.
 */
const CORRIDOR_ANCHORS = [
  { lon: -63.575, lat: 44.6488 }, // Halifax
  { lon: -64.800, lat: 46.099 }, // Moncton
  { lon: -66.643, lat: 45.963 }, // Fredericton
  { lon: -68.325, lat: 47.373 }, // Edmundston (NB side of QC border)
  { lon: -68.65, lat: 47.55 }, // Dégelis (QC approach)
  { lon: -69.542, lat: 47.837 }, // Rivière-du-Loup
  { lon: -71.208, lat: 46.813 }, // Quebec City
  { lon: -73.567, lat: 45.502 }, // Montreal
  { lon: -75.697, lat: 45.421 }, // Ottawa
  { lon: -79.383, lat: 43.653 }, // Toronto
  { lon: -81.0, lat: 46.49 }, // Sudbury — keeps ON highway north of Georgian Bay
  { lon: -84.35, lat: 46.52 }, // Sault Ste. Marie
  { lon: -89.247, lat: 48.38 }, // Thunder Bay
  { lon: -97.138, lat: 49.895 }, // Winnipeg
  { lon: -104.618, lat: 50.445 }, // Regina
  { lon: -106.67, lat: 52.133 }, // Saskatoon
  { lon: -113.491, lat: 53.547 }, // Edmonton
  { lon: -114.071, lat: 51.045 }, // Calgary
  { lon: -119.496, lat: 49.888 }, // Kelowna
  { lon: -123.121, lat: 49.283 } // Vancouver
];

function nearlySamePoint(a, b, eps = 0.08) {
  return Math.abs(a.lon - b.lon) < eps && Math.abs(a.lat - b.lat) < eps;
}

function haversineKm(a, b) {
  const toRad = (d) => (d * Math.PI) / 180;
  const R = 6371;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function corridorLocationsForRoute(locations) {
  const pts = (locations || [])
    .map((loc) => {
      const lon = Number(loc.lon != null ? loc.lon : loc.lng);
      const lat = Number(loc.lat);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
      return { lon, lat };
    })
    .filter(Boolean);
  if (pts.length < 2) return pts;

  const start = pts[0];
  const end = pts[pts.length - 1];
  const minLon = Math.min(...pts.map((p) => p.lon));
  const maxLon = Math.max(...pts.map((p) => p.lon));
  const span = maxLon - minLon;
  const distKm = haversineKm(start, end);

  // Inject southern corridor anchors for inter-province hauls.
  // NB→QC (Fredericton→Quebec City) is ~570 km but only ~4.6° of longitude —
  // the old 5° gate skipped anchors, forcing one merged NB+QC hop that OOMs /
  // times out on Vercel Hobby when the QC pack is inflated.
  // Gate on distance OR longitude so Atlantic cross-border city pairs split.
  if (span < 3 && distKm < 280) return pts;

  const westToEast = start.lon < end.lon;
  const anchors = CORRIDOR_ANCHORS.filter((a) => a.lon >= minLon - 0.5 && a.lon <= maxLon + 0.5)
    .filter((a) => !nearlySamePoint(a, start) && !nearlySamePoint(a, end))
    // Keep anchors that lie between the endpoints along the travel axis.
    .filter((a) =>
      westToEast ? a.lon > start.lon && a.lon < end.lon : a.lon < start.lon && a.lon > end.lon
    )
    .sort((a, b) => (westToEast ? a.lon - b.lon : b.lon - a.lon));
  return [start, ...anchors, end];
}

module.exports = {
  mergeRegionalGraphs,
  shortestRegionPath,
  regionsForRoute,
  corridorLocationsForRoute,
  REGION_NEIGHBOURS,
  MATCH_METERS
};
