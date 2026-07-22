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
  // One QC province pack (OSM-only). Legacy qc-* neighbours kept so emergency
  // quadrant packs still path-find if re-enabled in select.js.
  qc: ["on", "nb", "nl"],
  "qc-west": ["on", "qc", "qc-sl", "qc-north"],
  "qc-sl": ["nb", "nl", "qc", "qc-west", "qc-north"],
  "qc-north": ["qc", "qc-sl", "qc-west"],
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
 * Corridor waypoints for canada-chain hops and pack clipping.
 *
 * Product law:
 * - **cleanest** — highway city/spine hubs OK (Google-fast A→B).
 * - **direct / balanced / dirt** — NEVER inject city hubs (Halifax, Moncton,
 *   Fredericton, Edmundston, Québec, Montreal, …). Sample the A→B chord so
 *   packs clip/chain without forcing urban sightseeing beelines. User-staged
 *   midpoints in `locations` are kept as-is.
 */
const CLEAN_CORRIDOR_ANCHORS = [
  { lon: -64.800, lat: 46.099 }, // Moncton — TCH isthmus (Clean only)
  { lon: -66.643, lat: 45.963 }, // Fredericton
  { lon: -68.325, lat: 47.373 }, // Edmundston
  { lon: -68.65, lat: 47.55 }, // Dégelis
  { lon: -69.542, lat: 47.837 }, // Rivière-du-Loup
  { lon: -71.208, lat: 46.813 }, // Quebec City
  { lon: -72.349, lat: 46.353 }, // A-40 east of Trois-Rivières
  { lon: -72.701, lat: 46.300 }, // west of Trois-Rivières
  { lon: -73.80, lat: 45.60 }, // Laval north ring (not island core)
  { lon: -75.697, lat: 45.421 }, // Ottawa
  { lon: -79.383, lat: 43.653 }, // Toronto
  { lon: -81.0, lat: 46.49 }, // Sudbury
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

/** Major urban cores adventure chord samples must not land inside. */
const ADVENTURE_URBAN_AVOID = [
  { minLat: 44.55, maxLat: 44.78, minLon: -63.75, maxLon: -63.4, nudgeLat: 0.4 }, // Halifax
  { minLat: 45.4, maxLat: 45.72, minLon: -73.98, maxLon: -73.4, nudgeLat: 0.28 }, // Montreal island
  { minLat: 43.55, maxLat: 43.85, minLon: -79.55, maxLon: -79.15, nudgeLat: 0.35 }, // Toronto
  { minLat: 45.85, maxLat: 46.2, minLon: -64.95, maxLon: -64.55, nudgeLat: 0.2 }, // Moncton / Dieppe
  { minLat: 45.88, maxLat: 46.1, minLon: -64.45, maxLon: -64.28, nudgeLat: 0.15 }, // Sackville NS
  { minLat: 45.78, maxLat: 45.9, minLon: -64.28, maxLon: -64.12, nudgeLat: 0.12 }, // Amherst
  { minLat: 45.88, maxLat: 46.05, minLon: -66.75, maxLon: -66.5, nudgeLat: 0.2 }, // Fredericton
  { minLat: 45.2, maxLat: 45.35, minLon: -66.2, maxLon: -65.95, nudgeLat: 0.18 }, // Saint John
  { minLat: 47.3, maxLat: 47.45, minLon: -68.45, maxLon: -68.2, nudgeLat: 0.2 }, // Edmundston
  { minLat: 46.75, maxLat: 46.9, minLon: -71.35, maxLon: -71.1, nudgeLat: 0.2 } // Québec City core
];

function pointInAdventureUrbanCore(lon, lat) {
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return false;
  for (const box of ADVENTURE_URBAN_AVOID) {
    if (lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon) {
      return true;
    }
  }
  return false;
}

const ADVENTURE_HOP_KM = 320;

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

function lerpPoint(a, b, t) {
  return {
    lon: a.lon + (b.lon - a.lon) * t,
    lat: a.lat + (b.lat - a.lat) * t
  };
}

function nudgeOffUrbanCore(p) {
  let lat = p.lat;
  let lon = p.lon;
  for (const box of ADVENTURE_URBAN_AVOID) {
    if (lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon) {
      lat = box.maxLat + box.nudgeLat;
    }
  }
  return { lon, lat };
}

/**
 * Adventure long-haul: do not force city visits as routed hops.
 * Clip guides may include border/isthmus fabric keepers so NS↔NB↔QC stays
 * connected after corridor clip (Edmundston-area fabric is ~47.3°N while the
 * NG→Mirabel chord sits ~45.6°N — chord-only clip deleted the only NB–QC join).
 */
const ADVENTURE_CONNECTIVITY_CLIP = [
  { lon: -64.35, lat: 45.92 }, // Tantramar / isthmus — not Halifax metro
  { lon: -68.2, lat: 47.35 }, // NB–QC approach (north of Edmundston downtown core box)
  { lon: -70.9, lat: 46.75 }, // St. Lawrence south shore approach
  { lon: -72.5, lat: 46.2 }, // Mauricie / TR south
  { lon: -73.9, lat: 45.65 } // north of Montreal island
];

function adventureCorridorPoints(start, end, distKm, forClip) {
  if (!forClip) return [start, end];
  const westToEast = start.lon < end.lon;
  const minLon = Math.min(start.lon, end.lon);
  const maxLon = Math.max(start.lon, end.lon);
  const pts = [start, end];
  if (distKm >= ADVENTURE_HOP_KM * 1.15) {
    const hops = Math.max(1, Math.round(distKm / ADVENTURE_HOP_KM));
    for (let i = 1; i < hops; i += 1) {
      pts.push(nudgeOffUrbanCore(lerpPoint(start, end, i / hops)));
    }
  }
  for (const p of ADVENTURE_CONNECTIVITY_CLIP) {
    if (p.lon >= minLon - 0.4 && p.lon <= maxLon + 0.4) {
      pts.push(nudgeOffUrbanCore(p));
    }
  }
  const dedup = [];
  for (const p of pts.sort((a, b) => (westToEast ? a.lon - b.lon : b.lon - a.lon))) {
    const last = dedup[dedup.length - 1];
    if (last && nearlySamePoint(last, p, 0.15)) continue;
    dedup.push(p);
  }
  if (!nearlySamePoint(dedup[0], start, 0.02)) dedup.unshift(start);
  if (!nearlySamePoint(dedup[dedup.length - 1], end, 0.02)) dedup.push(end);
  return dedup;
}

function isCleanProfile(profile) {
  const p = String(profile || "").toLowerCase();
  return p === "cleanest" || p === "clean";
}

/**
 * @param {object[]} locations route pins (user stages preserved)
 * @param {{ profile?: string, forClip?: boolean }} [options]
 *   profile — cleanest gets highway hubs; adventure never does.
 *   forClip — adventure may add chord samples to widen pack clip (not as routed hops).
 */
function corridorLocationsForRoute(locations, options = {}) {
  const pts = (locations || [])
    .map((loc) => {
      const lon = Number(loc.lon != null ? loc.lon : loc.lng);
      const lat = Number(loc.lat);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
      return { lon, lat };
    })
    .filter(Boolean);
  if (pts.length < 2) return pts;

  // Explicit user stages (3+ pins): never replace with engineered hubs.
  if (pts.length >= 3) return pts;

  const start = pts[0];
  const end = pts[pts.length - 1];
  const minLon = Math.min(start.lon, end.lon);
  const maxLon = Math.max(start.lon, end.lon);
  const span = maxLon - minLon;
  const distKm = haversineKm(start, end);

  const { primaryRegionForPoint, provinceFamily } = require("./select");
  const families = new Set(
    [start, end]
      .map((p) => primaryRegionForPoint(p.lon, p.lat))
      .filter(Boolean)
      .map(provinceFamily)
  );
  if (families.size === 1 && families.has("qc")) return pts;
  if (span < 3 && distKm < 200) return pts;

  // Adventure: no city hub chain. Routed hops stay [A, B]; clip may sample chord.
  if (!isCleanProfile(options.profile)) {
    return adventureCorridorPoints(start, end, distKm, !!options.forClip);
  }

  // Cleanest: highway spine hubs for fast Google-shaped longhaul.
  const westToEast = start.lon < end.lon;
  const anchors = CLEAN_CORRIDOR_ANCHORS.filter((a) => a.lon >= minLon - 0.5 && a.lon <= maxLon + 0.5)
    .filter((a) => !nearlySamePoint(a, start) && !nearlySamePoint(a, end))
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
  ADVENTURE_URBAN_AVOID,
  pointInAdventureUrbanCore,
  REGION_NEIGHBOURS,
  MATCH_METERS
};
