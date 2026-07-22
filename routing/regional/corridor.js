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
// Include collector — AB Yellowhead (Hwy 16) and similar are often collector in NRN.
const LONGHAUL_ROAD_TRACK = new Set(["freeway", "arterial", "ramp", "collector"]);

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

/** Stricter spine for Vercel longhaul packs — named highway classes only. */
function isLonghaulSpineEdge(edge, graphBbox = null, { hasRoadClass = true } = {}) {
  const surface = edge.s;
  const meters = Number(edge.m) || 0;
  const g = edge.g || [];
  const onBorder =
    graphBbox &&
    g.length >= 2 &&
    (nearBboxEdge(g[0], graphBbox) || nearBboxEdge(g[g.length - 1], graphBbox));

  if (hasRoadClass) {
    const rt = String(edge.rt || "");
    if (LONGHAUL_ROAD_TRACK.has(rt)) return true;
    // Mixed packs (NRN + OSM): NRN often has no rt. Keep paved/gravel/unknown
    // unclassed edges so provincial spines stay connected after OSM ingest.
    if (!rt && surface !== 2 && surface !== 3) return true;
    if (onBorder && surface !== 3 && meters >= 150) return true;
    return false;
  }

  // NS/NB (and similar) packs store no road class — keep non-track longer edges.
  if (surface === 3) return false;
  if (onBorder && meters >= 100) return true;
  return (surface === 0 || surface === 1 || surface === 4 || surface === 2) && meters >= 350;
}

function extractHighwayGraph(graph) {
  // Drop track-class edges only. Keep paved/gravel/unknown/access so provinces
  // whose NRN pavement is mostly Unknown (e.g. QC) stay connected.
  const keepEdges = (graph.edges || []).filter((e) => e.s !== 3);
  return compactGraph(graph, keepEdges, "highway");
}

/**
 * National / long-haul spine: freeway/arterial/collector (+ border connectors).
 * Small enough to fetch on Vercel Hobby without OOM.
 */
function extractSpineGraph(graph) {
  const bbox = graph.bbox || null;
  const keepEdges = (graph.edges || []).filter((e) => isSpineEdge(e, bbox));
  return compactGraph(graph, keepEdges, "spine");
}

function extractLonghaulSpineGraph(graph) {
  const bbox = graph.bbox || null;
  const hasRoadClass = (graph.edges || []).some((e) => e.rt);
  const keepEdges = (graph.edges || []).filter((e) =>
    isLonghaulSpineEdge(e, bbox, { hasRoadClass })
  );
  return compactGraph(graph, keepEdges, "longhaul-spine");
}

/**
 * Maritime Vercel pack: NRN non-track + OSM freeway/arterial/collector/ramp.
 * Drops provincial forest capillaries and OSM local islands that shatter
 * nearest-node / snap connectivity between cities.
 * @deprecated Prefer extractRoadFabricLonghaulGraph({ mode: "dense" }).
 */
function extractMaritimeLonghaulGraph(graph) {
  const keepEdges = (graph.edges || []).filter((e) => {
    const src = String(e.src || "");
    if (/national road network/i.test(src)) return e.s !== 3;
    const rt = String(e.rt || "");
    return LONGHAUL_ROAD_TRACK.has(rt);
  });
  return compactGraph(graph, keepEdges, "maritime-longhaul");
}

/**
 * Atlantic Vercel pack: spine everywhere + non-track edges near hub cities.
 * Hub bulbs reconnect village meshes (e.g. Lac-Beauport) without shipping
 * the full provincial capillary graph.
 * @deprecated Prefer extractRoadFabricLonghaulGraph({ mode: "corridor" }).
 */
function extractAtlanticLonghaulGraph(graph, hubLocations = [], hubBufferMeters = 45000) {
  const bbox = graph.bbox || null;
  const hasRoadClass = (graph.edges || []).some((e) => e.rt);
  const hubs = corridorPolyline(hubLocations);
  const keepEdges = (graph.edges || []).filter((e) => {
    if (isLonghaulSpineEdge(e, bbox, { hasRoadClass })) return true;
    if (e.s === 3) return false; // drop tracks
    if (!hubs.length) return false;
    const g = e.g || [];
    if (!g.length) return false;
    const samples = [g[0], g[Math.floor(g.length / 2)], g[g.length - 1]];
    return samples.some((p) => hubs.some((h) => haversineMeters(p, h) <= hubBufferMeters));
  });
  return compactGraph(graph, keepEdges, "atlantic-longhaul");
}

const FABRIC_OSM_ROADISH = new Set([
  "freeway",
  "arterial",
  "collector",
  "local",
  "ramp",
  "service"
]);

function isOpenStreetMapSrc(src) {
  return /openstreetmap/i.test(String(src || ""));
}

function isNrnSrc(src) {
  return /national road network/i.test(String(src || ""));
}

/**
 * Live mental model for Vercel longhaul packs:
 *   Default (NB etc.): OSM + NRN road fabric; provincial capillary omitted.
 *   Quebec: OSM-only (drop NRN).
 *   Nova Scotia (locked): OSM + NSTDB provincial capillary; drop NRN.
 *
 * Modes:
 *   osm / osm-only — Quebec: drop NRN; keep all OSM motorized fabric.
 *   osm-provincial / osm+nstdb — NS: drop NRN; keep OSM + provincial (NSTDB).
 *   maritime / hub — NRN + OSM (Maritimes / legacy). Hub limits OSM bulbs.
 *   corridor / dense — all NRN non-track + OSM hub/highway.
 */
function extractRoadFabricLonghaulGraph(graph, options = {}) {
  const hubLocations = options.hubLocations || [];
  const hubBufferMeters = Number(options.hubBufferMeters) || 40000;
  const hubs = corridorPolyline(hubLocations);
  const mode = String(options.mode || "hub").toLowerCase();
  const osmOnly = mode === "osm" || mode === "osm-only";
  const osmProvincial =
    mode === "osm-provincial" ||
    mode === "osm+provincial" ||
    mode === "osm+nstdb" ||
    mode === "osm-nstdb";
  // Small provinces (maritime) can keep all NRN non-track.
  const denseNrn =
    !osmOnly && !osmProvincial && (mode === "corridor" || mode === "dense" || mode === "maritime");

  function nearHub(edge) {
    if (!hubs.length) return false;
    const g = edge.g || [];
    if (!g.length) return false;
    const samples = [g[0], g[Math.floor(g.length / 2)], g[g.length - 1]];
    return samples.some((p) => hubs.some((h) => haversineMeters(p, h) <= hubBufferMeters));
  }

  const keepEdges = [];
  for (const e of graph.edges || []) {
    const src = e.src || "";
    const osm = isOpenStreetMapSrc(src);
    const nrn = isNrnSrc(src);
    const provincial = !osm && !nrn;

    if (osmOnly) {
      if (!osm) continue;
      // Full OSM motorized fabric inside the quadrant bbox (already highway-filtered
      // at ingest). Normalize unknown access → permissive for dual-sport routing.
      keepEdges.push(e.ac === 2 ? { ...e, ac: 1 } : e);
      continue;
    }

    if (osmProvincial) {
      // NS locked fabric: OSM + NSTDB. Never keep NRN highway spine.
      if (nrn) continue;
      if (osm) {
        keepEdges.push(e.ac === 2 ? { ...e, ac: 1 } : e);
        continue;
      }
      if (provincial) keepEdges.push(e);
      continue;
    }

    if (!osm && !nrn) continue; // drop provincial capillary (default longhaul)

    if (nrn) {
      if (e.s === 3) continue;
      if (denseNrn) {
        // All NRN non-track (size controlled by province + corridor clip).
        keepEdges.push(e);
        continue;
      }
      // Hub mode: spine everywhere, locals only near hubs (QC-safe for Hobby).
      // Skip resource roads in longhaul — capillary/dirt fidelity is a later pass.
      const rt = String(e.rt || "");
      if (LONGHAUL_ROAD_TRACK.has(rt)) {
        keepEdges.push(e);
        continue;
      }
      if (rt === "resource") continue;
      if (nearHub(e)) keepEdges.push(e);
      continue;
    }

    // OSM fabric — normalize legacy unknown access to permissive.
    const edge = e.ac === 2 ? { ...e, ac: 1 } : e;
    const rt = String(e.rt || "");
    // Highways keep intercity connectivity; hubs keep basemap locals for snaps.
    if (LONGHAUL_ROAD_TRACK.has(rt) || nearHub(e)) keepEdges.push(edge);
  }

  const compacted = compactGraph(graph, keepEdges, "road-fabric-longhaul");
  return relabelComponents(compacted);
}

/**
 * Recompute edge.c from the extracted adjacency. Keeps every edge.
 * Stale component ids from the full regional pack caused false
 * disconnected_components after thinning.
 */
function relabelComponents(graph) {
  const nodeCount = (graph.nodes || []).length;
  const edges = graph.edges || [];
  if (!nodeCount || !edges.length) return graph;

  const parent = new Int32Array(nodeCount);
  for (let i = 0; i < nodeCount; i += 1) parent[i] = i;
  function find(x) {
    while (parent[x] !== x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }
  function uni(a, b) {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  }

  for (const e of edges) {
    if (e.a == null || e.b == null) continue;
    if (e.a < 0 || e.b < 0 || e.a >= nodeCount || e.b >= nodeCount) continue;
    uni(e.a, e.b);
  }

  const rootToId = new Map();
  let next = 0;
  for (const e of edges) {
    const r = find(e.a);
    if (!rootToId.has(r)) {
      rootToId.set(r, next);
      next += 1;
    }
    e.c = rootToId.get(r);
  }
  graph.componentCount = next;
  graph.meta = {
    ...(graph.meta || {}),
    componentRelabel: { components: next, edges: edges.length }
  };
  return graph;
}

/**
 * Drop edges not in the largest connected component and rewrite edge.c.
 * Prefer relabelComponents for fabric packs — LCC removes local OSM/NRN coverage.
 */
function keepLargestComponent(graph) {
  const nodeCount = (graph.nodes || []).length;
  const edges = graph.edges || [];
  if (!nodeCount || !edges.length) return graph;

  const parent = new Int32Array(nodeCount);
  for (let i = 0; i < nodeCount; i += 1) parent[i] = i;
  function find(x) {
    while (parent[x] !== x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }
  function uni(a, b) {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  }

  for (const e of edges) {
    if (e.a == null || e.b == null) continue;
    if (e.a < 0 || e.b < 0 || e.a >= nodeCount || e.b >= nodeCount) continue;
    uni(e.a, e.b);
  }

  const sizes = new Map();
  for (let i = 0; i < nodeCount; i += 1) {
    const r = find(i);
    sizes.set(r, (sizes.get(r) || 0) + 1);
  }
  let giantRoot = 0;
  let giantSize = 0;
  for (const [root, size] of sizes) {
    if (size > giantSize) {
      giantSize = size;
      giantRoot = root;
    }
  }

  const keepEdges = edges.filter((e) => find(e.a) === giantRoot && find(e.b) === giantRoot);
  const out = compactGraph(graph, keepEdges, "lcc");
  for (const e of out.edges) e.c = 0;
  out.componentCount = 1;
  out.meta = {
    ...(out.meta || {}),
    ...(graph.meta || {}),
    largestComponentTrim: {
      inputEdges: edges.length,
      outputEdges: out.edges.length,
      inputComponents: sizes.size,
      giantNodeCount: giantSize
    }
  };
  out.regionId = String(graph.regionId || "region").replace(/:lcc$/, "") + ":lcc";
  return out;
}

function compactGraph(graph, keepEdges, roleSuffix) {
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
    role: e.role || roleSuffix
  }));
  const boundaryNodes = [];
  for (const oldId of graph.boundaryNodes || []) {
    if (remap.has(oldId)) boundaryNodes.push(remap.get(oldId));
  }
  return {
    ...graph,
    regionId: (graph.regionId || "region") + ":" + roleSuffix,
    nodeCount: nodes.length,
    edgeCount: edges.length,
    boundaryNodes,
    boundaryNodeCount: boundaryNodes.length,
    nodes,
    edges
  };
}

/**
 * Keep edges that touch bbox [W,S,E,N]. Used to carve QC into quadrant packs.
 */
function clipGraphToBbox(graph, bbox) {
  if (!bbox || bbox.length < 4) return graph;
  const [w, s, e, n] = bbox;
  const keepEdges = (graph.edges || []).filter((edge) => {
    const g = edge.g || [];
    if (!g.length) return false;
    for (const p of g) {
      if (p[0] >= w && p[0] <= e && p[1] >= s && p[1] <= n) return true;
    }
    return false;
  });
  return compactGraph(graph, keepEdges, "bbox");
}

module.exports = {
  clipGraphToCorridor,
  clipGraphToBbox,
  extractHighwayGraph,
  extractSpineGraph,
  extractLonghaulSpineGraph,
  extractAtlanticLonghaulGraph,
  extractMaritimeLonghaulGraph,
  extractRoadFabricLonghaulGraph,
  keepLargestComponent,
  relabelComponents,
  isSpineEdge,
  isLonghaulSpineEdge,
  corridorPolyline,
  haversineMeters
};
