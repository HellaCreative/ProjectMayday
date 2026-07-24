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
const { resolveGraphRequest } = require("../regional/select");
const { corridorLocationsForRoute, pointInAdventureUrbanCore } = require("../regional/merge");
const {
  surfaceMultiplier: profileSurfaceMultiplier,
  roadClassMultiplier,
  classSpeedKmh: profileClassSpeedKmh,
  maxSurfaceMultiplier,
  costPerKmView
} = require("./profile-costs");
const {
  unpackSurface,
  unpackAccess,
  unpackStructure,
  unpackConfidence,
  unpackSeasonal
} = require("./pack-v2");
const { findPathV2 } = require("./find-path-v2");

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

function isOpenStreetMapEdge(edge) {
  return !!(edge && /openstreetmap/i.test(String(edge.src || edge.source || "")));
}

function accessAllowed(accessCode, policy, enums, edge) {
  // Product rule: OSM basemap roads are always routable when included.
  // Surface/class still drive visuals and costing; access gating is for
  // provincial capillary / unknown-legality only.
  if (isOpenStreetMapEdge(edge)) {
    return policy.motorizedPermissive !== false;
  }
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
 */
const ELLIPSE_FACTORS = {
  cleanest: 1.25,
  // Crow-flies Direct: tight enough to kill north-of-B dirt tourism spurs
  // (Myra→Fall River spur sat at ~1.33× chord) while still allowing NSTDB cuts.
  direct: 1.28,
  // Balanced needs room off Direct’s crow-flies cut via cost mix, not a wider
  // ellipse — Myra north tourism tip sits ~1.30× chord; keep ≤ Direct’s band.
  balanced: 1.28,
  dirt: 2.6
};

function ellipseAttemptsForProfile(profile) {
  if (!ellipsePruneEnabled()) {
    return [{ factor: Infinity, label: "unpruned", escalation: "none" }];
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
 * On full NS packs it stole snaps from nearby NSTDB forest edges and, with
 * end-rematch, pinned both ends to the paved giant — dirt routes died.
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
  if (regionId === "ns" || regionId === "nb" || regionId === "pe") return false;
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
  const preferPavedSnap = prof === "cleanest" || role === "end";
  const candidates = edgeCandidateIndexes(runtime, point[0], point[1], matchMeters);
  const isV2 = runtime.format === "v2";
  let bestAny = null;
  let bestGiant = null;
  for (const index of candidates) {
    let accessCode;
    let surfaceCode;
    let structureCode;
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
      // Tie-break only — never steal a snap that is substantially closer.
      if (preferAdventureSnap && surfaceName !== "paved") {
        surfaceBias = -22;
      } else if (preferPavedSnap && surfaceName === "paved") {
        surfaceBias = -30;
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
        edgeMeters
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

async function routeRequest(body = {}) {
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
    return {
      status: "error",
      error: "graph_load_failed",
      message: err && err.message ? err.message : String(err),
      regionIds: graphResolution.regionIds || []
    };
  }
  return routeOnRuntime(body, graphResolution, runtime);
}

async function routeCanadaChain(body, graphResolution) {
  const profile = body.profile || "balanced";
  // Adventure: province-seam joints (not city hubs) so each hop loads ≤2 packs.
  // Cleanest: highway spine anchors. Plain [A,B] mega-merges OOM on Hobby.
  const waypoints = corridorLocationsForRoute(body.locations || [], {
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
    const hop = await routeRequest({
      ...body,
      locations: [waypoints[i], waypoints[i + 1]],
      disableChain: true,
      disableLonghaul: true,
      preferLonghaulPacks: true,
      options: {
        ...(body.options || {}),
        matchLimitMeters: Math.min(500, Number((body.options || {}).matchLimitMeters) || 500)
      }
    });
    if (hop.status !== "complete") {
      return {
        status: hop.status || "failed",
        error: hop.error || "chain_hop_failed",
        message:
          (hop.message || "Long-haul hop failed") +
          ` (hop ${i + 1}/${waypoints.length - 1})`,
        regionIds: graphResolution.regionIds,
        hopIndex: i,
        hop
      };
    }
    parts.push(hop);
    totalMeters += hop.distanceMeters || 0;
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
      engine: "dirt-node-astar-chain",
      graphMode: "canada-chain",
      regionIds: graphResolution.regionIds,
      waypoints: waypoints.length,
      fallback: null,
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
  for (const seg of segments || []) {
    const meters = Number(seg.distanceMeters) || 0;
    if (!(meters > 0)) continue;
    const surfaceName = seg.surfaceClass || seg.trackClass || "unknown";
    const accessName = seg.accessClass || "motorized_unknown";
    bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + meters;
    byAccessM[accessName] = (byAccessM[accessName] || 0) + meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += meters;
  }
  const pct = (m) => (distanceMeters > 0 ? Math.round((m / distanceMeters) * 100) : 0);
  const dirtMeters = adventureSurfaceMeters(bySurfaceM);
  return {
    pavedPercent: pct(bySurfaceM.paved || 0),
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

async function routeOnRuntime(body, graphResolution, runtime) {
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

  const start = locations[0];
  const end = locations[locations.length - 1];
  let startMatch = matchPoint(runtime, start, policy, limit, avoidEdgeIds, null, profile, "start");
  let endMatch = matchPoint(runtime, end, policy, limit, avoidEdgeIds, null, profile, "end");
  // Soft expand once within the hard cap: prefer snap-on-place over hard fail
  // when a road exists a bit beyond the default radius (thinned hubs / fat taps).
  // nearestMeters is null when the spatial index finds zero candidates inside
  // the first radius — still retry at the hard cap (QC hub coords / hinterland).
  if (!startMatch.ok && limit < HARD_MATCH_CAP_M) {
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
  if (!endMatch.ok && limit < HARD_MATCH_CAP_M) {
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

  const searchStarted = Date.now();
  const path = findPath(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds);
  const searchMs = Date.now() - searchStarted;
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
        avoidedEdgeIds: Array.from(avoidEdgeIds),
        searchMs,
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
  if (avoidEdgeIds.size > 0) {
    const usedAvoided = path.segments.some((seg) => avoidEdgeIds.has(String(seg.edgeId)));
    warnings.push({
      code: "avoided_edges",
      message: avoidEdgeIds.size + " reported edge(s) were excluded from routing server-side.",
      avoidedEdgeIds: Array.from(avoidEdgeIds),
      containedAvoidedEdge: usedAvoided
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
      avoidedEdgeIds: Array.from(avoidEdgeIds),
      engine: path.searchMeta && path.searchMeta.bidir ? "dirt-node-bidir-astar" : "dirt-node-astar",
      searchMs,
      profileCost: path.profileCost,
      searchMeta: path.searchMeta || null,
      fallback: null,
      regionIds: graphResolution.regionIds,
      graphMode: graphResolution.mode,
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

function findPath(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds) {
  if (runtime.format === "v2") {
    return findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds);
  }
  const { data, adjacency, enums } = runtime;
  const edges = data.edges;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
  const geom = runtime.geom || null;

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
  const maxMult = maxSurfaceMultiplier(profile);
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

  function insideEllipse(node, factor) {
    if (!Number.isFinite(factor) || factor === Infinity) return true;
    const ll = nodeCoord[node];
    if (!ll) return true;
    return haversineMeters(startLL, ll) + haversineMeters(ll, endLL) <= factor * abMeters * 1.0000001;
  }

  function adventureUrbanMult(ll) {
    if (!ll || profile === "cleanest") return 1;
    if (!pointInAdventureUrbanCore(ll[0], ll[1])) return 1;
    // Waypoint / pin in the core: allow flow through that city.
    if (haversineMeters(ll, startLL) < 2500 || haversineMeters(ll, endLL) < 2500) return 1;
    // Strong enough that trunk/primary through Moncton/Fredericton loses to
    // yellow/white/track detours; finite so unavoidable bridges still work.
    if (profile === "dirt") return 5.5;
    if (profile === "balanced") return 4.2;
    return 3.6; // direct
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
        const away = dTo - dFrom;
        if (away > 60 && dFrom < Math.max(3500, abMeters * 0.3)) {
          const w = profile === "direct" ? 10 : profile === "balanced" ? 3.5 : 1.2;
          accessCost += (away / 1000) * w;
        }
        const mid = [
          (nodeCoord[fromNode][0] + nodeCoord[toNode][0]) / 2,
          (nodeCoord[fromNode][1] + nodeCoord[toNode][1]) / 2
        ];
        accessCost *= adventureUrbanMult(mid);
      }
      return accessCost;
    }
    const surfaceMult = surfaceMultiplier(edge.surface, profile, enums);
    const classMult = roadClassMultiplier(edge.roadTrack, profile);
    let cost = (edge.meters / 1000) * surfaceMult * classMult;
    // When the rider opts into unknown access, non-cleanest profiles should
    // prefer NSTDB / provincial capillary (motorized_unknown) over paved spine.
    // Direct: mild pull only — length still wins (no dirt% objective).
    // Balanced: open purple toward ~50/50 without cloning Direct’s crow-flies cut.
    // Dirt: strong.
    if (policy.motorizedUnknown && profile !== "cleanest") {
      const accessName = enums.ACCESS_NAME[edge.access] || "";
      if (accessName === "motorized_unknown") {
        if (profile === "dirt") cost *= 0.5;
        else if (profile === "direct") cost *= 0.78;
        else cost *= 0.9; // balanced — journey dirt without owning the corridor
      }
      const id = String(edge.edgeId || "");
      const src = String(edge.source || "");
      // Provincial capillary parity: NSTDB and NB Forest Roads (not OSM alone).
      if (
        id.startsWith("ns-") ||
        id.startsWith("nb-fr") ||
        /nstdb|Topographic|Forest Roads/i.test(src)
      ) {
        if (profile === "dirt") cost *= 0.68;
        else if (profile === "direct") cost *= 0.86;
        else cost *= 0.93;
      }
      // Balanced+Allow mix: on purple-rich NS fabric, nudge paved into the
      // journey so dirt% lands ~40–60 instead of cloning Direct. Arterial /
      // urban penalties still keep highway corridors from becoming Clean-lite.
      if (profile === "balanced") {
        const surfaceName = enums.SURFACE_NAME[edge.surface] || "";
        if (surfaceName === "paved") cost *= 0.9;
        else if (
          surfaceName === "gravel" ||
          surfaceName === "access" ||
          surfaceName === "track"
        ) {
          cost *= 1.06;
        }
      }
    }
    // Adventure: avoid major city/town cores unless pin is there or unavoidable.
    if (fromNode != null && toNode != null && nodeCoord[fromNode] && nodeCoord[toNode]) {
      const mid = [
        (nodeCoord[fromNode][0] + nodeCoord[toNode][0]) / 2,
        (nodeCoord[fromNode][1] + nodeCoord[toNode][1]) / 2
      ];
      cost *= adventureUrbanMult(mid);
    } else if (edge.g && edge.g.length) {
      const mid = edge.g[Math.floor(edge.g.length / 2)];
      if (mid) cost *= adventureUrbanMult(mid);
    }
    // Approach-to-goal: penalize edges that increase distance to B.
    // Clean: apply for the whole journey so side-road starts prefer forward
    // paved progress over reverse/U-turn snacks onto a distant freeway.
    // Direct/Balanced: kill dirt-tourism spurs; Dirt: only near B.
    if (fromNode != null && toNode != null && nodeCoord[fromNode] && nodeCoord[toNode]) {
      const dFrom = haversineMeters(nodeCoord[fromNode], endLL);
      const dTo = haversineMeters(nodeCoord[toNode], endLL);
      const away = dTo - dFrom;
      if (away > 50) {
        const nearGoal = dFrom < Math.max(2800, abMeters * 0.28);
        if (nearGoal || profile === "direct" || profile === "cleanest" || profile === "balanced") {
          let w = 0;
          if (profile === "cleanest") w = nearGoal ? 6.5 : 3.2;
          else if (profile === "direct") w = nearGoal ? 9 : 3.5;
          else if (profile === "balanced") w = nearGoal ? 5.5 : 3.2;
          else w = nearGoal ? 1.4 : 0.35; // dirt: allow wander, kill pure destination loops
          if (w > 0) cost += (away / 1000) * w;
        }
      }
    }
    return cost;
  }

  function materializeUsed(used, searchMeta) {
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

  const attempts = ellipseAttemptsForProfile(profile);
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
    softStitchCount
  });
}

module.exports = {
  routeRequest,
  loadGraph,
  DEFAULT_MATCH_METERS,
  matchPoint,
  normalizePolicy,
  accessAllowed
};
