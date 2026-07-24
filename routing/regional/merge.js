"use strict";

/**
 * Merge multiple regional graph payloads into one runtime-compatible graph.
 * Connects adjacent regions by unifying near-coincident boundary nodes
 * (no free-space connectors across unmapped land).
 */

const MATCH_METERS = 1500;
const { relabelComponents } = require("./corridor");

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

  // Recompute edge.c after cross-region node joins. Stale per-province
  // component ids collide (both packs use c=0/1) and make the router think
  // start/end share a component when the merged adjacency is still split —
  // or miss a real join (NB↔PE Confederation Bridge).
  const graph = relabelComponents({
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
  });

  return {
    graph,
    report: {
      regionIds,
      boundaryMatches,
      boundaryCandidates,
      matchLimitMeters: MATCH_METERS,
      freeSpaceConnectors: 0,
      componentCount: graph.componentCount
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
  // Confederation Bridge is a legal road link (not ferry) — NB↔PE must chain.
  nb: ["qc", "ns", "pe"],
  ns: ["nb"],
  pe: ["nb"],
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
  { lon: -63.75, lat: 46.21 }, // Confederation Bridge (Clean NB↔PE)
  { lon: -63.126, lat: 46.238 }, // Charlottetown
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
  // Downtown peninsula + core bridges only — leave Vanier / south-bank / New
  // Maryland ring approaches outside so adventure can skirt instead of Queen St.
  { minLat: 45.952, maxLat: 45.978, minLon: -66.665, maxLon: -66.618, nudgeLat: 0.18 }, // Fredericton downtown
  { minLat: 45.2, maxLat: 45.35, minLon: -66.2, maxLon: -65.95, nudgeLat: 0.18 }, // Saint John
  { minLat: 47.3, maxLat: 47.45, minLon: -68.45, maxLon: -68.2, nudgeLat: 0.2 }, // Edmundston
  { minLat: 46.75, maxLat: 46.9, minLon: -71.35, maxLon: -71.1, nudgeLat: 0.2 }, // Québec City core
  // Gatineau downtown / Hull — leave Chelsea / north ring for adventure skirts.
  { minLat: 45.42, maxLat: 45.5, minLon: -75.78, maxLon: -75.68, nudgeLat: 0.18 },
  // PE cores — surgical so adventure can skirt, not tour downtown one-ways.
  { minLat: 46.228, maxLat: 46.248, minLon: -63.145, maxLon: -63.11, nudgeLat: 0.12 }, // Charlottetown downtown
  { minLat: 46.385, maxLat: 46.405, minLon: -63.81, maxLon: -63.77, nudgeLat: 0.1 }, // Summerside core
  // Ontario cores — downtown-tight (not metro-wide) so adventure skirts 401 cores.
  { minLat: 43.62, maxLat: 43.68, minLon: -79.42, maxLon: -79.35, nudgeLat: 0.22 }, // Toronto downtown / PATH
  { minLat: 45.41, maxLat: 45.44, minLon: -75.72, maxLon: -75.68, nudgeLat: 0.16 }, // Ottawa Centretown
  // Prairie / west cores (Phase 1 OSM-only)
  { minLat: 49.88, maxLat: 49.91, minLon: -97.16, maxLon: -97.12, nudgeLat: 0.14 }, // Winnipeg downtown
  { minLat: 50.44, maxLat: 50.46, minLon: -104.63, maxLon: -104.6, nudgeLat: 0.12 }, // Regina downtown
  { minLat: 52.12, maxLat: 52.14, minLon: -106.68, maxLon: -106.65, nudgeLat: 0.12 }, // Saskatoon downtown
  { minLat: 51.03, maxLat: 51.06, minLon: -114.09, maxLon: -114.05, nudgeLat: 0.16 }, // Calgary downtown
  { minLat: 53.53, maxLat: 53.55, minLon: -113.51, maxLon: -113.48, nudgeLat: 0.16 }, // Edmonton downtown
  { minLat: 49.27, maxLat: 49.3, minLon: -123.14, maxLon: -123.1, nudgeLat: 0.14 }, // Vancouver downtown
  { minLat: 48.42, maxLat: 48.44, minLon: -123.38, maxLon: -123.35, nudgeLat: 0.12 } // Victoria downtown
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
  { lon: -63.75, lat: 46.21 }, // Confederation Bridge mid — NB↔PE fabric keeper
  { lon: -68.2, lat: 47.35 }, // NB–QC approach (north of Edmundston downtown core box)
  { lon: -70.9, lat: 46.75 }, // St. Lawrence south shore approach
  { lon: -72.5, lat: 46.2 }, // Mauricie / TR south
  { lon: -73.9, lat: 45.65 }, // north of Montreal island
  { lon: -74.58, lat: 45.61 }, // Hawkesbury — QC↔ON seam keeper
  { lon: -74.73, lat: 45.02 }, // Cornwall / 401 — QC↔ON southern approach
  { lon: -94.49, lat: 49.78 }, // Kenora — ON↔MB approach
  { lon: -101.4, lat: 49.7 }, // MB↔SK southern corridor
  { lon: -110.0, lat: 49.7 }, // SK↔AB southern corridor
  { lon: -116.4, lat: 51.2 } // AB↔BC divide approach (Golden / Lake Louise band)
];

/**
 * Province-seam joints for canada-chain hops (adventure). Not city hubs —
 * only land/bridge fabric keepers so each hop loads ≤2 packs. Dégelis sits
 * inside QC so the final Laurentians leg is QC-only (Hobby OOM avoidance:
 * a single A→B hop inflated NS+NB+QC ~463MB JSON → FUNCTION_INVOCATION_FAILED).
 * West seams keep QC|ON, ON|MB, MB|SK, SK|AB, AB|BC as ≤2-pack hops.
 */
const ADVENTURE_CHAIN_JOINTS = [
  { lon: -64.35, lat: 45.92, between: ["ns", "nb"] }, // Tantramar / isthmus
  { lon: -63.75, lat: 46.21, between: ["nb", "pe"] }, // Confederation Bridge
  { lon: -68.65, lat: 47.55, between: ["nb", "qc"] }, // Dégelis — QC entry
  { lon: -74.58, lat: 45.61, between: ["qc", "on"] }, // Hawkesbury — ON entry (not Ottawa/Toronto)
  { lon: -94.49, lat: 49.78, between: ["on", "mb"] }, // Kenora — MB entry (not Winnipeg)
  { lon: -101.4, lat: 49.7, between: ["mb", "sk"] }, // MB↔SK prairie seam
  { lon: -110.0, lat: 49.7, between: ["sk", "ab"] }, // SK↔AB prairie seam
  { lon: -116.4, lat: 51.2, between: ["ab", "bc"] } // AB↔BC divide seam
];

function dedupeCorridorPoints(pts, start, end, westToEast) {
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

/**
 * Adventure canada-chain waypoints: border seams only (no Halifax/Moncton/…).
 * Keeps NS→QC as NS|NB → NB|QC → QC instead of one multi-pack mega-hop.
 */
function adventureChainWaypoints(start, end) {
  const { primaryRegionForPoint, provinceFamily } = require("./select");
  const startFam = provinceFamily(primaryRegionForPoint(start.lon, start.lat));
  const endFam = provinceFamily(primaryRegionForPoint(end.lon, end.lat));
  if (!startFam || !endFam || startFam === endFam) return [start, end];

  const regionPath = shortestRegionPath(startFam, endFam) || [];
  if (regionPath.length < 2) return [start, end];
  const pathSet = new Set(regionPath);
  const westToEast = start.lon < end.lon;
  const minLon = Math.min(start.lon, end.lon);
  const maxLon = Math.max(start.lon, end.lon);

  const pts = [start, end];
  for (const j of ADVENTURE_CHAIN_JOINTS) {
    if (!j.between.every((r) => pathSet.has(r))) continue;
    if (j.lon < minLon - 0.35 || j.lon > maxLon + 0.35) continue;
    if (nearlySamePoint(j, start) || nearlySamePoint(j, end)) continue;
    // Do not nudgeOffUrbanCore — seams are placed on fabric keepers. Sackville /
    // Amherst avoid boxes would shove Tantramar into the strait (match_failed).
    pts.push({ lon: j.lon, lat: j.lat });
  }
  return dedupeCorridorPoints(pts, start, end, westToEast);
}

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
  return dedupeCorridorPoints(pts, start, end, westToEast);
}

function isCleanProfile(profile) {
  const p = String(profile || "").toLowerCase();
  return p === "cleanest" || p === "clean";
}

/**
 * @param {object[]} locations route pins (user stages preserved)
 * @param {{ profile?: string, forClip?: boolean, forChain?: boolean }} [options]
 *   profile — cleanest gets highway hubs; adventure never does.
 *   forClip — adventure may add chord samples to widen pack clip (not as routed hops).
 *   forChain — adventure inserts province-seam joints so canada-chain hops
 *     load ≤2 packs (avoids Hobby OOM on NS→QC mega-merge).
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

  // Adventure: no city hub chain. forChain → border seams; forClip → chord
  // samples for pack clipping; plain [A,B] otherwise (single-pack / local).
  if (!isCleanProfile(options.profile)) {
    if (options.forChain) return adventureChainWaypoints(start, end);
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
  adventureChainWaypoints,
  ADVENTURE_URBAN_AVOID,
  ADVENTURE_CHAIN_JOINTS,
  pointInAdventureUrbanCore,
  REGION_NEIGHBOURS,
  MATCH_METERS
};
