"use strict";

const {
  loadGraph,
  loadGraphAsync,
  loadGraphsForRequest,
  clearGraphCache,
  resetCacheStats,
  getCacheStats,
  chainCacheEnabled,
  isLonghaulGraphPath
} = require("./graph");
const { resolveGraphRequest, primaryRegionForPoint, provinceFamily } = require("../regional/select");
const { corridorLocationsForRoute, pointInAdventureUrbanCore } = require("../regional/merge");
const { pruneGeographicLoops } = require("./path-pruning");
const {
  surfaceMultiplier: profileSurfaceMultiplier,
  roadClassMultiplier,
  classSpeedKmh: profileClassSpeedKmh,
  maxSurfaceMultiplier,
  costPerKmView,
  approachAwayExtraCost,
  cleanCityStreetMult,
  isMajorHighwayClass,
  pinMatchesMajorHighway,
  majorHighwayAvoidMult,
  isBcDirt
} = require("./profile-costs");
const {
  buildRouteDiagnostics,
  classifyRouteFailureReason,
  sumPops
} = require("./route-diagnostics");
const {
  unpackSurface,
  unpackAccess,
  unpackStructure,
  unpackConfidence,
  unpackSeasonal,
  unpackRoadClass,
  ROAD_CLASS_NAME
} = require("./pack-v2");
const { findPathV2 } = require("./find-path-v2");
const {
  isDirtSurface,
  outsideCorridor,
  maxProgressRegressionMeters
} = require("./hop-search");
const crossPackTopology = require("../schema/cross-pack-topology.v1.json");
const { resolveLocationsByEligibleEdge } = require("../regional/endpoint-resolver");

const CLEAN_PAVED_ATTEMPT_MS = 12_000;
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

function coordinateInUrbanBoxes(coordinate, boxes) {
  if (!Array.isArray(coordinate) || coordinate.length < 2) return false;
  return (boxes || []).some((box) =>
    coordinate[1] >= box.minLat && coordinate[1] <= box.maxLat &&
    coordinate[0] >= box.minLon && coordinate[0] <= box.maxLon
  );
}

function coordinateNearUrbanBoxes(coordinate, boxes, clearanceMeters = 5000) {
  if (!Array.isArray(coordinate) || coordinate.length < 2) return false;
  return (boxes || []).some((box) => {
    const nearest = [
      Math.max(Number(box.minLon), Math.min(Number(box.maxLon), coordinate[0])),
      Math.max(Number(box.minLat), Math.min(Number(box.maxLat), coordinate[1]))
    ];
    return haversineMeters(coordinate, nearest) < clearanceMeters;
  });
}

function clippedDirtMeters(runtime, startLL, endLL, corridorMeters, policy) {
  if (!runtime || runtime.format !== "v2" || !(corridorMeters > 0)) return 0;
  const { pack, enums } = runtime;
  const midLat = (startLL[1] + endLL[1]) / 2;
  const latPad = corridorMeters / 111320;
  const lonPad = corridorMeters / (111320 * Math.max(0.2, Math.cos(midLat * Math.PI / 180)));
  const minLon = Math.min(startLL[0], endLL[0]) - lonPad;
  const maxLon = Math.max(startLL[0], endLL[0]) + lonPad;
  const minLat = Math.min(startLL[1], endLL[1]) - latPad;
  const maxLat = Math.max(startLL[1], endLL[1]) + latPad;
  let meters = 0;
  for (let i = 0; i < pack.undirectedEdgeCount; i += 1) {
    const attr = pack.edgeAttrs[i];
    if (!accessAllowed(unpackAccess(attr), policy, enums)) continue;
    const surface = enums.SURFACE_NAME[unpackSurface(attr)] || "unknown";
    const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
    if (!isDirtSurface(surface, road)) continue;
    const a = pack.edgeFrom[i] * 2;
    const b = pack.edgeTo[i] * 2;
    const point = [
      (pack.nodeCoords[a] + pack.nodeCoords[b]) / 2,
      (pack.nodeCoords[a + 1] + pack.nodeCoords[b + 1]) / 2
    ];
    if (point[0] < minLon || point[0] > maxLon || point[1] < minLat || point[1] > maxLat) continue;
    if (outsideCorridor(point, startLL, endLL, corridorMeters)) meters += pack.edgeMeters[i];
  }
  return Math.round(meters);
}

function fallbackReasonFor(path, fallbackUsed, searchOutcome) {
  if (fallbackUsed) return "no_route";
  if (searchOutcome === "timeCap" || searchOutcome === "popCap") return "timeout";
  const candidates = path && path.searchMeta && path.searchMeta.corridorCandidates;
  if (
    path && path.searchMeta && path.searchMeta.corridorMeters == null &&
    Array.isArray(candidates) && candidates.some((row) => row.corridorMeters != null && row.outcome === "noPath")
  ) return "corridor_exhausted";
  return null;
}

function isLowDirtRoute(profile, path, threshold = 70) {
  const dirtPercent = Number(path && path.stats && path.stats.dirtPercent);
  return profile === "dirt" && Number.isFinite(dirtPercent) && dirtPercent < threshold;
}

function backtrackSummary(path, priorEdgeIds) {
  const prior = priorEdgeIds instanceof Set
    ? priorEdgeIds
    : new Set((priorEdgeIds || []).map(String));
  const meters = ((path && path.segments) || []).reduce((sum, segment) =>
    prior.has(String(segment.edgeId))
      ? sum + (Number(segment.distanceMeters) || 0)
      : sum,
  0);
  const total = Number(path && path.distanceMeters) || 0;
  return {
    backtrackMeters: Math.round(meters),
    backtrackPct: total > 0 ? Math.round(meters / total * 1000) / 10 : 0,
    backtrackReason: meters > 0 ? "dead_end_or_only_connector" : null
  };
}

function restrictedSummary(path) {
  const meters = ((path && path.segments) || []).reduce((sum, segment) =>
    String(segment.accessClass || "") === "motorized_restricted"
      ? sum + (Number(segment.distanceMeters) || 0)
      : sum,
  0);
  return {
    restrictedMeters: Math.round(meters),
    // Restricted edges are filtered before relaxation. Seeing one here is an
    // auditable correctness failure, never an implicit permission fallback.
    restrictedReason: meters > 0 ? "filter_miss" : null
  };
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

function accessAllowed(accessCode, policy, enums, edge) {
  // Access class, not dataset name, is authoritative. OSM path/cycleway edges
  // with uncertain motorcycle legality must remain behind Allow Unknown.
  void edge;
  const name = enums.ACCESS_NAME[accessCode];
  if (name === "motorized_restricted" || name === "motorized_excluded") return false;
  if (name === "motorized_unknown") return !!policy.motorizedUnknown;
  if (name === "motorized_verified") return true;
  if (name === "motorized_permissive") return policy.motorizedPermissive !== false;
  return false;
}

function surfaceMultiplier(surfaceCode, profile, enums) {
  // Prefer central Stage 2c tables; enums kept for call-site compatibility.
  void enums;
  return profileSurfaceMultiplier(surfaceCode, profile);
}

function classSpeedKmh(surfaceCode, enums) {
  void enums;
  return profileClassSpeedKmh(surfaceCode);
}

class MinHeap {
  constructor() { this.items = []; }
  push(item) {
    this.items.push(item);
    this.bubbleUp(this.items.length - 1);
  }
  peek() {
    return this.items.length ? this.items[0] : null;
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

/**
 * Env flag helper. defaultOn=true after median-of-three re-bench for Stage 0/1a/1b.
 * Explicit 0/false/off disables. ROUTING_ELLIPSE_DIRT stays default off.
 */
function envFlagEnabled(name, defaultOn) {
  const v = process.env[name];
  if (v === "0" || v === "false" || v === "off") return false;
  if (v === "1" || v === "true" || v === "on") return true;
  return !!defaultOn;
}

function bidirAstarEnabled() {
  return envFlagEnabled("ROUTING_BIDIR_ASTAR", true);
}

function ellipsePruneEnabled() {
  return envFlagEnabled("ROUTING_ELLIPSE_PRUNE", true);
}

function ellipseDirtEnabled() {
  return envFlagEnabled("ROUTING_ELLIPSE_DIRT", false);
}

/**
 * Ellipse detour factors by profile.
 *   cleanest — tight Google-style pavement corridor
 *   direct   — crow-flies on dirt fabric; wide enough for NSTDB/OSM cuts
 *              off the highway chord (not so tight it forces the paved spine)
 *   balanced — wider for dual-sport mix
 *   dirt     — widest adventure room; stays unpruned unless ROUTING_ELLIPSE_DIRT=1
 *              Exception: BC Dirt uses factor 2.0 (~2× crow-flies) so denser
 *              FSR meandering cannot balloon a day ride without bound.
 */
const ELLIPSE_FACTORS = {
  cleanest: 1.25,
  // Crow-flies Direct: tight band — length wins; mild dirt only among equals.
  direct: 1.22,
  // Balanced may leave Direct’s cut to pick up dirt corridors.
  balanced: 1.55,
  dirt: 2.6
};

function ellipseAttemptsForProfile(profile, regionId) {
  if (!ellipsePruneEnabled()) {
    return [{ factor: Infinity, label: "unpruned", escalation: "none" }];
  }
  // BC Dirt: enforce ~2× crow-flies soft cap (dense capillary must not invent
  // unbounded contour tourism). Other provinces keep dirt unpruned unless
  // ROUTING_ELLIPSE_DIRT=1.
  if (isBcDirt(profile, regionId)) {
    const base = 2.0;
    return [
      { factor: base, label: "ellipse-bc-dirt-" + base, escalation: "bc_dirt_cap" },
      { factor: base * 1.15, label: "ellipse-bc-dirt-widen", escalation: "widen" },
      { factor: Infinity, label: "unpruned-fallback", escalation: "fallback" }
    ];
  }
  if (profile === "dirt" && !ellipseDirtEnabled()) {
    return [{ factor: Infinity, label: "dirt-unpruned", escalation: "dirt_disabled" }];
  }
  const base = ELLIPSE_FACTORS[profile] != null ? ELLIPSE_FACTORS[profile] : 1.5;
  return [
    { factor: base, label: "ellipse-" + base, escalation: "initial" },
    { factor: base * 1.25, label: "ellipse-widen-1", escalation: "widen" },
    { factor: base * 1.6, label: "ellipse-widen-2", escalation: "widen" },
    { factor: Infinity, label: "unpruned-fallback", escalation: "fallback" }
  ];
}

function flipEdge(edge) {
  return {
    ...edge,
    a: edge.b,
    b: edge.a,
    forward: edge.forward === false,
    coords: edge.coords ? [...edge.coords].reverse() : null
  };
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

function giantComponentId(runtime) {
  if (runtime._giantComponentId != null) return runtime._giantComponentId;
  const edges = runtime.data && runtime.data.edges;
  if (!edges || !edges.length) {
    runtime._giantComponentId = 0;
    return 0;
  }
  const counts = new Map();
  for (const e of edges) {
    const c = e.c;
    if (c == null || c < 0) continue;
    counts.set(c, (counts.get(c) || 0) + 1);
  }
  let best = 0;
  let bestN = -1;
  for (const [c, n] of counts) {
    if (n > bestN) {
      bestN = n;
      best = c;
    }
  }
  runtime._giantComponentId = best;
  return best;
}

/**
 * Giant-component hard bias (+400m) was added for QC longhaul OSM islands.
 * On earlier full NS overlay packs it stole snaps from nearby NSTDB forest
 * edges and, with end-rematch, pinned both ends to the paved giant. The
 * foundational NS pack is OSM-only; keep the guard for older installed packs.
 *
 * Full packs: two-pass snap (prefer nearest eligible edge in the giant
 * component within the match radius; only then fall back to islands).
 * Longhaul: keep the hard bias + component rematch for QC From-here.
 */
function preferGiantComponentSnap(runtime) {
  if (!runtime || runtime.format === "v2") return false;
  // NS/NB/PE longhaul files are province fabric, not thinned QC hubs. Hard
  // giant bias (+400m) steals driveway snaps onto distant paved islands and
  // then fails disconnected_components after skip-clip warm reuse.
  const regionId = String(
    (runtime.data && (runtime.data.regionId || runtime.data.province)) || ""
  )
    .toLowerCase()
    .replace(/:corridor$/i, "");
  if (
    regionId === "ns" ||
    regionId === "nb" ||
    regionId === "pe" ||
    regionId === "on" ||
    regionId === "mb" ||
    regionId === "sk" ||
    regionId === "ab" ||
    regionId === "bc"
  ) {
    return false;
  }
  if (isLonghaulGraphPath(runtime.path)) return true;
  const schema = String(
    (runtime.data && runtime.data.schemaVersion) ||
      (runtime.meta && runtime.meta.schemaVersion) ||
      ""
  );
  return schema.startsWith("longhaul");
}

function matchPoint(
  runtime,
  location,
  policy,
  matchMeters,
  avoidEdgeIds,
  preferComponentId = null,
  profile = null,
  snapRole = "any"
) {
  const enums = runtime.enums;
  const point = [Number(location.lon ?? location.lng), Number(location.lat)];
  if (!Number.isFinite(point[0]) || !Number.isFinite(point[1])) {
    return { ok: false, reason: "invalid_location" };
  }
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
  const preferId = Number.isFinite(preferComponentId) ? preferComponentId : null;
  const longhaulBias = preferGiantComponentSnap(runtime);
  const giantId = runtime.format === "v2" ? null : giantComponentId(runtime);
  // Soft surface bias on top of two-pass giant snap (full packs) / longhaul bias.
  // Start only: prefer nearby dirt/track/access so pins do not start on pavement
  // when a dirt edge is almost as close. End snaps stay distance-first — adventure
  // dirt bias at B caused paved-approach → dirt-spur U-turns past the destination.
  // Cleanest: slight paved preference on both ends.
  const prof = profile ? String(profile).toLowerCase() : null;
  const role = snapRole === "start" || snapRole === "end" ? snapRole : "any";
  const preferAdventureSnap = prof && prof !== "cleanest" && role !== "end";
  // Clean snaps nearest eligible way — never prefer pavement over a closer dirt/service.
  const preferPavedSnap = role === "end" && prof !== "cleanest";
  const candidates = edgeCandidateIndexes(runtime, point[0], point[1], matchMeters);
  const isV2 = runtime.format === "v2";
  let bestAny = null;
  let bestGiant = null;
  for (const index of candidates) {
    let accessCode;
    let surfaceCode;
    let structureCode;
    let roadTrack = "unknown";
    let edgeId;
    let componentId;
    let edgeMeters;
    let coords;
    if (isV2) {
      const attr = runtime.pack.edgeAttrs[index];
      accessCode = unpackAccess(attr);
      surfaceCode = unpackSurface(attr);
      structureCode = unpackStructure(attr);
      edgeId = runtime.pack.edgeId(index);
      componentId = -1;
      edgeMeters = runtime.pack.edgeMeters[index];
      roadTrack = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
      // Geometry sidecar: snap only (not used in relax).
      coords = runtime.geom.polyline(index);
    } else {
      const edge = runtime.data.edges[index];
      if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
      if (avoid && avoid.has(String(edge.i))) continue;
      accessCode = edge.ac;
      surfaceCode = edge.s;
      structureCode = edge.t;
      edgeId = edge.i;
      componentId = edge.c;
      edgeMeters = edge.m;
      coords = edge.g;
      roadTrack = edge.rt || "unknown";
    }
    if (isV2) {
      if (!accessAllowed(accessCode, policy, enums, null)) continue;
      if (avoid && avoid.has(String(edgeId))) continue;
    }
    let along = 0;
    for (let i = 1; i < coords.length; i += 1) {
      const a = coords[i - 1];
      const b = coords[i];
      const segM = haversineMeters(a, b);
      const projected = projectOnSegment(point, a, b);
      // Hard prefer an explicit component (end rematch). Longhaul: hard-penalize
      // non-giant. Full packs: distance-only here; giant preference is two-pass.
      let componentPenalty = 0;
      if (
        preferId != null &&
        componentId != null &&
        componentId >= 0 &&
        componentId !== preferId
      ) {
        componentPenalty = 1e6;
      } else if (
        longhaulBias &&
        preferId == null &&
        giantId != null &&
        componentId != null &&
        componentId >= 0 &&
        componentId !== giantId
      ) {
        // Prefer giant for QC islands, but do not steal a clearly closer local
        // edge (pin drop / driveway) — that caused hard snap fails when the
        // giant sat just outside the match radius.
        if (projected.distanceM > Math.min(180, matchMeters * 0.4)) {
          componentPenalty = Math.max(400, matchMeters);
        }
      }
      const surfaceName = enums.SURFACE_NAME[surfaceCode] || "unknown";
      let surfaceBias = 0;
      if (preferAdventureSnap && surfaceName !== "paved") {
        surfaceBias = -22;
      } else if (preferPavedSnap && surfaceName === "paved") {
        surfaceBias = -30;
        if (isMajorHighwayClass(roadTrack) && projected.distanceM >= 18) {
          surfaceBias = 28;
        }
      }
      const score = projected.distanceM + componentPenalty + surfaceBias;
      const candidate = {
        ok: true,
        edgeIndex: index,
        edgeId,
        accessClass: enums.ACCESS_NAME[accessCode],
        surfaceClass: enums.SURFACE_NAME[surfaceCode],
        structureType: enums.STRUCTURE_NAME[structureCode],
        componentId,
        distanceM: projected.distanceM,
        score,
        coord: projected.coord,
        segmentIndex: i - 1,
        distanceAlongM: along + segM * projected.t,
        edgeMeters,
        roadTrack
      };
      if (!bestAny || score < bestAny.score) bestAny = candidate;
      if (
        !longhaulBias &&
        preferId == null &&
        giantId != null &&
        componentId === giantId &&
        projected.distanceM <= matchMeters &&
        (!bestGiant || score < bestGiant.score)
      ) {
        bestGiant = candidate;
      }
      along += segM;
    }
  }
  const best =
    !longhaulBias && preferId == null && bestGiant && bestGiant.distanceM <= matchMeters
      ? bestGiant
      : bestAny;
  if (!best || best.distanceM > matchMeters) {
    return {
      ok: false,
      reason: "snap_no_eligible_edge",
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

/**
 * If the path got within `closeM` of the destination then wandered away before
 * finishing, truncate at the closest approach and pin the final coordinate to
 * the end match. Fixes Clean/adventure U-turns past B from wrong end-edge entry.
 */
function trimDestinationOvershoot(geometry, endLL, closeM = 100, wanderM = 160) {
  if (!geometry || geometry.length < 5 || !endLL) return geometry;
  let bestI = 0;
  let bestD = Infinity;
  for (let i = 0; i < geometry.length; i += 1) {
    const d = haversineMeters(geometry[i], endLL);
    if (d < bestD) {
      bestD = d;
      bestI = i;
    }
  }
  if (bestD > closeM) return geometry;
  let after = 0;
  for (let i = bestI + 1; i < geometry.length; i += 1) {
    after += haversineMeters(geometry[i - 1], geometry[i]);
  }
  if (after < wanderM) return geometry;
  const trimmed = geometry.slice(0, bestI + 1);
  const last = trimmed[trimmed.length - 1];
  if (!last || last[0] !== endLL[0] || last[1] !== endLL[1]) {
    trimmed.push([endLL[0], endLL[1]]);
  }
  return trimmed;
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

function normalizePolicy(input, profile) {
  const policy = input || {};
  // Product law: Clean / cleanest is immune to Allow — never open purple
  // motorized_unknown capillary, even if the UI toggle is on.
  const isClean = String(profile || "").toLowerCase() === "cleanest";
  return {
    motorizedPermissive: policy.motorizedPermissive !== false,
    motorizedUnknown: isClean ? false : !!policy.motorizedUnknown
  };
}

function debugGraphBbox(body) {
  const raw = body && body.bbox;
  const minLon = Number(raw && raw.minLon);
  const minLat = Number(raw && raw.minLat);
  const maxLon = Number(raw && raw.maxLon);
  const maxLat = Number(raw && raw.maxLat);
  if (
    !Number.isFinite(minLon) || !Number.isFinite(minLat) ||
    !Number.isFinite(maxLon) || !Number.isFinite(maxLat) ||
    minLon >= maxLon || minLat >= maxLat
  ) {
    return null;
  }
  // This is a viewport diagnostic, never a province export.
  if (maxLon - minLon > 3 || maxLat - minLat > 3) return null;
  return { minLon, minLat, maxLon, maxLat };
}

function debugPolylineIntersects(coords, bbox) {
  if (!coords || coords.length < 2) return false;
  let minLon = Infinity;
  let minLat = Infinity;
  let maxLon = -Infinity;
  let maxLat = -Infinity;
  for (const point of coords) {
    const lon = Number(point && point[0]);
    const lat = Number(point && point[1]);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    if (lon < minLon) minLon = lon;
    if (lat < minLat) minLat = lat;
    if (lon > maxLon) maxLon = lon;
    if (lat > maxLat) maxLat = lat;
  }
  return !(
    maxLon < bbox.minLon || minLon > bbox.maxLon ||
    maxLat < bbox.minLat || minLat > bbox.maxLat
  );
}

function debugPolyline(coords) {
  if (!coords || coords.length <= 64) return coords || [];
  const step = Math.ceil(coords.length / 64);
  const out = [];
  for (let i = 0; i < coords.length; i += step) out.push(coords[i]);
  const last = coords[coords.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

function debugGraphResponse(body, graphResolution, runtime) {
  const bbox = debugGraphBbox(body);
  if (!bbox) {
    return {
      status: "error",
      error: "invalid_debug_bbox",
      message: "Provide a valid viewport bbox no larger than 3 degrees."
    };
  }
  const requestedCap = Number(body.cap);
  const cap = Math.max(250, Math.min(4000, Number.isFinite(requestedCap) ? requestedCap : 3500));
  const indices = new Set();
  const grid = runtime.edgeGrid;
  const gridSize = runtime.GRID;
  if (grid && Number.isFinite(gridSize) && gridSize > 0) {
    const x0 = Math.floor(bbox.minLon / gridSize);
    const y0 = Math.floor(bbox.minLat / gridSize);
    const x1 = Math.floor(bbox.maxLon / gridSize);
    const y1 = Math.floor(bbox.maxLat / gridSize);
    for (let x = x0; x <= x1; x += 1) {
      for (let y = y0; y <= y1; y += 1) {
        const bucket = grid.get(x + ":" + y);
        if (bucket) for (const index of bucket) indices.add(index);
      }
    }
  }

  const features = [];
  const enums = runtime.enums || {};
  const v2 = runtime.format === "v2";
  const candidateIndices = grid
    ? Array.from(indices)
    : Array.from({ length: runtime.data.edgeCount || 0 }, (_, index) => index);
  if (v2 && runtime.pack.edgeFrom && runtime.pack.edgeTo) {
    const centerLon = (bbox.minLon + bbox.maxLon) / 2;
    const centerLat = (bbox.minLat + bbox.maxLat) / 2;
    const nodeCoords = runtime.pack.nodeCoords;
    const score = (index) => {
      const a = runtime.pack.edgeFrom[index];
      const b = runtime.pack.edgeTo[index];
      const lon = (nodeCoords[a * 2] + nodeCoords[b * 2]) / 2;
      const lat = (nodeCoords[a * 2 + 1] + nodeCoords[b * 2 + 1]) / 2;
      const dx = (lon - centerLon) * Math.cos(centerLat * Math.PI / 180);
      const dy = lat - centerLat;
      return dx * dx + dy * dy;
    };
    candidateIndices.sort((a, b) => score(a) - score(b));
  }
  let matchingCount = 0;
  for (const index of candidateIndices) {
    let coords;
    let edgeId;
    let surfaceCode;
    let accessCode;
    let structureCode;
    let roadClass;
    if (v2) {
      coords = runtime.geom.polyline(index);
      const attr = runtime.pack.edgeAttrs[index];
      edgeId = runtime.pack.edgeId(index);
      surfaceCode = unpackSurface(attr);
      accessCode = unpackAccess(attr);
      structureCode = unpackStructure(attr);
      roadClass = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
    } else {
      const edge = runtime.data.edges[index];
      if (!edge) continue;
      coords = edge.g || [];
      edgeId = String(edge.i || index);
      surfaceCode = edge.s;
      accessCode = edge.ac;
      structureCode = edge.t;
      roadClass = String(edge.rt || "unknown");
    }
    if (!debugPolylineIntersects(coords, bbox)) continue;
    matchingCount += 1;
    if (features.length >= cap) continue;
    features.push({
      edgeId,
      coordinates: debugPolyline(coords),
      surfaceClass: (enums.SURFACE_NAME || [])[surfaceCode] || "unknown",
      accessClass: (enums.ACCESS_NAME || [])[accessCode] || "motorized_permissive",
      structureType: (enums.STRUCTURE_NAME || [])[structureCode] || "none",
      roadClass
    });
  }
  return {
    status: "complete",
    action: "debug_graph",
    routingRevision: "ride-objectives-v4",
    source: "live-pack",
    regionIds: graphResolution.regionIds,
    features,
    capped: matchingCount > cap,
    matchingCount,
    cap
  };
}

async function routeRequestCore(body = {}) {
  const endpointResolution = await resolveLocationsByEligibleEdge(body);
  body = endpointResolution.body;
  if (endpointResolution.resolutions.some((row) => row.probes && row.probes.length > 1)) {
    console.log("route endpoint resolver " + JSON.stringify(endpointResolution.resolutions));
  }
  const graphResolution = resolveGraphRequest(body);
  if (!graphResolution.ok) {
    return {
      status: "error",
      error: graphResolution.error,
      message: graphResolution.message,
      regionIds: graphResolution.regionIds || []
    };
  }

  if (graphResolution.mode === "canada-chain") {
    return routeCanadaChain(body, graphResolution);
  }

  let runtime;
  try {
    runtime = await loadGraphsForRequest(graphResolution, {
      locations: body.locations || [],
      corridorBufferMeters: body.options && body.options.corridorBufferMeters,
      profile: body.profile
    });
  } catch (err) {
    const message = err && err.message ? err.message : String(err);
    const corridorClip = /corridor clip removed all edges/i.test(message);
    return {
      status: "error",
      error: corridorClip ? "corridor_clip" : "graph_load_failed",
      message,
      regionIds: graphResolution.regionIds || [],
      debug: {
        failureReason: corridorClip ? "corridor_clip" : "graph_load_failed",
        diagnostics: {
          failureReason: corridorClip ? "corridor_clip" : "graph_load_failed",
          buildMs: null,
          searchAttempts: []
        }
      }
    };
  }
  if (body.action === "debug_graph") {
    return debugGraphResponse(body, graphResolution, runtime);
  }
  return routeOnRuntime(body, graphResolution, runtime);
}

function echoLegId(result, legId) {
  if (legId == null || legId === "" || !result || typeof result !== "object") return result;
  const echoed = { ...result, legId };
  if (Array.isArray(result.geometry)) {
    echoed.geometryProperties = { ...(result.geometryProperties || {}), legId };
  }
  return echoed;
}

async function routeRequest(body = {}) {
  return echoLegId(await routeRequestCore(body), body.legId);
}

/** Generous radius for snapping engineered chain seams onto live longhaul fabric. */
const SEAM_SNAP_RADIUS_M = 12000;
/** After seam snap, hop match for seam pins only (user pins keep the normal cap). */
const SEAM_HOP_MATCH_M = 600;

function isChainSeamLocation(loc) {
  if (!loc || typeof loc !== "object") return false;
  if (loc.seamSnapped) return true;
  const role = String(loc.role || "");
  return role === "seam" || role === "spine";
}

function inferSeamRegionIds(waypoints, index) {
  const wp = waypoints[index] || {};
  if (Array.isArray(wp.between) && wp.between.length) {
    return [...new Set(wp.between.map((r) => String(r).toLowerCase()))];
  }
  const { primaryRegionForPoint, provinceFamily } = require("../regional/select");
  const famOf = (p) => {
    if (!p) return null;
    const lon = Number(p.lon != null ? p.lon : p.lng);
    const lat = Number(p.lat);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
    return provinceFamily(primaryRegionForPoint(lon, lat));
  };
  // Spine hubs are in-province TCH cities — one pack is enough.
  if (String(wp.role || "") === "spine") {
    const self = famOf(wp);
    return self ? [self] : [];
  }
  const regions = new Set();
  for (const p of [waypoints[index - 1], wp, waypoints[index + 1]]) {
    const fam = famOf(p);
    if (fam) regions.add(fam);
  }
  return [...regions];
}

async function loadSeamRegionRuntime(regionId, seed) {
  const lon = Number(seed.lon != null ? seed.lon : seed.lng);
  const lat = Number(seed.lat);
  const locations = [
    { lon, lat },
    { lon: lon + 0.01, lat }
  ];
  const resolution = resolveGraphRequest({
    regionId: String(regionId).toLowerCase(),
    preferLonghaulPacks: false,
    disableLonghaul: true,
    locations
  });
  if (!resolution.ok) {
    throw new Error(resolution.message || resolution.error || "seam_region_resolve_failed");
  }
  return loadGraphsForRequest(resolution, {
    locations,
    profile: "balanced",
    // Tight bulb around the seed — never warm-reuse the full province pack.
    forceCorridorClip: true,
    corridorBufferMeters: Math.max(SEAM_SNAP_RADIUS_M + 3000, 15000)
  });
}

function releaseSeamProbeMemory() {
  // Seam probes must not leave province-wide longhaul runtimes resident —
  // Hobby RSS then trips graph_memory_pressure on the first real hop merge.
  clearGraphCache();
  if (typeof global.gc === "function") {
    try {
      global.gc();
    } catch (_) {
      /* ignore */
    }
  }
}

/**
 * Snap one engineered chain waypoint onto an existing longhaul edge.
 * Never invents free-space connectors — only projects onto eligible fabric.
 */
async function snapSeamWaypoint(seed, regionIds, profile) {
  const topology = await topologySeamWaypoint(seed, regionIds);
  if (topology.ok) return topology;
  // Rebuilt target packs must never fall back to a sampled border snap. Other
  // legacy pairs retain the old resolver only until their next deliberate rebuild.
  const targetPair = new Set(regionIds.map((id) => String(id).toLowerCase()));
  if (
    targetPair.size === 2 &&
    targetPair.has("bc") &&
    (targetPair.has("ab") || targetPair.has("wa"))
  ) {
    return topology;
  }
  const preferPaved =
    String(profile || "").toLowerCase() === "cleanest" || String(seed.role || "") === "spine";
  const snapProfile = preferPaved ? "cleanest" : String(profile || "balanced").toLowerCase();
  const snapRole = preferPaved ? "end" : "any";
  // Seam seeds are not user pins — allow unknown capillary when adventure profiles need it.
  const policy = {
    motorizedPermissive: true,
    motorizedUnknown: snapProfile === "cleanest" ? false : true
  };

  const candidates = [];
  let nearestMeters = null;

  try {
    for (const regionId of regionIds) {
      let runtime;
      try {
        runtime = await loadSeamRegionRuntime(regionId, seed);
      } catch (_) {
        releaseSeamProbeMemory();
        continue;
      }
      const match = matchPoint(
        runtime,
        seed,
        policy,
        SEAM_SNAP_RADIUS_M,
        null,
        null,
        snapProfile,
        snapRole
      );
      // Drop the province-wide runtime before the next probe / hop.
      releaseSeamProbeMemory();
      if (!match.ok) {
        if (match.nearestMeters != null) {
          if (nearestMeters == null || match.nearestMeters < nearestMeters) {
            nearestMeters = match.nearestMeters;
          }
        }
        continue;
      }
      candidates.push({
        regionId,
        match: {
          ...match,
          // Detach from runtime-owned arrays.
          coord: [match.coord[0], match.coord[1]]
        }
      });
    }

    if (!candidates.length) {
      return { ok: false, nearestMeters, regionIds };
    }

    let best = null;
    for (const cand of candidates) {
      const coord = { lon: cand.match.coord[0], lat: cand.match.coord[1] };
      let dualCount = 1;
      let otherNear = 0;
      for (const regionId of regionIds) {
        if (regionId === cand.regionId) continue;
        let runtime;
        try {
          runtime = await loadSeamRegionRuntime(regionId, coord);
        } catch (_) {
          releaseSeamProbeMemory();
          continue;
        }
        const other = matchPoint(
          runtime,
          coord,
          policy,
          SEAM_SNAP_RADIUS_M,
          null,
          null,
          snapProfile,
          snapRole
        );
        releaseSeamProbeMemory();
        if (other.ok) {
          dualCount += 1;
          otherNear = Math.max(otherNear, other.distanceM);
        }
      }
      const pavedBonus = cand.match.surfaceClass === "paved" ? -150 : 0;
      const needDual = Math.min(2, regionIds.length);
      const dualBonus = dualCount >= needDual ? -2000 : 0;
      const score = cand.match.distanceM + otherNear * 0.25 + pavedBonus + dualBonus;
      if (!best || score < best.score) {
        best = {
          score,
          lon: coord.lon,
          lat: coord.lat,
          seedDistanceM: cand.match.distanceM,
          surfaceClass: cand.match.surfaceClass,
          regionId: cand.regionId,
          dualCount
        };
      }
    }

    return {
      ok: true,
      lon: best.lon,
      lat: best.lat,
      seedDistanceM: Math.round(best.seedDistanceM),
      surfaceClass: best.surfaceClass,
      regionId: best.regionId,
      dualCount: best.dualCount,
      regionIds
    };
  } finally {
    releaseSeamProbeMemory();
  }
}

/**
 * Resolve a seam only when both phone/live packs prove the same OSM way and
 * exact OSM vertex. The approximate chain waypoint is used for ranking only.
 */
/**
 * Select a topology-authored seam from the deployment index. This avoids four
 * full R2 graph downloads before a cross-region fuel plan can even begin.
 */
function topologySeamFromIndex(seed, regionIds, index = crossPackTopology) {
  const ids = [...new Set((regionIds || []).map((id) => String(id).toLowerCase()))];
  if (ids.length !== 2) {
    return { ok: false, authoritative: false, reason: "seam_pair_required", regionIds: ids };
  }
  const records = (index && index.regions) || {};
  const left = records[ids[0]];
  const right = records[ids[1]];
  const leftRows = left && left.neighbors && left.neighbors[ids[1]];
  const rightRows = right && right.neighbors && right.neighbors[ids[0]];
  if (!Array.isArray(leftRows) || !Array.isArray(rightRows)) {
    return { ok: false, authoritative: false, reason: "seam_pair_not_indexed", regionIds: ids };
  }

  const rightKeys = new Set(
    rightRows
      .filter((row) => Number(row.gapMeters) <= 2 && Array.isArray(row.coordinate))
      .map((row) => `${row.osmWayId}|${Number(row.coordinate[0]).toFixed(5)}|${Number(row.coordinate[1]).toFixed(5)}`)
  );
  const seedCoord = [Number(seed.lon != null ? seed.lon : seed.lng), Number(seed.lat)];
  const shared = leftRows
    .filter((row) => Number(row.gapMeters) <= 2 && Array.isArray(row.coordinate))
    .filter((row) => rightKeys.has(
      `${row.osmWayId}|${Number(row.coordinate[0]).toFixed(5)}|${Number(row.coordinate[1]).toFixed(5)}`
    ))
    .filter((row) => !coordinateNearUrbanBoxes(row.coordinate, left.urbanCores || []))
    .filter((row) => !coordinateNearUrbanBoxes(row.coordinate, right.urbanCores || []))
    .sort((a, b) => haversineMeters(seedCoord, a.coordinate) - haversineMeters(seedCoord, b.coordinate));
  if (!shared.length) {
    return {
      ok: false,
      authoritative: true,
      reason: "no_non_urban_shared_osm_seam",
      nearestMeters: null,
      regionIds: ids
    };
  }
  const best = shared[0];
  return {
    ok: true,
    authoritative: true,
    lon: Number(best.coordinate[0]),
    lat: Number(best.coordinate[1]),
    seedDistanceM: Math.round(haversineMeters(seedCoord, best.coordinate)),
    surfaceClass: "pack-proven",
    regionId: ids[0],
    dualCount: 2,
    osmWayId: String(best.osmWayId),
    seamMethod: "same-osm-way-and-vertex-index",
    regionIds: ids
  };
}

async function topologySeamWaypoint(seed, regionIds) {
  const ids = [...new Set((regionIds || []).map((id) => String(id).toLowerCase()))];
  if (ids.length !== 2) return { ok: false, reason: "seam_pair_required", regionIds: ids };
  const indexed = topologySeamFromIndex(seed, ids);
  if (indexed.authoritative) return indexed;
  const rowsByRegion = new Map();
  const coresByRegion = new Map();
  try {
    for (const id of ids) {
      let runtime;
      try {
        runtime = await loadSeamRegionRuntime(id, seed);
      } catch (_) {
        releaseSeamProbeMemory();
        return { ok: false, reason: "seam_pack_load_failed", regionIds: ids };
      }
      const meta = runtime.pack && runtime.pack.meta ? runtime.pack.meta : runtime.meta || {};
      const neighbor = ids.find((other) => other !== id);
      const rows = Array.isArray((meta.crossPackSeams || {})[neighbor])
        ? meta.crossPackSeams[neighbor]
        : [];
      rowsByRegion.set(id, rows.map((row) => ({ ...row })));
      coresByRegion.set(
        id,
        Array.isArray(meta.urbanCores) ? meta.urbanCores.map((box) => ({ ...box })) : []
      );
      releaseSeamProbeMemory();
    }

    const left = rowsByRegion.get(ids[0]) || [];
    const right = rowsByRegion.get(ids[1]) || [];
    const rightKeys = new Set(
      right
        .filter((row) => Number(row.gapMeters) <= 2)
        .map((row) => `${row.osmWayId}|${Number(row.coordinate && row.coordinate[0]).toFixed(5)}|${Number(row.coordinate && row.coordinate[1]).toFixed(5)}`)
    );
    const seedCoord = [Number(seed.lon != null ? seed.lon : seed.lng), Number(seed.lat)];
    const shared = left
      .filter((row) => Number(row.gapMeters) <= 2 && Array.isArray(row.coordinate))
      .filter((row) =>
        rightKeys.has(
          `${row.osmWayId}|${Number(row.coordinate[0]).toFixed(5)}|${Number(row.coordinate[1]).toFixed(5)}`
        )
      )
      // A chain seam is an implementation detail, not the rider's B pin. If it
      // sits inside an urban core, endpoint exemption would silently open that
      // core to the whole hop. Only topology-proven seams outside both packs'
      // urban walls may become intermediate waypoints.
      .filter((row) => ids.every((id) => {
        return !coordinateNearUrbanBoxes(row.coordinate, coresByRegion.get(id));
      }))
      .sort((a, b) => haversineMeters(seedCoord, a.coordinate) - haversineMeters(seedCoord, b.coordinate));
    if (!shared.length) {
      return { ok: false, reason: "no_non_urban_shared_osm_seam", nearestMeters: null, regionIds: ids };
    }
    const best = shared[0];
    return {
      ok: true,
      lon: Number(best.coordinate[0]),
      lat: Number(best.coordinate[1]),
      seedDistanceM: Math.round(haversineMeters(seedCoord, best.coordinate)),
      surfaceClass: "pack-proven",
      regionId: ids[0],
      dualCount: 2,
      osmWayId: String(best.osmWayId),
      seamMethod: "same-osm-way-and-vertex",
      regionIds: ids
    };
  } finally {
    releaseSeamProbeMemory();
  }
}

/**
 * Resolve every intermediate canada-chain waypoint onto live longhaul fabric.
 * User start/end pins are left untouched.
 */
async function resolveChainSeamWaypoints(waypoints, body = {}) {
  const profile = String(body.profile || "balanced").toLowerCase();
  const out = (waypoints || []).map((w) => ({ ...w }));
  const snaps = [];

  for (let i = 1; i < out.length - 1; i += 1) {
    const seed = out[i];
    if (!isChainSeamLocation(seed) && seed.role == null && !seed.between) {
      // Engineered intermediates from corridor helpers always carry role/between
      // after merge.js update; still treat bare mids as seams for older callers.
    }
    const regionIds = inferSeamRegionIds(out, i);
    if (!regionIds.length) {
      return {
        ok: false,
        error: "seam_snap_failed",
        message: "Could not resolve provinces for chain seam",
        seamIndex: i,
        nearestMeters: null,
        seed: { lon: seed.lon, lat: seed.lat }
      };
    }

    const snapped = await snapSeamWaypoint(seed, regionIds, profile);
    if (!snapped.ok) {
      return {
        ok: false,
        error: "seam_snap_failed",
        message:
          "Chain seam could not snap onto road fabric within " + SEAM_SNAP_RADIUS_M + " m",
        seamIndex: i,
        nearestMeters: snapped.nearestMeters,
        seed: {
          lon: seed.lon,
          lat: seed.lat,
          between: seed.between || regionIds
        },
        regionIds
      };
    }

    out[i] = {
      lon: snapped.lon,
      lat: snapped.lat,
      role: seed.role || "seam",
      between: Array.isArray(seed.between) ? seed.between.slice() : regionIds.slice(),
      seamSnapped: true
    };
    snaps.push({
      index: i,
      from: { lon: seed.lon, lat: seed.lat },
      to: { lon: snapped.lon, lat: snapped.lat },
      seedDistanceM: snapped.seedDistanceM,
      surfaceClass: snapped.surfaceClass,
      regionId: snapped.regionId,
      dualCount: snapped.dualCount,
      osmWayId: snapped.osmWayId || null,
      seamMethod: snapped.seamMethod || "legacy-sampled-snap"
    });
  }

  return { ok: true, waypoints: out, snaps };
}

/** A hard leg ceiling is cumulative across every regional chain hop. */
function remainingChainPathCap(options, completedMeters) {
  const requested = Number((options || {}).maxPathMeters);
  if (!Number.isFinite(requested)) return null;
  return requested - Math.max(0, Number(completedMeters) || 0);
}

async function routeCanadaChain(body, graphResolution) {
  const profile = body.profile || "balanced";
  // Every profile uses neutral province-seam joints (never city hubs) so each
  // hop loads ≤2 packs without manufacturing an urban-core endpoint exemption.
  let waypoints = corridorLocationsForRoute(body.locations || [], {
    profile,
    forChain: true
  });
  if (waypoints.length < 2) {
    return {
      status: "error",
      error: "chain_failed",
      message: "Could not build long-haul waypoint chain"
    };
  }

  const useChainCache = chainCacheEnabled();
  resetCacheStats();
  if (!useChainCache) {
    clearGraphCache();
  }

  // Pack-resilient seam snap: hard-coded joint seeds can land kilometres off
  // thinned longhaul fabric after province rebuilds. Snap intermediates only.
  const seamResolved = await resolveChainSeamWaypoints(waypoints, body);
  if (!seamResolved.ok) {
    return {
      status: "error",
      error: seamResolved.error || "seam_snap_failed",
      message: seamResolved.message || "Chain seam snap failed",
      regionIds: graphResolution.regionIds,
      seamIndex: seamResolved.seamIndex,
      nearestMeters: seamResolved.nearestMeters,
      seed: seamResolved.seed
    };
  }
  waypoints = seamResolved.waypoints;
  // Seam probes inflate full province packs; reclaim before hop merges.
  releaseSeamProbeMemory();

  const parts = [];
  let totalMeters = 0;
  const warnings = [];
  let searchMsTotal = 0;
  const hopCacheSnapshots = [];

  for (let i = 0; i < waypoints.length - 1; i += 1) {
    if (!useChainCache) {
      clearGraphCache();
      // Encourage reclaim before the next inflate (QC longhaul ~1.3GB RSS).
      if (typeof global.gc === "function") {
        try {
          global.gc();
        } catch (_) {
          /* ignore */
        }
      }
    }
    const hopStart = waypoints[i];
    const hopEnd = waypoints[i + 1];
    const startFam = provinceFamily(
      hopStart.resolvedRegionId || primaryRegionForPoint(
        Number(hopStart.lon != null ? hopStart.lon : hopStart.lng),
        Number(hopStart.lat)
      )
    );
    const endFam = provinceFamily(
      hopEnd.resolvedRegionId || primaryRegionForPoint(
        Number(hopEnd.lon != null ? hopEnd.lon : hopEnd.lng),
        Number(hopEnd.lat)
      )
    );
    const hopRegion =
      i === waypoints.length - 2 ? endFam || startFam : startFam || endFam;
    const requestedPathCap = Number((body.options || {}).maxPathMeters);
    const remainingPathCap = remainingChainPathCap(body.options, totalMeters);
    if (remainingPathCap != null && remainingPathCap <= 0) {
      return {
        status: "failed",
        error: "max_path_exceeded",
        message: "The regional route chain exceeds the fuel-leg distance limit.",
        regionIds: graphResolution.regionIds,
        hopIndex: i
      };
    }
    const hop = await routeRequest({
      ...body,
      locations: [hopStart, hopEnd],
      disableChain: true,
      disableLonghaul: true,
      preferLonghaulPacks: false,
      regionId: hopRegion || undefined,
      options: {
        ...(body.options || {}),
        // A fuel-leg ceiling applies to the complete cross-region leg, not
        // independently to every province hop.
        maxPathMeters: remainingPathCap == null ? (body.options || {}).maxPathMeters : remainingPathCap,
        matchLimitMeters: Math.min(500, Number((body.options || {}).matchLimitMeters) || 500),
        chainSeamHop: true
      }
    });
    if (hop.status !== "complete") {
      const destinationKind = hopEnd.seamSnapped
        ? `seam:${(hopEnd.between || []).join("-") || "regional"}`
        : "rider-pin";
      return {
        status: hop.status || "failed",
        error: hop.error || "chain_hop_failed",
        message:
          (hop.message || "Long-haul hop failed") +
          ` (hop ${i + 1}/${waypoints.length - 1} destination=${destinationKind})`,
        regionIds: graphResolution.regionIds,
        hopIndex: i,
        hop,
        seamSnaps: seamResolved.snaps
      };
    }
    parts.push(hop);
    totalMeters += hop.distanceMeters || 0;
    if (Number.isFinite(requestedPathCap) && totalMeters > requestedPathCap + 1) {
      return {
        status: "failed",
        error: "max_path_exceeded",
        message: "The regional route chain exceeds the fuel-leg distance limit.",
        regionIds: graphResolution.regionIds,
        hopIndex: i
      };
    }
    if (Array.isArray(hop.warnings)) warnings.push(...hop.warnings);
    if (hop.debug && Number.isFinite(hop.debug.searchMs)) {
      searchMsTotal += hop.debug.searchMs;
    }
    hopCacheSnapshots.push({
      hop: i + 1,
      loadMs: hop.debug && hop.debug.graph ? hop.debug.graph.loadMs : null,
      searchMs: hop.debug ? hop.debug.searchMs : null
    });
  }

  const geometry = [];
  const segments = [];
  for (let i = 0; i < parts.length; i += 1) {
    const g = parts[i].geometry || [];
    const start = i === 0 ? 0 : 1; // avoid duplicate joint coordinates
    for (let j = start; j < g.length; j += 1) geometry.push(g[j]);
    for (const seg of parts[i].segments || []) segments.push(seg);
  }

  const cache = getCacheStats();
  // Surface/access % must come from hop segments — never leave only hop
  // timing fields here or the client shows 0% Dirt while painting blue/gray.
  const surfaceStats = aggregateRouteSurfaceStats(segments, totalMeters);
  const hopSearches = parts.map((part, index) => ({
    hop: index + 1,
    routingRevision: part.debug && part.debug.routingRevision || null,
    searchMeta: part.debug && part.debug.searchMeta || null,
    fallback: part.debug && part.debug.fallback || null,
    distanceMeters: part.distanceMeters || 0,
    dirtPercent: part.stats && part.stats.dirtPercent
  }));
  const hopMetas = hopSearches.map((row) => row.searchMeta).filter(Boolean);
  const chainSearchMeta = {
    pass2Outcome: hopMetas.some((meta) => meta.timedOut)
      ? (hopMetas.find((meta) => meta.timedOut).pass2Outcome || "timeCap")
      : "completed",
    pops: hopMetas.reduce((sum, meta) => sum + (Number(meta.pops) || 0), 0),
    timedOut: hopMetas.some((meta) => meta.timedOut === true),
    rideObjective:
      profile === "dirt" ? "earned-dirt-detour" :
      profile === "balanced" ? "surface-balance" :
      profile === "direct" ? "crow-flies-adventure" : "clean-pavement",
    corridorMeters: hopMetas.reduce((max, meta) =>
      Math.max(max, Number(meta.corridorMeters) || 0), 0
    ) || null,
    maxCrossTrackMeters: hopMetas.reduce((max, meta) =>
      Math.max(max, Number(meta.maxCrossTrackMeters) || 0), 0
    ) || null,
    corridorWidened: hopMetas.some((meta) => meta.corridorWidened === true),
    urbanCoreFallbackUsed: hopMetas.some((meta) => meta.urbanCoreFallbackUsed === true),
    cleanUnpavedFallbackUsed: hopMetas.some((meta) => meta.cleanUnpavedFallbackUsed === true),
    settlementFallbackUsed: hopMetas.some((meta) => meta.settlementFallbackUsed === true),
    hopSearches
  };
  return {
    status: "complete",
    profile: String(body.profile || "balanced").toLowerCase(),
    distanceMeters: totalMeters,
    geometry,
    segments,
    warnings,
    stats: {
      ...surfaceStats,
      hops: parts.length,
      hopKm: parts.map((p) => Math.round((p.distanceMeters || 0) / 1000)),
      searchMs: searchMsTotal,
      packLoads: cache.loads,
      packCacheHits: cache.hits,
      inflateMs: cache.inflateMs
    },
    debug: {
      routingRevision: "ride-objectives-v9-settlement-gated",
      engine: "dirt-node-astar-chain",
      graphMode: "canada-chain",
      packIdentity: parts.flatMap((part) =>
        part && part.debug && Array.isArray(part.debug.packIdentity)
          ? part.debug.packIdentity
          : []
      ),
      searchMeta: chainSearchMeta,
      regionIds: graphResolution.regionIds,
      waypoints: waypoints.length,
      seamSnaps: seamResolved.snaps,
      fallback: chainSearchMeta.urbanCoreFallbackUsed
        ? "urban_core_last_resort"
        : chainSearchMeta.settlementFallbackUsed ? "settlement_last_resort" : null,
      chainCacheEnabled: useChainCache,
      cache,
      hopTimings: hopCacheSnapshots,
      searchMs: searchMsTotal
    }
  };
}

/** Build paved/dirt/access % from route segments (shared by single-pack + chain). */
function aggregateRouteSurfaceStats(segments, distanceMeters) {
  const bySurfaceM = Object.create(null);
  const byAccessM = Object.create(null);
  let unknownAccessMeters = 0;
  let dirtMeters = 0;
  let pavedMeters = 0;
  for (const seg of segments || []) {
    const meters = Number(seg.distanceMeters) || 0;
    if (!(meters > 0)) continue;
    const surfaceName = seg.surfaceClass || seg.trackClass || "unknown";
    const roadClassName = seg.trackClass || seg.roadClass || "unknown";
    const accessName = seg.accessClass || "motorized_unknown";
    bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + meters;
    if (isDirtSurface(surfaceName, roadClassName)) dirtMeters += meters;
    else pavedMeters += meters;
    byAccessM[accessName] = (byAccessM[accessName] || 0) + meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += meters;
  }
  const pct = (m) => (distanceMeters > 0 ? Math.round((m / distanceMeters) * 100) : 0);
  return {
    pavedPercent: pct(pavedMeters),
    gravelPercent: pct(bySurfaceM.gravel || 0),
    accessPercent: pct((bySurfaceM.access || 0) + (bySurfaceM.resource || 0)),
    trackPercent: pct((bySurfaceM.track || 0) + (bySurfaceM.double_track || 0)),
    singlePercent: pct(bySurfaceM.single || 0),
    unknownSurfacePercent: pct(bySurfaceM.unknown || 0),
    dirtPercent: pct(dirtMeters),
    unknownAccessPercent: pct(unknownAccessMeters),
    permissiveAccessPercent: pct(byAccessM.motorized_permissive || 0),
    verifiedAccessPercent: pct(byAccessM.motorized_verified || 0)
  };
}

function adventureSurfaceMeters(bySurfaceM) {
  const s = bySurfaceM || {};
  return (
    (s.gravel || 0) +
    (s.access || 0) +
    (s.resource || 0) +
    (s.track || 0) +
    (s.double_track || 0) +
    (s.unknown || 0) +
    (s.single || 0)
  );
}

/**
 * Balanced + Allow ON helper: keep the path whose dirt% is closer to 50.
 * Ties → shorter, then verified (Allow OFF). Either side may be null.
 */
function pickCloserToBalancedMix(pathVerified, pathWithUnknown) {
  if (pathVerified && pathWithUnknown) {
    const da = Math.abs((pathVerified.stats && pathVerified.stats.dirtPercent) - 50);
    const db = Math.abs((pathWithUnknown.stats && pathWithUnknown.stats.dirtPercent) - 50);
    if (da !== db) {
      return da < db
        ? { path: pathVerified, source: "verified" }
        : { path: pathWithUnknown, source: "unknown" };
    }
    const distA = pathVerified.distanceMeters || 0;
    const distB = pathWithUnknown.distanceMeters || 0;
    if (Math.abs(distA - distB) > 75) {
      return distA <= distB
        ? { path: pathVerified, source: "verified" }
        : { path: pathWithUnknown, source: "unknown" };
    }
    return { path: pathVerified, source: "verified" };
  }
  if (pathVerified) return { path: pathVerified, source: "verified" };
  if (pathWithUnknown) return { path: pathWithUnknown, source: "unknown" };
  return null;
}

async function routeOnRuntime(body, graphResolution, runtime) {
  const buildStarted = Date.now();
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

  const policy = normalizePolicy(body.accessPolicy, profile);
  const options = body.options || {};
  const matchMeters = Number(options.matchLimitMeters);
  // Default 250 m on dense/legacy packs. Longhaul / Vercel packs are thinned —
  // hub roads can sit ~300–500 m from a basemap click (e.g. Saint-Raymond).
  const HARD_MATCH_CAP_M = 750;
  if (Number.isFinite(matchMeters) && matchMeters > HARD_MATCH_CAP_M) {
    return {
      status: "error",
      error: "match_limit_too_large",
      message: "matchLimitMeters may not exceed " + HARD_MATCH_CAP_M
    };
  }
  const onVercel = !!(process.env.VERCEL || process.env.VERCEL_ENV);
  const longhaulGraph =
    onVercel ||
    !!(graphResolution &&
      (graphResolution.longhaulPacks ||
        String(graphResolution.mode || "").includes("longhaul") ||
        String(graphResolution.mode || "").includes("canada-chain")));
  const defaultMatch = longhaulGraph ? 500 : DEFAULT_MATCH_METERS;
  let limit = Number.isFinite(matchMeters) && matchMeters > 0
    ? matchMeters
    : defaultMatch;

  // Optional server-enforced avoidance (route incident recovery). Edge IDs are
  // excluded from snapping AND from graph traversal. This is never a browser
  // filter of a returned route — the alternate is computed without these edges.
  const avoidEdgeIds = new Set(
    (Array.isArray(options.avoidEdgeIds) ? options.avoidEdgeIds : [])
      .filter((id) => id != null)
      .map((id) => String(id))
  );
  const priorEdgeIds = new Set(
    (Array.isArray(options.priorEdgeIds) ? options.priorEdgeIds : [])
      .filter((id) => id != null)
      .map((id) => String(id))
  );
  const arrivalEdgeId = options.arrivalEdgeId == null
    ? null
    : String(options.arrivalEdgeId);
  const backtrackFactor = Number.isFinite(Number(options.backtrackFactor))
    ? Math.max(1, Number(options.backtrackFactor))
    : 4;

  const start = locations[0];
  const end = locations[locations.length - 1];
  // Canada-chain seam pins (already snapped onto fabric) may use a slightly
  // larger per-endpoint match than user pins — still ≤ HARD_MATCH_CAP_M.
  const chainSeamHop = !!options.chainSeamHop;
  const startLimit =
    chainSeamHop && isChainSeamLocation(start)
      ? Math.min(HARD_MATCH_CAP_M, Math.max(limit, SEAM_HOP_MATCH_M))
      : limit;
  const endLimit =
    chainSeamHop && isChainSeamLocation(end)
      ? Math.min(HARD_MATCH_CAP_M, Math.max(limit, SEAM_HOP_MATCH_M))
      : limit;
  let startMatch = matchPoint(
    runtime,
    start,
    policy,
    startLimit,
    avoidEdgeIds,
    null,
    profile,
    "start"
  );
  let endMatch = matchPoint(runtime, end, policy, endLimit, avoidEdgeIds, null, profile, "end");
  // Soft expand once within the hard cap: prefer snap-on-place over hard fail
  // when a road exists a bit beyond the default radius (thinned hubs / fat taps).
  // nearestMeters is null when the spatial index finds zero candidates inside
  // the first radius — still retry at the hard cap (QC hub coords / hinterland).
  if (!startMatch.ok && startLimit < HARD_MATCH_CAP_M) {
    const near = startMatch.nearestMeters;
    if (near == null || near <= HARD_MATCH_CAP_M) {
      const expanded = matchPoint(
        runtime,
        start,
        policy,
        HARD_MATCH_CAP_M,
        avoidEdgeIds,
        null,
        profile,
        "start"
      );
      if (expanded.ok) {
        startMatch = expanded;
        limit = HARD_MATCH_CAP_M;
      }
    }
  }
  if (!endMatch.ok && endLimit < HARD_MATCH_CAP_M) {
    const near = endMatch.nearestMeters;
    if (near == null || near <= HARD_MATCH_CAP_M) {
      const expanded = matchPoint(
        runtime,
        end,
        policy,
        HARD_MATCH_CAP_M,
        avoidEdgeIds,
        null,
        profile,
        "end"
      );
      if (expanded.ok) {
        endMatch = expanded;
        limit = HARD_MATCH_CAP_M;
      }
    }
  }
  // Reconcile disconnected snaps.
  // Longhaul / OSM-only: try end→start, then start→end, then both→giant.
  // PE cities often snap onto tiny service islands inside the match radius
  // while the highway giant sits ~30–90 m away — end→start alone fails when
  // start landed on a 2-edge driveway component.
  // Full packs: rematch the nongiant endpoint onto the giant so a purple
  // NSTDB island click still yields a connected route — without the hard
  // +400m bias that stole snaps from connected forest edges in-radius.
  if (
    startMatch.ok &&
    endMatch.ok &&
    startMatch.componentId != null &&
    endMatch.componentId != null &&
    startMatch.componentId >= 0 &&
    endMatch.componentId >= 0 &&
    startMatch.componentId !== endMatch.componentId
  ) {
    const giantId = giantComponentId(runtime);
    if (preferGiantComponentSnap(runtime)) {
      const endSame = matchPoint(
        runtime,
        end,
        policy,
        limit,
        avoidEdgeIds,
        startMatch.componentId,
        profile,
        "end"
      );
      if (endSame.ok && endSame.componentId === startMatch.componentId) {
        endMatch = endSame;
      } else {
        const startSame = matchPoint(
          runtime,
          start,
          policy,
          limit,
          avoidEdgeIds,
          endMatch.componentId,
          profile,
          "start"
        );
        if (startSame.ok && startSame.componentId === endMatch.componentId) {
          startMatch = startSame;
        } else if (giantId != null) {
          const startOnGiant = matchPoint(
            runtime,
            start,
            policy,
            limit,
            avoidEdgeIds,
            giantId,
            profile,
            "start"
          );
          const endOnGiant = matchPoint(
            runtime,
            end,
            policy,
            limit,
            avoidEdgeIds,
            giantId,
            profile,
            "end"
          );
          if (
            startOnGiant.ok &&
            endOnGiant.ok &&
            startOnGiant.componentId === giantId &&
            endOnGiant.componentId === giantId
          ) {
            startMatch = startOnGiant;
            endMatch = endOnGiant;
          }
        }
      }
    } else if (giantId != null) {
      if (endMatch.componentId === giantId && startMatch.componentId !== giantId) {
        const startOnGiant = matchPoint(
          runtime,
          start,
          policy,
          limit,
          avoidEdgeIds,
          giantId,
          profile,
          "start"
        );
        if (startOnGiant.ok && startOnGiant.componentId === giantId) {
          startMatch = startOnGiant;
        }
      } else if (startMatch.componentId === giantId && endMatch.componentId !== giantId) {
        const endOnGiant = matchPoint(
          runtime,
          end,
          policy,
          limit,
          avoidEdgeIds,
          giantId,
          profile,
          "end"
        );
        if (endOnGiant.ok && endOnGiant.componentId === giantId) {
          endMatch = endOnGiant;
        }
      } else if (
        startMatch.componentId !== giantId &&
        endMatch.componentId !== giantId
      ) {
        const startOnGiant = matchPoint(
          runtime,
          start,
          policy,
          limit,
          avoidEdgeIds,
          giantId,
          profile,
          "start"
        );
        const endOnGiant = matchPoint(
          runtime,
          end,
          policy,
          limit,
          avoidEdgeIds,
          giantId,
          profile,
          "end"
        );
        if (
          startOnGiant.ok &&
          endOnGiant.ok &&
          startOnGiant.componentId === giantId &&
          endOnGiant.componentId === giantId
        ) {
          startMatch = startOnGiant;
          endMatch = endOnGiant;
        }
      }
    }
  }

  // Snap selection is part of the routing contract. Log the final edge and
  // access class after component reconciliation so a device/server trace can
  // prove whether profiles started from the same eligible graph fabric.
  if (options.logSnap === true) {
    console.log(
      "route snap profile=" + profile +
      " startEdge=" + (startMatch.ok ? startMatch.edgeId : "none") +
      " startAccess=" + (startMatch.ok ? startMatch.accessClass : startMatch.reason) +
      " endEdge=" + (endMatch.ok ? endMatch.edgeId : "none") +
      " endAccess=" + (endMatch.ok ? endMatch.accessClass : endMatch.reason)
    );
  }

  if (!startMatch.ok || !endMatch.ok) {
    const noEligible = startMatch.reason === "snap_no_eligible_edge" ||
      endMatch.reason === "snap_no_eligible_edge";
    const failureReason = "snap_failure";
    return {
      status: "failed",
      profile,
      accessPolicy: policy,
      error: noEligible ? "snap_no_eligible_edge" : "match_failed",
      message: !startMatch.ok
        ? "No eligible edge within " + limit + " m of start"
        : "No eligible edge within " + limit + " m of destination",
      warnings: [{
        code: noEligible ? "snap_no_eligible_edge" : "match_failed",
        message: "Could not snap to an eligible graph edge. No free-space connector was created."
      }],
      debug: {
        startMatch,
        endMatch,
        matchLimitMeters: limit,
        fallback: null,
        failureReason,
        diagnostics: buildRouteDiagnostics({
          requestedProfile: profile,
          buildMs: Date.now() - buildStarted,
          searchMs: 0,
          attempts: [],
          failureReason,
          searchOutcome: "snap_failure"
        }),
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
    const failureReason = "disconnected";
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
        failureReason,
        diagnostics: buildRouteDiagnostics({
          requestedProfile: profile,
          buildMs: Date.now() - buildStarted,
          searchMs: 0,
          attempts: [],
          failureReason,
          searchOutcome: "disconnected_components"
        })
      },
      maneuvers: [],
      segments: [],
      geometry: [],
      distanceMeters: 0
    };
  }

  const searchStarted = Date.now();
  const searchOpts = {
    sessionSeed: Number(options.sessionSeed) || 0,
    priorEdgeIds: Array.from(priorEdgeIds),
    arrivalEdgeId,
    backtrackFactor
  };
  if (Number.isFinite(Number(options.maxPathMeters))) {
    searchOpts.maxPathMeters = Number(options.maxPathMeters);
  }
  if (Number.isFinite(Number(options.directExtraBudgetMeters))) {
    searchOpts.directExtraBudgetMeters = Number(options.directExtraBudgetMeters);
  }
  let path = null;
  let urbanCoreFallbackUsed = false;
  let cleanUnpavedFallbackUsed = false;
  let settlementFallbackUsed = false;
  let cleanSearchOutcome = null;
  let primarySearchOutcome = null;
  let lastSearchDiagnostics = null;
  if (profile === "cleanest") {
    const cleanFindOnce = (extra) => {
      const diagnostics = {};
      const found = findPath(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds,
        Object.assign({}, searchOpts, extra || {}, { diagnostics })
      );
      lastSearchDiagnostics = diagnostics;
      return {
        path: found,
        outcome: found ? "completed" : (diagnostics.outcome || "noPath"),
        pops: diagnostics.pops || (found && found.searchMeta && found.searchMeta.pops) || 0
      };
    };
    // Clean law: pavement through-edges, no corridor, no hard regression.
    // Soft forward fan lives in profile costs. Metro/motorway last-resort only
    // after proved noPath. Settlement towns are not walls.
    const cleanBase = {
      pavedOnly: true,
      costMode: "profile",
      variety: false,
      boundedSearch: true,
      corridorMeters: 0,
      hardCorridor: false,
      progressRegressionMeters: Number.MAX_SAFE_INTEGER,
      settlementWall: false,
      settlementFallback: false,
      cityWall: true,
      urbanCoreFallback: false,
      timeCapMs: CLEAN_PAVED_ATTEMPT_MS,
      deadlineAtMs: Date.now() + CLEAN_PAVED_ATTEMPT_MS
    };
    const paved = cleanFindOnce(cleanBase);
    if (paved.path) {
      path = paved.path;
      cleanSearchOutcome = "completed";
      path.searchMeta = path.searchMeta || {};
      path.searchMeta.corridorMeters = null;
      path.searchMeta.corridorWidened = false;
      path.searchMeta.rideObjective = "practical-pavement";
    } else {
      cleanSearchOutcome = paved.outcome || "noPath";
    }
    if (!path && cleanSearchOutcome === "noPath") {
      const unpaved = cleanFindOnce(Object.assign({}, cleanBase, {
        pavedOnly: false,
        timeCapMs: CLEAN_PAVED_ATTEMPT_MS * 2,
        deadlineAtMs: Date.now() + CLEAN_PAVED_ATTEMPT_MS * 2
      }));
      if (unpaved.path) {
        path = unpaved.path;
        cleanSearchOutcome = "completed";
        cleanUnpavedFallbackUsed = true;
        path.searchMeta = path.searchMeta || {};
        path.searchMeta.cleanUnpavedFallbackUsed = true;
        path.searchMeta.corridorMeters = null;
        path.searchMeta.rideObjective = "practical-pavement";
      } else {
        cleanSearchOutcome = unpaved.outcome || "noPath";
      }
    }
  } else {
    const diagnostics = {};
    const adventureSearchOpts = Object.assign({}, searchOpts, {
      // A settlement relaxation is a fallback, not a normal scoring mode.
      // findPathV2 may relax it only after every bounded attempt proves noPath.
      // Direct's hard promise is shortest graph path +15 km. Smaller mapped
      // settlements remain scored avoidance, but cannot be hard walls that
      // redefine the shortest reference underneath that distance budget.
      settlementWall: profile !== "direct",
      settlementFallback: profile === "direct",
      diagnostics
    });
    path = findPath(
      runtime, startMatch, endMatch, profile, policy, avoidEdgeIds,
      adventureSearchOpts
    );
    lastSearchDiagnostics = diagnostics;
    primarySearchOutcome = path ? "completed" : (diagnostics.outcome || "noPath");
    // A city wall may sever the only mountain-valley or border connection.
    // Only a proved no-path result (never a timeout/pop cap) may relax it, and
    // the relaxed search still charges the prohibitive urban-core multiplier.
    if (!path && diagnostics.outcome === "noPath") {
      const relaxedDiagnostics = {};
      path = findPath(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds,
        Object.assign({}, searchOpts, {
          cityWall: false,
          urbanCoreFallback: true,
          settlementWall: false,
          settlementFallback: true,
          diagnostics: relaxedDiagnostics
        })
      );
      lastSearchDiagnostics = relaxedDiagnostics;
      if (path) {
        urbanCoreFallbackUsed = true;
        path.searchMeta = path.searchMeta || {};
        path.searchMeta.urbanCoreFallbackUsed = true;
      }
    }
  }
  // Major urban cores / motorways: Clean may cross only after proved noPath.
  if (!path && profile === "cleanest" && cleanSearchOutcome === "noPath") {
    const cleanFindRelaxed = (extra) => {
      const diagnostics = {};
      const found = findPath(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds,
        Object.assign({}, searchOpts, extra, { diagnostics })
      );
      lastSearchDiagnostics = diagnostics;
      return {
        path: found,
        outcome: found ? "completed" : (diagnostics.outcome || "noPath"),
        pops: diagnostics.pops || (found && found.searchMeta && found.searchMeta.pops) || 0
      };
    };
    const relaxedBase = {
      cityWall: false,
      urbanCoreFallback: true,
      settlementWall: false,
      settlementFallback: false,
      costMode: "profile",
      variety: false,
      boundedSearch: true,
      corridorMeters: 0,
      hardCorridor: false,
      progressRegressionMeters: Number.MAX_SAFE_INTEGER,
      timeCapMs: CLEAN_PAVED_ATTEMPT_MS,
      deadlineAtMs: Date.now() + CLEAN_PAVED_ATTEMPT_MS
    };
    let attempt = cleanFindRelaxed(Object.assign({}, relaxedBase, { pavedOnly: true }));
    if (!attempt.path) {
      attempt = cleanFindRelaxed(Object.assign({}, relaxedBase, {
        pavedOnly: false,
        timeCapMs: CLEAN_PAVED_ATTEMPT_MS * 2,
        deadlineAtMs: Date.now() + CLEAN_PAVED_ATTEMPT_MS * 2
      }));
      if (attempt.path) cleanUnpavedFallbackUsed = true;
    }
    if (attempt.path) {
      path = attempt.path;
      cleanSearchOutcome = "completed";
      urbanCoreFallbackUsed = true;
      path.searchMeta = path.searchMeta || {};
      path.searchMeta.urbanCoreFallbackUsed = true;
      path.searchMeta.corridorMeters = null;
      path.searchMeta.rideObjective = "practical-pavement";
      if (cleanUnpavedFallbackUsed) path.searchMeta.cleanUnpavedFallbackUsed = true;
    } else {
      cleanSearchOutcome = attempt.outcome || "noPath";
    }
  }
  // Balanced + Allow ON: unknown dirt usually wins under normal surface weights and
  // blows past ~50/50. Also search Allow OFF (own snaps) and keep whichever mix is
  // closer to half dirt — even if that means discarding unknown entirely.
  let balancedMixChoice = null;
  if (path && profile === "balanced" && policy.motorizedUnknown) {
    const policyVerified = Object.assign({}, policy, { motorizedUnknown: false });
    const startVerified = matchPoint(
      runtime, start, policyVerified, limit, avoidEdgeIds, null, profile, "start"
    );
    const endVerified = matchPoint(
      runtime, end, policyVerified, limit, avoidEdgeIds, null, profile, "end"
    );
    let pathVerified = null;
    if (startVerified.ok && endVerified.ok) {
      pathVerified = findPath(
        runtime, startVerified, endVerified, profile, policyVerified, avoidEdgeIds, searchOpts
      );
    }
    const picked = pickCloserToBalancedMix(pathVerified, path);
    if (picked) {
      balancedMixChoice = picked.source;
      path = picked.path;
      if (picked.source === "verified") {
        startMatch = startVerified;
        endMatch = endVerified;
      }
    }
  }
  const searchMs = Date.now() - searchStarted;
  if (!path) {
    const failedOutcome = cleanSearchOutcome || primarySearchOutcome;
    const searchIncomplete = failedOutcome === "timeCap" || failedOutcome === "popCap";
    const attempts =
      (lastSearchDiagnostics && lastSearchDiagnostics.attempts) ||
      [];
    const failureReason = classifyRouteFailureReason({
      searchOutcome: failedOutcome,
      attempts
    });
    const diagnostics = buildRouteDiagnostics({
      requestedProfile: profile,
      buildMs: Date.now() - buildStarted,
      searchMs,
      attempts,
      searchMeta: {
        pops: Number(lastSearchDiagnostics && lastSearchDiagnostics.pops) || sumPops(attempts),
        corridorCandidates: attempts
      },
      failureReason,
      searchOutcome: failedOutcome
    });
    return {
      status: "failed",
      profile,
      accessPolicy: policy,
      error: "no_route",
      message: searchIncomplete
        ? "Clean search reached its safety limit before proving whether a route exists"
        : "No route on the eligible graph",
      warnings: [{
        code: searchIncomplete ? "search_limit" : "no_route",
        message: searchIncomplete
          ? "The urban-core wall stayed in force because the search did not prove that every wall-respecting option was exhausted. Try again or add an intermediate waypoint."
          : "Eligible edges do not connect start to destination under the current access policy."
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
        avoidedEdgeIds: Array.from(avoidEdgeIds),
        searchMs,
        fallback: null,
        searchOutcome: failedOutcome,
        failureReason,
        objective:
          profile === "dirt" ? "earned-dirt-detour" :
          profile === "balanced" ? "surface-balance" :
          profile === "direct" ? "crow-flies-adventure" : "clean-pavement",
        outcome: failedOutcome || "noPath",
        pops: diagnostics.pops,
        corridor: null,
        settlementFallback: false,
        fallbackReason: searchIncomplete ? "timeout" : "no_route",
        preFallbackDirtPct: null,
        preFallbackMeters: null,
        corridorClippedDirtMeters: 0,
        diagnostics
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
  if (urbanCoreFallbackUsed) {
    warnings.push({
      code: "urban_core_fallback",
      message: "No route could reach the destination while keeping every urban core as a wall. This Clean route uses an urban crossing only as a last resort."
    });
  }
  if (cleanUnpavedFallbackUsed) {
    warnings.push({
      code: "clean_unpaved_fallback",
      message: "No fully paved route could reach the destination while respecting the current routing walls. Clean used tagged unpaved road only as a last resort."
    });
  }
  if (settlementFallbackUsed || (path.searchMeta && path.searchMeta.settlementFallbackUsed)) {
    warnings.push({
      code: "settlement_fallback",
      message: "This route could not avoid every mapped town without losing its routing objective. Town travel remains strongly penalized and is used only where the alternatives are worse."
    });
  }
  if (startMatch.distanceM > 1 || endMatch.distanceM > 1) {
    warnings.push({
      code: "access_legs",
      message: "Start/end were snapped onto the graph. Access distances are reported separately and are not free-space connectors through unmapped land."
    });
  }
  if (avoidEdgeIds.size > 0) {
    const usedAvoided = path.segments.some((seg) => avoidEdgeIds.has(String(seg.edgeId)));
    warnings.push({
      code: "avoided_edges",
      message: avoidEdgeIds.size + " reported edge(s) were excluded from routing server-side.",
      avoidedEdgeIds: Array.from(avoidEdgeIds),
      containedAvoidedEdge: usedAvoided
    });
  }

  const selectedCorridor = Number(path.searchMeta && path.searchMeta.corridorMeters);
  const selectedDirtPct = Number(path.stats && path.stats.dirtPercent);
  const selectedMeters = Number(path.distanceMeters);
  const fallbackReason = fallbackReasonFor(
    path,
    urbanCoreFallbackUsed || settlementFallbackUsed || !!(path.searchMeta && path.searchMeta.settlementFallbackUsed),
    cleanSearchOutcome || primarySearchOutcome
  );
  const corridorClippedDirtMeters = clippedDirtMeters(
    runtime,
    startMatch.coord,
    endMatch.coord,
    Number.isFinite(selectedCorridor) ? selectedCorridor : 0,
    policy
  );
  const lowDirt = isLowDirtRoute(profile, path);
  const balancedMiss = profile === "balanced"
    ? Number(path.searchMeta && path.searchMeta.balancedMiss) || 0
    : null;
  const backtrack = backtrackSummary(path, priorEdgeIds);
  const restricted = restrictedSummary(path);
  const attemptRows =
    (path.searchMeta && path.searchMeta.corridorCandidates) ||
    (lastSearchDiagnostics && lastSearchDiagnostics.attempts) ||
    [];
  const routeDiagnostics = buildRouteDiagnostics({
    requestedProfile: profile,
    buildMs: Date.now() - buildStarted,
    searchMs,
    attempts: attemptRows,
    searchMeta: path.searchMeta || {},
    backtrackPct: backtrack.backtrackPct,
    urbanCoreFallbackUsed,
    cleanUnpavedFallbackUsed,
    settlementFallbackUsed:
      settlementFallbackUsed || !!(path.searchMeta && path.searchMeta.settlementFallbackUsed),
    searchOutcome: "completed"
  });

  return {
    status: "complete",
    routeId: "route-" + Date.now().toString(36),
    profile,
    lowDirt,
    balancedMiss,
    vehicle: body.vehicle || "dual-sport-motorcycle",
    accessPolicy: policy,
    geometry: path.geometry,
    distanceMeters: Math.round(path.distanceMeters),
    ...backtrack,
    ...restricted,
    estimatedMovingSeconds: Math.round(path.movingSeconds),
    estimatedElapsedSeconds: Math.round(path.movingSeconds * 1.15),
    stats: path.stats,
    segments: path.segments,
    maneuvers: buildManeuvers(path.geometry),
    warnings,
    debug: {
      routingRevision: "ride-objectives-v9-settlement-gated",
      startMatchedEdge: startMatch.edgeId,
      endMatchedEdge: endMatch.edgeId,
      startAccessMeters: Math.round(startMatch.distanceM),
      endAccessMeters: Math.round(endMatch.distanceM),
      startAccessClass: startMatch.accessClass,
      endAccessClass: endMatch.accessClass,
      componentId: startMatch.componentId,
      matchLimitMeters: limit,
      avoidedEdgeIds: Array.from(avoidEdgeIds),
      engine: path.searchMeta && path.searchMeta.bidir ? "dirt-node-bidir-astar" : "dirt-node-astar",
      searchMs,
      profileCost: path.profileCost,
      searchMeta: path.searchMeta || null,
      balancedMixChoice,
      balancedMiss,
      fallback: urbanCoreFallbackUsed ? "urban_core_last_resort" : null,
      objective: path.searchMeta && path.searchMeta.rideObjective || (
        profile === "dirt" ? "earned-dirt-detour" :
        profile === "balanced" ? "surface-balance" :
        profile === "direct" ? "crow-flies-adventure" : "clean-pavement"
      ),
      outcome: "completed",
      pops: Number(path.searchMeta && path.searchMeta.pops) || 0,
      corridor: Number.isFinite(selectedCorridor) ? selectedCorridor : null,
      settlementFallback: !!(settlementFallbackUsed || (path.searchMeta && path.searchMeta.settlementFallbackUsed)),
      fallbackReason,
      lowDirt,
      preFallbackDirtPct: urbanCoreFallbackUsed
        ? null
        : (Number.isFinite(selectedDirtPct) ? selectedDirtPct : null),
      preFallbackMeters: urbanCoreFallbackUsed
        ? null
        : (Number.isFinite(selectedMeters) ? Math.round(selectedMeters) : null),
      corridorClippedDirtMeters,
      diagnostics: routeDiagnostics,
      regionIds: graphResolution.regionIds,
      graphMode: graphResolution.mode,
      packIdentity: runtime.packIdentity || [],
      merge: runtime.mergeReport || null,
      graph: {
        edgeCount: runtime.data.edgeCount,
        nodeCount: runtime.data.nodeCount,
        loadMs: runtime.loadMs,
        regionId: runtime.data.regionId || null,
        province: runtime.data.province || null,
        schemaVersion: runtime.data.schemaVersion || null
      }
    }
  };
}

function findPath(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, searchOpts) {
  if (runtime.format === "v2") {
    return findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, undefined, searchOpts);
  }
  const { data, adjacency, enums } = runtime;
  const edges = data.edges;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
  const geom = runtime.geom || null;
  const prior = new Set(((searchOpts && searchOpts.priorEdgeIds) || []).map(String));
  const arrival = searchOpts && searchOpts.arrivalEdgeId != null
    ? String(searchOpts.arrivalEdgeId)
    : null;
  const backtrackFactor = Number.isFinite(Number(searchOpts && searchOpts.backtrackFactor))
    ? Math.max(1, Number(searchOpts.backtrackFactor))
    : 4;

  function withBacktrackPenalty(cost, edgeId) {
    const id = String(edgeId == null ? "" : edgeId);
    if (arrival != null && id === arrival) return cost * 12;
    if (prior.has(id)) return cost * backtrackFactor;
    return cost;
  }

  function resolveEdgeCoords(edge) {
    if (edge.coords && edge.coords.length) return edge.coords;
    if (edge._ei == null) return [];
    const forward = edge.forward !== false;
    if (geom) return geom.polylineMaybeReversed(edge._ei, forward);
    const raw = edges[edge._ei].g || [];
    return forward ? raw : raw.slice().reverse();
  }
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
        forward: false,
        coords: meta.coords ? meta.coords.slice().reverse() : null
      }
    });
  }

  function edgePolyline(edgeIndex) {
    if (geom) return geom.polyline(edgeIndex);
    return edges[edgeIndex].g;
  }

  function attach(node, match) {
    const edge = edges[match.edgeIndex];
    const full = edgePolyline(match.edgeIndex);
    const edgeView = { ...edge, g: full, _ei: match.edgeIndex };
    const toA = coordsFromAToMatch(edgeView, match);
    const toB = coordsFromMatchToB(edgeView, match);
    // Use match distanceAlong for costs so float32 sidecar geom cannot drift profileCost.
    const mA = Math.max(0, Number(match.distanceAlongM) || lineMeters(toA));
    const mB = Math.max(0, (Number(match.edgeMeters) || edge.m) - mA);
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
      accessLeg: true,
      forward: true
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
      accessLeg: true,
      forward: true
    });
  }

  attach(startNode, startMatch);
  attach(endNode, endMatch);
  if (startMatch.edgeIndex === endMatch.edgeIndex) {
    const edge = edges[startMatch.edgeIndex];
    const edgeView = { ...edge, g: edgePolyline(startMatch.edgeIndex), _ei: startMatch.edgeIndex };
    const coords = coordsBetweenMatches(edgeView, startMatch, endMatch);
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
      accessLeg: false,
      forward: true
    });
  }

  // Packed edges are undirected in adjacency. Reverse relaxation uses the same
  // profile cost as forward (rev 2.1). One-way direction is not packed yet.
  // Stage 2: do not copy/reverse polylines here; only numeric cost fields.
  function neighbors(node) {
    const out = [];
    if (node < n) {
      for (const idx of adjacency[node]) {
        const edge = edges[idx];
        if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
        if (avoid && avoid.has(String(edge.i))) continue;
        const other = edge.a === node ? edge.b : edge.a;
        const forward = edge.a === node;
        out.push({
          to: other,
          edge: {
            a: node,
            b: other,
            meters: edge.m,
            surface: edge.s,
            access: edge.ac,
            structure: edge.t,
            roadTrack: edge.rt || "unknown",
            edgeId: edge.i,
            componentId: edge.c,
            source: edge.src,
            sourceDescription: edge.desc,
            sourceRecordId: edge.rid,
            confidence: edge.conf,
            seasonal: edge.seasonal,
            virtual: false,
            accessLeg: false,
            forward,
            _ei: idx,
            coords: null
          }
        });
      }
    }
    for (const item of virtualAdj.get(node) || []) out.push(item);
    return out;
  }

  function resolveEdgeCoords(edge) {
    if (edge.coords && edge.coords.length) return edge.coords;
    if (edge._ei == null) return [];
    const forward = edge.forward !== false;
    if (geom) return geom.polylineMaybeReversed(edge._ei, forward);
    const raw = edges[edge._ei].g || [];
    return forward ? raw : raw.slice().reverse();
  }

  const nodeCoord = new Array(total);
  if (runtime.pack && runtime.pack.nodeCoords) {
    const nc = runtime.pack.nodeCoords;
    for (let i = 0; i < n; i += 1) {
      nodeCoord[i] = [nc[i * 2], nc[i * 2 + 1]];
    }
  } else {
    for (let i = 0; i < n; i += 1) {
      const idxs = adjacency[i];
      if (!idxs || !idxs.length) continue;
      const edge = edges[idxs[0]];
      const g = edge.g || (geom ? geom.polyline(idxs[0]) : null);
      if (!g || !g.length) continue;
      nodeCoord[i] = edge.a === i ? g[0] : g[g.length - 1];
    }
  }
  nodeCoord[startNode] = startMatch.coord;
  nodeCoord[endNode] = endMatch.coord;

  const startLL = startMatch.coord;
  const endLL = endMatch.coord;
  const abMeters = haversineMeters(startLL, endLL);
  const startOnMajorHighway = pinMatchesMajorHighway(startMatch);
  const endOnMajorHighway = pinMatchesMajorHighway(endMatch);
  const regionId =
    (runtime.pack && (runtime.pack.regionId || runtime.pack.province)) ||
    (runtime.data && (runtime.data.regionId || runtime.data.province)) ||
    (runtime.meta && (runtime.meta.regionId || runtime.meta.province)) ||
    "";
  const maxMult = maxSurfaceMultiplier(profile, regionId);
  const useBidir = bidirAstarEnabled();

  // Soft-stitch motorized_unknown islands (NSTDB / provincial capillary) when
  // Allow is on. Conflation leaves purple fabric as near-touching components;
  // without stitches Direct/Dirt keep a paved spine and only nibble dirt spurs.
  //
  // Hard rule: NEVER span a gap from a dead-end track to another dead-end track
  // (island↔island tip stitches invented gray connectors / Sackville loops).
  // Only island → through giant (degree ≥ 2) near-touch joins are allowed.
  // Gaps remain real meters (access legs), not free-space teleports.
  // Cleanest stays on the giant pavement fabric — no stitches.
  let softStitchCount = 0;
  if (policy.motorizedUnknown && profile !== "cleanest" && !geom) {
    const STITCH_M = 100;
    const padDeg = Math.max(0.04, (abMeters / 111320) * 0.35);
    const minLon = Math.min(startLL[0], endLL[0]) - padDeg;
    const maxLon = Math.max(startLL[0], endLL[0]) + padDeg;
    const minLat = Math.min(startLL[1], endLL[1]) - padDeg;
    const maxLat = Math.max(startLL[1], endLL[1]) + padDeg;
    const CELL = 0.0005; // ~55 m
    const giantGrid = new Map();
    function gridKey(lon, lat) {
      return Math.floor(lon / CELL) + ":" + Math.floor(lat / CELL);
    }
    function remember(grid, node) {
      const ll = nodeCoord[node];
      if (!ll) return;
      if (ll[0] < minLon || ll[0] > maxLon || ll[1] < minLat || ll[1] > maxLat) return;
      const key = gridKey(ll[0], ll[1]);
      let bucket = grid.get(key);
      if (!bucket) {
        bucket = [];
        grid.set(key, bucket);
      }
      bucket.push(node);
    }
    // Degree among currently searchable edges — dead-end = degree 1.
    const degree = new Int32Array(n);
    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i];
      if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
      if (edge.a < n) degree[edge.a] += 1;
      if (edge.b < n) degree[edge.b] += 1;
    }
    const islandNodes = new Set();
    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i];
      const mid = edge.g && edge.g[Math.floor(edge.g.length / 2)];
      if (
        mid &&
        (mid[0] < minLon || mid[0] > maxLon || mid[1] < minLat || mid[1] > maxLat)
      ) {
        continue;
      }
      if (edge.c === 0) {
        // Through giant only — never soft-land on a pavement stub tip.
        if (degree[edge.a] >= 2) remember(giantGrid, edge.a);
        if (degree[edge.b] >= 2) remember(giantGrid, edge.b);
        continue;
      }
      if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
      const accessName = enums.ACCESS_NAME[edge.ac] || "";
      if (accessName !== "motorized_unknown") continue;
      islandNodes.add(edge.a);
      islandNodes.add(edge.b);
    }
    const stitchSeen = new Set();
    function nearestThroughGiant(ll, excludeNode) {
      if (!ll) return null;
      const cx = Math.floor(ll[0] / CELL);
      const cy = Math.floor(ll[1] / CELL);
      let best = null;
      let bestD = STITCH_M + 1;
      for (let dx = -2; dx <= 2; dx += 1) {
        for (let dy = -2; dy <= 2; dy += 1) {
          const bucket = giantGrid.get(cx + dx + ":" + (cy + dy));
          if (!bucket) continue;
          for (const gn of bucket) {
            if (gn === excludeNode) continue;
            if (degree[gn] < 2) continue;
            const gl = nodeCoord[gn];
            if (!gl) continue;
            // Do not soft-stitch capillary into major town cores (unless pin is there).
            if (
              pointInAdventureUrbanCore(gl[0], gl[1]) &&
              haversineMeters(gl, startLL) > 2500 &&
              haversineMeters(gl, endLL) > 2500
            ) {
              continue;
            }
            const d = haversineMeters(ll, gl);
            if (d < bestD && d > 0.5) {
              bestD = d;
              best = gn;
            }
          }
        }
      }
      return best != null && bestD <= STITCH_M ? { node: best, meters: bestD } : null;
    }
    function addStitch(aNode, bNode, meters) {
      // Hard ban: dead-end ↔ dead-end gap span (any length).
      if (degree[aNode] <= 1 && degree[bNode] <= 1) return;
      const a = Math.min(aNode, bNode);
      const b = Math.max(aNode, bNode);
      const key = a + ":" + b;
      if (stitchSeen.has(key)) return;
      stitchSeen.add(key);
      const ga = nodeCoord[aNode];
      const gb = nodeCoord[bNode];
      addVirt(aNode, bNode, {
        a: aNode,
        b: bNode,
        coords: ga && gb ? [ga, gb] : null,
        meters: Math.max(1, meters),
        surface: 3,
        access: 2,
        structure: 0,
        roadTrack: "track",
        edgeId: "soft-stitch-" + key,
        componentId: -1,
        source: "soft-stitch",
        sourceDescription: "Near-touch capillary stitch",
        sourceRecordId: key,
        confidence: "low",
        seasonal: false,
        virtual: true,
        accessLeg: true,
        softStitch: true,
        forward: true
      });
      softStitchCount += 1;
    }
    for (const islandNode of islandNodes) {
      const ll = nodeCoord[islandNode];
      if (!ll) continue;
      const toGiant = nearestThroughGiant(ll, islandNode);
      if (toGiant) addStitch(islandNode, toGiant.node, toGiant.meters);
      // Intentionally no island↔island stitches — those spanned dead-end gaps.
    }
  }

  // Permissive junction near-miss repair when Allow is OFF (all profiles).
  // Legacy NS-style overlay packs carry OSM and NSTDB as co-mapped fabrics that only share
  // node ids where conflation found exact shared vertices. Legal public roads
  // (OSM unclassified/residential, NSTDB paved/gravel locals) are often left
  // as dangling tips 0–40 m from the through network. With Allow ON the
  // motorized_unknown capillary bridges those gaps, but with Allow OFF whole
  // permissive roads became unreachable → silent no_route (Farm Road,
  // Heatherton NS). Join permissive dead-end tips to the nearest eligible
  // node within 40 m. Tip↔tip IS allowed here (unlike the unknown soft-stitch
  // above): a mapped public road ending metres from another mapped public
  // road is a junction miss, not a gray connector across unmapped land.
  // Meters stay real and stitches still pay the last-resort premium.
  // NS field: OSM service tips can sit ~130 m apart with no shared node while
  // NSTDB purple is the only topological bridge — Allow OFF must still join
  // white-to-white without opening unknown capillary.
  let permStitchCount = 0;
  if (!policy.motorizedUnknown && !geom) {
    const JOIN_M = 150;
    const padDeg = Math.max(0.04, (abMeters / 111320) * 0.35);
    const minLon = Math.min(startLL[0], endLL[0]) - padDeg;
    const maxLon = Math.max(startLL[0], endLL[0]) + padDeg;
    const minLat = Math.min(startLL[1], endLL[1]) - padDeg;
    const maxLat = Math.max(startLL[1], endLL[1]) + padDeg;
    const CELL = 0.0005; // ~55 m cells
    // JOIN_M 150 m needs a 3-ring (~165 m) — one-ring only covered ~110 m and
    // missed real OSM tip gaps (~130 m) that purple used to paper over.
    const CELL_RING = Math.max(1, Math.ceil(JOIN_M / 55) + 1);
    const degree = new Int32Array(n);
    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i];
      if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
      if (edge.a < n) degree[edge.a] += 1;
      if (edge.b < n) degree[edge.b] += 1;
    }
    const grid = new Map();
    const eligibleSeen = new Set();
    const tips = [];
    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i];
      if (!accessAllowed(edge.ac, policy, enums, edge)) continue;
      for (const nodeId of [edge.a, edge.b]) {
        if (nodeId >= n || eligibleSeen.has(nodeId)) continue;
        const ll = nodeCoord[nodeId];
        if (!ll || ll[0] < minLon || ll[0] > maxLon || ll[1] < minLat || ll[1] > maxLat) continue;
        eligibleSeen.add(nodeId);
        const key = Math.floor(ll[0] / CELL) + ":" + Math.floor(ll[1] / CELL);
        let bucket = grid.get(key);
        if (!bucket) {
          bucket = [];
          grid.set(key, bucket);
        }
        bucket.push(nodeId);
        if (degree[nodeId] === 1) tips.push(nodeId);
      }
    }
    // Long A→B corridors collect thousands of tips; cap would skip the pin-local
    // OSM near-miss (house driveway islands). Prefer tips near start/end first.
    tips.sort((a, b) => {
      const la = nodeCoord[a];
      const lb = nodeCoord[b];
      const da = Math.min(haversineMeters(la, startLL), haversineMeters(la, endLL));
      const db = Math.min(haversineMeters(lb, startLL), haversineMeters(lb, endLL));
      return da - db;
    });
    const MAX_PERM_STITCHES = 4000;
    const permSeen = new Set();
    for (const tip of tips) {
      if (permStitchCount >= MAX_PERM_STITCHES) break;
      const ll = nodeCoord[tip];
      // Never re-join the tip to its own edge's far endpoint.
      const direct = new Set();
      for (const idx of adjacency[tip] || []) {
        const edge = edges[idx];
        direct.add(edge.a === tip ? edge.b : edge.a);
      }
      const cx = Math.floor(ll[0] / CELL);
      const cy = Math.floor(ll[1] / CELL);
      let best = null;
      let bestD = JOIN_M + 1;
      for (let dx = -CELL_RING; dx <= CELL_RING; dx += 1) {
        for (let dy = -CELL_RING; dy <= CELL_RING; dy += 1) {
          for (const cand of grid.get(cx + dx + ":" + (cy + dy)) || []) {
            if (cand === tip || direct.has(cand)) continue;
            const cll = nodeCoord[cand];
            if (!cll) continue;
            const d = haversineMeters(ll, cll);
            if (d < bestD) {
              bestD = d;
              best = cand;
            }
          }
        }
      }
      if (best == null || bestD > JOIN_M) continue;
      const key = Math.min(tip, best) + ":" + Math.max(tip, best);
      if (permSeen.has(key)) continue;
      permSeen.add(key);
      addVirt(tip, best, {
        a: tip,
        b: best,
        coords: [ll, nodeCoord[best]],
        meters: Math.max(1, bestD),
        surface: 4,
        access: 1,
        structure: 0,
        roadTrack: "local",
        edgeId: "perm-stitch-" + key,
        componentId: -1,
        source: "perm-stitch",
        sourceDescription: "Mapped-road junction near-miss join",
        sourceRecordId: key,
        confidence: "low",
        seasonal: false,
        virtual: true,
        accessLeg: true,
        softStitch: true,
        forward: true
      });
      permStitchCount += 1;
    }
  }

  function insideEllipse(node, factor) {
    if (!Number.isFinite(factor) || factor === Infinity) return true;
    const ll = nodeCoord[node];
    if (!ll) return true;
    return haversineMeters(startLL, ll) + haversineMeters(ll, endLL) <= factor * abMeters * 1.0000001;
  }

  function urbanAvoidMult(ll) {
    if (!ll) return 1;
    if (!pointInAdventureUrbanCore(ll[0], ll[1])) return 1;
    // Waypoint / pin in the core: allow flow through that city.
    if (haversineMeters(ll, startLL) < 2500 || haversineMeters(ll, endLL) < 2500) return 1;
    // Strong enough that trunk/primary through a core loses to a ring/highway
    // or a dirt bypass. Finite so unavoidable bridges still work.
    if (profile === "cleanest") return 4.0;
    if (profile === "dirt") return 5.5;
    if (profile === "balanced") return 4.8;
    return 4.4; // direct — dirt fabric, still skip downtown unless the pin is there
  }

  function edgeStepCost(edge, fromNode, toNode) {
    if (edge.accessLeg) {
      // Soft-stitch / pin access: real meters, but Direct still pays for
      // walking away from the goal near B (no free dirt-tourism connectors).
      // Soft-stitches pay a steep premium so they are connectivity last-resort,
      // not gray shortcuts across unmapped land.
      let accessCost = (edge.meters / 1000) * (edge.softStitch ? 12 : 1);
      if (
        fromNode != null &&
        toNode != null &&
        nodeCoord[fromNode] &&
        nodeCoord[toNode] &&
        profile !== "cleanest"
      ) {
        const dFrom = haversineMeters(nodeCoord[fromNode], endLL);
        const dTo = haversineMeters(nodeCoord[toNode], endLL);
        // Dirt uses graduated near-B clamp; Direct/Balanced keep legacy band.
        const minAway = profile === "dirt" ? 50 : 60;
        accessCost += approachAwayExtraCost(profile, dFrom, dTo, abMeters, minAway, regionId);
        const mid = [
          (nodeCoord[fromNode][0] + nodeCoord[toNode][0]) / 2,
          (nodeCoord[fromNode][1] + nodeCoord[toNode][1]) / 2
        ];
        accessCost *= urbanAvoidMult(mid);
      }
      return withBacktrackPenalty(accessCost, edge.edgeId);
    }
    const surfaceMult = surfaceMultiplier(edge.surface, profile, enums);
    const classMult = roadClassMultiplier(edge.roadTrack, profile);
    let cost = (edge.meters / 1000) * surfaceMult * classMult;
    if (fromNode != null && toNode != null && nodeCoord[toNode]) {
      const dToPin = haversineMeters(nodeCoord[toNode], endLL);
      const dFromStart = haversineMeters(nodeCoord[toNode], startLL);
      cost *= majorHighwayAvoidMult(
        profile,
        edge.roadTrack,
        dFromStart,
        dToPin,
        startOnMajorHighway,
        endOnMajorHighway
      );
      cost *= cleanCityStreetMult(profile, edge.roadTrack, dToPin);
    } else {
      cost *= majorHighwayAvoidMult(
        profile,
        edge.roadTrack,
        1e9,
        1e9,
        false,
        false
      );
    }
    // When the rider opts into unknown access, Direct/Dirt prefer capillary
    // over paved spine. Direct stays on-line via away-tax, not via a paved table.
    // Balanced deliberately does NOT get that discount: Allow only unlocks the
    // edges so they can compete; the normal ~50/50 surface weights still decide.
    // (An earlier ×0.72/×0.78 Balanced pull blew mix routes to ~85% dirt.)
    if (policy.motorizedUnknown && profile !== "cleanest") {
      const accessName = enums.ACCESS_NAME[edge.access] || "";
      if (accessName === "motorized_unknown") {
        if (profile === "dirt" || profile === "direct") cost *= 0.5;
      }
      const id = String(edge.edgeId || "");
      const src = String(edge.source || "");
      // Provincial capillary parity: NSTDB and NB Forest Roads (not OSM alone).
      if (
        id.startsWith("ns-") ||
        id.startsWith("nb-fr") ||
        /nstdb|Topographic|Forest Roads/i.test(src)
      ) {
        if (profile === "dirt" || profile === "direct") cost *= 0.68;
      }
    }
    // Adventure: avoid major city/town cores unless pin is there or unavoidable.
    if (fromNode != null && toNode != null && nodeCoord[fromNode] && nodeCoord[toNode]) {
      const mid = [
        (nodeCoord[fromNode][0] + nodeCoord[toNode][0]) / 2,
        (nodeCoord[fromNode][1] + nodeCoord[toNode][1]) / 2
      ];
      cost *= urbanAvoidMult(mid);
    } else if (edge.g && edge.g.length) {
      const mid = edge.g[Math.floor(edge.g.length / 2)];
      if (mid) cost *= urbanAvoidMult(mid);
    }
    // Approach-to-goal: penalize edges that increase distance to B.
    // Dirt: hunt mid-route; small arrival clamp in the last ~2.5 km of B.
    // Direct: dirt fabric, hold the line. Balanced: milder mix. Clean: pavement.
    if (fromNode != null && toNode != null && nodeCoord[fromNode] && nodeCoord[toNode]) {
      const dFrom = haversineMeters(nodeCoord[fromNode], endLL);
      const dTo = haversineMeters(nodeCoord[toNode], endLL);
      cost += approachAwayExtraCost(profile, dFrom, dTo, abMeters, 50, regionId);
    }
    return withBacktrackPenalty(cost, edge.edgeId);
  }

  function materializeUsed(used, searchMeta) {
    // Strip geographic out-and-backs / house loops for every profile. A
    // motorcycle turnaround on a dead spur is bad in Direct and Dirt alike —
    // Dirt still prefers adventure surface during search; pruning only removes
    // non-advancing loops after the path is chosen.
    const pruned = pruneGeographicLoops(used, resolveEdgeCoords);
    used = pruned.edges;
    searchMeta.prunedLoopCount = pruned.prunedLoopCount;
    searchMeta.prunedLoopMeters = Math.round(pruned.prunedMeters);
    const geometry = [];
    const segments = [];
    let distanceMeters = 0;
    let unknownAccessMeters = 0;
    let movingSeconds = 0;
    let profileCost = 0;
    const bySurfaceM = { paved: 0, gravel: 0, access: 0, track: 0, unknown: 0, single: 0 };
    const byAccessM = {
      motorized_verified: 0,
      motorized_permissive: 0,
      motorized_unknown: 0
    };

    for (const edge of used) {
      const coords = resolveEdgeCoords(edge);
      for (const c of coords) {
        const last = geometry[geometry.length - 1];
        if (last && last[0] === c[0] && last[1] === c[1]) continue;
        geometry.push(c);
      }
      const meters = edge.meters;
      distanceMeters += meters;
      profileCost += edgeStepCost(edge, null, null);
      const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
      const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
      bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + meters;
      if (byAccessM[accessName] != null) byAccessM[accessName] += meters;
      if (accessName === "motorized_unknown") unknownAccessMeters += meters;
      movingSeconds += (meters / 1000) / classSpeedKmh(edge.surface, enums) * 3600;

      segments.push({
        edgeId: edge.edgeId,
        surfaceClass: surfaceName,
        trackClass: edge.roadTrack || "unknown",
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
        geometry: coords
      });
    }

    const trimmedGeom = trimDestinationOvershoot(geometry, endLL);
    if (trimmedGeom !== geometry && trimmedGeom.length < geometry.length) {
      // Geometry-only safety trim when search still overshoots; keep segment
      // honesty for stats but report path length from trimmed line.
      distanceMeters = lineMeters(trimmedGeom);
      geometry.length = 0;
      for (const c of trimmedGeom) geometry.push(c);
    }

    // Dirt share = same adventure set the map paints blue/gray/purple.
    const stats = aggregateRouteSurfaceStats(segments, distanceMeters);
    return {
      geometry,
      segments,
      distanceMeters,
      unknownAccessMeters,
      movingSeconds,
      profileCost,
      searchMeta,
      stats
    };
  }

  function searchUnidirectional(ellipseFactor) {
    const dist = new Float64Array(total);
    dist.fill(Infinity);
    const prevNode = new Int32Array(total);
    prevNode.fill(-1);
    const prevEdge = new Array(total);
    const heap = new MinHeap();
    dist[startNode] = 0;
    // Default path stays Dijkstra (heap key = g). Heuristic is Stage 1a bidir only.
    heap.push({ node: startNode, cost: 0 });

    while (heap.items.length) {
      const cur = heap.pop();
      if (!cur || cur.cost !== dist[cur.node]) continue;
      if (cur.node === endNode) break;
      if (!insideEllipse(cur.node, ellipseFactor)) continue;
      for (const next of neighbors(cur.node)) {
        if (!insideEllipse(next.to, ellipseFactor)) continue;
        const cost = cur.cost + edgeStepCost(next.edge, cur.node, next.to);
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
    return { used, profileCost: dist[endNode] };
  }

  /**
   * Bidirectional Dijkstra (flag name ROUTING_BIDIR_ASTAR retained).
   * Forward from start, reverse from end. Heap ordered by g.
   * Do not stop at first frontier contact. Terminate only when the best known
   * meeting cost is provably minimal (peekFwd.g + peekRev.g >= mu).
   * Undirected edges: reverse uses the same profile cost as forward.
   */
  function searchBidirectional(ellipseFactor) {
    const distF = new Float64Array(total);
    const distR = new Float64Array(total);
    distF.fill(Infinity);
    distR.fill(Infinity);
    const prevF = new Int32Array(total);
    const prevR = new Int32Array(total);
    prevF.fill(-1);
    prevR.fill(-1);
    const edgeF = new Array(total);
    const edgeR = new Array(total);
    const closedF = new Uint8Array(total);
    const closedR = new Uint8Array(total);
    const heapF = new MinHeap();
    const heapR = new MinHeap();

    distF[startNode] = 0;
    distR[endNode] = 0;
    // Heap ordered by g (bidirectional Dijkstra). Correct mu termination requires
    // peek().g to be the true frontier minimum g; f-ordering breaks that.
    heapF.push({ node: startNode, g: 0, cost: 0 });
    heapR.push({ node: endNode, g: 0, cost: 0 });

    let mu = Infinity;
    let meet = -1;

    function considerMeet(node) {
      if (!Number.isFinite(distF[node]) || !Number.isFinite(distR[node])) return;
      const totalCost = distF[node] + distR[node];
      if (totalCost < mu) {
        mu = totalCost;
        meet = node;
      }
    }

    function relaxSide(forward) {
      const heap = forward ? heapF : heapR;
      const dist = forward ? distF : distR;
      const prev = forward ? prevF : prevR;
      const prevEdgeArr = forward ? edgeF : edgeR;
      const closed = forward ? closedF : closedR;

      const cur = heap.pop();
      if (!cur || cur.g !== dist[cur.node]) return;
      if (closed[cur.node]) return;
      closed[cur.node] = 1;
      considerMeet(cur.node);

      if (!insideEllipse(cur.node, ellipseFactor)) return;

      for (const next of neighbors(cur.node)) {
        if (!insideEllipse(next.to, ellipseFactor)) continue;
        const g = cur.g + edgeStepCost(next.edge, cur.node, next.to);
        if (g < dist[next.to]) {
          dist[next.to] = g;
          prev[next.to] = cur.node;
          prevEdgeArr[next.to] = next.edge;
          heap.push({ node: next.to, g, cost: g });
          considerMeet(next.to);
        }
      }
    }

    while (heapF.items.length && heapR.items.length) {
      const topF = heapF.peek();
      const topR = heapR.peek();
      if (!topF || !topR) break;
      if (Number.isFinite(mu) && topF.g + topR.g >= mu) break;

      if (heapF.items.length <= heapR.items.length) relaxSide(true);
      else relaxSide(false);
    }

    // Final scan in case a better meeting node was only partially settled.
    for (let i = 0; i < total; i += 1) considerMeet(i);

    if (!Number.isFinite(mu) || meet < 0) return null;

    const used = [];
    for (let node = meet; node !== startNode;) {
      const edge = edgeF[node];
      if (!edge) return null;
      used.push(edge);
      node = prevF[node];
    }
    used.reverse();

    for (let node = meet; node !== endNode;) {
      const edge = edgeR[node];
      if (!edge) return null;
      used.push(flipEdge(edge));
      node = prevR[node];
    }

    return { used, profileCost: mu };
  }

  const attempts = ellipseAttemptsForProfile(profile, regionId);
  let chosen = null;
  let chosenAttempt = null;
  const sanityBaseKm = Math.max(abMeters / 1000, 0.001);

  for (const attempt of attempts) {
    const raw = useBidir
      ? searchBidirectional(attempt.factor)
      : searchUnidirectional(attempt.factor);
    if (!raw) continue;

    const sanity =
      Number.isFinite(attempt.factor) && attempt.factor !== Infinity
        ? attempt.factor * sanityBaseKm * maxMult * 2.5
        : Infinity;
    if (Number.isFinite(sanity) && raw.profileCost > sanity) {
      continue;
    }

    chosen = raw;
    chosenAttempt = attempt;
    break;
  }

  if (!chosen) return null;

  return materializeUsed(chosen.used, {
    bidir: useBidir,
    ellipseFactor: chosenAttempt.factor,
    ellipseLabel: chosenAttempt.label,
    ellipseEscalation: chosenAttempt.escalation,
    profileCost: chosen.profileCost,
    softStitchCount,
    permStitchCount
  });
}

module.exports = {
  routeRequest,
  echoLegId,
  loadGraph,
  DEFAULT_MATCH_METERS,
  SEAM_SNAP_RADIUS_M,
  matchPoint,
  normalizePolicy,
  accessAllowed,
  resolveChainSeamWaypoints,
  snapSeamWaypoint,
  coordinateInUrbanBoxes,
  coordinateNearUrbanBoxes,
  remainingChainPathCap,
  topologySeamFromIndex,
  fallbackReasonFor,
  clippedDirtMeters,
  isLowDirtRoute,
  backtrackSummary,
  restrictedSummary
};
