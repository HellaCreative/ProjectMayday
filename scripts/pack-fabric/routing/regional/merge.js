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
  // Land / contiguous borders plus topology-proven vehicle ferry links.
  // A ferry pair is added only when both v3 packs publish the same routable
  // OSM vertices in cross-pack-topology.v1.json.
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
  nb: ["qc", "ns", "pe", "me"],
  ns: ["nb", "pe", "nl"],
  pe: ["nb", "ns"],
  nl: ["qc", "ns"],
  yt: ["bc", "nt"],
  nt: ["yt", "bc", "ab", "sk", "nu"],
  nu: ["nt", "mb"],
  me: ["nb"]
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
    for (const nxt of neighboursOf(cur)) {
      if (seen.has(nxt)) continue;
      const nextPath = path.concat(nxt);
      if (nxt === end) return nextPath;
      seen.add(nxt);
      queue.push(nextPath);
    }
  }
  return null;
}

function bboxesTouch(a, b, pad = 0.15) {
  if (!a || !b || a.length < 4 || b.length < 4) return false;
  return !(a[2] + pad < b[0] || b[2] + pad < a[0] || a[3] + pad < b[1] || b[3] + pad < a[1]);
}

/**
 * Canada–Canada stays on the explicit land/bridge graph (rectangles lie).
 * US–US and Canada–US use bbox touch so we don't maintain 50-state adjacency.
 */
function neighboursOf(id) {
  const key = String(id || "").toLowerCase();
  const out = new Set(REGION_NEIGHBOURS[key] || []);
  const { REGION_BBOX, US_STATE_IDS } = require("./select");
  const bbox = REGION_BBOX[key];
  if (!bbox) return [...out];
  const idIsUS = US_STATE_IDS.has(key);
  for (const [other, ob] of Object.entries(REGION_BBOX)) {
    if (other === key) continue;
    const otherUS = US_STATE_IDS.has(other);
    if (!idIsUS && !otherUS) continue;
    if (bboxesTouch(bbox, ob)) out.add(other);
  }
  return [...out];
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
 * Product law: no profile may inject city hubs. Long-haul routing uses neutral
 * province seams and chord samples so pack clipping/chaining never turns an
 * urban core into an artificial A/B exemption. User-staged midpoints in
 * `locations` are kept as-is.
 */

/** Major urban cores adventure chord samples must not land inside. */
const ADVENTURE_URBAN_AVOID = [
  { minLat: 44.55, maxLat: 44.78, minLon: -63.75, maxLon: -63.4, nudgeLat: 0.4 }, // Halifax
  { minLat: 45.4, maxLat: 45.72, minLon: -73.98, maxLon: -73.4, nudgeLat: 0.28 }, // Montreal island
  { minLat: 43.55, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, nudgeLat: 0.35 }, // Toronto metro
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
  { minLat: 51.03, maxLat: 51.18, minLon: -114.28, maxLon: -113.90, nudgeLat: 0.16 }, // Calgary metro
  { minLat: 53.53, maxLat: 53.55, minLon: -113.51, maxLon: -113.48, nudgeLat: 0.16 }, // Edmonton downtown
  { minLat: 49.00, maxLat: 49.42, minLon: -123.32, maxLon: -122.70, nudgeLat: 0.20 }, // Vancouver metro
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
  { lon: -110.0, lat: 51.4 }, // SK↔AB Kindersley / Hwy 7
];

/**
 * Named pass list retired. Hops use dynamicSeamForPair (chord ∩ shared bbox).
 * Kept as an empty export so older tests/docs that import the name don't throw.
 */
const ADVENTURE_CHAIN_JOINTS = [];

function dedupeCorridorPoints(pts, start, end, westToEast, nearEps = 0.15) {
  const dedup = [];
  for (const p of pts.sort((a, b) => (westToEast ? a.lon - b.lon : b.lon - a.lon))) {
    const last = dedup[dedup.length - 1];
    if (last && nearlySamePoint(last, p, nearEps)) continue;
    dedup.push(p);
  }
  if (!nearlySamePoint(dedup[0], start, 0.02)) dedup.unshift(start);
  if (!nearlySamePoint(dedup[dedup.length - 1], end, 0.02)) dedup.push(end);
  return dedup;
}

/**
 * Adventure canada-chain waypoints: one hop per adjacent region pair.
 *
 * Long shared borders (AB–BC, SK–AB, 49th, US states): seam = where THIS
 * A→B chord crosses the two region families, then snap onto fabric.
 * Named mountain passes are not used — different pins get different crossings.
 * Plan via-pins (3+ locations) skip this and are the rider's way to force a door.
 *
 * Bottleneck land links (isthmus / bridge / short Madawaska corridor) are the
 * only legal road between those pairs — not scenic funnels.
 */
const BOTTLENECK_LINKS = [
  { between: ["ns", "nb"], lon: -64.35, lat: 45.92 },
  { between: ["nb", "pe"], lon: -63.75, lat: 46.21 },
  { between: ["nb", "qc"], lon: -68.65, lat: 47.55 }
];

function distToChordKm(p, start, end) {
  let best = Infinity;
  for (let i = 0; i <= 24; i += 1) {
    const d = haversineKm(p, lerpPoint(start, end, i / 24));
    if (d < best) best = d;
  }
  return best;
}

function pairKey(left, right) {
  return [String(left).toLowerCase(), String(right).toLowerCase()].sort().join("|");
}

function bottleneckDoor(left, right) {
  const key = pairKey(left, right);
  return BOTTLENECK_LINKS.find((d) => pairKey(d.between[0], d.between[1]) === key) || null;
}

function familyAt(lon, lat) {
  const { primaryRegionForPoint, provinceFamily } = require("./select");
  const id = primaryRegionForPoint(lon, lat);
  return id ? provinceFamily(id) : null;
}

function familyForLocation(location) {
  const { primaryRegionForPoint, provinceFamily } = require("./select");
  const hinted = String(
    location && (location.resolvedRegionId || location.regionIdHint) || ""
  ).toLowerCase();
  if (hinted) return provinceFamily(hinted);
  return provinceFamily(primaryRegionForPoint(location.lon, location.lat));
}

function refineCrossing(a, b) {
  let lo = a;
  let hi = b;
  for (let k = 0; k < 14; k += 1) {
    const mid = lerpPoint(lo, hi, 0.5);
    const fam = familyAt(mid.lon, mid.lat);
    const loFam = familyAt(lo.lon, lo.lat);
    if (fam === loFam) lo = mid;
    else hi = mid;
  }
  return lerpPoint(lo, hi, 0.5);
}

function sharedBboxBand(left, right) {
  const { REGION_BBOX } = require("./select");
  const a = REGION_BBOX[left];
  const b = REGION_BBOX[right];
  if (!a || !b) return null;
  const w = Math.max(a[0], b[0]);
  const s = Math.max(a[1], b[1]);
  const e = Math.min(a[2], b[2]);
  const n = Math.min(a[3], b[3]);
  if (w < e && s < n) return [w, s, e, n];
  const gapW = Math.min(a[2], b[2]);
  const gapE = Math.max(a[0], b[0]);
  const gapS = Math.min(a[3], b[3]);
  const gapN = Math.max(a[1], b[1]);
  if (gapW <= gapE) {
    const lon = (gapW + gapE) / 2;
    const south = Math.max(a[1], b[1]);
    const north = Math.min(a[3], b[3]);
    if (south < north) return [lon - 0.05, south, lon + 0.05, north];
  }
  if (gapS <= gapN) {
    const lat = (gapS + gapN) / 2;
    const west = Math.max(a[0], b[0]);
    const east = Math.min(a[2], b[2]);
    if (west < east) return [west, lat - 0.05, east, lat + 0.05];
  }
  return null;
}

function pointInBand(lon, lat, band) {
  return lon >= band[0] && lon <= band[2] && lat >= band[1] && lat <= band[3];
}

function closestInBandToChord(band, start, end) {
  let best = null;
  let bestKm = Infinity;
  const lonSteps = 12;
  const latSteps = 12;
  for (let i = 0; i <= lonSteps; i += 1) {
    const lon = band[0] + ((band[2] - band[0]) * i) / lonSteps;
    for (let j = 0; j <= latSteps; j += 1) {
      const lat = band[1] + ((band[3] - band[1]) * j) / latSteps;
      const p = { lon, lat };
      const km = distToChordKm(p, start, end);
      if (km < bestKm) {
        bestKm = km;
        best = p;
      }
    }
  }
  return best;
}

function bboxClipSeam(left, right, start, end) {
  const band = sharedBboxBand(left, right);
  if (!band) return null;
  const inside = [];
  for (let i = 0; i <= 40; i += 1) {
    const p = lerpPoint(start, end, i / 40);
    if (pointInBand(p.lon, p.lat, band)) inside.push(p);
  }
  let seed;
  if (inside.length >= 2) {
    seed = lerpPoint(inside[0], inside[inside.length - 1], 0.5);
  } else if (inside.length === 1) {
    seed = inside[0];
  } else {
    seed = closestInBandToChord(band, start, end);
  }
  return seed;
}

function dynamicSeamForPair(left, right, start, end) {
  const a = String(left).toLowerCase();
  const b = String(right).toLowerCase();
  const door = bottleneckDoor(a, b);
  if (door) {
    return {
      lon: door.lon,
      lat: door.lat,
      role: "seam",
      between: [a, b].sort()
    };
  }

  const samples = 48;
  let prevPt = start;
  let prevFam = familyAt(start.lon, start.lat);
  for (let i = 1; i <= samples; i += 1) {
    const p = lerpPoint(start, end, i / samples);
    const fam = familyAt(p.lon, p.lat);
    if (
      prevFam &&
      fam &&
      prevFam !== fam &&
      ((prevFam === a && fam === b) || (prevFam === b && fam === a))
    ) {
      const seed = refineCrossing(prevPt, p);
      if (seed && !nearlySamePoint(seed, start, 0.000001) && !nearlySamePoint(seed, end, 0.000001)) {
        return { lon: seed.lon, lat: seed.lat, role: "seam", between: [a, b].sort() };
      }
    }
    if (fam) {
      prevFam = fam;
      prevPt = p;
    }
  }

  const seed = bboxClipSeam(a, b, start, end);
  if (!seed) return null;
  if (nearlySamePoint(seed, start, 0.000001) || nearlySamePoint(seed, end, 0.000001)) return null;
  return { lon: seed.lon, lat: seed.lat, role: "seam", between: [a, b].sort() };
}

function adventureChainWaypoints(start, end) {
  const startFam = familyForLocation(start);
  const endFam = familyForLocation(end);
  if (!startFam || !endFam || startFam === endFam) return [start, end];

  const regionPath = shortestRegionPath(startFam, endFam) || [];
  if (regionPath.length < 2) return [start, end];
  const pts = [start];
  for (let i = 0; i < regionPath.length - 1; i += 1) {
    const seam = dynamicSeamForPair(regionPath[i], regionPath[i + 1], start, end);
    if (!seam) continue;
    pts.push(seam);
  }
  pts.push(end);
  return pts.filter((point, index) =>
    index === 0 || !nearlySamePoint(point, pts[index - 1], 0.000001)
  );
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

/**
 * @param {object[]} locations route pins (user stages preserved)
 * @param {{ profile?: string, forClip?: boolean, forChain?: boolean }} [options]
 *   profile — affects each routed hop, never the engineered seam geometry.
 *   forClip — may add chord samples to widen pack clip (not as routed hops).
 *   forChain — inserts province-seam joints so canada-chain hops
 *     load ≤2 packs (avoids Hobby OOM on NS→QC mega-merge).
 */
function corridorLocationsForRoute(locations, options = {}) {
  const pts = (locations || [])
    .map((loc) => {
      const lon = Number(loc.lon != null ? loc.lon : loc.lng);
      const lat = Number(loc.lat);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
      return {
        lon,
        lat,
        resolvedRegionId: loc.resolvedRegionId || loc.regionIdHint || null
      };
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

  const families = new Set(
    [start, end]
      .map(familyForLocation)
      .filter(Boolean)
  );
  if (families.size === 1 && families.has("qc")) return pts;
  // Short same-region rides skip engineered hops. Cross-region always chains
  // (Vancouver→Seattle is ~190 km but still needs the 49th).
  if (families.size <= 1 && span < 3 && distKm < 200) return pts;

  // No profile receives city waypoints. The profile objective is evaluated by
  // the router inside each neutral geographic hop.
  if (options.forChain) return adventureChainWaypoints(start, end);
  return adventureCorridorPoints(start, end, distKm, !!options.forClip);
}

module.exports = {
  mergeRegionalGraphs,
  shortestRegionPath,
  regionsForRoute,
  corridorLocationsForRoute,
  adventureChainWaypoints,
  ADVENTURE_URBAN_AVOID,
  ADVENTURE_CHAIN_JOINTS,
  dynamicSeamForPair,
  neighboursOf,
  pointInAdventureUrbanCore,
  REGION_NEIGHBOURS,
  MATCH_METERS
};
