"use strict";

/**
 * Fuel planning is a forward graph operation, not a repair pass over an
 * already-generated ride. One bounded Dijkstra discovers every pump reachable
 * on the eligible road fabric from the current point. The planner commits the
 * best forward pump, repeats from there, and stops as soon as point 2 is
 * graph-reachable within the remaining tank.
 *
 * Reachability produces a bounded candidate set. Actual profile routes then
 * score those candidates before a pump is committed, and the caller renders
 * the selected point 1 -> F1 -> ... -> point 2 legs.
 */
const { loadGraphsForRequest, clearGraphCache } = require("./graph");
const {
  classifyFuelFailureReason,
  enrichFuelDiagnostics
} = require("./route-diagnostics");
const {
  matchPoint,
  normalizePolicy,
  accessAllowed,
  resolveChainSeamWaypoints,
  routeRequest
} = require("./router");
const {
  resolveGraphRequest,
  primaryRegionForPoint,
  provinceFamily
} = require("../regional/select");
const { corridorLocationsForRoute } = require("../regional/merge");
const { resolveProfile } = require("./profile-costs");
const { loadFuelForLocations, loadRegionFuel } = require("./fuel-data");

function mergePackIdentities(...groups) {
  const byRegion = new Map();
  for (const identity of groups.flat().filter(Boolean)) {
    const key = String(identity.regionId || "unknown").toLowerCase();
    byRegion.set(key, { ...(byRegion.get(key) || {}), ...identity });
  }
  return [...byRegion.values()];
}
const { unpackAccess, unpackSurface } = require("./pack-v2");
const { projectedProgressMeters, crossTrackMeters } = require("./hop-search");
const { resolveLocationsByEligibleEdge } = require("../regional/endpoint-resolver");

const HARD_MATCH_METERS = 750;
const MIN_STOP_SEPARATION_M = 800;
const MIN_FORWARD_PROGRESS_M = 8_000;
const MIN_DESTINATION_FUEL_CLEARANCE_M = 5_000;
/** Bumped when fuel-selection / ranking contracts change. Clients may assert. */
const FUEL_CHAIN_SERVICE_VERSION = "2026-09-02.route-first-shared-plan.11";
/** Watch at 50%; prefer sensible equal-stop choices at 70%. Lockstep: HopSearchPolicy.swift. */
const FUEL_COMFORT_LO = 0.50;
const FUEL_COMFORT_HI = 0.70;
/** Allow a short forecourt connector, never a meaningful down-and-back fuel stem. */
const MAX_FUEL_RETRACE_M = 1_000;
/** Numbered waypoint on a packed pump. Lockstep: HopSearchPolicy.fuelWaypointSnapMeters. */
const WAYPOINT_FUEL_SNAP_METERS = 150;
/** Clean rejects pumps whose full chain exceeds foundation by this much. */
const MAX_CLEAN_CHAIN_DETOUR_RATIO = 1.12;
const MAX_CLEAN_CHAIN_DETOUR_ABS_M = 20_000;
/** Fuel anchors may follow terrain, but may not materially inflate the foundation journey. */
const MAX_FUEL_CHAIN_DETOUR_RATIO = 1.50;
const MAX_FUEL_CHAIN_DETOUR_ABS_M = 50_000;
/** Soft corridor half-width; beyond this, cross-track dominates clean ranking. */
const CORRIDOR_SOFT_WIDTH_M = 25_000;
const SHORTLIST_MIN_SEPARATION_M = 15_000;
const CLEAN_MAJOR_ROAD_CLASSES = new Set([
  "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
  "freeway", "ramp", "arterial"
]);

const MAX_RECENT_EDGE_HISTORY = 256;

function appendRecentEdge(history, edgeId) {
  const id = String(edgeId == null ? "" : edgeId);
  if (!id) return;
  if (history.has(id)) history.delete(id);
  history.add(id);
  while (history.size > MAX_RECENT_EDGE_HISTORY) {
    history.delete(history.values().next().value);
  }
}

function recentEdgeHistory(edgeIds) {
  const history = new Set();
  for (const edgeId of (edgeIds || []).slice(-MAX_RECENT_EDGE_HISTORY)) {
    appendRecentEdge(history, edgeId);
  }
  return history;
}

function cleanRouteQuality(response, penalizeMajorRoads) {
  const debug = response && response.debug || {};
  const meta = debug.searchMeta || {};
  const diagnostics = debug.diagnostics || {};
  const fallbacks = Array.isArray(diagnostics.profileFallbacks)
    ? diagnostics.profileFallbacks.map((row) => String(row).toLowerCase())
    : [];
  const urbanFallback = meta.urbanCoreFallbackUsed === true ||
    debug.fallback === "urban_core_last_resort" || fallbacks.includes("urban_core_relaxed");
  const settlementFallback = meta.settlementFallbackUsed === true ||
    debug.settlementFallback === true || fallbacks.includes("settlement_relaxed");
  let majorRoadMeters = 0;
  let routedMeters = 0;
  for (const segment of (response && response.segments) || []) {
    const meters = Number(segment && segment.distanceMeters) || 0;
    if (!(meters > 0)) continue;
    routedMeters += meters;
    const roadClass = String(
      segment.roadClassLeaf || segment.trackClass || segment.roadClass || "unknown"
    ).toLowerCase();
    if (penalizeMajorRoads && CLEAN_MAJOR_ROAD_CLASSES.has(roadClass)) {
      majorRoadMeters += meters;
    }
  }
  if (!(routedMeters > 0)) routedMeters = Number(response && response.distanceMeters) || 0;
  return {
    fallbackCount: (urbanFallback ? 2 : 0) + (settlementFallback ? 1 : 0),
    majorRoadMeters,
    routedMeters
  };
}

function responseBacktrackMeters(response) {
  const direct = Number(response && response.backtrackMeters);
  if (Number.isFinite(direct) && direct >= 0) return direct;
  const shape = response && response.debug && response.debug.searchMeta &&
    response.debug.searchMeta.routeShape;
  const backward = Number(shape && shape.backwardMeters);
  return Number.isFinite(backward) && backward >= 0 ? backward : 0;
}

function routeChainQuality(response, penalizeMajorRoads) {
  const meters = Math.max(0, Number(response && response.distanceMeters) || 0);
  const dirtPercent = Number(response && response.stats && response.stats.dirtPercent);
  const clean = cleanRouteQuality(response, penalizeMajorRoads);
  return {
    meters,
    dirtMeters: meters * (Number.isFinite(dirtPercent) ? dirtPercent : 0) / 100,
    cleanFallbackCount: clean.fallbackCount,
    cleanMajorRoadMeters: clean.majorRoadMeters,
    backtrackMeters: responseBacktrackMeters(response)
  };
}

function combineChainQuality(...parts) {
  return parts.filter(Boolean).reduce((total, part) => ({
    meters: total.meters + (Number(part.meters) || 0),
    dirtMeters: total.dirtMeters + (Number(part.dirtMeters) || 0),
    cleanFallbackCount: total.cleanFallbackCount + (Number(part.cleanFallbackCount) || 0),
    cleanMajorRoadMeters: total.cleanMajorRoadMeters + (Number(part.cleanMajorRoadMeters) || 0),
    backtrackMeters: total.backtrackMeters + (Number(part.backtrackMeters) || 0)
  }), {
    meters: 0,
    dirtMeters: 0,
    cleanFallbackCount: 0,
    cleanMajorRoadMeters: 0,
    backtrackMeters: 0
  });
}

function comfortCapMeters(firstLegMaxMeters, usableRangeMeters) {
  const usable = Number(usableRangeMeters);
  const first = Number(firstLegMaxMeters);
  if (!(usable > 0) || !(first >= 0)) return 0;
  return Math.min(first, usable);
}

function compareChainPlans(a, b, profile, firstCapMeters) {
  if (!!a.complete !== !!b.complete) return a.complete ? -1 : 1;
  const aq = a.quality || combineChainQuality();
  const bq = b.quality || combineChainQuality();
  if ((a.stops || []).length !== (b.stops || []).length) {
    return (a.stops || []).length - (b.stops || []).length;
  }
  const aBacktrack = aq.meters > 0 ? aq.backtrackMeters / aq.meters : 0;
  const bBacktrack = bq.meters > 0 ? bq.backtrackMeters / bq.meters : 0;
  // A lollipop, figure-eight, or repeated approach is a ride-quality defect,
  // not an acceptable way to save one fuel stop.
  if (Math.abs(aBacktrack - bBacktrack) > 0.01) return aBacktrack - bBacktrack;
  const aDetour = Number(a.directionalDetourMeters) || 0;
  const bDetour = Number(b.directionalDetourMeters) || 0;
  if (Math.abs(aDetour - bDetour) > 2_000) return aDetour - bDetour;
  const aProgress = Number(a.progressMeters) || 0;
  const bProgress = Number(b.progressMeters) || 0;
  if (Math.abs(aProgress - bProgress) > 2_000) return bProgress - aProgress;
  if (Math.abs(aq.meters - bq.meters) > 50) return aq.meters - bq.meters;
  switch (resolveProfile(profile)) {
    case "dirt": {
      const aDirt = aq.meters > 0 ? aq.dirtMeters / aq.meters * 100 : 0;
      const bDirt = bq.meters > 0 ? bq.dirtMeters / bq.meters * 100 : 0;
      if (Math.abs(aDirt - bDirt) > 0.5) return bDirt - aDirt;
      break;
    }
    case "balanced": {
      const aDirt = aq.meters > 0 ? aq.dirtMeters / aq.meters * 100 : 0;
      const bDirt = bq.meters > 0 ? bq.dirtMeters / bq.meters * 100 : 0;
      const delta = Math.abs(aDirt - 50) - Math.abs(bDirt - 50);
      if (Math.abs(delta) > 0.5) return delta;
      break;
    }
    case "cleanest": {
      if (aq.cleanFallbackCount !== bq.cleanFallbackCount) {
        return aq.cleanFallbackCount - bq.cleanFallbackCount;
      }
      const aMajor = aq.meters > 0 ? aq.cleanMajorRoadMeters / aq.meters : 0;
      const bMajor = bq.meters > 0 ? bq.cleanMajorRoadMeters / bq.meters : 0;
      if (Math.abs(aMajor - bMajor) > 0.005) return aMajor - bMajor;
      break;
    }
    default:
      break;
  }
  void firstCapMeters;
  return 0;
}

function fuelNeedForProfileRide(profileMeters, firstLegMaxMeters, usableRangeMeters) {
  if (profileMeters == null || firstLegMaxMeters == null || usableRangeMeters == null) return null;
  const meters = Number(profileMeters);
  const firstCap = Number(firstLegMaxMeters);
  const usable = Number(usableRangeMeters);
  if (!(meters >= 0) || !(firstCap >= 0) || !(usable > 0)) return null;
  const firstHardCap = comfortCapMeters(firstCap, usable);
  if (meters > firstHardCap + 1) {
    return Math.ceil((meters - firstHardCap) / usable);
  }
  // Watching and the 70% preferred zone only order pumps after a stop has been
  // proven necessary. They never manufacture a stop on a reachable ride.
  return 0;
}

function fuelPlanStatus(planned) {
  if (planned && planned.ok) return "complete";
  return planned && planned.error === "no_route_connected_fuel_chain"
    ? "gap"
    : "failed";
}

class MinHeap {
  constructor() { this.items = []; }
  push(item) {
    this.items.push(item);
    let i = this.items.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.items[p].cost <= this.items[i].cost) break;
      [this.items[p], this.items[i]] = [this.items[i], this.items[p]];
      i = p;
    }
  }
  pop() {
    if (!this.items.length) return null;
    const top = this.items[0];
    const end = this.items.pop();
    if (!this.items.length) return top;
    this.items[0] = end;
    let i = 0;
    for (;;) {
      let best = i;
      const left = i * 2 + 1;
      const right = left + 1;
      if (left < this.items.length && this.items[left].cost < this.items[best].cost) best = left;
      if (right < this.items.length && this.items[right].cost < this.items[best].cost) best = right;
      if (best === i) break;
      [this.items[best], this.items[i]] = [this.items[i], this.items[best]];
      i = best;
    }
    return top;
  }
}

function haversineMeters(a, b) {
  const toRad = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toRad;
  const dLon = (b[0] - a[0]) * toRad;
  const lat1 = a[1] * toRad;
  const lat2 = b[1] * toRad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}

function locationCoordinate(location) {
  return [
    Number(location && (location.lon != null ? location.lon : location.lng)),
    Number(location && location.lat)
  ];
}

function edgeView(runtime, edgeIndex) {
  if (runtime.format === "v2") {
    const pack = runtime.pack;
    return {
      a: pack.edgeFrom[edgeIndex],
      b: pack.edgeTo[edgeIndex],
      meters: Number(pack.edgeMeters[edgeIndex]),
      access: unpackAccess(pack.edgeAttrs[edgeIndex]),
      surface: (runtime.enums.SURFACE_NAME || [])[unpackSurface(pack.edgeAttrs[edgeIndex])] || "unknown",
      id: pack.edgeId(edgeIndex)
    };
  }
  const edge = runtime.data.edges[edgeIndex];
  return {
    a: edge.a,
    b: edge.b,
    meters: Number(edge.m),
    access: edge.ac,
    surface: (runtime.enums.SURFACE_NAME || [])[edge.s] || "unknown",
    id: String(edge.i)
  };
}

function nodeCount(runtime) {
  return runtime.format === "v2" ? runtime.pack.nodeCount : runtime.data.nodeCount;
}

function forEachNeighbor(runtime, node, visit) {
  if (runtime.format === "v2") {
    const pack = runtime.pack;
    for (let arc = pack.nodeOffsets[node]; arc < pack.nodeOffsets[node + 1]; arc += 1) {
      const edgeIndex = pack.edgeUndirectedIndex[arc];
      visit(pack.edgeTargets[arc], edgeIndex);
    }
    return;
  }
  for (const edgeIndex of runtime.adjacency[node] || []) {
    const edge = runtime.data.edges[edgeIndex];
    visit(edge.a === node ? edge.b : edge.a, edgeIndex);
  }
}

function seedMatchDistances(runtime, match, distances, heap) {
  const edge = edgeView(runtime, match.edgeIndex);
  const along = Math.max(0, Math.min(edge.meters, Number(match.distanceAlongM) || 0));
  const seeds = [
    [edge.a, along],
    [edge.b, Math.max(0, edge.meters - along)]
  ];
  for (const [node, meters] of seeds) {
    if (meters < distances[node]) {
      distances[node] = meters;
      heap.push({ node, cost: meters });
    }
  }
}

/** Physical graph distance to every node within one usable tank. */
function boundedGraphDistances(
  runtime,
  startMatch,
  policy,
  maxMeters,
  avoidEdgeIds = [],
  priorEdgeIds = [],
  arrivalEdgeId = null,
  backtrackFactor = 4
) {
  const count = nodeCount(runtime);
  const distances = new Float64Array(count);
  distances.fill(Infinity);
  const scores = new Float64Array(count);
  scores.fill(Infinity);
  const heap = new MinHeap();
  const avoid = new Set((avoidEdgeIds || []).map(String));
  const prior = new Set((priorEdgeIds || []).map(String));
  const arrival = arrivalEdgeId == null ? null : String(arrivalEdgeId);
  const penalty = (id) => arrival != null && String(id) === arrival
    ? 12
    : (prior.has(String(id)) ? Math.max(1, Number(backtrackFactor) || 4) : 1);
  seedMatchDistances(runtime, startMatch, distances, heap);
  for (const item of heap.items) scores[item.node] = item.cost;
  let pops = 0;

  while (heap.items.length) {
    const current = heap.pop();
    if (!current || current.cost !== scores[current.node]) continue;
    if (distances[current.node] > maxMeters) continue;
    pops += 1;
    forEachNeighbor(runtime, current.node, (next, edgeIndex) => {
      const edge = edgeView(runtime, edgeIndex);
      if (avoid.has(edge.id)) return;
      if (!accessAllowed(edge.access, policy, runtime.enums, null)) return;
      const candidateMeters = distances[current.node] + edge.meters;
      const candidateScore = current.cost + edge.meters * penalty(edge.id);
      if (candidateMeters > maxMeters || candidateScore >= scores[next]) return;
      distances[next] = candidateMeters;
      scores[next] = candidateScore;
      heap.push({ node: next, cost: candidateScore });
    });
  }

  return { distances, pops };
}

function distanceToMatch(runtime, originMatch, targetMatch, distances) {
  const edge = edgeView(runtime, targetMatch.edgeIndex);
  const along = Math.max(0, Math.min(edge.meters, Number(targetMatch.distanceAlongM) || 0));
  let meters = Math.min(
    distances[edge.a] + along,
    distances[edge.b] + Math.max(0, edge.meters - along)
  );
  if (originMatch.edgeIndex === targetMatch.edgeIndex) {
    meters = Math.min(
      meters,
      Math.abs(
        (Number(originMatch.distanceAlongM) || 0) -
        (Number(targetMatch.distanceAlongM) || 0)
      )
    );
  }
  return meters + Math.max(0, Number(targetMatch.distanceM) || 0);
}

/**
 * Find the nearest route-connected pump without flooding the whole usable
 * range. Nearby stations are matched in expanding geographic batches; the
 * graph walk stops as soon as its frontier cannot beat the best pump already
 * reached. Straight-line distance is a lower bound, so an unexamined batch can
 * be skipped once its nearest member is farther than the proven road result.
 */
function nearestReachableFuelDistance({
  runtime,
  stations,
  origin,
  profile = "cleanest",
  accessPolicy = { motorizedPermissive: true, motorizedUnknown: false },
  maxMeters,
  avoidEdgeIds = []
}) {
  const resolvedProfile = resolveProfile(profile);
  const policy = normalizePolicy(accessPolicy, resolvedProfile);
  const avoid = new Set((avoidEdgeIds || []).map(String));
  const originMatch = matchPoint(
    runtime, origin, policy, HARD_MATCH_METERS, avoid, null, resolvedProfile, "start"
  );
  if (!originMatch.ok) {
    return { meters: null, pops: 0, matched: 0, considered: 0 };
  }
  const originCoord = locationCoordinate(origin);
  const ordered = (stations || []).map((station) => {
    const location = stationLocation(station);
    return {
      station,
      location,
      straightMeters: Number.isFinite(location.lat) && Number.isFinite(location.lon)
        ? haversineMeters(originCoord, [location.lon, location.lat])
        : Infinity
    };
  }).filter((row) => Number.isFinite(row.straightMeters))
    .sort((a, b) => a.straightMeters - b.straightMeters);

  const targetMatches = [];
  let considered = 0;
  let totalPops = 0;
  const batchEnds = [...new Set([
    Math.min(32, ordered.length),
    Math.min(128, ordered.length),
    ordered.length
  ])].filter((value) => value > 0);

  function searchMatchedTargets() {
    const byNode = new Map();
    let best = Infinity;
    const originEdge = edgeView(runtime, originMatch.edgeIndex);
    const originAlong = Math.max(
      0, Math.min(originEdge.meters, Number(originMatch.distanceAlongM) || 0)
    );
    for (const target of targetMatches) {
      const edge = edgeView(runtime, target.match.edgeIndex);
      const along = Math.max(0, Math.min(edge.meters, Number(target.match.distanceAlongM) || 0));
      const snap = Math.max(0, Number(target.match.distanceM) || 0);
      const endpoints = [
        [edge.a, along + snap],
        [edge.b, Math.max(0, edge.meters - along) + snap]
      ];
      for (const [node, offset] of endpoints) {
        const previous = byNode.get(node);
        if (previous == null || offset < previous) byNode.set(node, offset);
      }
      if (target.match.edgeIndex === originMatch.edgeIndex) {
        best = Math.min(best, Math.abs(originAlong - along) + snap);
      }
    }

    const count = nodeCount(runtime);
    const distances = new Float64Array(count);
    distances.fill(Infinity);
    const heap = new MinHeap();
    seedMatchDistances(runtime, originMatch, distances, heap);
    let pops = 0;
    while (heap.items.length) {
      const current = heap.pop();
      if (!current || current.cost !== distances[current.node]) continue;
      if (current.cost > maxMeters || current.cost >= best) break;
      pops += 1;
      const targetOffset = byNode.get(current.node);
      if (targetOffset != null) best = Math.min(best, current.cost + targetOffset);
      forEachNeighbor(runtime, current.node, (next, edgeIndex) => {
        const edge = edgeView(runtime, edgeIndex);
        if (avoid.has(edge.id)) return;
        if (!accessAllowed(edge.access, policy, runtime.enums, null)) return;
        const candidate = current.cost + edge.meters;
        if (candidate > maxMeters || candidate >= best || candidate >= distances[next]) return;
        distances[next] = candidate;
        heap.push({ node: next, cost: candidate });
      });
    }
    return { meters: Number.isFinite(best) && best <= maxMeters ? best : null, pops };
  }

  let best = null;
  for (const batchEnd of batchEnds) {
    for (; considered < batchEnd; considered += 1) {
      const row = ordered[considered];
      const match = matchPoint(
        runtime, row.location, policy, HARD_MATCH_METERS, avoid, null, resolvedProfile, "end"
      );
      if (match.ok) targetMatches.push({ ...row, match });
    }
    const result = searchMatchedTargets();
    totalPops += result.pops;
    if (result.meters != null) {
      best = result.meters;
      const nextLowerBound = ordered[considered]?.straightMeters ?? Infinity;
      if (nextLowerBound >= best) break;
    }
  }
  return {
    meters: best,
    pops: totalPops,
    matched: targetMatches.length,
    considered
  };
}

function stationLocation(station) {
  return {
    lat: Number(station && (station.lat != null ? station.lat : station.latitude)),
    lon: Number(station && (station.lon != null ? station.lon : station.lng != null ? station.lng : station.longitude)),
    label: (station && (station.name || station.brand)) || "Fuel"
  };
}

/**
 * A numbered rider waypoint is a live refuel only while it sits on a packed
 * pump. Recompute from coordinates; never persist a flag on the waypoint.
 * Lockstep: FuelItinerary.nearestFuelStation.
 */
function deriveWaypointFuelStation(location, stations, radiusMeters = WAYPOINT_FUEL_SNAP_METERS) {
  const point = locationCoordinate(location);
  const radius = Number(radiusMeters);
  if (!Number.isFinite(point[0]) || !Number.isFinite(point[1]) || !(radius >= 0)) return null;
  if (!Array.isArray(stations) || !stations.length) return null;
  let best = null;
  for (const station of stations) {
    const at = stationLocation(station);
    if (!Number.isFinite(at.lat) || !Number.isFinite(at.lon)) continue;
    const meters = haversineMeters(point, [at.lon, at.lat]);
    if (meters > radius) continue;
    if (!best || meters < best.metersFromWaypoint) {
      best = {
        id: String(station.id || station.stationId || ""),
        name: station.name || station.brand || at.label,
        lat: at.lat,
        lon: at.lon,
        metersFromWaypoint: meters
      };
    }
  }
  return best && best.id ? best : null;
}

/** Every rider waypoint after the origin, including a final pump destination. */
function deriveWaypointRefuels(locations, stations, radiusMeters = WAYPOINT_FUEL_SNAP_METERS) {
  const rows = [];
  const points = Array.isArray(locations) ? locations : [];
  for (let index = 1; index < points.length; index += 1) {
    const hit = deriveWaypointFuelStation(points[index], stations, radiusMeters);
    if (hit) rows.push({ locationIndex: index, ...hit });
  }
  return rows;
}

// A warm live-planning isolate sees the same immutable graph and fuel
// sidecar across profile changes. Reuse pump-to-road snaps; only the rider's
// destination needs matching on each request.
const preparedFuelTargetCache = new WeakMap();

function prepareTargets(runtime, stations, destination, policy, profile, avoid) {
  const started = Date.now();
  const destinationMatch = matchPoint(
    runtime,
    destination,
    policy,
    HARD_MATCH_METERS,
    avoid,
    null,
    profile,
    "end"
  );
  const stationCacheKey = stations && stations.routingCacheKey;
  const avoidKey = [...avoid].sort().join(",");
  const snapProfileClass = resolveProfile(profile) === "cleanest" ? "cleanest" : "adventure";
  const cacheKey = stationCacheKey
    ? `${stationCacheKey}|${snapProfileClass}|unknown=${policy.motorizedUnknown ? 1 : 0}|avoid=${avoidKey}`
    : null;
  let runtimeCache = preparedFuelTargetCache.get(runtime);
  let targetCache = cacheKey && runtimeCache && runtimeCache.get(cacheKey);
  const cacheHit = !!targetCache;
  if (!targetCache) {
    targetCache = new Map();
    if (cacheKey) {
      if (!runtimeCache) {
        runtimeCache = new Map();
        preparedFuelTargetCache.set(runtime, runtimeCache);
      }
      runtimeCache.set(cacheKey, targetCache);
      while (runtimeCache.size > 8) {
        runtimeCache.delete(runtimeCache.keys().next().value);
      }
    }
  }
  const stationRows = (stations || []).map((station) => ({
    station,
    location: stationLocation(station)
  })).filter((row) =>
    Number.isFinite(row.location.lat) && Number.isFinite(row.location.lon)
  );
  const prepareDiagnostics = {
    elapsedMs: Date.now() - started,
    cacheHit,
    stationsConsidered: 0,
    stationsMatched: 0
  };
  const matchedStationIDs = new Set();

  function fuelTargetsNear(origin, maxMeters) {
    const originCoordinate = locationCoordinate(origin);
    // Road distance cannot be shorter than the geographic chord. The extra
    // snap allowance covers both endpoint projections, so this removes only
    // pumps that are physically incapable of fitting in the current tank.
    const geographicLimit = Math.max(0, Number(maxMeters) || 0) + HARD_MATCH_METERS * 2;
    const nearby = stationRows.filter((row) =>
      haversineMeters(originCoordinate, [row.location.lon, row.location.lat]) <= geographicLimit
    );
    const fuelTargets = [];
    const matchStarted = Date.now();
    for (const row of nearby) {
      const stationID = String(row.station.id || row.station.stationId || "");
      const cached = targetCache.get(stationID);
      if (cached !== undefined) {
        if (cached) {
          matchedStationIDs.add(stationID);
          fuelTargets.push(cached);
        }
        continue;
      }
      prepareDiagnostics.stationsConsidered += 1;
      const { station, location } = row;
      const match = matchPoint(
        runtime,
        location,
        policy,
        HARD_MATCH_METERS,
        avoid,
        null,
        profile,
        "end"
      );
      if (!match.ok) {
        targetCache.set(stationID, null);
        continue;
      }
      const target = {
        station,
        location,
        match,
        dirtAdjacent: (() => {
          const surface = edgeView(runtime, match.edgeIndex).surface;
          return surface !== "paved" && surface !== "unknown";
        })()
      };
      targetCache.set(stationID, target);
      matchedStationIDs.add(stationID);
      fuelTargets.push(target);
    }
    prepareDiagnostics.stationsMatched = matchedStationIDs.size;
    prepareDiagnostics.elapsedMs += Date.now() - matchStarted;
    return fuelTargets;
  }

  return {
    destinationMatch,
    fuelTargetsNear,
    prepareDiagnostics
  };
}

function fuelPlanningSpan(profile) {
  // Historical per-profile span. Commit ranking uses FUEL_COMFORT_LO/HI for
  // every profile; this remains exported so older callers do not break.
  switch (resolveProfile(profile)) {
    case "dirt": return 0.78;
    case "balanced": return 0.84;
    case "cleanest": return 0.95;
    default: return 0.84;
  }
}

/**
 * 0 = preferred zone (70%+ consumed), 1 = watched zone (50–70%),
 * 2 = early sparse-corridor fallback.
 * Dijkstra reachability stays at 100% reserve-adjusted usable range.
 * Lockstep: HopSearchPolicy.tankCommitBand.
 */
function fuelSearchStartMeters(firstLegMaxMeters, usableRangeMeters) {
  const usable = Number(usableRangeMeters);
  const first = Number(firstLegMaxMeters);
  if (!(usable > 0) || !(first >= 0)) return 0;
  const used = Math.max(0, usable - Math.min(first, usable));
  return Math.max(0, usable * FUEL_COMFORT_LO - used);
}

function fuelPreferredStartMeters(firstLegMaxMeters, usableRangeMeters) {
  const usable = Number(usableRangeMeters);
  const first = Number(firstLegMaxMeters);
  if (!(usable > 0) || !(first >= 0)) return 0;
  const used = Math.max(0, usable - Math.min(first, usable));
  return Math.max(0, usable * FUEL_COMFORT_HI - used);
}

function tankCommitBand(graphMeters, capMeters, usableRangeMeters = capMeters) {
  const cap = Number(capMeters);
  const meters = Number(graphMeters);
  if (!(cap > 0) || !Number.isFinite(meters)) return 2;
  if (meters >= fuelPreferredStartMeters(cap, usableRangeMeters)) return 0;
  if (meters >= fuelSearchStartMeters(cap, usableRangeMeters)) return 1;
  return 2;
}

function compareTankCommit(
  aMeters, aProgress, bMeters, bProgress, capMeters, usableRangeMeters = capMeters
) {
  const band = tankCommitBand(aMeters, capMeters, usableRangeMeters) -
    tankCommitBand(bMeters, capMeters, usableRangeMeters);
  if (band !== 0) return band;
  const pa = Number(aProgress) || 0;
  const pb = Number(bProgress) || 0;
  if (Math.abs(pa - pb) > 2_000) return pb - pa;
  return 0;
}

/** The reserve-adjusted usable range is the hard routing ceiling. */
function hopBudgetMeters(graphMeters, capMeters) {
  const cap = Number(capMeters);
  if (!(cap > 0)) return cap;
  void graphMeters;
  return cap;
}

function stationEligibility(row, {
  current,
  destination,
  capMeters,
  visited = new Set(),
  allowNearStartRecovery = false,
  profile = "balanced",
  destinationGraphMeters = null
}) {
  const point = [row.location.lon, row.location.lat];
  const startMeters = haversineMeters(point, current);
  const remainingMeters = haversineMeters(point, destination);
  const currentRemaining = haversineMeters(current, destination);
  const gainMeters = currentRemaining - remainingMeters;
  const progressMeters = projectedProgressMeters(point, current, destination);
  const crossTrack = Math.abs(crossTrackMeters(point, current, destination));
  const notVisited = !visited.has(String(row.station.id));
  const routeReachable = Number.isFinite(row.graphMeters) && row.graphMeters <= capMeters + 1;
  let forward = routeReachable && notVisited
    && row.graphMeters >= MIN_STOP_SEPARATION_M
    && remainingMeters >= MIN_DESTINATION_FUEL_CLEARANCE_M
    && progressMeters >= MIN_FORWARD_PROGRESS_M
    && progressMeters < currentRemaining - MIN_DESTINATION_FUEL_CLEARANCE_M
    && gainMeters >= -5_000;
  // Use the graph foundation—not a straight-line corridor—to accommodate
  // water, terrain, and sparse road networks. A pump chain may meander, but it
  // may not create a large fuel-only journey expansion.
  if (forward) {
    const directMeters = destinationGraphMeters == null
      ? NaN : Number(destinationGraphMeters);
    const remainingGraph = row.remainingGraphMeters == null
      ? NaN : Number(row.remainingGraphMeters);
    if (Number.isFinite(directMeters) && Number.isFinite(remainingGraph)) {
      const chainMeters = Number(row.graphMeters) + remainingGraph;
      const detourCap = Math.max(
        directMeters * MAX_FUEL_CHAIN_DETOUR_RATIO,
        directMeters + MAX_FUEL_CHAIN_DETOUR_ABS_M
      );
      if (chainMeters > detourCap + 1) forward = false;
    }
  }
  // Clean: reject needless lateral excursions whose full P1→pump→P2
  // chain is dominated by the foundation ride. Score alone was letting a
  // Wallace-class pump win because it used nearly the whole tank.
  const profileKey = resolveProfile(profile);
  if (forward && profileKey === "cleanest") {
    const directMeters = destinationGraphMeters == null
      ? NaN : Number(destinationGraphMeters);
    const remainingGraph = row.remainingGraphMeters == null
      ? NaN : Number(row.remainingGraphMeters);
    if (Number.isFinite(directMeters) && Number.isFinite(remainingGraph) && Number.isFinite(row.graphMeters)) {
      const chainMeters = row.graphMeters + remainingGraph;
      const detourCap = Math.max(
        directMeters * MAX_CLEAN_CHAIN_DETOUR_RATIO,
        directMeters + MAX_CLEAN_CHAIN_DETOUR_ABS_M
      );
      if (chainMeters > detourCap + 1) forward = false;
    }
    // Hard corridor gate: pumps that sit far sideways of the P1→P2 axis are
    // not "forward" for paved skeleton planning even if closer to P2 than P1.
    // Also reject early off-axis resets (e.g. Eastern Passage on a ride that
    // should climb the Truro corridor) when sideways exceeds forward progress.
    if (crossTrack > CORRIDOR_SOFT_WIDTH_M * 2.2 && progressMeters < currentRemaining * 0.55) {
      forward = false;
    }
    if (crossTrack > CORRIDOR_SOFT_WIDTH_M && crossTrack > progressMeters * 0.9) {
      forward = false;
    }
    if (progressMeters < Math.max(MIN_FORWARD_PROGRESS_M * 4, currentRemaining * 0.18)
        && crossTrack > CORRIDOR_SOFT_WIDTH_M * 0.6) {
      forward = false;
    }
  }
  const recovery = routeReachable && notVisited && allowNearStartRecovery
    && startMeters >= 50 && remainingMeters >= MIN_STOP_SEPARATION_M;
  return {
    routeReachable,
    notVisited,
    forward,
    recovery,
    startMeters,
    remainingMeters,
    gainMeters,
    progressMeters,
    crossTrack
  };
}

function rankForwardFuel(
  reachable,
  currentLocation,
  destinationLocation,
  capMeters,
  visited,
  profile = "balanced",
  destinationFuelUsedLimitMeters = null,
  destinationGraphMeters = null,
  allowNearStartRecovery = false,
  fullUsableRangeMeters = capMeters
) {
  const current = locationCoordinate(currentLocation);
  const destination = locationCoordinate(destinationLocation);

  const scored = reachable.map((row) => {
      const eligibility = stationEligibility(row, {
        current,
        destination,
        capMeters,
        visited,
        allowNearStartRecovery,
        profile,
        destinationGraphMeters
      });
      const remaining = eligibility.remainingMeters;
      const gain = eligibility.gainMeters;
      const progress = eligibility.progressMeters;
      const crossTrack = eligibility.crossTrack;
      const profileKey = resolveProfile(profile);
      const crossTrackWeight = profileKey === "cleanest" ? 1.15 : 0.35;
      // Progress/coherence first. Dirt adjacency is deliberately only a weak
      // discovery hint; complete-chain ranking applies profile quality last.
      const score =
        progress * 1.0 +
        gain * 0.45 -
        crossTrack * crossTrackWeight +
        ((profile === "dirt" || profile === "balanced") && row.dirtAdjacent ? 25_000 : 0);
      return {
        ...row,
        eligibility,
        startMeters: eligibility.startMeters,
        remainingMeters: remaining,
        progressMeters: progress,
        crossTrack,
        score
      };
    });
  const forward = scored.filter((row) => row.eligibility.forward);
  const normal = forward.slice().sort((a, b) =>
    (tankCommitBand(a.graphMeters, capMeters, fullUsableRangeMeters) -
      tankCommitBand(b.graphMeters, capMeters, fullUsableRangeMeters)) ||
      a.crossTrack - b.crossTrack || b.progressMeters - a.progressMeters ||
      a.graphMeters - b.graphMeters
  );
  if (allowNearStartRecovery && normal.length === 0) {
    // A rider waypoint does not reset the tank. When its remaining fuel cannot
    // reach any normally-forward pump, permit one nearby graph-reachable reset
    // beside or slightly behind it. Existing forward choices always win; after
    // this recovery refuel the normal forward-progress gate applies again.
    return scored
      .filter((row) => row.eligibility.recovery)
      .sort((a, b) =>
        a.graphMeters - b.graphMeters || a.startMeters - b.startMeters || b.score - a.score
      );
  }
  const arrivalLimit = destinationFuelUsedLimitMeters == null
    ? NaN
    : Number(destinationFuelUsedLimitMeters);
  if (resolveProfile(profile) === "cleanest") {
    const bestBand = normal.reduce(
      (best, row) => Math.min(best, tankCommitBand(
        row.graphMeters, capMeters, fullUsableRangeMeters
      )),
      2
    );
    const band = normal.filter((row) => tankCommitBand(
      row.graphMeters, capMeters, fullUsableRangeMeters
    ) === bestBand);
    const exact = band.filter((row) => Number.isFinite(row.remainingGraphMeters));
    const withinArrival = Number.isFinite(arrivalLimit)
      ? exact.filter((row) => row.remainingGraphMeters <= arrivalLimit + 1)
      : exact;
    const pool = withinArrival.length ? withinArrival : exact;
    if (pool.length) {
      const directMeters = Number(destinationGraphMeters);
      const ordered = pool.slice().sort((a, b) => {
        const detourA = a.graphMeters + a.remainingGraphMeters - (Number.isFinite(directMeters) ? directMeters : 0);
        const detourB = b.graphMeters + b.remainingGraphMeters - (Number.isFinite(directMeters) ? directMeters : 0);
        return compareTankCommit(
          a.graphMeters, a.progressMeters, b.graphMeters, b.progressMeters,
          capMeters, fullUsableRangeMeters
        ) || detourA - detourB || a.remainingGraphMeters - b.remainingGraphMeters;
      });
      // Candidate discovery must not erase a rural/profile-quality alternative
      // before its actual Clean route is measured. Keep the coherent priority
      // pool first, then the remaining forward pumps for bounded route scoring.
      const picked = new Set(ordered.map((row) => String(row.station.id)));
      return ordered.concat(normal.filter((row) => !picked.has(String(row.station.id))));
    }
  }
  if (!Number.isFinite(arrivalLimit)) return normal;
  // When the following rider leg needs carried fuel, this stop's job is to
  // occur near the waypoint. Prefer pumps whose straight-line remainder can
  // plausibly fit the required arrival-fuel ceiling; graph search still proves
  // the exact distance before accepting the chain.
  const nearWaypoint = normal.filter((row) => row.remainingMeters <= arrivalLimit + 1);
  const pool = nearWaypoint.length ? nearWaypoint : normal;
  return pool.sort((a, b) =>
    compareTankCommit(
      a.graphMeters, a.progressMeters, b.graphMeters, b.progressMeters,
      capMeters, fullUsableRangeMeters
    ) || a.remainingMeters - b.remainingMeters || b.score - a.score
  );
}

async function planFuelChainOnRuntime({
  runtime,
  stations,
  start,
  destination,
  profile,
  accessPolicy: rawPolicy,
  usableRangeMeters,
  firstLegMaxMeters,
  requireFuelStopBeforeEnd = false,
  minimumFuelStops = 0,
  destinationFuelUsedLimitMeters = null,
  avoidEdgeIds = [],
  cleanMetroMultiplier = null,
  avoidMotorways = false,
  priorEdgeIds = [],
  arrivalEdgeId = null,
  backtrackFactor = 4,
  routeCandidate = null,
  candidateK = 6,
  hopTimeBudgetMs = 4_000,
  maxStops = 12,
  maxStates = 24,
  probeFirstReachableStation = false,
  excludedStationIds = [],
  requiredFirstStationId = null,
  preferredStationIds = [],
  allowPartialWindow = false,
  timeBudgetMs = null,
  profileMeters = null,
  graphOnlyFeeler = false,
  foundationRoute = null
}) {
  profile = resolveProfile(profile);
  const policy = normalizePolicy(rawPolicy, profile);
  const avoid = new Set((avoidEdgeIds || []).map(String));
  const startMatch = matchPoint(
    runtime,
    start,
    policy,
    HARD_MATCH_METERS,
    avoid,
    null,
    profile,
    "start"
  );
  if (!startMatch.ok) {
    return {
      ok: false,
      error: "match_failed",
      message: "Point 1 is not close enough to an eligible road in the live pack."
    };
  }

  const targets = prepareTargets(runtime, stations, destination, policy, profile, avoid);
  if (!targets.destinationMatch.ok) {
    return {
      ok: false,
      error: "match_failed",
      message: "Point 2 is not close enough to an eligible road in the live pack."
    };
  }

  let states = 0;
  let dijkstraPops = 0;
  const started = Date.now();
  const searchBudgetMs = Number(timeBudgetMs) > 0 ? Number(timeBudgetMs) : null;
  const destinationLimitForDiagnostics = destinationFuelUsedLimitMeters == null
    ? NaN : Number(destinationFuelUsedLimitMeters);
  const fuelDecisionDiagnostics = {
    watchStartMeters: Math.round(fuelSearchStartMeters(firstLegMaxMeters, usableRangeMeters)),
    preferredStartMeters: Math.round(fuelPreferredStartMeters(firstLegMaxMeters, usableRangeMeters)),
    hardRangeMeters: Math.round(firstLegMaxMeters),
    destinationEscapeMeters: Number.isFinite(destinationLimitForDiagnostics)
      ? Math.max(0, Math.round(usableRangeMeters - destinationLimitForDiagnostics))
      : null,
    targetPrepareMs: targets.prepareDiagnostics.elapsedMs,
    targetCacheHit: targets.prepareDiagnostics.cacheHit
  };
  const memo = new Map();
  const stationCandidates = [];
  const preferredStations = new Set((preferredStationIds || []).map(String));
  let effectiveK = Math.max(1, Math.min(6, Number(candidateK) || 6));
  let maxHopMs = 0;
  let firstReachableStationMeters = null;
  let stationsReachableWithinRange = 0;
  let timeBudgetExceeded = false;
  const physicalStart = locationCoordinate(start);
  const physicalDestination = locationCoordinate(destination);
  const physicalTotal = haversineMeters(physicalStart, physicalDestination);
  let bestPartial = { progressMeters: 0, stops: [], graphMeters: [], location: start };
  const deadline = searchBudgetMs != null ? started + searchBudgetMs : Infinity;
  const returnedStopLimit = Math.max(1, Math.min(12, Number(maxStops) || 12));
  // The UI may request one visible stop at a time. Selection still looks far
  // enough ahead to compare competing rural/profile chains before committing
  // that first stop.
  const searchStopLimit = allowPartialWindow
    ? Math.min(4, Math.max(
        returnedStopLimit + 2,
        (Number(minimumFuelStops) || 0) + 1
      ))
    : returnedStopLimit;
  const destinationGraph = boundedGraphDistances(
    runtime, targets.destinationMatch, policy, usableRangeMeters,
    avoidEdgeIds, [], null, 1
  );
  dijkstraPops += destinationGraph.pops;

  function reachableFrom(currentKey, currentLocation, currentMatch, capMeters, history, arrival) {
    const historyKey = [...history].sort().join(",");
    const memoKey = `${currentKey}:${Math.round(capMeters)}:${arrival || "-"}:${historyKey}`;
    if (memo.has(memoKey)) return memo.get(memoKey);
    const graph = boundedGraphDistances(
      runtime, currentMatch, policy, capMeters, avoidEdgeIds,
      [...history], arrival, backtrackFactor
    );
    dijkstraPops += graph.pops;
    const destinationMeters = distanceToMatch(
      runtime,
      currentMatch,
      targets.destinationMatch,
      graph.distances
    );
    const fuel = [];
    for (const target of targets.fuelTargetsNear(currentLocation, capMeters)) {
      const graphMeters = distanceToMatch(runtime, currentMatch, target.match, graph.distances);
      if (Number.isFinite(graphMeters) && graphMeters <= capMeters) {
        const remainingGraphMeters = distanceToMatch(
          runtime, targets.destinationMatch, target.match, destinationGraph.distances
        );
        fuel.push({ ...target, graphMeters, remainingGraphMeters });
      }
    }
    const result = { destinationMeters, fuel };
    memo.set(memoKey, result);
    return result;
  }

  const defaultProfileHop = async ({
    candidate, from, maxMeters, priorEdgeIds: evaluationHistory, arrivalEdgeId: evaluationArrival
  }) => {
    const usesFoundation = foundationRoute && candidate.station.id === "__destination__" &&
      Math.abs(Number(from.lat) - Number(start.lat)) < 1e-7 &&
      Math.abs(Number(from.lon) - Number(start.lon)) < 1e-7;
    if (usesFoundation) return foundationRoute;
    return routeRequest({
      profile,
      locations: [from, candidate.location],
      accessPolicy: rawPolicy,
      options: {
        avoidEdgeIds,
        priorEdgeIds: [...(evaluationHistory || [])],
        arrivalEdgeId: evaluationArrival,
        backtrackFactor,
        cleanMetroMultiplier,
        avoidMotorways: avoidMotorways === true,
        internalFuelProbe: true,
        directExtraBudgetMeters: undefined,
        maxPathMeters: maxMeters
      }
    });
  };
  let profileRouteAttempts = 0;
  const profileRouteTimings = [];
  const profileRoute = routeCandidate || defaultProfileHop;
  const evaluateProfileHop = graphOnlyFeeler
    ? (async ({ candidate }) => ({
        status: "complete",
        distanceMeters: candidate.graphMeters,
        stats: { dirtPercent: 0 },
        segments: []
      }))
    : (async (options) => {
        profileRouteAttempts += 1;
        const attemptStarted = Date.now();
        const candidateId = options && options.candidate && options.candidate.station
          ? String(options.candidate.station.id || "-")
          : "-";
        try {
          const response = await profileRoute(options);
          profileRouteTimings.push({
            candidateId,
            elapsedMs: Date.now() - attemptStarted,
            status: response && response.status || "unknown",
            distanceMeters: Number.isFinite(Number(response && response.distanceMeters))
              ? Math.round(Number(response.distanceMeters))
              : null,
            maxMeters: Number.isFinite(Number(options && options.maxMeters))
              ? Math.round(Number(options.maxMeters))
              : null
          });
          return response;
        } catch (error) {
          profileRouteTimings.push({
            candidateId,
            elapsedMs: Date.now() - attemptStarted,
            status: "error",
            distanceMeters: null,
            maxMeters: Number.isFinite(Number(options && options.maxMeters))
              ? Math.round(Number(options.maxMeters))
              : null
          });
          throw error;
        }
      });

  function slowestProfileRoutes() {
    return profileRouteTimings.slice().sort((a, b) =>
      b.elapsedMs - a.elapsedMs
    ).slice(0, 6);
  }

  function exceededSearchBudget() {
    return timeBudgetExceeded || (Number.isFinite(deadline) && Date.now() > deadline);
  }

  function destinationCandidate(graphMeters) {
    return {
      station: { id: "__destination__", name: "Destination" },
      location: destination,
      match: targets.destinationMatch,
      graphMeters,
      remainingGraphMeters: 0
    };
  }

  async function evaluatedRoutes(
    ranked, currentKey, currentLocation, cap, visited, history, arrival, depth = 0
  ) {
    const candidates = [];
    const stationLocations = new Set();
    const unique = [];
    for (const candidate of ranked) {
      const key = `${Number(candidate.location.lat).toFixed(4)}:${Number(candidate.location.lon).toFixed(4)}`;
      if (stationLocations.has(key)) continue;
      stationLocations.add(key);
      unique.push(candidate);
    }
    // OSM often contains several objects for one forecourt or a tight town
    // cluster. Spend K=6 on geographically distinct choices so the planner
    // compares real chain shapes instead of six aliases of the same detour.
    // Prefer corridor progress bins so a Wallace cluster cannot fill all K
    // slots and starve Truro/on-axis pumps that ranked slightly lower on tank use.
    const currentCoord = locationCoordinate(currentLocation);
    const destinationCoord = locationCoordinate(destination);
    const axisMeters = Math.max(1, haversineMeters(currentCoord, destinationCoord));
    const evaluationLimit = depth === 0 ? Math.min(6, effectiveK) : Math.min(2, effectiveK);
    const binCount = Math.max(3, evaluationLimit);
    const binUsed = new Set();
    function progressBin(candidate) {
      const point = locationCoordinate(candidate.location);
      const progress = Math.max(0, projectedProgressMeters(point, currentCoord, destinationCoord));
      return Math.min(binCount - 1, Math.floor((progress / axisMeters) * binCount));
    }
    function tooClose(candidate) {
      const point = locationCoordinate(candidate.location);
      return candidates.some((selected) =>
        haversineMeters(point, locationCoordinate(selected.location)) < SHORTLIST_MIN_SEPARATION_M
      );
    }
    function fillFrom(pool, limit = evaluationLimit) {
      for (const candidate of pool) {
        if (candidates.length >= limit) return;
        if (candidates.includes(candidate) || tooClose(candidate)) continue;
        const bin = progressBin(candidate);
        if (binUsed.has(bin)) continue;
        binUsed.add(bin);
        candidates.push(candidate);
      }
      for (const candidate of pool) {
        if (candidates.length >= limit) return;
        if (candidates.includes(candidate) || tooClose(candidate)) continue;
        candidates.push(candidate);
      }
    }
    if (probeFirstReachableStation) {
      candidates.push(...unique.slice().sort((a, b) =>
        Number(a.graphMeters) - Number(b.graphMeters)
      ).slice(0, evaluationLimit));
    } else {
      // A prior Dirt/Balanced/Clean calculation for the same rider corridor
      // may send back its proven pumps. Evaluate up to two of those first,
      // then fill the remaining bounded shortlist normally. They are hints,
      // never requirements; current access, range and continuation checks
      // still decide whether they remain valid for this profile.
      const retained = unique.filter((row) =>
        preferredStations.has(String(row.station.id))
      );
      fillFrom(retained, Math.min(2, evaluationLimit));
      // Preserve candidates capable of finishing with the fewest stops before
      // spending the bounded K=6 budget on general forward choices. One early
      // candidate is retained only as a sparse-corridor fallback.
      const watched = unique.filter((row) => tankCommitBand(
        row.graphMeters, cap, usableRangeMeters
      ) <= 1);
      const canFinishNextTank = watched.filter((row) =>
        Number.isFinite(Number(row.remainingGraphMeters)) &&
          Number(row.remainingGraphMeters) <= usableRangeMeters + 1
      );
      const preferred = watched.filter((row) => tankCommitBand(
        row.graphMeters, cap, usableRangeMeters
      ) === 0);
      const early = unique.filter((row) => tankCommitBand(
        row.graphMeters, cap, usableRangeMeters
      ) === 2);
      const watchedLimit = early.length ? Math.max(1, evaluationLimit - 1) : evaluationLimit;
      fillFrom(canFinishNextTank, watchedLimit);
      fillFrom(preferred, watchedLimit);
      fillFrom(watched, watchedLimit);
      fillFrom(early);
    }
    for (const candidate of unique) {
      if (candidates.length >= evaluationLimit) break;
      if (!candidates.includes(candidate)) candidates.push(candidate);
    }
    const hopStarted = Date.now();
    const rows = [];
    async function evaluateCandidate(candidate, rank) {
      let row;
      let diagnostic;
      const hopCap = hopBudgetMeters(candidate.graphMeters, cap);
      try {
        const response = await evaluateProfileHop({
          candidate,
          from: currentLocation,
          maxMeters: hopCap,
          profile,
          accessPolicy: rawPolicy,
          priorEdgeIds: [...history],
          arrivalEdgeId: arrival,
          backtrackFactor
        });
        const meters = Number(response && response.distanceMeters);
        const dirtPct = Number(response && response.stats && response.stats.dirtPercent);
        const firstBacktrackMeters = responseBacktrackMeters(response);
        const fits = response && response.status === "complete"
          && Number.isFinite(meters) && meters <= hopCap + 1
          && firstBacktrackMeters <= MAX_FUEL_RETRACE_M + 1;
        row = {
          candidate,
          response,
          rank,
          meters: Number.isFinite(meters) ? meters : candidate.graphMeters,
          dirtPct: Number.isFinite(dirtPct) ? dirtPct : 0,
          chainDirtPct: Number.isFinite(dirtPct) ? dirtPct : 0,
          fits,
          continuationDestinationMeters: null,
          continuationResponse: null,
          hasForwardStation: false,
          validForward: false,
          cleanFallbackCount: 0,
          cleanMajorRoadMeters: 0,
          cleanRoutedMeters: 0,
          firstQuality: null,
          chainQuality: null,
          nextHistory: null,
          nextArrival: null
        };
        row.firstQuality = routeChainQuality(response, avoidMotorways === true);
        row.chainQuality = row.firstQuality;
        const firstClean = cleanRouteQuality(response, avoidMotorways === true);
        row.cleanFallbackCount = firstClean.fallbackCount;
        row.cleanMajorRoadMeters = firstClean.majorRoadMeters;
        row.cleanRoutedMeters = firstClean.routedMeters;
        let validForward = false;
        if (fits) {
          const nextHistory = recentEdgeHistory([...history]);
          let nextArrival = arrival;
          for (const segment of (response && response.segments) || []) {
            const edgeId = segment && segment.edgeId != null ? String(segment.edgeId) : "";
            if (!edgeId) continue;
            appendRecentEdge(nextHistory, edgeId);
            nextArrival = edgeId;
          }
          row.nextHistory = nextHistory;
          row.nextArrival = nextArrival;
          const continuation = reachableFrom(
            String(candidate.station.id), candidate.location, candidate.match, usableRangeMeters,
            nextHistory, nextArrival
          );
          const forwardStations = rankForwardFuel(
            continuation.fuel,
            candidate.location,
            destination,
            usableRangeMeters,
            new Set([...visited, String(candidate.station.id)]),
            profile
          );
          row.continuationDestinationMeters = Number.isFinite(continuation.destinationMeters)
            ? continuation.destinationMeters
            : null;
          if (
            Number.isFinite(continuation.destinationMeters) &&
            continuation.destinationMeters <= usableRangeMeters + 1
          ) {
            const continuationResponse = await evaluateProfileHop({
              candidate: destinationCandidate(continuation.destinationMeters),
              from: candidate.location,
              maxMeters: usableRangeMeters,
              profile,
              accessPolicy: rawPolicy,
              priorEdgeIds: [...nextHistory],
              arrivalEdgeId: nextArrival,
              backtrackFactor
            });
            const routedContinuationMeters = Number(
              continuationResponse && continuationResponse.distanceMeters
            );
            if (
              continuationResponse && continuationResponse.status === "complete" &&
              Number.isFinite(routedContinuationMeters) &&
              routedContinuationMeters <= usableRangeMeters + 1 &&
              responseBacktrackMeters(continuationResponse) <= MAX_FUEL_RETRACE_M + 1
            ) {
              row.continuationResponse = continuationResponse;
              row.continuationDestinationMeters = routedContinuationMeters;
              const continuationDirtPct = Number(
                continuationResponse.stats && continuationResponse.stats.dirtPercent
              );
              if (Number.isFinite(continuationDirtPct)) {
                row.chainDirtPct = (
                  row.meters * row.dirtPct + routedContinuationMeters * continuationDirtPct
                ) / (row.meters + routedContinuationMeters);
              }
              const continuationClean = cleanRouteQuality(
                continuationResponse,
                avoidMotorways === true
              );
              row.cleanFallbackCount += continuationClean.fallbackCount;
              row.cleanMajorRoadMeters += continuationClean.majorRoadMeters;
              row.cleanRoutedMeters += continuationClean.routedMeters;
              row.chainQuality = combineChainQuality(
                row.firstQuality,
                routeChainQuality(continuationResponse, avoidMotorways === true)
              );
            } else {
              row.continuationDestinationMeters = null;
            }
          }
          row.hasForwardStation = forwardStations.length > 0;
          validForward = (
            row.continuationResponse != null
          ) || forwardStations.length > 0;
        }
        row.validForward = validForward;
        diagnostic = {
          id: String(candidate.station.id),
          departureId: currentKey,
          latitude: Number(candidate.location.lat),
          longitude: Number(candidate.location.lon),
          name: candidate.station.name || candidate.station.brand || "Fuel stop",
          meters: Math.round(row.meters),
          graphMeters: Number.isFinite(candidate.graphMeters)
            ? Math.round(candidate.graphMeters)
            : null,
          dirtPct: row.dirtPct,
          validForward,
          commitBand: tankCommitBand(row.meters, cap, usableRangeMeters),
          canFinish: row.continuationResponse != null,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null
        };
      } catch (_) {
        diagnostic = {
          id: String(candidate.station.id),
          departureId: currentKey,
          latitude: Number(candidate.location.lat),
          longitude: Number(candidate.location.lon),
          name: candidate.station.name || candidate.station.brand || "Fuel stop",
          meters: Math.round(candidate.graphMeters),
          dirtPct: 0,
          chainDirtPct: 0,
          validForward: false,
          commitBand: tankCommitBand(candidate.graphMeters, cap, usableRangeMeters),
          canFinish: false,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null
        };
        row = {
          candidate,
          response: null,
          rank,
          meters: candidate.graphMeters,
          dirtPct: 0,
          fits: false,
          continuationDestinationMeters: null,
          continuationResponse: null,
          hasForwardStation: false,
          validForward: false,
          cleanFallbackCount: Infinity,
          cleanMajorRoadMeters: Infinity,
          cleanRoutedMeters: 0,
          firstQuality: null,
          chainQuality: null,
          nextHistory: null,
          nextArrival: null
        };
      }
      return { row, diagnostic };
    }

    function hopProgress(row) {
      return Number(row.candidate.progressMeters) || row.meters;
    }

    function compareEvaluatedRows(a, b) {
      if (a.validForward !== b.validForward) return a.validForward ? -1 : 1;
      const aStops = a.continuationResponse ? 1 : 2;
      const bStops = b.continuationResponse ? 1 : 2;
      if (aStops !== bStops) return aStops - bStops;
      const crossDelta = Number(a.candidate.crossTrack) - Number(b.candidate.crossTrack);
      if (Number.isFinite(crossDelta) && Math.abs(crossDelta) > 2_000) return crossDelta;
      const progressDelta = hopProgress(b) - hopProgress(a);
      if (Math.abs(progressDelta) > 2_000) return progressDelta;
      const remainA = a.candidate.remainingGraphMeters == null
        ? NaN : Number(a.candidate.remainingGraphMeters);
      const remainB = b.candidate.remainingGraphMeters == null
        ? NaN : Number(b.candidate.remainingGraphMeters);
      const chainA = Number.isFinite(remainA) ? a.meters + remainA : NaN;
      const chainB = Number.isFinite(remainB) ? b.meters + remainB : NaN;
      if (Number.isFinite(chainA) && Number.isFinite(chainB) &&
          Math.abs(chainA - chainB) > 1_000) return chainA - chainB;
      switch (resolveProfile(profile)) {
        case "dirt": {
          const dirtDelta = b.chainDirtPct - a.chainDirtPct;
          if (Math.abs(dirtDelta) > 0.5) return dirtDelta;
          break;
        }
        case "balanced": {
          const mixDelta = Math.abs(a.chainDirtPct - 50) - Math.abs(b.chainDirtPct - 50);
          if (Math.abs(mixDelta) > 0.5) return mixDelta;
          break;
        }
        case "cleanest": {
          if (a.cleanFallbackCount !== b.cleanFallbackCount) {
            return a.cleanFallbackCount - b.cleanFallbackCount;
          }
          const majorShareA = a.cleanRoutedMeters > 0
            ? a.cleanMajorRoadMeters / a.cleanRoutedMeters
            : 0;
          const majorShareB = b.cleanRoutedMeters > 0
            ? b.cleanMajorRoadMeters / b.cleanRoutedMeters
            : 0;
          if (Math.abs(majorShareA - majorShareB) > 0.005) {
            return majorShareA - majorShareB;
          }
          const foundation = Number(profileMeters);
          const foundationCap = Number.isFinite(foundation) && foundation > 0
            ? foundation * 1.12
            : Infinity;
          const aCoherent = chainA <= foundationCap + 1;
          const bCoherent = chainB <= foundationCap + 1;
          if (aCoherent !== bCoherent) return aCoherent ? -1 : 1;
          if (aCoherent && bCoherent) {
            const chainDelta = chainA - chainB;
            if (Math.abs(chainDelta) > 1_000) return chainDelta;
          }
          break;
        }
        default:
          break;
      }
      return a.rank - b.rank;
    }

    function canUnevaluatedCandidateBeatComplete(candidate, winner) {
      const remaining = Number(candidate.remainingGraphMeters);
      const arrivalLimit = destinationFuelUsedLimitMeters == null
        ? NaN
        : Number(destinationFuelUsedLimitMeters);
      const oneStopLimit = Number.isFinite(arrivalLimit)
        ? Math.min(usableRangeMeters, arrivalLimit)
        : usableRangeMeters;
      // Graph distance is a lower bound for the active-profile route. If even
      // that cannot finish after this pump, it cannot tie the winner's stop count.
      if (!Number.isFinite(remaining) || remaining > oneStopLimit + 1) return false;

      const candidateCross = Number(candidate.crossTrack);
      const winnerCross = Number(winner.candidate.crossTrack);
      if (Number.isFinite(candidateCross) && Number.isFinite(winnerCross)) {
        if (candidateCross < winnerCross - 2_000) return true;
        if (candidateCross > winnerCross + 2_000) return false;
      }
      const candidateProgress = Number(candidate.progressMeters) || Number(candidate.graphMeters) || 0;
      const winnerProgress = hopProgress(winner);
      if (candidateProgress > winnerProgress + 2_000) return true;
      if (candidateProgress < winnerProgress - 2_000) return false;

      const candidateLowerBound = Number(candidate.graphMeters) + remaining;
      const winnerChainMeters =
        Number(winner.meters) + Number(winner.continuationDestinationMeters);
      if (
        Number.isFinite(candidateLowerBound) && Number.isFinite(winnerChainMeters) &&
        candidateLowerBound > winnerChainMeters + 1_000
      ) return false;
      // Direction and distance are still tied closely enough that profile
      // quality could decide the result. Evaluate this candidate.
      return true;
    }

    // Profile-route probes dominate fuel latency. Run two geographically
    // distinct choices in parallel, then check the request deadline before the
    // next pair. This compares up to K=6 real rides without unbounded search.
    const batchSize = Math.min(2, Math.max(1, candidates.length));
    const watchedAvailable = unique.some((row) => tankCommitBand(
      row.graphMeters, cap, usableRangeMeters
    ) <= 1);
    const earlyAvailable = unique.some((row) => tankCommitBand(
      row.graphMeters, cap, usableRangeMeters
    ) === 2);
    for (let startRank = 0; startRank < candidates.length; startRank += batchSize) {
      if (rows.length > 0 && Date.now() >= deadline) break;
      const batch = candidates.slice(startRank, startRank + batchSize);
      const evaluatedBatch = await Promise.all(batch.map((candidate, offset) =>
        evaluateCandidate(candidate, startRank + offset)
      ));
      evaluatedBatch.sort((a, b) => a.row.rank - b.row.rank);
      for (const evaluated of evaluatedBatch) {
        rows.push(evaluated.row);
        stationCandidates.push(evaluated.diagnostic);
      }
      const watchedFit = rows.some((evaluated) =>
        evaluated.fits && evaluated.validForward && tankCommitBand(
          evaluated.meters, cap, usableRangeMeters
        ) <= 1
      );
      const earlyFit = rows.some((evaluated) =>
        evaluated.fits && evaluated.validForward && tankCommitBand(
          evaluated.meters, cap, usableRangeMeters
        ) === 2
      );
      const provenComplete = rows.filter((evaluated) =>
        evaluated.fits && evaluated.validForward && evaluated.continuationResponse &&
        (
          destinationFuelUsedLimitMeters == null ||
          !Number.isFinite(Number(destinationFuelUsedLimitMeters)) ||
          Number(evaluated.continuationDestinationMeters) <=
            Number(destinationFuelUsedLimitMeters) + 1
        )
      ).sort(compareEvaluatedRows)[0];
      const requiredStopsSatisfied = depth + 1 >= Math.max(
        0, Number(minimumFuelStops) || 0
      );
      if (provenComplete && requiredStopsSatisfied && (!watchedAvailable || tankCommitBand(
        provenComplete.meters, cap, usableRangeMeters
      ) <= 1)) {
        const remaining = candidates.slice(startRank + batch.length);
        if (!remaining.some((candidate) =>
          canUnevaluatedCandidateBeatComplete(candidate, provenComplete)
        )) break;
      }
      // Graph-only probes have no ride-quality signal. Real fuel allocation
      // keeps routing candidates until either their profile rides are compared
      // or the remaining choices are proven unable to beat a complete winner.
      if (
        graphOnlyFeeler && rows.length >= 2 &&
        (watchedFit || (!watchedAvailable && (earlyFit || !earlyAvailable)))
      ) break;
    }
    const elapsed = Date.now() - hopStarted;
    maxHopMs = Math.max(maxHopMs, elapsed);
    void hopTimeBudgetMs;
    const fitting = rows.filter((row) => row.fits);
    if (probeFirstReachableStation) {
      return fitting.sort((a, b) => a.meters - b.meters || a.rank - b.rank);
    }
    // Reachability deliberately includes the whole usable tank so an early
    // top-up can rescue a genuinely sparse corridor. It must not, however,
    // compete with a valid route-connected pump after the 50% search window.
    // The previous shortlist let a 32 km pump win a full-tank 260 km departure
    // even though several later candidates were valid, multiplying one needed
    // stop into three. Use early pumps only as the safety fallback they are.
    const watchedFitting = fitting.filter((row) =>
      row.validForward && tankCommitBand(row.meters, cap, usableRangeMeters) <= 1
    );
    const eligibleFitting = watchedFitting.length
      ? fitting.filter((row) => tankCommitBand(row.meters, cap, usableRangeMeters) <= 1)
      : fitting;
    eligibleFitting.sort(compareEvaluatedRows);
    return eligibleFitting;
  }

  async function search(
    currentKey, currentLocation, currentMatch, visited, depth, history, arrival,
    prefixStops = [], prefixGraphMeters = []
  ) {
    const physicalRemaining = haversineMeters(
      locationCoordinate(currentLocation), physicalDestination
    );
    const progressMeters = Math.max(0, physicalTotal - physicalRemaining);
    if (progressMeters > bestPartial.progressMeters) {
      bestPartial = {
        progressMeters,
        stops: prefixStops.slice(),
        graphMeters: prefixGraphMeters.slice(),
        location: currentLocation
      };
    }
    if (Date.now() >= deadline) {
      timeBudgetExceeded = true;
      return null;
    }
    if (states >= maxStates || depth > searchStopLimit) return null;
    states += 1;
    const cap = depth === 0 ? firstLegMaxMeters : usableRangeMeters;
    if (!(cap > 0)) return null;
    const reach = reachableFrom(
      currentKey, currentLocation, currentMatch, cap, history, arrival
    );
    if (depth === 0) {
      stationsReachableWithinRange = Array.isArray(reach.fuel) ? reach.fuel.length : 0;
      firstReachableStationMeters = reach.fuel.reduce((best, row) =>
        best == null || row.graphMeters < best ? row.graphMeters : best
      , null);
      if (probeFirstReachableStation) {
        const ranked = rankForwardFuel(
          reach.fuel, currentLocation, destination, cap, visited, profile,
          null,
          reach.destinationMeters,
          true,
          usableRangeMeters
        );
        const evaluated = await evaluatedRoutes(
          ranked, currentKey, currentLocation, cap, visited, history, arrival
        );
        const evaluatedFirstReachableStationMeters = evaluated.reduce((best, row) =>
          best == null || row.meters < best ? row.meters : best
        , null);
        // K is deliberately bounded, but a fuel-range promise is always based
        // on a completed profile route. Raw graph distance discovers candidates;
        // it never substitutes for routed distance in look-ahead.
        firstReachableStationMeters = evaluatedFirstReachableStationMeters;
        return { stops: [], graphMeters: [], probe: true };
      }
    }
    const mustContinueForProfileRide = depth < Math.max(0, Number(minimumFuelStops) || 0);
    let stopRequiredHere = (depth === 0 && requireFuelStopBeforeEnd) || mustContinueForProfileRide;
    const configuredDestinationLimit = destinationFuelUsedLimitMeters == null
      ? NaN
      : Number(destinationFuelUsedLimitMeters);
    // destinationFuelUsedLimitMeters is measured from a full tank. If this
    // rider leg begins with fuel already consumed, only the remaining portion
    // of that arrival allowance is available before the first generated pump.
    // After a pump, the next search depth starts with a full tank again.
    const carriedFuelUsed = depth === 0
      ? Math.max(0, usableRangeMeters - firstLegMaxMeters)
      : 0;
    const destinationLimit = Number.isFinite(configuredDestinationLimit)
      ? Math.max(0, configuredDestinationLimit - carriedFuelUsed)
      : NaN;
    let directPlan = null;
    if (
      Number.isFinite(reach.destinationMeters) &&
      reach.destinationMeters <= cap &&
      (!Number.isFinite(destinationLimit) || reach.destinationMeters <= destinationLimit + 1)
    ) {
      try {
        const response = await evaluateProfileHop({
          candidate: destinationCandidate(reach.destinationMeters),
          from: currentLocation,
          maxMeters: cap,
          profile,
          accessPolicy: rawPolicy,
          priorEdgeIds: [...history],
          arrivalEdgeId: arrival,
          backtrackFactor
        });
        const routedMeters = Number(response && response.distanceMeters);
        if (
          response && response.status === "complete" &&
          Number.isFinite(routedMeters) && routedMeters <= cap + 1 &&
          (!Number.isFinite(destinationLimit) || routedMeters <= destinationLimit + 1)
        ) {
          directPlan = {
            stops: [],
            graphMeters: [routedMeters],
            routes: [response],
            quality: routeChainQuality(response, avoidMotorways === true),
            complete: true
          };
          if (stopRequiredHere) directPlan = null;
          // A reachable destination wins unless a hard range, explicit station,
          // or destination-escape requirement proves that a stop is needed.
          if (depth === 0 && !stopRequiredHere) {
            return directPlan;
          }
        }
      } catch (_) {
        // Graph reachability is only a candidate generator. Continue searching
        // for a pump when the active profile cannot complete this final hop.
      }
    }
    if (depth >= searchStopLimit) {
      return directPlan;
    }

    let ranked = rankForwardFuel(
      reach.fuel,
      currentLocation,
      destination,
      cap,
      visited,
      profile,
      destinationFuelUsedLimitMeters,
      reach.destinationMeters,
      depth === 0 && firstLegMaxMeters + 1 < usableRangeMeters,
      usableRangeMeters
    );
    if (depth === 0 && requiredFirstStationId != null) {
      const required = String(requiredFirstStationId);
      ranked = ranked.filter((row) => String(row.station.id) === required);
      if (!ranked.length) return null;
    }
    // This is bounded graph look-ahead, not full route probing. Six branches
    // are enough to escape a closed service-road pump without exponential work.
    const evaluated = await evaluatedRoutes(
      ranked, currentKey, currentLocation, cap, visited, history, arrival, depth
    );
    const stationPlans = [];
    for (const evaluation of evaluated.slice(0, 2)) {
      if (states >= maxStates) break;
      if (!evaluation.validForward) continue;
      const candidate = evaluation.candidate;
      const stop = {
        ...candidate.station,
        graphMeters: evaluation.meters,
        dirtPercent: evaluation.dirtPct
      };
      const continuationMeters = Number(evaluation.continuationDestinationMeters);
      const requiredStopsSatisfied = depth + 1 >= Math.max(
        0, Number(minimumFuelStops) || 0
      );
      if (
        evaluation.continuationResponse &&
        Number.isFinite(continuationMeters) &&
        requiredStopsSatisfied &&
        (!Number.isFinite(destinationLimit) || continuationMeters <= destinationLimit + 1)
      ) {
        stationPlans.push({
          stops: [stop],
          graphMeters: [evaluation.meters, continuationMeters],
          routes: [evaluation.response, evaluation.continuationResponse],
          quality: evaluation.chainQuality,
          directionalDetourMeters: Number(evaluation.candidate.crossTrack) || 0,
          progressMeters: Number(evaluation.candidate.progressMeters) || 0,
          complete: true,
          partial: false
        });
      }
      // Once this hop has produced a complete minimum-stop plan, recursively
      // adding another pump can only make that same branch worse. Candidate
      // comparison above has already preserved any live one-stop rivals whose
      // direction, distance, or profile quality could still win.
      if (requiredStopsSatisfied && stationPlans.some((plan) => plan.complete)) {
        continue;
      }
      if (Date.now() >= deadline) {
        if (!stationPlans.length && allowPartialWindow && evaluation.validForward) {
          stationPlans.push({
            stops: [stop],
            graphMeters: [evaluation.meters],
            routes: [evaluation.response],
            quality: evaluation.firstQuality,
            complete: false,
            partial: true
          });
        }
        if (!stationPlans.length) timeBudgetExceeded = true;
        break;
      }
      const id = String(candidate.station.id);
      const nextVisited = new Set(visited);
      nextVisited.add(id);
      const nextHistory = evaluation.nextHistory || new Set(history);
      const nextArrival = evaluation.nextArrival || arrival;
      const tail = await search(
        id, candidate.location, candidate.match, nextVisited, depth + 1,
        nextHistory, nextArrival,
        prefixStops.concat([{
          ...candidate.station,
          graphMeters: evaluation.meters,
          dirtPercent: evaluation.dirtPct
        }]),
        prefixGraphMeters.concat([evaluation.meters])
      );
      if (tail) {
        stationPlans.push({
          stops: [stop].concat(tail.stops),
          graphMeters: [evaluation.meters].concat(tail.graphMeters),
          routes: [evaluation.response].concat(tail.routes || []),
          quality: combineChainQuality(evaluation.firstQuality, tail.quality),
          directionalDetourMeters: Number(evaluation.candidate.crossTrack) || 0,
          progressMeters: Number(evaluation.candidate.progressMeters) || 0,
          complete: tail.complete === true,
          partial: !!tail.partial
        });
        continue;
      }
      // A bounded look-ahead may end before B while still proving a forward
      // profile-routed pump. Return only the visible window; the next request
      // resumes from that committed anchor with a fresh budget.
      if (allowPartialWindow && evaluation.validForward &&
          depth + 1 >= Math.min(returnedStopLimit, searchStopLimit)) {
        stationPlans.push({
          stops: [stop],
          graphMeters: [evaluation.meters],
          routes: [evaluation.response],
          quality: evaluation.firstQuality,
          complete: false,
          partial: true
        });
      }
    }
    if (stationPlans.length) {
      stationPlans.sort((a, b) => compareChainPlans(a, b, profile, cap));
      if (stopRequiredHere) return stationPlans[0];
      const options = directPlan ? stationPlans.concat([directPlan]) : stationPlans;
      options.sort((a, b) => compareChainPlans(a, b, profile, cap));
      return options[0];
    }
    return directPlan;
  }

  const chain = await search(
    "start", start, startMatch, new Set((excludedStationIds || []).map(String)), 0,
    recentEdgeHistory((priorEdgeIds || []).map(String)),
    arrivalEdgeId == null ? null : String(arrivalEdgeId), [], []
  );
  if (!chain) {
    const routedPrefixMeters = bestPartial.graphMeters.reduce((sum, meters) => sum + Number(meters || 0), 0);
    const knownProfileMeters = profileMeters == null ? NaN : Number(profileMeters);
    const gapMeters = Number.isFinite(knownProfileMeters)
      ? Math.max(0, knownProfileMeters - routedPrefixMeters)
      : Math.max(0, physicalTotal - bestPartial.progressMeters);
    const remainingCap = bestPartial.stops.length ? usableRangeMeters : firstLegMaxMeters;
    const plannedFailure = {
      ok: false,
      error: timeBudgetExceeded ? "window_time_budget" : "no_route_connected_fuel_chain",
      timeBudgetExceeded
    };
    const gapReason = classifyFuelFailureReason(plannedFailure);
    return {
      ok: false,
      error: plannedFailure.error,
      message: timeBudgetExceeded
        ? "Fuel planning could not finish this window in time."
        : "No forward, route-connected fuel chain fits the usable range.",
      diagnostics: enrichFuelDiagnostics({
        ...fuelDecisionDiagnostics,
        targetPrepareMs: targets.prepareDiagnostics.elapsedMs,
        targetCacheHit: targets.prepareDiagnostics.cacheHit,
        stationsConsidered: targets.prepareDiagnostics.stationsConsidered,
        states,
        dijkstraPops,
        matchedFuel: targets.prepareDiagnostics.stationsMatched,
        candidateK: effectiveK,
        stationCandidates,
        elapsedMs: Date.now() - started,
        maxHopMs,
        profileRouteAttempts,
        slowestProfileRoutes: slowestProfileRoutes(),
        searchDeadlineOverrunMs: Number.isFinite(deadline)
          ? Math.max(0, Date.now() - deadline)
          : 0,
        timeBudgetExceeded: exceededSearchBudget()
      }, {
        stationsReachableWithinRange,
        candidatesEvaluated: stationCandidates.length,
        gapReason,
        failureReason: gapReason,
        stationCandidates
      }),
      firstReachableStationMeters,
      stops: bestPartial.stops,
      graphMeters: bestPartial.graphMeters,
      routes: [],
      gapMeters,
      overByMeters: Math.max(0, gapMeters - remainingCap),
      gapFrom: bestPartial.stops[bestPartial.stops.length - 1] || null,
      gapTo: {
        id: "rider-waypoint-end",
        lat: Number(destination.lat),
        lon: Number(destination.lon),
        name: "Rider waypoint"
      }
    };
  }

  const returnedStops = chain.stops.slice(0, returnedStopLimit);
  const reachesDestination = chain.complete === true && chain.stops.length <= returnedStopLimit;
  const returnedGraphMeters = reachesDestination
    ? chain.graphMeters
    : chain.graphMeters.slice(0, returnedStops.length);
  const returnedRoutes = reachesDestination
    ? (chain.routes || [])
    : (chain.routes || []).slice(0, returnedStops.length);
  return {
    ok: true,
    stops: returnedStops,
    graphMeters: returnedGraphMeters,
    routes: returnedRoutes,
    stationCandidates,
    firstReachableStationMeters,
    windowComplete: reachesDestination,
    diagnostics: enrichFuelDiagnostics({
      ...fuelDecisionDiagnostics,
      targetPrepareMs: targets.prepareDiagnostics.elapsedMs,
      targetCacheHit: targets.prepareDiagnostics.cacheHit,
      stationsConsidered: targets.prepareDiagnostics.stationsConsidered,
      strategy: "forward_graph_reachability",
      states,
      dijkstraPops,
      matchedFuel: targets.prepareDiagnostics.stationsMatched,
      candidateK: effectiveK,
      elapsedMs: Date.now() - started,
      maxHopMs,
      profileRouteAttempts,
      slowestProfileRoutes: slowestProfileRoutes(),
      searchDeadlineOverrunMs: Number.isFinite(deadline)
        ? Math.max(0, Date.now() - deadline)
        : 0,
      timeBudgetExceeded: exceededSearchBudget(),
      selectedReason: returnedStops.length
        ? "minimum_stops_forward"
        : "direct_destination"
    }, {
      stationsReachableWithinRange,
      candidatesEvaluated: stationCandidates.length,
      stationCandidates
    })
  };
}

/**
 * Cross-region fuel planning applies the same forward operation to each
 * topology-authored regional seam while carrying fuel consumption across the
 * seam. Seams are never returned as rider waypoints and never reset the tank.
 */
async function planCrossRegionFuelChain(body, selection, fuelOptions, dependencies = {}) {
  const loadRuntime = dependencies.loadGraphsForRequest || loadGraphsForRequest;
  const loadRegion = dependencies.loadRegionFuel || loadRegionFuel;
  const resolveSeams = dependencies.resolveChainSeamWaypoints || resolveChainSeamWaypoints;
  const planRuntime = dependencies.planFuelChainOnRuntime || planFuelChainOnRuntime;
  let waypoints = corridorLocationsForRoute(body.locations || [], {
    profile: body.profile,
    forChain: true
  });
  const resolved = await resolveSeams(waypoints, body);
  if (!resolved.ok) {
    return {
      status: "failed",
      error: resolved.error || "seam_snap_failed",
      message: resolved.message || "A regional road-fabric seam could not be resolved."
    };
  }
  waypoints = resolved.waypoints;

  const usableRangeMeters = Number(fuelOptions.usableRangeMeters);
  const initialCap = Number(fuelOptions.firstLegMaxMeters || usableRangeMeters);
  let fuelUsedMeters = Math.max(0, usableRangeMeters - initialCap);
  const allStops = [];
  const graphMeters = [];
  const stationCandidates = [];
  const packIdentities = [];
  let totalStates = 0;
  let totalPops = 0;
  let matchedFuel = 0;
  let maxHopMs = 0;
  let graphMeterCountThroughLastStop = 0;
  const started = Date.now();
  const windowMaxStops = Math.min(12, Math.max(1, Number(fuelOptions.windowMaxStops) || 12));
  const allowPartialWindow = !!fuelOptions.allowPartialWindow;
  const windowDeadline = Number(fuelOptions.windowTimeBudgetMs) > 0
    ? started + Number(fuelOptions.windowTimeBudgetMs)
    : Infinity;

  for (let i = 0; i < waypoints.length - 1; i += 1) {
    if (Date.now() >= windowDeadline) {
      clearGraphCache();
      return {
        status: "gap",
        error: "window_time_budget",
        message: "This fuel window reached its planning budget.",
        regionIds: selection.regionIds,
        packIdentity: mergePackIdentities(packIdentities),
        stops: allStops,
        graphMeters,
        gapMeters: null,
        overByMeters: null
      };
    }
    const hopStart = waypoints[i];
    const hopEnd = waypoints[i + 1];
    const startCoord = locationCoordinate(hopStart);
    const endCoord = locationCoordinate(hopEnd);
    const startFamily = provinceFamily(
      hopStart.resolvedRegionId || primaryRegionForPoint(startCoord[0], startCoord[1])
    );
    const endFamily = provinceFamily(
      hopEnd.resolvedRegionId || primaryRegionForPoint(endCoord[0], endCoord[1])
    );
    const regionId = i === waypoints.length - 2
      ? endFamily || startFamily
      : startFamily || endFamily;
    if (!regionId) {
      return {
        status: "failed",
        error: "region_unknown",
        message: `Could not resolve the regional fabric for fuel segment ${i + 1}.`,
        packIdentity: mergePackIdentities(packIdentities)
      };
    }

    clearGraphCache();
    const resolution = resolveGraphRequest({
      ...body,
      regionId,
      locations: [hopStart, hopEnd]
    });
    const fuel = await loadRegion(regionId);
    if (fuel && fuel.packIdentity) packIdentities.push(fuel.packIdentity);
    if (!fuel || !Array.isArray(fuel.stations) || !fuel.stations.length) {
      clearGraphCache();
      return {
        status: "unknown",
        error: "fuel_data_unavailable",
        message: `Fuel data is unavailable for regional segment ${i + 1}/${waypoints.length - 1}.`,
        regionIds: selection.regionIds,
        packIdentity: mergePackIdentities(packIdentities),
        stops: allStops,
        graphMeters
      };
    }
    const runtime = await loadRuntime(resolution, {
      locations: [hopStart, hopEnd],
      profile: body.profile
    });
    packIdentities.push(...(runtime.packIdentity || []));
    const cap = usableRangeMeters - fuelUsedMeters;
    const planned = await planRuntime({
      runtime,
      stations: fuel.stations,
      start: hopStart,
      destination: hopEnd,
      profile: String(body.profile || "dirt").toLowerCase(),
      accessPolicy: body.accessPolicy,
      usableRangeMeters,
      firstLegMaxMeters: cap,
      // Only an actual pump satisfies this requirement; a seam does not.
      requireFuelStopBeforeEnd: false,
      minimumFuelStops: i === waypoints.length - 2
        ? Math.max(0, Number(fuelOptions.minimumFuelStops) || 0) - allStops.length
        : 0,
      destinationFuelUsedLimitMeters: i === waypoints.length - 2
        ? fuelOptions.destinationFuelUsedLimitMeters
        : null,
      avoidEdgeIds: ((body.options || {}).avoidEdgeIds || []),
      cleanMetroMultiplier: (body.options || {}).cleanMetroMultiplier,
      avoidMotorways: (body.options || {}).avoidMotorways === true,
      priorEdgeIds: ((body.options || {}).priorEdgeIds || []).slice(-MAX_RECENT_EDGE_HISTORY),
      arrivalEdgeId: (body.options || {}).arrivalEdgeId || null,
      backtrackFactor: (body.options || {}).backtrackFactor || 4,
      excludedStationIds: fuelOptions.excludedStationIds || [],
      requiredFirstStationId: i === 0 ? fuelOptions.requiredFirstStationId : null,
      maxStops: Math.max(1, windowMaxStops - allStops.length),
      allowPartialWindow,
      timeBudgetMs: Number.isFinite(windowDeadline)
        ? Math.max(1, windowDeadline - Date.now())
        : null,
      profileMeters: haversineMeters(startCoord, endCoord),
      // Cross-region feelers obey the same contract as same-region feelers:
      // graph reachability selects the next anchor; the client routes only the
      // committed rider leg. Do not generate disposable profile scout routes.
      graphOnlyFeeler: fuelOptions.forwardFeeler === true
    });
    if (!planned.ok) {
      clearGraphCache();
      // A time budget is an inconclusive search, never proof of a physical
      // fuel gap. Only an exhausted graph search may produce gap state.
      return {
        status: fuelPlanStatus(planned),
        error: planned.error,
        message: `${planned.message || "No fuel chain found"} (regional segment ${i + 1}/${waypoints.length - 1})`,
        regionIds: selection.regionIds,
        packIdentity: mergePackIdentities(packIdentities),
        stops: allStops.concat(planned.stops || []),
        graphMeters: graphMeters.concat(planned.graphMeters || []),
        diagnostics: planned.diagnostics || null,
        gapMeters: planned.gapMeters,
        overByMeters: planned.overByMeters,
        gapFrom: planned.gapFrom,
        gapTo: planned.gapTo
      };
    }

    const priorStopCount = allStops.length;
    const priorGraphMeterCount = graphMeters.length;
    allStops.push(...planned.stops);
    graphMeters.push(...planned.graphMeters);
    if (planned.stops.length) {
      const remainingWindowStops = Math.max(0, windowMaxStops - priorStopCount);
      graphMeterCountThroughLastStop = priorGraphMeterCount + Math.min(
        remainingWindowStops,
        planned.stops.length,
        planned.graphMeters.length
      );
    }
    stationCandidates.push(...(planned.stationCandidates || []));
    totalStates += Number(planned.diagnostics && planned.diagnostics.states) || 0;
    totalPops += Number(planned.diagnostics && planned.diagnostics.dijkstraPops) || 0;
    matchedFuel += Number(planned.diagnostics && planned.diagnostics.matchedFuel) || 0;
    maxHopMs = Math.max(maxHopMs, Number(planned.diagnostics && planned.diagnostics.maxHopMs) || 0);
    if (
      allowPartialWindow &&
      (planned.windowComplete === false || allStops.length >= windowMaxStops)
    ) {
      clearGraphCache();
      return {
        status: "complete",
        error: null,
        message: null,
        regionIds: selection.regionIds,
        packIdentity: mergePackIdentities(packIdentities),
        stops: allStops.slice(0, windowMaxStops),
        // Regional seams consume fuel but are not rider-visible stops. Keep
        // every graph minimum through the returned pump; slicing this array by
        // stop count drops the pre-seam hop and disables the client's reserved
        // cross-region cap because the hop counts no longer match.
        graphMeters: graphMeterCountThroughLastStop > 0
          ? graphMeters.slice(0, graphMeterCountThroughLastStop)
          : graphMeters,
        stationCandidates,
        windowComplete: false,
        diagnostics: enrichFuelDiagnostics({
          strategy: "forward_graph_reachability_across_seams_window",
          states: totalStates,
          dijkstraPops: totalPops,
          matchedFuel,
          elapsedMs: Date.now() - started,
          maxHopMs
        }, {
          candidatesEvaluated: stationCandidates.length,
          stationCandidates
        })
      };
    }
    if (planned.stops.length) {
      fuelUsedMeters = planned.graphMeters[planned.graphMeters.length - 1] || 0;
    } else {
      fuelUsedMeters += planned.graphMeters[0] || 0;
    }
    if (fuelUsedMeters > usableRangeMeters + 1) {
      clearGraphCache();
      return {
        status: "failed",
        error: "fuel_range_exceeded_at_seam",
        message: "The route reaches a regional boundary after the usable fuel range.",
        packIdentity: mergePackIdentities(packIdentities),
        diagnostics: enrichFuelDiagnostics({}, {
          failureReason: "fuel_range_exceeded_at_seam",
          gapReason: "fuel_range_exceeded_at_seam"
        })
      };
    }
  }
  clearGraphCache();

  if (fuelOptions.requireFuelStopBeforeEnd && !allStops.length) {
    return {
      status: "failed",
      error: "fuel_stop_required",
      message: "A route-connected fuel stop is required before point 2.",
      packIdentity: mergePackIdentities(packIdentities),
      diagnostics: enrichFuelDiagnostics({}, {
        failureReason: "fuel_stop_required",
        gapReason: "fuel_stop_required"
      })
    };
  }
  return {
    status: "complete",
    error: null,
    message: null,
    regionIds: selection.regionIds,
    packIdentity: mergePackIdentities(packIdentities),
    stops: allStops,
    graphMeters,
    stationCandidates,
    windowComplete: true,
    diagnostics: enrichFuelDiagnostics({
      strategy: "forward_graph_reachability_across_seams",
      states: totalStates,
      dijkstraPops: totalPops,
      matchedFuel,
      elapsedMs: Date.now() - started,
      maxHopMs
    }, {
      candidatesEvaluated: stationCandidates.length,
      stationCandidates
    })
  };
}

/**
 * Consecutive numbered waypoints are planned as their own hops. A waypoint
 * that currently sits on a packed pump resets the tank; an ordinary waypoint
 * only carries remaining fuel. Automatic candidate search opens after half of
 * the reserve-adjusted usable range has been consumed.
 */
async function planFuelChainAcrossRiderWaypoints(body, {
  locations,
  usableRangeMeters,
  firstLegMaxMeters,
  rawFuelOptions,
  dependencies
}) {
  const loadFuel = dependencies.loadFuelForLocations || loadFuelForLocations;
  const fuel = await loadFuel(locations);
  if (!fuel.ok) {
    return {
      status: "error",
      error: fuel.error,
      message: fuel.message
    };
  }
  const waypointResets = deriveWaypointRefuels(locations, fuel.stations);
  const resetAt = new Set(waypointResets.map((row) => row.locationIndex));
  let fuelUsedMeters = Math.max(0, usableRangeMeters - firstLegMaxMeters);
  const allStops = [];
  const graphMeters = [];
  const stationCandidates = [];
  const packIdentities = [fuel.packIdentity];
  let lastHop = null;

  for (let index = 0; index < locations.length - 1; index += 1) {
    const hopFuel = { ...rawFuelOptions };
    delete hopFuel.profileMeters;
    hopFuel.usableRangeMeters = usableRangeMeters;
    hopFuel.firstLegMaxMeters = Math.max(0, usableRangeMeters - fuelUsedMeters);
    hopFuel.requireFuelStopBeforeEnd = false;
    hopFuel.minimumFuelStops = 0;
    hopFuel.destinationFuelUsedLimitMeters = null;
    hopFuel.riderLegId = `${rawFuelOptions.riderLegId || "itinerary"}:${index}`;
    const hop = await fuelChainRequest({
      ...body,
      locations: [locations[index], locations[index + 1]],
      fuel: hopFuel
    }, dependencies);
    lastHop = hop;
    stationCandidates.push(...(hop.stationCandidates || []));
    packIdentities.push(hop.packIdentity);
    if (hop.status !== "complete") {
      return {
        ...hop,
        stops: allStops.concat(hop.stops || []),
        graphMeters: graphMeters.concat(hop.graphMeters || []),
        stationCandidates,
        waypointResets,
        packIdentity: mergePackIdentities(...packIdentities)
      };
    }
    allStops.push(...(hop.stops || []));
    graphMeters.push(...(hop.graphMeters || []));
    if (resetAt.has(index + 1)) {
      fuelUsedMeters = 0;
    } else if ((hop.stops || []).length) {
      fuelUsedMeters = hop.graphMeters[hop.graphMeters.length - 1] || 0;
    } else {
      fuelUsedMeters += hop.graphMeters[0] || 0;
    }
  }

  return {
    status: "complete",
    error: null,
    message: null,
    serviceVersion: FUEL_CHAIN_SERVICE_VERSION,
    regionIds: fuel.regionIds,
    packIdentity: mergePackIdentities(...packIdentities),
    stops: allStops,
    graphMeters,
    stationCandidates,
    waypointResets,
    windowComplete: true,
    diagnostics: lastHop && lastHop.diagnostics
  };
}

async function fuelChainRequest(body = {}, dependencies = {}) {
  const requestStarted = Date.now();
  const loadFuel = dependencies.loadFuelForLocations || loadFuelForLocations;
  const loadRuntime = dependencies.loadGraphsForRequest || loadGraphsForRequest;
  const endpointResolution = await resolveLocationsByEligibleEdge(body, {
    probeRegion: dependencies.probeRegion
  });
  body = endpointResolution.body;
  const selection = resolveGraphRequest(body);
  if (!selection.ok) {
    return {
      status: "error",
      error: selection.error,
      message: selection.message
    };
  }
  const locations = Array.isArray(body.locations) ? body.locations : [];
  if (locations.length < 2) {
    return {
      status: "error",
      error: "invalid_locations",
      message: "Provide point 1 and point 2."
    };
  }
  const rawFuelOptions = body.fuel || {};
  const windowBudgetMs = Number(rawFuelOptions.windowTimeBudgetMs) > 0
    ? Number(rawFuelOptions.windowTimeBudgetMs)
    : null;
  const windowBudgetOverrunMs = () => windowBudgetMs == null
    ? 0
    : Math.max(0, Date.now() - requestStarted - windowBudgetMs);
  const forwardFeeler = rawFuelOptions.forwardFeeler === true;
  const routeFirstPlan = rawFuelOptions.routeFirstPlan === true && !forwardFeeler &&
    selection.mode !== "canada-chain";
  let fuelOptions = rawFuelOptions;
  const usableRangeMeters = Number(fuelOptions.usableRangeMeters);
  const firstLegMaxMeters = Number(fuelOptions.firstLegMaxMeters || usableRangeMeters);
  if (!(usableRangeMeters > 0) || !(firstLegMaxMeters > 0)) {
    return {
      status: "error",
      error: "invalid_fuel_range",
      message: "Fuel range must be greater than zero."
    };
  }

  if (locations.length > 2) {
    return planFuelChainAcrossRiderWaypoints(body, {
      locations,
      usableRangeMeters,
      firstLegMaxMeters,
      rawFuelOptions,
      dependencies
    });
  }

  let profileMeters = rawFuelOptions.profileMeters == null
    ? NaN : Number(rawFuelOptions.profileMeters);
  let foundationRoute = null;
  let fuel = null;
  let routeFirstMs = 0;
  if (routeFirstPlan) {
    const routeProfile = dependencies.routeRequest || routeRequest;
    const routeBody = {
      ...body,
      options: { ...(body.options || {}) }
    };
    delete routeBody.options.maxPathMeters;
    delete routeBody.options.internalFuelProbe;
    const routeStarted = Date.now();
    [foundationRoute, fuel] = await Promise.all([
      routeProfile(routeBody),
      loadFuel(locations)
    ]);
    routeFirstMs = Date.now() - routeStarted;
    profileMeters = Number(foundationRoute && foundationRoute.distanceMeters);
    if (!foundationRoute || foundationRoute.status !== "complete" || !(profileMeters >= 0)) {
      return {
        status: "failed",
        error: "profile_ride_unavailable",
        message: foundationRoute && (foundationRoute.message || foundationRoute.error) ||
          "The selected ride could not be built before fuel planning.",
        routes: foundationRoute ? [foundationRoute] : []
      };
    }
  }
  if (forwardFeeler) {
    profileMeters = haversineMeters(
      locationCoordinate(locations[0]),
      locationCoordinate(locations[locations.length - 1])
    );
  } else if (!(profileMeters >= 0)) {
    const routeProfile = dependencies.routeRequest || routeRequest;
    const options = { ...(body.options || {}) };
    delete options.maxPathMeters;
    const profileRide = await routeProfile({
      profile: body.profile,
      locations,
      vehicle: body.vehicle,
      accessPolicy: body.accessPolicy,
      options
    });
    profileMeters = Number(profileRide && profileRide.distanceMeters);
    if (!profileRide || profileRide.status !== "complete" || !(profileMeters >= 0)) {
      return {
        status: "failed",
        error: "profile_ride_unavailable",
        message: "The active-profile rider leg could not be measured before fuel planning."
      };
    }
  }
  const stopsNeeded = forwardFeeler ? 0 : fuelNeedForProfileRide(
    profileMeters, firstLegMaxMeters, usableRangeMeters
  );
  if (stopsNeeded == null) {
    return {
      status: "error",
      error: "invalid_profile_distance",
      message: "The active-profile rider leg distance is invalid."
    };
  }
  fuelOptions = {
    ...rawFuelOptions,
    profileMeters,
    requireFuelStopBeforeEnd: !!rawFuelOptions.requireFuelStopBeforeEnd || stopsNeeded > 0,
    minimumFuelStops: Math.max(
      Number(rawFuelOptions.minimumFuelStops) || 0,
      stopsNeeded
    )
  };
  console.log(
    `${forwardFeeler ? "fuel feeler" : "fuel need"} riderLeg=${rawFuelOptions.riderLegId || "unknown"} ` +
    `profileMeters=${Math.round(profileMeters)} usable=${Math.round(usableRangeMeters)} ` +
    `stopsNeeded=${stopsNeeded}`
  );

  if (selection.mode === "canada-chain") {
    return planCrossRegionFuelChain(body, selection, fuelOptions, dependencies);
  }

  if (!fuel) fuel = await loadFuel(locations);
  if (!fuel.ok) {
    return {
      status: "error",
      error: fuel.error,
      message: fuel.message
    };
  }
  if (!fuel.stations.length) {
    return {
      status: "unknown",
      error: "fuel_data_unavailable",
      message: "Live fuel data is unavailable for this part of the route.",
      stops: []
    };
  }

  const runtime = await loadRuntime(selection, {
    locations,
    profile: body.profile
  });
  const options = body.options || {};
  const waypointResets = deriveWaypointRefuels(locations, fuel.stations);
  const finalWaypointReset = waypointResets.find((row) => row.locationIndex === locations.length - 1);
  let destinationEscapeMeters = null;
  let destinationEscapeDiagnostics = null;
  if (rawFuelOptions.ensureDestinationFuelEscape === true) {
    if (finalWaypointReset) {
      destinationEscapeMeters = 0;
      destinationEscapeDiagnostics = { pops: 0, matched: 1, considered: 1 };
    } else {
      const escapeStarted = Date.now();
      destinationEscapeDiagnostics = nearestReachableFuelDistance({
        runtime,
        stations: fuel.stations,
        origin: locations[locations.length - 1],
        profile: "cleanest",
        accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
        maxMeters: usableRangeMeters,
        avoidEdgeIds: options.avoidEdgeIds || []
      });
      destinationEscapeDiagnostics.elapsedMs = Date.now() - escapeStarted;
      destinationEscapeMeters = destinationEscapeDiagnostics.meters;
    }
    const escapeArrivalLimit = destinationEscapeMeters == null
      ? 0
      : Math.max(0, usableRangeMeters - destinationEscapeMeters);
    const requestedArrivalLimit = Number(fuelOptions.destinationFuelUsedLimitMeters);
    fuelOptions = {
      ...fuelOptions,
      destinationFuelUsedLimitMeters: Number.isFinite(requestedArrivalLimit)
        ? Math.min(requestedArrivalLimit, escapeArrivalLimit)
        : escapeArrivalLimit
    };
  }

  if (routeFirstPlan && foundationRoute) {
    const initialFuelUsed = Math.max(0, usableRangeMeters - firstLegMaxMeters);
    const configuredArrivalLimit = Number(fuelOptions.destinationFuelUsedLimitMeters);
    const directArrivalAllowance = Number.isFinite(configuredArrivalLimit)
      ? Math.max(0, configuredArrivalLimit - initialFuelUsed)
      : Infinity;
    const directAllowed =
      fuelOptions.requireFuelStopBeforeEnd !== true &&
      (Number(fuelOptions.minimumFuelStops) || 0) === 0 &&
      !fuelOptions.requiredFirstStationId &&
      profileMeters <= firstLegMaxMeters + 1 &&
      profileMeters <= directArrivalAllowance + 1;
    if (directAllowed) {
      return {
        status: "complete",
        error: null,
        message: null,
        serviceVersion: FUEL_CHAIN_SERVICE_VERSION,
        regionIds: fuel.regionIds,
        packIdentity: mergePackIdentities(
          runtime.packIdentity || [],
          fuel.packIdentity || [],
          foundationRoute.debug && foundationRoute.debug.packIdentity || []
        ),
        stops: [],
        graphMeters: [profileMeters],
        routes: [foundationRoute],
        stationCandidates: [],
        destinationEscapeMeters,
        waypointResets,
        windowComplete: true,
        diagnostics: enrichFuelDiagnostics({
          strategy: "route_first_direct",
          states: 1,
          dijkstraPops: Number(destinationEscapeDiagnostics && destinationEscapeDiagnostics.pops) || 0,
          matchedFuel: fuel.stations.length,
          elapsedMs: Date.now() - requestStarted,
          totalElapsedMs: Date.now() - requestStarted,
          windowBudgetMs,
          windowBudgetOverrunMs: windowBudgetOverrunMs(),
          selectedReason: "direct_destination",
          routeFirstMs,
          graphFetchMs: runtime.loadDiagnostics && runtime.loadDiagnostics.fetchMs,
          graphDecodeMs: runtime.loadDiagnostics && runtime.loadDiagnostics.decodeMs,
          graphGridMs: runtime.loadDiagnostics && runtime.loadDiagnostics.gridMs,
          fuelFetchMs: fuel.loadDiagnostics && fuel.loadDiagnostics.fetchMs,
          fuelCacheHit: fuel.loadDiagnostics && fuel.loadDiagnostics.cacheHit,
          destinationEscapeSearchMs: destinationEscapeDiagnostics && destinationEscapeDiagnostics.elapsedMs,
          destinationEscapePops: destinationEscapeDiagnostics && destinationEscapeDiagnostics.pops
        }, {
          candidatesEvaluated: 0,
          stationCandidates: []
        })
      };
    }
  }
  const planned = await planFuelChainOnRuntime({
    runtime,
    stations: fuel.stations,
    start: locations[0],
    destination: locations[locations.length - 1],
    profile: String(body.profile || "dirt").toLowerCase(),
    accessPolicy: body.accessPolicy,
    usableRangeMeters,
    firstLegMaxMeters,
    requireFuelStopBeforeEnd: !!fuelOptions.requireFuelStopBeforeEnd,
    minimumFuelStops: Number(fuelOptions.minimumFuelStops) || 0,
    destinationFuelUsedLimitMeters: fuelOptions.destinationFuelUsedLimitMeters,
    avoidEdgeIds: options.avoidEdgeIds || [],
    cleanMetroMultiplier: options.cleanMetroMultiplier,
    avoidMotorways: options.avoidMotorways === true,
    priorEdgeIds: (options.priorEdgeIds || []).slice(-MAX_RECENT_EDGE_HISTORY),
    arrivalEdgeId: options.arrivalEdgeId || null,
    backtrackFactor: options.backtrackFactor || 4,
    probeFirstReachableStation: !!fuelOptions.probeFirstReachableStation,
    excludedStationIds: fuelOptions.excludedStationIds || [],
    requiredFirstStationId: fuelOptions.requiredFirstStationId || null,
    preferredStationIds: fuelOptions.preferredStationIds || [],
    maxStops: Math.min(12, Math.max(1, Number(fuelOptions.windowMaxStops) || 12)),
    allowPartialWindow: !!fuelOptions.allowPartialWindow,
    timeBudgetMs: Number(fuelOptions.windowTimeBudgetMs) || null,
    profileMeters,
    graphOnlyFeeler: forwardFeeler,
    foundationRoute
  });

  // Do not offer auxiliary fuel for an incomplete computation. A timeout is a
  // retryable planning failure; only an exhausted graph search proves a gap.
  return {
    status: fuelPlanStatus(planned),
    error: planned.error || null,
    message: planned.message || null,
    serviceVersion: FUEL_CHAIN_SERVICE_VERSION,
    regionIds: fuel.regionIds,
    packIdentity: mergePackIdentities(runtime.packIdentity || [], fuel.packIdentity || []),
    stops: planned.stops || [],
    graphMeters: planned.graphMeters || [],
    routes: planned.routes || [],
    stationCandidates: planned.stationCandidates || [],
    firstReachableStationMeters: planned.firstReachableStationMeters,
    destinationEscapeMeters,
    windowComplete: planned.windowComplete,
    waypointResets,
    gapMeters: planned.gapMeters,
    overByMeters: planned.overByMeters,
    gapFrom: planned.gapFrom,
    gapTo: planned.gapTo,
    diagnostics: planned.diagnostics ? {
      ...planned.diagnostics,
      totalElapsedMs: Date.now() - requestStarted,
      windowBudgetMs,
      windowBudgetOverrunMs: windowBudgetOverrunMs(),
      routeFirstMs,
      graphFetchMs: runtime.loadDiagnostics && runtime.loadDiagnostics.fetchMs,
      graphDecodeMs: runtime.loadDiagnostics && runtime.loadDiagnostics.decodeMs,
      graphGridMs: runtime.loadDiagnostics && runtime.loadDiagnostics.gridMs,
      fuelFetchMs: fuel.loadDiagnostics && fuel.loadDiagnostics.fetchMs,
      fuelCacheHit: fuel.loadDiagnostics && fuel.loadDiagnostics.cacheHit,
      destinationEscapeSearchMs: destinationEscapeDiagnostics && destinationEscapeDiagnostics.elapsedMs,
      destinationEscapePops: destinationEscapeDiagnostics && destinationEscapeDiagnostics.pops
    } : null
  };
}

/**
 * Deterministic itinerary-level range solver used by the benchmark and unit
 * fixtures. Distances are measured along already-routed RiderLegs. A station
 * is considered only when the complete tail remains feasible, so surface
 * preference can never select a pump that strands the following rider leg.
 */
function planItineraryFuelChain({ legs, usableRangeMeters, initialFuelUsedMeters = 0 }) {
  const usable = Number(usableRangeMeters);
  if (!(usable > 0) || !Array.isArray(legs)) return { ok: false, error: "invalid_itinerary" };
  let offset = 0;
  const stations = [];
  const waypointResets = [];
  for (let legIndex = 0; legIndex < legs.length; legIndex += 1) {
    const leg = legs[legIndex] || {};
    const meters = Number(leg.meters);
    if (!(meters >= 0)) return { ok: false, error: "invalid_leg_distance", legIndex };
    for (const station of leg.stations || []) {
      const along = Number(station.meters);
      if (along >= 0 && along <= meters) {
        stations.push({ ...station, legIndex, absoluteMeters: offset + along });
      }
    }
    offset += meters;
    const waypoint = leg.waypoint || leg.end || null;
    const pois = []
      .concat(leg.fuelPois || [])
      .concat((leg.stations || []).filter((row) => row && (row.lat != null || row.latitude != null)));
    const derived = deriveWaypointFuelStation(waypoint, pois);
    if (derived) {
      waypointResets.push({
        legIndex,
        absoluteMeters: offset,
        id: derived.id,
        name: derived.name,
        lat: derived.lat,
        lon: derived.lon,
        metersFromWaypoint: derived.metersFromWaypoint
      });
    }
  }
  const finish = offset;
  const resetPoints = stations.concat(waypointResets.map((row) => ({ ...row, waypoint: true })))
    .sort((a, b) => a.absoluteMeters - b.absoluteMeters);
  const memo = new Map();
  function solve(position, used, excludedBefore) {
    const key = `${Math.round(position)}:${Math.round(used)}:${excludedBefore}`;
    if (memo.has(key)) return memo.get(key);
    if (used + finish - position <= usable + 1) return { stops: [], waypointResets: [] };
    const reachable = resetPoints.filter((row) =>
      row.absoluteMeters > position + 0.5 && row.absoluteMeters >= excludedBefore
        && used + row.absoluteMeters - position <= usable + 1
    );
    const viable = [];
    for (const candidate of reachable) {
      const tail = solve(candidate.absoluteMeters, 0, candidate.absoluteMeters + 0.5);
      if (!tail) continue;
      viable.push({
        candidate,
        result: {
          stops: candidate.waypoint ? tail.stops : [candidate].concat(tail.stops),
          waypointResets: candidate.waypoint
            ? [candidate].concat(tail.waypointResets)
            : tail.waypointResets
        }
      });
    }
    viable.sort((a, b) => {
      const stopDelta = a.result.stops.length - b.result.stops.length;
      if (stopDelta) return stopDelta;
      const progress = b.candidate.absoluteMeters - a.candidate.absoluteMeters;
      if (Math.abs(progress) > 1_000) return progress;
      const dirt = Number(b.candidate.dirtPct || 0) - Number(a.candidate.dirtPct || 0);
      if (dirt) return dirt;
      return 0;
    });
    const result = viable.length ? viable[0].result : null;
    memo.set(key, result);
    return result;
  }
  const result = solve(0, Math.max(0, Number(initialFuelUsedMeters) || 0), 0);
  return result ? { ok: true, ...result } : { ok: false, error: "no_route_connected_fuel_chain" };
}

module.exports = {
  FUEL_CHAIN_SERVICE_VERSION,
  FUEL_COMFORT_LO,
  FUEL_COMFORT_HI,
  boundedGraphDistances,
  distanceToMatch,
  nearestReachableFuelDistance,
  fuelPlanningSpan,
  tankCommitBand,
  fuelSearchStartMeters,
  fuelPreferredStartMeters,
  rankForwardFuel,
  stationEligibility,
  fuelNeedForProfileRide,
  comfortCapMeters,
  compareChainPlans,
  fuelPlanStatus,
  planFuelChainOnRuntime,
  planCrossRegionFuelChain,
  planItineraryFuelChain,
  deriveWaypointFuelStation,
  deriveWaypointRefuels,
  WAYPOINT_FUEL_SNAP_METERS,
  fuelChainRequest
};
