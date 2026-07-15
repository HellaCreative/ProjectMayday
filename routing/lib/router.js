"use strict";

const { loadGraph } = require("./graph");

const DEFAULT_MATCH_METERS = 250;
const EARTH_M = 6371000;

function haversineMeters(a, b) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_M * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function projectOnSegment(point, a, b) {
  const [px, py] = point;
  const [ax, ay] = a;
  const [bx, by] = b;
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  let t = 0;
  if (len2 > 0) t = ((px - ax) * dx + (py - ay) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  const coord = [ax + dx * t, ay + dy * t];
  return { coord, t, distanceM: haversineMeters(point, coord) };
}

function accessAllowed(accessCode, policy, enums) {
  const name = enums.ACCESS_NAME[accessCode];
  if (name === "motorized_restricted" || name === "motorized_excluded") return false;
  if (name === "motorized_unknown") return !!policy.motorizedUnknown;
  if (name === "motorized_verified") return true;
  if (name === "motorized_permissive") return policy.motorizedPermissive !== false;
  return false;
}

function surfaceMultiplier(surfaceCode, profile, enums) {
  const name = enums.SURFACE_NAME[surfaceCode] || "unknown";
  const tables = {
    direct: { paved: 1, gravel: 1, access: 1, track: 1, unknown: 1.02 },
    balanced: { paved: 1.85, gravel: 0.9, access: 0.82, track: 0.75, unknown: 0.95 },
    dirt: { paved: 6.5, gravel: 0.72, access: 0.58, track: 0.48, unknown: 0.7 },
    cleanest: { paved: 0.85, gravel: 1.55, access: 1.8, track: 2.4, unknown: 1.9 }
  };
  const table = tables[profile] || tables.balanced;
  return table[name] != null ? table[name] : 1;
}

function classSpeedKmh(surfaceCode, enums) {
  const name = enums.SURFACE_NAME[surfaceCode] || "unknown";
  const speeds = { paved: 70, gravel: 45, access: 35, track: 25, unknown: 30 };
  return speeds[name] || 30;
}

class MinHeap {
  constructor() { this.items = []; }
  push(item) {
    this.items.push(item);
    this.bubbleUp(this.items.length - 1);
  }
  pop() {
    if (!this.items.length) return null;
    const top = this.items[0];
    const end = this.items.pop();
    if (this.items.length) {
      this.items[0] = end;
      this.sinkDown(0);
    }
    return top;
  }
  bubbleUp(i) {
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.items[p].cost <= this.items[i].cost) break;
      [this.items[p], this.items[i]] = [this.items[i], this.items[p]];
      i = p;
    }
  }
  sinkDown(i) {
    for (;;) {
      let smallest = i;
      const l = i * 2 + 1;
      const r = l + 1;
      if (l < this.items.length && this.items[l].cost < this.items[smallest].cost) smallest = l;
      if (r < this.items.length && this.items[r].cost < this.items[smallest].cost) smallest = r;
      if (smallest === i) break;
      [this.items[smallest], this.items[i]] = [this.items[i], this.items[smallest]];
      i = smallest;
    }
  }
}

function edgeCandidateIndexes(runtime, lng, lat, radiusMeters) {
  const { edgeGrid, GRID } = runtime;
  const pad = Math.ceil((radiusMeters / 111320) / GRID) + 1;
  const cx = Math.floor(lng / GRID);
  const cy = Math.floor(lat / GRID);
  const seen = new Set();
  const out = [];
  for (let x = cx - pad; x <= cx + pad; x += 1) {
    for (let y = cy - pad; y <= cy + pad; y += 1) {
      const bucket = edgeGrid.get(x + ":" + y);
      if (!bucket) continue;
      for (const idx of bucket) {
        if (seen.has(idx)) continue;
        seen.add(idx);
        out.push(idx);
      }
    }
  }
  return out;
}

function matchPoint(runtime, location, policy, matchMeters) {
  const enums = runtime.enums;
  const point = [Number(location.lon ?? location.lng), Number(location.lat)];
  if (!Number.isFinite(point[0]) || !Number.isFinite(point[1])) {
    return { ok: false, reason: "invalid_location" };
  }
  const candidates = edgeCandidateIndexes(runtime, point[0], point[1], matchMeters);
  let best = null;
  for (const index of candidates) {
    const edge = runtime.data.edges[index];
    if (!accessAllowed(edge.ac, policy, enums)) continue;
    const coords = edge.g;
    let along = 0;
    for (let i = 1; i < coords.length; i += 1) {
      const a = coords[i - 1];
      const b = coords[i];
      const segM = haversineMeters(a, b);
      const projected = projectOnSegment(point, a, b);
      if (!best || projected.distanceM < best.distanceM) {
        best = {
          ok: true,
          edgeIndex: index,
          edgeId: edge.i,
          accessClass: enums.ACCESS_NAME[edge.ac],
          surfaceClass: enums.SURFACE_NAME[edge.s],
          structureType: enums.STRUCTURE_NAME[edge.t],
          componentId: edge.c,
          distanceM: projected.distanceM,
          coord: projected.coord,
          segmentIndex: i - 1,
          distanceAlongM: along + segM * projected.t,
          edgeMeters: edge.m
        };
      }
      along += segM;
    }
  }
  if (!best || best.distanceM > matchMeters) {
    return {
      ok: false,
      reason: "no_eligible_edge_within_match_limit",
      matchLimitMeters: matchMeters,
      nearestMeters: best ? Math.round(best.distanceM) : null
    };
  }
  return best;
}

function coordsFromAToMatch(edge, match) {
  const coords = edge.g;
  const out = [];
  for (let i = 0; i <= match.segmentIndex; i += 1) out.push(coords[i]);
  const last = out[out.length - 1];
  if (!last || last[0] !== match.coord[0] || last[1] !== match.coord[1]) out.push(match.coord);
  return dedupe(out);
}

function coordsFromMatchToB(edge, match) {
  const coords = edge.g;
  const out = [match.coord];
  for (let i = match.segmentIndex + 1; i < coords.length; i += 1) out.push(coords[i]);
  return dedupe(out);
}

function coordsBetweenMatches(edge, startMatch, endMatch) {
  if (startMatch.distanceAlongM <= endMatch.distanceAlongM) {
    const forward = [];
    const coords = edge.g;
    forward.push(startMatch.coord);
    for (let i = startMatch.segmentIndex + 1; i <= endMatch.segmentIndex; i += 1) {
      forward.push(coords[i]);
    }
    forward.push(endMatch.coord);
    return dedupe(forward);
  }
  return coordsBetweenMatches(edge, endMatch, startMatch).reverse();
}

function dedupe(coords) {
  const out = [];
  for (const c of coords) {
    const last = out[out.length - 1];
    if (last && last[0] === c[0] && last[1] === c[1]) continue;
    out.push(c);
  }
  return out;
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) total += haversineMeters(coords[i - 1], coords[i]);
  return total;
}

function buildManeuvers(geometry) {
  if (!geometry || geometry.length < 3) {
    return [{
      type: "arrive",
      instruction: "Arrive at destination",
      distanceMeters: 0,
      alongMeters: lineMeters(geometry || [])
    }];
  }
  // Lightweight geometric cues; Phase 2E can replace with richer roadbook.
  const maneuvers = [];
  let along = 0;
  let lastEmit = -Infinity;
  for (let i = 1; i < geometry.length - 1; i += 1) {
    const a = geometry[i - 1];
    const b = geometry[i];
    const c = geometry[i + 1];
    along += haversineMeters(a, b);
    const bearingIn = Math.atan2(b[0] - a[0], b[1] - a[1]);
    const bearingOut = Math.atan2(c[0] - b[0], c[1] - b[1]);
    let delta = ((bearingOut - bearingIn) * 180) / Math.PI;
    while (delta > 180) delta -= 360;
    while (delta < -180) delta += 360;
    const abs = Math.abs(delta);
    if (abs < 35) continue;
    if (along - lastEmit < 90) continue;
    const side = delta > 0 ? "right" : "left";
    let number = 2;
    if (abs >= 50) number = 3;
    if (abs >= 70) number = 4;
    if (abs >= 100) number = 5;
    if (abs >= 135) number = 6;
    maneuvers.push({
      type: "bend",
      instruction: number + " " + side.toUpperCase(),
      side,
      number,
      degrees: Math.round(abs),
      alongMeters: Math.round(along),
      distanceMeters: 0
    });
    lastEmit = along;
  }
  maneuvers.push({
    type: "arrive",
    instruction: "Arrive at destination",
    distanceMeters: 0,
    alongMeters: Math.round(lineMeters(geometry))
  });
  return maneuvers;
}

function normalizePolicy(input) {
  const policy = input || {};
  return {
    motorizedPermissive: policy.motorizedPermissive !== false,
    motorizedUnknown: !!policy.motorizedUnknown
  };
}

function routeRequest(body = {}) {
  const runtime = loadGraph();
  const enums = runtime.enums;
  const profile = String(body.profile || "balanced").toLowerCase();
  if (!["direct", "balanced", "dirt", "cleanest"].includes(profile)) {
    return {
      status: "error",
      error: "invalid_profile",
      message: "profile must be direct|balanced|dirt|cleanest"
    };
  }

  const locations = body.locations || [];
  if (!Array.isArray(locations) || locations.length < 2) {
    return {
      status: "error",
      error: "invalid_locations",
      message: "Provide at least two locations"
    };
  }

  const policy = normalizePolicy(body.accessPolicy);
  const options = body.options || {};
  const matchMeters = Number(options.matchLimitMeters);
  // Default 250 m. Explicit overrides allowed only within a small hard cap —
  // never the old zoom-dependent 2–6 km browser snap.
  const HARD_MATCH_CAP_M = 500;
  if (Number.isFinite(matchMeters) && matchMeters > HARD_MATCH_CAP_M) {
    return {
      status: "error",
      error: "match_limit_too_large",
      message: "matchLimitMeters may not exceed " + HARD_MATCH_CAP_M
    };
  }
  const limit = Number.isFinite(matchMeters) && matchMeters > 0
    ? matchMeters
    : DEFAULT_MATCH_METERS;

  const start = locations[0];
  const end = locations[locations.length - 1];
  const startMatch = matchPoint(runtime, start, policy, limit);
  const endMatch = matchPoint(runtime, end, policy, limit);

  if (!startMatch.ok || !endMatch.ok) {
    return {
      status: "failed",
      profile,
      accessPolicy: policy,
      error: "match_failed",
      message: !startMatch.ok
        ? "No eligible edge within " + limit + " m of start"
        : "No eligible edge within " + limit + " m of destination",
      warnings: [{
        code: "match_failed",
        message: "Could not snap to an eligible graph edge. No free-space connector was created."
      }],
      debug: {
        startMatch,
        endMatch,
        matchLimitMeters: limit,
        fallback: null,
        graph: {
          edgeCount: runtime.data.edgeCount,
          nodeCount: runtime.data.nodeCount,
          loadMs: runtime.loadMs
        }
      },
      maneuvers: [],
      segments: [],
      geometry: [],
      distanceMeters: 0
    };
  }

  if (
    startMatch.componentId != null &&
    endMatch.componentId != null &&
    startMatch.componentId >= 0 &&
    endMatch.componentId >= 0 &&
    startMatch.componentId !== endMatch.componentId
  ) {
    return {
      status: "failed",
      profile,
      accessPolicy: policy,
      error: "disconnected_components",
      message: "Start and destination are on disconnected networks",
      warnings: [{
        code: "disconnected_components",
        message: "A and B are on different connected components. No free-space join was invented."
      }],
      debug: {
        startMatch,
        endMatch,
        matchLimitMeters: limit,
        componentId: null,
        fallback: null
      },
      maneuvers: [],
      segments: [],
      geometry: [],
      distanceMeters: 0
    };
  }

  const path = findPath(runtime, startMatch, endMatch, profile, policy);
  if (!path) {
    return {
      status: "failed",
      profile,
      accessPolicy: policy,
      error: "no_route",
      message: "No route on the eligible graph",
      warnings: [{
        code: "no_route",
        message: "Eligible edges do not connect start to destination under the current access policy."
      }],
      debug: {
        startMatchedEdge: startMatch.edgeId,
        endMatchedEdge: endMatch.edgeId,
        startAccessMeters: Math.round(startMatch.distanceM),
        endAccessMeters: Math.round(endMatch.distanceM),
        startAccessClass: startMatch.accessClass,
        endAccessClass: endMatch.accessClass,
        componentId: startMatch.componentId,
        matchLimitMeters: limit,
        fallback: null
      },
      maneuvers: [],
      segments: [],
      geometry: [],
      distanceMeters: 0
    };
  }

  const warnings = [];
  if (policy.motorizedUnknown) {
    warnings.push({
      code: "unknown_access_enabled",
      message: "Unknown access is not permission and may include closures, private land, seasonal restrictions, or enforcement."
    });
  }
  if (path.unknownAccessMeters > 0) {
    warnings.push({
      code: "unknown_access_used",
      message: Math.round(path.unknownAccessMeters) + " m (" + path.stats.unknownAccessPercent + "%) uses motorized_unknown edges."
    });
  }
  if (path.stats.pavedPercent > 0 && profile === "dirt") {
    warnings.push({
      code: "unavoidable_pavement",
      message: path.stats.pavedPercent + "% of this dirt-preference route is paved connector distance."
    });
  }
  if (startMatch.distanceM > 1 || endMatch.distanceM > 1) {
    warnings.push({
      code: "access_legs",
      message: "Start/end were snapped onto the graph. Access distances are reported separately and are not free-space connectors through unmapped land."
    });
  }

  return {
    status: "complete",
    routeId: "route-" + Date.now().toString(36),
    profile,
    vehicle: body.vehicle || "dual-sport-motorcycle",
    accessPolicy: policy,
    geometry: path.geometry,
    distanceMeters: Math.round(path.distanceMeters),
    estimatedMovingSeconds: Math.round(path.movingSeconds),
    estimatedElapsedSeconds: Math.round(path.movingSeconds * 1.15),
    stats: path.stats,
    segments: path.segments,
    maneuvers: buildManeuvers(path.geometry),
    warnings,
    debug: {
      startMatchedEdge: startMatch.edgeId,
      endMatchedEdge: endMatch.edgeId,
      startAccessMeters: Math.round(startMatch.distanceM),
      endAccessMeters: Math.round(endMatch.distanceM),
      startAccessClass: startMatch.accessClass,
      endAccessClass: endMatch.accessClass,
      componentId: startMatch.componentId,
      matchLimitMeters: limit,
      engine: "dirt-node-astar",
      fallback: null,
      graph: {
        edgeCount: runtime.data.edgeCount,
        nodeCount: runtime.data.nodeCount,
        loadMs: runtime.loadMs
      }
    }
  };
}

function findPath(runtime, startMatch, endMatch, profile, policy) {
  const { data, adjacency, enums } = runtime;
  const edges = data.edges;

  // Virtual nodes: start = n, end = n+1
  const n = data.nodeCount;
  const startNode = n;
  const endNode = n + 1;
  const total = n + 2;

  const virtualAdj = new Map();
  function addVirt(a, b, meta) {
    if (!virtualAdj.has(a)) virtualAdj.set(a, []);
    if (!virtualAdj.has(b)) virtualAdj.set(b, []);
    virtualAdj.get(a).push({ to: b, edge: meta });
    virtualAdj.get(b).push({
      to: a,
      edge: {
        ...meta,
        a: b,
        b: a,
        coords: [...meta.coords].reverse()
      }
    });
  }

  function attach(node, match) {
    const edge = edges[match.edgeIndex];
    const toA = coordsFromAToMatch(edge, match);
    const toB = coordsFromMatchToB(edge, match);
    const mA = lineMeters(toA);
    const mB = lineMeters(toB);
    addVirt(node, edge.a, {
      a: node,
      b: edge.a,
      coords: [...toA].reverse(),
      meters: mA,
      surface: edge.s,
      access: edge.ac,
      structure: edge.t,
      edgeId: edge.i,
      componentId: edge.c,
      source: edge.src,
      sourceDescription: edge.desc,
      sourceRecordId: edge.rid,
      confidence: edge.conf,
      seasonal: edge.seasonal,
      virtual: true,
      accessLeg: true
    });
    addVirt(node, edge.b, {
      a: node,
      b: edge.b,
      coords: toB,
      meters: mB,
      surface: edge.s,
      access: edge.ac,
      structure: edge.t,
      edgeId: edge.i,
      componentId: edge.c,
      source: edge.src,
      sourceDescription: edge.desc,
      sourceRecordId: edge.rid,
      confidence: edge.conf,
      seasonal: edge.seasonal,
      virtual: true,
      accessLeg: true
    });
  }

  attach(startNode, startMatch);
  attach(endNode, endMatch);
  if (startMatch.edgeIndex === endMatch.edgeIndex) {
    const edge = edges[startMatch.edgeIndex];
    const coords = coordsBetweenMatches(edge, startMatch, endMatch);
    addVirt(startNode, endNode, {
      a: startNode,
      b: endNode,
      coords,
      meters: lineMeters(coords),
      surface: edge.s,
      access: edge.ac,
      structure: edge.t,
      edgeId: edge.i,
      componentId: edge.c,
      source: edge.src,
      sourceDescription: edge.desc,
      sourceRecordId: edge.rid,
      confidence: edge.conf,
      seasonal: edge.seasonal,
      virtual: true,
      accessLeg: false
    });
  }

  function neighbors(node) {
    const out = [];
    if (node < n) {
      for (const idx of adjacency[node]) {
        const edge = edges[idx];
        if (!accessAllowed(edge.ac, policy, enums)) continue;
        const other = edge.a === node ? edge.b : edge.a;
        const forward = edge.a === node;
        out.push({
          to: other,
          edge: {
            a: node,
            b: other,
            coords: forward ? edge.g : [...edge.g].reverse(),
            meters: edge.m,
            surface: edge.s,
            access: edge.ac,
            structure: edge.t,
            edgeId: edge.i,
            componentId: edge.c,
            source: edge.src,
            sourceDescription: edge.desc,
            sourceRecordId: edge.rid,
            confidence: edge.conf,
            seasonal: edge.seasonal,
            virtual: false,
            accessLeg: false
          }
        });
      }
    }
    for (const item of virtualAdj.get(node) || []) out.push(item);
    return out;
  }

  const dist = new Float64Array(total);
  dist.fill(Infinity);
  const prevNode = new Int32Array(total);
  prevNode.fill(-1);
  const prevEdge = new Array(total);
  const heap = new MinHeap();
  dist[startNode] = 0;
  heap.push({ node: startNode, cost: 0 });

  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    if (cur.node === endNode) break;
    for (const next of neighbors(cur.node)) {
      // Access legs are scored as pure distance (no surface preference) and reported.
      const mult = next.edge.accessLeg
        ? 1
        : surfaceMultiplier(next.edge.surface, profile, enums);
      const cost = cur.cost + (next.edge.meters / 1000) * mult;
      if (cost < dist[next.to]) {
        dist[next.to] = cost;
        prevNode[next.to] = cur.node;
        prevEdge[next.to] = next.edge;
        heap.push({ node: next.to, cost });
      }
    }
  }

  if (!Number.isFinite(dist[endNode])) return null;

  const used = [];
  for (let node = endNode; node !== startNode;) {
    const edge = prevEdge[node];
    if (!edge) return null;
    used.push(edge);
    node = prevNode[node];
  }
  used.reverse();

  const geometry = [];
  const segments = [];
  let distanceMeters = 0;
  let unknownAccessMeters = 0;
  let movingSeconds = 0;
  const bySurfaceM = { paved: 0, gravel: 0, access: 0, track: 0, unknown: 0, single: 0 };
  const byAccessM = {
    motorized_verified: 0,
    motorized_permissive: 0,
    motorized_unknown: 0
  };

  for (const edge of used) {
    for (const c of edge.coords) {
      const last = geometry[geometry.length - 1];
      if (last && last[0] === c[0] && last[1] === c[1]) continue;
      geometry.push(c);
    }
    const meters = edge.meters;
    distanceMeters += meters;
    const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
    const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
    bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + meters;
    if (byAccessM[accessName] != null) byAccessM[accessName] += meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += meters;
    movingSeconds += (meters / 1000) / classSpeedKmh(edge.surface, enums) * 3600;

    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
      structureType: enums.STRUCTURE_NAME[edge.structure] || "none",
      accessClass: accessName,
      source: edge.source,
      sourceRecordId: edge.sourceRecordId,
      sourceDescription: edge.sourceDescription,
      confidence: edge.confidence,
      seasonal: !!edge.seasonal,
      distanceMeters: Math.round(meters),
      componentId: edge.componentId,
      accessLeg: !!edge.accessLeg,
      geometry: edge.coords
    });
  }

  const pct = (m) => (distanceMeters > 0 ? Math.round((m / distanceMeters) * 100) : 0);
  return {
    geometry,
    segments,
    distanceMeters,
    unknownAccessMeters,
    movingSeconds,
    stats: {
      pavedPercent: pct(bySurfaceM.paved || 0),
      gravelPercent: pct(bySurfaceM.gravel || 0),
      accessPercent: pct(bySurfaceM.access || 0),
      trackPercent: pct(bySurfaceM.track || 0),
      singlePercent: 0,
      unknownSurfacePercent: pct(bySurfaceM.unknown || 0),
      unknownAccessPercent: pct(unknownAccessMeters),
      permissiveAccessPercent: pct(byAccessM.motorized_permissive || 0),
      verifiedAccessPercent: pct(byAccessM.motorized_verified || 0)
    }
  };
}

module.exports = {
  routeRequest,
  loadGraph,
  DEFAULT_MATCH_METERS,
  matchPoint,
  normalizePolicy,
  accessAllowed
};
