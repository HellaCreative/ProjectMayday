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
const { matchPoint, normalizePolicy, accessAllowed, resolveChainSeamWaypoints, routeRequest, routeOnRuntime, echoLegId, buildManeuvers, aggregateRouteSurfaceStats } = require("./router");
const { selectConnectedSnapPair, snapEndpointRecord } = require("./legal-topology/snap");
const { tapRadiusMeters } = require("./legal-topology/tap-radius");
const {
  resolveGraphRequest,
  primaryRegionForPoint,
  provinceFamily
} = require("../regional/select");
const { corridorLocationsForRoute } = require("../regional/merge");
const { resolveProfile } = require("./profile-costs");
const { loadFuelForLocations, loadRegionFuel } = require("./fuel-data");
const { summarizeRouteQuality } = require("./route-quality");
const {
  compileRestrictionIndex,
  advanceRestrictionState,
  activeKey
} = require("./legal-topology/restrictions");

function mergePackIdentities(...groups) {
  const byRegion = new Map();
  for (const identity of groups.flat().filter(Boolean)) {
    const key = String(identity.regionId || "unknown").toLowerCase();
    byRegion.set(key, { ...(byRegion.get(key) || {}), ...identity });
  }
  return [...byRegion.values()];
}
const {
  ROAD_CLASS_NAME,
  unpackAccess,
  unpackSurface,
  unpackStructure,
  unpackRoadClass,
  unpackConfidence,
  unpackSeasonal
} = require("./pack-v2");
const {
  projectedProgressMeters,
  crossTrackMeters,
  routeShapeMetrics,
  METRO_CORE_WALL,
  metroBlocks
} = require("./hop-search");
const { resolveLocationsByEligibleEdge } = require("../regional/endpoint-resolver");
const { fallbackSettlementsForRegion } = require("./urban-settlements");

const HARD_MATCH_METERS = 750;
const MIN_STOP_SEPARATION_M = 800;
const MIN_FORWARD_PROGRESS_M = 8_000;
const MIN_DESTINATION_FUEL_CLEARANCE_M = 5_000;
/** Bumped when fuel-selection / ranking contracts change. Clients may assert. */
const FUEL_CHAIN_SERVICE_VERSION = "2026-09-07.fuel-is-route-foundation-reuse.31";
const FUEL_SELECTION_POLICY = "minimum_stops_rural_before_urban_then_75pct";
/**
 * Preserve the first three quarters of each usable tank for the requested
 * ride profile. Once that boundary is crossed, commit the first sensible
 * forward pump instead of spending the window hunting for a farther one.
 * Lockstep: HopSearchPolicy.swift.
 */
const FUEL_COMFORT_LO = 0.75;
const FUEL_COMFORT_HI = 0.75;
/** Maximum replacement choices returned for one committed fuel anchor. */
const MAX_STATION_ALTERNATIVES = 6;
/**
 * A cross-region graph-only choice is still proved by the client using the
 * requested profile. Retain a small ranked recovery set so one seam/profile
 * mismatch cannot consume the complete waypoint window and force another
 * province-wide pump search.
 */
const GRAPH_ONLY_RECOVERY_CANDIDATES = 4;
/** Allow a short forecourt connector, never a meaningful down-and-back fuel stem. */
const MAX_FUEL_RETRACE_M = 200;
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
/** A route-foundation pump must be on the actual selected road, not merely in its corridor. */
const FOUNDATION_ROUTE_MATCH_M = 25;
/** Coarse cells prioritize pumps along a proved meandering route before dense chord candidates. */
const FOUNDATION_PRIORITY_CELL_DEGREES = 0.02;
/**
 * Settlement polygons describe the town centre. Fuel forecourts and their
 * approach roads commonly sit just outside that line, so include a small
 * buffer when deciding whether a pump forces an avoidable urban entry.
 */
const FUEL_URBAN_APPROACH_BUFFER_M = 1_500;
/**
 * Straight-chord backtrack is a poor rejection test beside a meandering
 * foundation route. This exception is valid only when route proximity was
 * actually measured; a missing value must never be coerced to route cell 0.
 */
const MAX_FOUNDATION_NEARBY_CONTINUATION_BACKTRACK_M = 20_000;
// Dense regions can contain thousands of pumps inside one tank radius. Snap a
// broad, directionally ordered working set instead of blocking the request on
// every pump in the province. Sparse regions remain uncapped.
const DENSE_TARGET_MATCH_LIMIT = 192;
const DENSE_TARGET_MIN_MATCHES = 48;
// A candidate approach is not useful until the same riding profile also
// proves the pump-to-destination continuation. Keep a small share of the
// request alive for that second proof instead of allowing the first route to
// consume the complete live window.
const MIN_CONTINUATION_RESERVE_MS = 750;
const MAX_CONTINUATION_RESERVE_MS = 2_500;
const CONTINUATION_RESERVE_SHARE = 0.28;
// A completed route proof can cross its wall-clock deadline by a few scheduler
// ticks after the graph search has already succeeded. Accept only that tightly
// bounded completion; it is still a complete proof and remains well inside the
// client's transport timeout. An incomplete response never receives grace.
const COMPLETED_CONTINUATION_GRACE_MS = 250;
const CLEAN_MAJOR_ROAD_CLASSES = new Set([
  "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
  "freeway", "ramp", "arterial"
]);

const MAX_RECENT_EDGE_HISTORY = 256;
const MAX_FUEL_PLANNING_BUDGET_MS = 30_000;

function finiteDiagnosticNumber(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function routeFirstBudgetForWindow(windowBudgetMs) {
  const budget = Number(windowBudgetMs);
  if (!(budget > 0)) return null;
  // The foundational ride is required evidence for every profile. Giving
  // Balanced and Clean less time than Dirt made dense-region cold starts fail
  // before their legal fallback could complete. Keep a five-second minimum
  // reserve for fuel selection while treating every riding style equally.
  // Live routing allows the active-profile foundation up to twenty seconds.
  // Keep at least five seconds for station matching and chain proof when the
  // enclosing fuel window is large enough to provide it.
  return Math.max(
    2_000,
    Math.min(20_000, Math.max(2_000, budget - 5_000), Math.round(budget * 0.67))
  );
}

function timeoutPartialBacktrackCap(evaluation) {
  const foundationCellDistance =
    evaluation && evaluation.candidate && evaluation.candidate.foundationCellDistance;
  return foundationCellDistance != null && Number.isFinite(Number(foundationCellDistance))
    ? MAX_FOUNDATION_NEARBY_CONTINUATION_BACKTRACK_M
    : MAX_FUEL_RETRACE_M;
}

/**
 * A deadline may shorten a proved fuel chain, but it may not turn an unsafe
 * approach into a committed stop. Prefer a rural partial when one exists and
 * reject any candidate whose completed continuation proves a material return
 * toward the departure point.
 */
function selectSafeTimeoutPartial(routedApproachPlans) {
  const safe = (routedApproachPlans || []).filter(({ evaluation }) => {
    // A route to a pump is not a fuel-chain proof. The same request must also
    // prove either the destination or a next forward pump before the current
    // pump can become a resumable waypoint.
    if (!evaluation || evaluation.validForward !== true) return false;
    const rawBacktrack = evaluation && evaluation.continuationBacktrackMeters;
    const backtrack = Number(rawBacktrack);
    return rawBacktrack == null || !Number.isFinite(backtrack) ||
      backtrack <= timeoutPartialBacktrackCap(evaluation) + 1;
  });
  if (!safe.length) return null;
  return safe.find(({ evaluation }) =>
    !evaluation.candidate.urbanEntry
  ) || safe[0];
}

function completedContinuationWithinWindow(response, deadlineAtMs, now = Date.now()) {
  if (!response || response.status !== "complete") return false;
  const deadline = Number(deadlineAtMs);
  if (!Number.isFinite(deadline)) return true;
  return Number(now) <= deadline + COMPLETED_CONTINUATION_GRACE_MS;
}

function routeFirstDeadlineAfterLoad(windowDeadlineAtMs, routeFirstBudgetMs, loadedAtMs) {
  if (routeFirstBudgetMs == null || loadedAtMs == null) return Infinity;
  const windowDeadline = Number(windowDeadlineAtMs);
  const routeBudget = Number(routeFirstBudgetMs);
  const loadedAt = Number(loadedAtMs);
  if (!Number.isFinite(routeBudget) || !Number.isFinite(loadedAt)) return Infinity;
  const searchDeadline = loadedAt + Math.max(0, routeBudget);
  return Number.isFinite(windowDeadline)
    ? Math.min(windowDeadline, searchDeadline)
    : searchDeadline;
}

function candidateApproachDeadlineAtMs(deadlineAtMs, now = Date.now()) {
  const deadline = Number(deadlineAtMs);
  if (!Number.isFinite(deadline)) return Infinity;
  const remaining = Math.max(0, deadline - now);
  const reserve = Math.min(
    MAX_CONTINUATION_RESERVE_MS,
    Math.max(MIN_CONTINUATION_RESERVE_MS, Math.round(remaining * CONTINUATION_RESERVE_SHARE))
  );
  return Math.max(now, deadline - reserve);
}

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
  const journey = response && response.quality || {};
  return {
    meters,
    dirtMeters: meters * (Number.isFinite(dirtPercent) ? dirtPercent : 0) / 100,
    cleanFallbackCount: clean.fallbackCount,
    cleanMajorRoadMeters: clean.majorRoadMeters,
    backtrackMeters: responseBacktrackMeters(response),
    urbanCoreMeters: Math.max(0, Number(journey.urbanCoreMeters) || 0),
    minimumSectionDirtPercent: Number.isFinite(Number(journey.minimumSectionDirtPercent))
      ? Number(journey.minimumSectionDirtPercent)
      : 0,
    longestPavedRunMeters: Math.max(0, Number(journey.longestPavedRunMeters) || 0),
    degradedLegs: journey.state === "degraded" ? 1 : 0
  };
}

function combineChainQuality(...parts) {
  return parts.filter(Boolean).reduce((total, part) => ({
    meters: total.meters + (Number(part.meters) || 0),
    dirtMeters: total.dirtMeters + (Number(part.dirtMeters) || 0),
    cleanFallbackCount: total.cleanFallbackCount + (Number(part.cleanFallbackCount) || 0),
    cleanMajorRoadMeters: total.cleanMajorRoadMeters + (Number(part.cleanMajorRoadMeters) || 0),
    backtrackMeters: total.backtrackMeters + (Number(part.backtrackMeters) || 0),
    urbanCoreMeters: total.urbanCoreMeters + (Number(part.urbanCoreMeters) || 0),
    minimumSectionDirtPercent: Math.min(
      total.minimumSectionDirtPercent,
      Number.isFinite(Number(part.minimumSectionDirtPercent))
        ? Number(part.minimumSectionDirtPercent)
        : 0
    ),
    longestPavedRunMeters: Math.max(
      total.longestPavedRunMeters,
      Number(part.longestPavedRunMeters) || 0
    ),
    degradedLegs: total.degradedLegs + (Number(part.degradedLegs) || 0)
  }), {
    meters: 0,
    dirtMeters: 0,
    cleanFallbackCount: 0,
    cleanMajorRoadMeters: 0,
    backtrackMeters: 0,
    urbanCoreMeters: 0,
    minimumSectionDirtPercent: 100,
    longestPavedRunMeters: 0,
    degradedLegs: 0
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
  // Once range safety and minimum stop count tie, avoid manufacturing an
  // urban visit solely to buy fuel. Profile and surface preferences follow.
  const aUrbanStops = Number(a.urbanStopCount) || 0;
  const bUrbanStops = Number(b.urbanStopCount) || 0;
  if (aUrbanStops !== bUrbanStops) return aUrbanStops - bUrbanStops;
  if (Math.abs(aq.urbanCoreMeters - bq.urbanCoreMeters) > 100) {
    return aq.urbanCoreMeters - bq.urbanCoreMeters;
  }
  const aFirstHop = Number(a && a.graphMeters && a.graphMeters[0]);
  const bFirstHop = Number(b && b.graphMeters && b.graphMeters[0]);
  const commitBand = tankCommitBand(aFirstHop, firstCapMeters) -
    tankCommitBand(bFirstHop, firstCapMeters);
  if (commitBand !== 0) return commitBand;
  const tankOrder = compareTankCommit(
    aFirstHop, a.progressMeters, bFirstHop, b.progressMeters,
    firstCapMeters, firstCapMeters
  );
  if (tankOrder !== 0) return tankOrder;
  const aBacktrack = aq.meters > 0 ? aq.backtrackMeters / aq.meters : 0;
  const bBacktrack = bq.meters > 0 ? bq.backtrackMeters / bq.meters : 0;
  // A lollipop, figure-eight, or repeated approach is a ride-quality defect,
  // not an acceptable way to save one fuel stop.
  if (Math.abs(aBacktrack - bBacktrack) > 0.01) return aBacktrack - bBacktrack;
  switch (resolveProfile(profile)) {
    case "dirt": {
      const aDirt = aq.meters > 0 ? aq.dirtMeters / aq.meters * 100 : 0;
      const bDirt = bq.meters > 0 ? bq.dirtMeters / bq.meters * 100 : 0;
      if (Math.abs(aDirt - bDirt) > 0.5) return bDirt - aDirt;
      if (Math.abs(aq.minimumSectionDirtPercent - bq.minimumSectionDirtPercent) > 2) {
        return bq.minimumSectionDirtPercent - aq.minimumSectionDirtPercent;
      }
      if (Math.abs(aq.longestPavedRunMeters - bq.longestPavedRunMeters) > 2_000) {
        return aq.longestPavedRunMeters - bq.longestPavedRunMeters;
      }
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
  const aDetour = Number(a.directionalDetourMeters) || 0;
  const bDetour = Number(b.directionalDetourMeters) || 0;
  if (Math.abs(aDetour - bDetour) > 2_000) return aDetour - bDetour;
  const aProgress = Number(a.progressMeters) || 0;
  const bProgress = Number(b.progressMeters) || 0;
  if (Math.abs(aProgress - bProgress) > 2_000) return bProgress - aProgress;
  if (Math.abs(aq.meters - bq.meters) > 50) return aq.meters - bq.meters;
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
  // Watching and the 75% preferred zone only order pumps after a stop has been
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

function expandUrbanBox(box, bufferMeters = FUEL_URBAN_APPROACH_BUFFER_M) {
  if (!box) return null;
  const minLat = Number(box.minLat);
  const maxLat = Number(box.maxLat);
  const minLon = Number(box.minLon);
  const maxLon = Number(box.maxLon);
  if (![minLat, maxLat, minLon, maxLon].every(Number.isFinite)) return null;
  const buffer = Math.max(0, Number(bufferMeters) || 0);
  const latPad = buffer / 111_320;
  const midLat = (minLat + maxLat) / 2;
  const lonScale = Math.max(0.2, Math.cos(midLat * Math.PI / 180));
  const lonPad = buffer / (111_320 * lonScale);
  return {
    ...box,
    minLat: minLat - latPad,
    maxLat: maxLat + latPad,
    minLon: minLon - lonPad,
    maxLon: maxLon + lonPad
  };
}

function fuelUrbanBoxesForRuntime(runtime) {
  const pack = runtime && runtime.pack ? runtime.pack : runtime;
  const meta = pack && pack.meta || {};
  const regionId = String(pack && (pack.regionId || meta.regionId) || "").toLowerCase();
  const embeddedCores = Array.isArray(meta.urbanCores) ? meta.urbanCores : [];
  const embeddedSettlements = Array.isArray(meta.settlements) ? meta.settlements : [];
  const settlements = embeddedSettlements.length
    ? embeddedSettlements
    : fallbackSettlementsForRegion(regionId);
  return METRO_CORE_WALL
    .concat(embeddedCores, settlements)
    .map((box) => expandUrbanBox(box))
    .filter(Boolean);
}

function fuelStopRequiresUrbanEntry(location, current, destination, urbanBoxes = []) {
  if (!urbanBoxes.length) return false;
  const point = locationCoordinate(location);
  if (!point.every(Number.isFinite)) return false;
  return metroBlocks(point[0], point[1], current, destination, urbanBoxes);
}

function routeSegmentCoordinates(segment) {
  const rows = segment && (segment.geometry || segment.coords);
  return Array.isArray(rows) ? rows.filter((point) =>
    Array.isArray(point) && Number.isFinite(Number(point[0])) && Number.isFinite(Number(point[1]))
  ).map((point) => [Number(point[0]), Number(point[1])]) : [];
}

function polylineMeasure(coords) {
  const cumulative = [0];
  for (let index = 1; index < coords.length; index += 1) {
    cumulative.push(cumulative[index - 1] + haversineMeters(coords[index - 1], coords[index]));
  }
  return cumulative;
}

function projectOnCoordinateSegment(point, a, b) {
  const lat = ((point[1] + a[1] + b[1]) / 3) * Math.PI / 180;
  const scaleX = Math.max(0.01, Math.cos(lat));
  const px = point[0] * scaleX;
  const py = point[1];
  const ax = a[0] * scaleX;
  const ay = a[1];
  const bx = b[0] * scaleX;
  const by = b[1];
  const dx = bx - ax;
  const dy = by - ay;
  const denominator = dx * dx + dy * dy;
  const t = denominator > 0
    ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / denominator))
    : 0;
  const coord = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
  return { coord, t, distanceM: haversineMeters(point, coord) };
}

function projectOnCoordinatePolyline(point, coords) {
  if (!Array.isArray(coords) || coords.length < 2) return null;
  const cumulative = polylineMeasure(coords);
  let best = null;
  for (let index = 1; index < coords.length; index += 1) {
    const projected = projectOnCoordinateSegment(point, coords[index - 1], coords[index]);
    const segmentMeters = cumulative[index] - cumulative[index - 1];
    const alongMeters = cumulative[index - 1] + segmentMeters * projected.t;
    if (!best || projected.distanceM < best.distanceM) {
      best = { ...projected, segmentIndex: index - 1, alongMeters, totalMeters: cumulative.at(-1) };
    }
  }
  return best;
}

function coordinateAtPolylineMeter(coords, cumulative, meters) {
  if (!coords.length) return null;
  const total = cumulative.at(-1) || 0;
  const target = Math.max(0, Math.min(total, Number(meters) || 0));
  if (target <= 0) return coords[0].slice();
  if (target >= total) return coords.at(-1).slice();
  let index = 1;
  while (index < cumulative.length && cumulative[index] < target) index += 1;
  const before = cumulative[index - 1];
  const span = Math.max(1e-9, cumulative[index] - before);
  const t = (target - before) / span;
  const a = coords[index - 1];
  const b = coords[index];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

function sliceCoordinatePolyline(coords, fromFraction, toFraction) {
  if (!Array.isArray(coords) || coords.length < 2) return [];
  const cumulative = polylineMeasure(coords);
  const total = cumulative.at(-1) || 0;
  if (!(total > 0)) return [coords[0].slice(), coords.at(-1).slice()];
  const fromMeters = Math.max(0, Math.min(total, fromFraction * total));
  const toMeters = Math.max(fromMeters, Math.min(total, toFraction * total));
  const output = [coordinateAtPolylineMeter(coords, cumulative, fromMeters)];
  for (let index = 1; index < coords.length - 1; index += 1) {
    if (cumulative[index] > fromMeters && cumulative[index] < toMeters) {
      output.push(coords[index].slice());
    }
  }
  output.push(coordinateAtPolylineMeter(coords, cumulative, toMeters));
  return output.filter((point, index) => index === 0 ||
    point[0] !== output[index - 1][0] || point[1] !== output[index - 1][1]);
}

function appendCoordinates(target, coords) {
  for (const coord of coords || []) {
    const last = target.at(-1);
    if (!last || last[0] !== coord[0] || last[1] !== coord[1]) target.push(coord.slice());
  }
}

function foundationRouteLayout(route) {
  const rows = [];
  const byEdge = new Map();
  let alongMeters = 0;
  for (const segment of (route && route.segments) || []) {
    const coords = routeSegmentCoordinates(segment);
    const meters = Number(segment && segment.distanceMeters);
    if (!(meters > 0) || coords.length < 2) continue;
    const row = {
      segment,
      coords,
      startMeters: alongMeters,
      endMeters: alongMeters + meters,
      meters
    };
    rows.push(row);
    const edgeId = segment && segment.edgeId == null ? null : String(segment.edgeId);
    if (edgeId) {
      if (!byEdge.has(edgeId)) byEdge.set(edgeId, []);
      byEdge.get(edgeId).push(row);
    }
    alongMeters += meters;
  }
  return { rows, byEdge, meters: alongMeters };
}

function foundationRouteCells(route) {
  if (!route || !Array.isArray(route.segments)) return null;
  const cells = new Set();
  const cell = FOUNDATION_PRIORITY_CELL_DEGREES;
  const add = (coord) => cells.add(
    `${Math.floor(coord[0] / cell)}:${Math.floor(coord[1] / cell)}`
  );
  for (const segment of route.segments) {
    const coords = routeSegmentCoordinates(segment);
    for (let index = 0; index < coords.length; index += 1) {
      const current = coords[index];
      add(current);
      if (index === 0) continue;
      const previous = coords[index - 1];
      const steps = Math.min(512, Math.ceil(Math.max(
        Math.abs(current[0] - previous[0]),
        Math.abs(current[1] - previous[1])
      ) / (cell * 0.5)));
      for (let step = 1; step < steps; step += 1) {
        const t = step / steps;
        add([
          previous[0] + (current[0] - previous[0]) * t,
          previous[1] + (current[1] - previous[1]) * t
        ]);
      }
    }
  }
  return cells.size ? cells : null;
}

function foundationCellDistance(location, cells) {
  if (!cells) return Infinity;
  const cell = FOUNDATION_PRIORITY_CELL_DEGREES;
  const x = Math.floor(Number(location.lon) / cell);
  const y = Math.floor(Number(location.lat) / cell);
  for (let ring = 0; ring <= 1; ring += 1) {
    for (let dx = -ring; dx <= ring; dx += 1) {
      for (let dy = -ring; dy <= ring; dy += 1) {
        if (ring > 0 && Math.abs(dx) !== ring && Math.abs(dy) !== ring) continue;
        if (cells.has(`${x + dx}:${y + dy}`)) return ring;
      }
    }
  }
  return Infinity;
}

function prepareFoundationTopology(layout, runtime) {
  const pack = runtime && runtime.pack;
  const geom = runtime && runtime.geom;
  if (!layout || !pack || pack.graphBinaryVersion < 4 || !geom) return false;
  const needed = new Set(layout.byEdge.keys());
  const byId = new Map();
  for (let ei = 0; ei < pack.undirectedEdgeCount && byId.size < needed.size; ei += 1) {
    const id = String(pack.edgeId(ei));
    if (needed.has(id)) byId.set(id, ei);
  }
  for (const row of layout.rows) {
    const edgeId = String(row.segment.edgeId || "");
    const ei = byId.get(edgeId);
    if (!Number.isInteger(ei)) return false;
    const full = geom.polyline(ei);
    if (!Array.isArray(full) || full.length < 2) return false;
    const forwardDistance = haversineMeters(row.coords[0], full[0]) +
      haversineMeters(row.coords.at(-1), full.at(-1));
    const reverseDistance = haversineMeters(row.coords[0], full.at(-1)) +
      haversineMeters(row.coords.at(-1), full[0]);
    row.edgeIndex = ei;
    row.forward = forwardDistance <= reverseDistance;
    row.entryNode = row.forward ? pack.edgeFrom[ei] : pack.edgeTo[ei];
    row.exitNode = row.forward ? pack.edgeTo[ei] : pack.edgeFrom[ei];
  }
  layout.foundationEdgeIndexes = new Set(layout.rows.map((row) => row.edgeIndex));
  layout.junctions = [];
  layout.junctionsByNode = new Map();
  for (let index = 1; index < layout.rows.length; index += 1) {
    const incoming = layout.rows[index - 1];
    const outgoing = layout.rows[index];
    if (incoming.exitNode !== outgoing.entryNode) continue;
    const node = incoming.exitNode;
    const junction = {
      node,
      alongMeters: outgoing.startMeters,
      incomingEdgeIndex: incoming.edgeIndex,
      outgoingEdgeIndex: outgoing.edgeIndex,
      coord: [pack.nodeCoords[node * 2], pack.nodeCoords[node * 2 + 1]]
    };
    layout.junctions.push(junction);
    if (!layout.junctionsByNode.has(node)) layout.junctionsByNode.set(node, []);
    layout.junctionsByNode.get(node).push(junction);
  }
  return true;
}

function foundationPlacement(target, layout) {
  const matches = [];
  const seen = new Set();
  for (const match of [target && target.match, ...(
    target && target.match && Array.isArray(target.match.candidates)
      ? target.match.candidates
      : []
  )]) {
    if (!match || match.edgeId == null || !Array.isArray(match.coord)) continue;
    const key = `${String(match.edgeId)}:${Number(match.distanceAlongM) || 0}:` +
      `${match.forward === false ? 0 : 1}`;
    if (seen.has(key)) continue;
    seen.add(key);
    matches.push(match);
  }
  let best = null;
  for (const match of matches) {
    const rows = layout.byEdge.get(String(match.edgeId)) || [];
    for (const row of rows) {
      if (Number.isInteger(row.edgeIndex) && Number.isInteger(match.edgeIndex) &&
          row.edgeIndex !== match.edgeIndex) continue;
      if (typeof row.forward === "boolean" && typeof match.forward === "boolean" &&
          row.forward !== match.forward) continue;
      const projected = projectOnCoordinatePolyline(match.coord, row.coords);
      if (!projected) continue;
      const fraction = projected.totalMeters > 0
        ? projected.alongMeters / projected.totalMeters
        : 0;
      const placement = {
        // V4 snapping deliberately retains several legal directed candidates.
        // A forecourt driveway can win the distance score even while the pump
        // is also a legal snap to the selected route beside it. Preserve the
        // route-matching candidate instead of discarding the Dirt foundation
        // and independently rerouting both fuel legs.
        target: { ...target, match },
        routeCoord: projected.coord,
        alongMeters: row.startMeters + row.meters * fraction,
        exitAlongMeters: row.startMeters + row.meters * fraction,
        offRouteMeters: projected.distanceM,
        accessMeters: 0,
        arrivalMeters: 0,
        departureMeters: 0,
        arrivalSegments: [],
        departureSegments: [],
        snapDistanceMeters: Math.max(0, Number(match.distanceM) || 0),
        accessProof: "same-foundation-directed-edge"
      };
      if (!best ||
          placement.offRouteMeters < best.offRouteMeters ||
          (placement.offRouteMeters === best.offRouteMeters &&
            placement.accessMeters < best.accessMeters)) {
        best = placement;
      }
    }
  }
  return best && best.offRouteMeters <= FOUNDATION_ROUTE_MATCH_M ? best : null;
}

function fuelArcAccessAllowed(runtime, ei, from, to, allowUnknown) {
  const pack = runtime.pack;
  const forward = pack.edgeFrom[ei] === from && pack.edgeTo[ei] === to;
  const code = pack.edgeAccess ? pack.edgeAccess[ei * 2 + (forward ? 0 : 1)] : 0;
  const name = (runtime.enums.ACCESS_NAME || [])[code];
  if (name === "motorized_verified") return true;
  if (name === "motorized_permissive") return true;
  if (name === "motorized_unknown") return allowUnknown === true;
  return false;
}

function packedAccessSegment(runtime, step, fromFraction = 0, toFraction = 1) {
  const pack = runtime.pack;
  const ei = step.edgeIndex;
  const forward = pack.edgeFrom[ei] === step.from && pack.edgeTo[ei] === step.to;
  const raw = runtime.geom.polyline(ei);
  const oriented = forward ? raw : raw.slice().reverse();
  const geometry = sliceCoordinatePolyline(oriented, fromFraction, toFraction);
  const distanceMeters = Number(pack.edgeMeters[ei]) * Math.max(0, toFraction - fromFraction);
  if (!(distanceMeters > 0.01) || geometry.length < 2) return null;
  const attr = pack.edgeAttrs[ei];
  const accessCode = pack.edgeAccess
    ? pack.edgeAccess[ei * 2 + (forward ? 0 : 1)]
    : unpackAccess(attr);
  const leaves = typeof pack.edgeLeaves === "function" ? pack.edgeLeaves(ei) : {};
  return {
    edgeId: String(pack.edgeId(ei)),
    surfaceClass: (runtime.enums.SURFACE_NAME || [])[unpackSurface(attr)] || "unknown",
    trackClass: ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown",
    structureType: (runtime.enums.STRUCTURE_NAME || [])[unpackStructure(attr)] || "none",
    accessClass: (runtime.enums.ACCESS_NAME || [])[accessCode] || "motorized_unknown",
    surfaceLeaf: leaves.surfaceLeaf == null ? null : leaves.surfaceLeaf,
    structureLeaf: leaves.structureLeaf == null ? null : leaves.structureLeaf,
    layer: Number(leaves.layer) || 0,
    confidence: unpackConfidence(attr),
    seasonal: !!unpackSeasonal(attr),
    distanceMeters,
    accessLeg: true,
    geometry
  };
}

function splitForecourtPath(runtime, path, stationMatch) {
  const arrivalSegments = [];
  const departureSegments = [];
  let passedStation = false;
  for (const step of path) {
    const isStationEdge = !passedStation && step.edgeIndex === stationMatch.edgeIndex &&
      ((runtime.pack.edgeFrom[step.edgeIndex] === step.from) === (stationMatch.forward !== false));
    if (!isStationEdge) {
      const segment = packedAccessSegment(runtime, step);
      if (segment) (passedStation ? departureSegments : arrivalSegments).push(segment);
      continue;
    }
    const edgeMeters = Math.max(1e-9, Number(runtime.pack.edgeMeters[step.edgeIndex]) || 0);
    const rawFraction = Math.max(
      0,
      Math.min(1, (Number(stationMatch.distanceAlongM) || 0) / edgeMeters)
    );
    const orientedFraction = stationMatch.forward === false ? 1 - rawFraction : rawFraction;
    const arrival = packedAccessSegment(runtime, step, 0, orientedFraction);
    const departure = packedAccessSegment(runtime, step, orientedFraction, 1);
    if (arrival) arrivalSegments.push(arrival);
    if (departure) departureSegments.push(departure);
    passedStation = true;
  }
  if (!passedStation) return null;
  const meters = (segments) => segments.reduce(
    (sum, segment) => sum + Math.max(0, Number(segment.distanceMeters) || 0), 0
  );
  return {
    arrivalSegments,
    departureSegments,
    arrivalMeters: meters(arrivalSegments),
    departureMeters: meters(departureSegments)
  };
}

/**
 * Prove a packed forecourt as one directed through-path. It may use distinct
 * one-way entrance and exit edges; it may not reverse an edge, return to its
 * entry junction, invent a free-space connector, or exceed 200 routed metres.
 */
function forecourtFoundationPlacement(target, layout, runtime, allowUnknown) {
  const pack = runtime && runtime.pack;
  if (!pack || pack.graphBinaryVersion < 4 || !pack.edgeFrom || !pack.edgeTo ||
      !pack.nodeOffsets || !pack.edgeUndirectedIndex || !runtime.geom ||
      !layout.foundationEdgeIndexes || !layout.junctionsByNode) return null;
  const restrictionIndex = compileRestrictionIndex(pack.restrictions || []);
  const matches = [];
  const seen = new Set();
  for (const match of [target && target.match, ...(
    target && target.match && Array.isArray(target.match.candidates)
      ? target.match.candidates
      : []
  )]) {
    if (!match || !Number.isInteger(match.edgeIndex) || !Array.isArray(match.coord) ||
        Math.max(0, Number(match.distanceM) || 0) > MAX_FUEL_RETRACE_M + 1 ||
        layout.foundationEdgeIndexes.has(match.edgeIndex)) continue;
    const key = `${match.edgeIndex}:${match.forward === false ? 0 : 1}`;
    if (seen.has(key)) continue;
    seen.add(key);
    matches.push(match);
  }
  let best = null;
  for (const match of matches) {
    const stationFrom = match.forward === false
      ? pack.edgeTo[match.edgeIndex] : pack.edgeFrom[match.edgeIndex];
    const stationTo = match.forward === false
      ? pack.edgeFrom[match.edgeIndex] : pack.edgeTo[match.edgeIndex];
    const entryCandidates = layout.junctions.filter((junction) =>
      haversineMeters(junction.coord, match.coord) <= MAX_FUEL_RETRACE_M + 1
    );
    for (const entry of entryCandidates) {
      const heap = new MinHeap();
      const seenStates = new Map();
      heap.push({
        node: entry.node,
        cost: 0,
        lastEdge: entry.incomingEdgeIndex,
        restrictions: [],
        stationMatch: null,
        path: [],
        usedEdges: new Set()
      });
      while (heap.items.length) {
        const current = heap.pop();
        if (!current || current.cost > MAX_FUEL_RETRACE_M + 1) continue;
        const stationKey = current.stationMatch
          ? `${current.stationMatch.edgeIndex}:${current.stationMatch.forward === false ? 0 : 1}`
          : "-";
        const key = `${current.node}:${current.lastEdge}:${stationKey}:${activeKey(current.restrictions)}`;
        if ((seenStates.get(key) ?? Infinity) <= current.cost) continue;
        seenStates.set(key, current.cost);

        if (current.stationMatch) {
          for (const exit of layout.junctionsByNode.get(current.node) || []) {
            if (exit.alongMeters <= entry.alongMeters + 1) continue;
            const turn = advanceRestrictionState(
              restrictionIndex,
              current.restrictions,
              current.lastEdge,
              exit.outgoingEdgeIndex,
              current.node
            );
            if (!turn.allowed) continue;
            const split = splitForecourtPath(runtime, current.path, current.stationMatch);
            if (!split) continue;
            const placement = {
              target: { ...target, match: current.stationMatch },
              routeCoord: entry.coord,
              exitRouteCoord: exit.coord,
              alongMeters: entry.alongMeters,
              exitAlongMeters: exit.alongMeters,
              offRouteMeters: Math.max(0, current.cost -
                (exit.alongMeters - entry.alongMeters)),
              accessMeters: current.cost,
              arrivalMeters: split.arrivalMeters,
              departureMeters: split.departureMeters,
              arrivalSegments: split.arrivalSegments,
              departureSegments: split.departureSegments,
              snapDistanceMeters: Math.max(0, Number(current.stationMatch.distanceM) || 0),
              accessEdgeIds: current.path.map((step) => String(pack.edgeId(step.edgeIndex))),
              accessProof: "v4-directed-forecourt-through-path"
            };
            if (!best || placement.accessMeters < best.accessMeters ||
                (placement.accessMeters === best.accessMeters &&
                  placement.offRouteMeters < best.offRouteMeters)) best = placement;
          }
        }

        for (let arc = pack.nodeOffsets[current.node]; arc < pack.nodeOffsets[current.node + 1]; arc += 1) {
          const edgeIndex = pack.edgeUndirectedIndex[arc];
          const next = pack.edgeTargets[arc];
          if (layout.foundationEdgeIndexes.has(edgeIndex) ||
              current.usedEdges.has(edgeIndex) ||
              edgeIndex === current.lastEdge ||
              !fuelArcAccessAllowed(runtime, edgeIndex, current.node, next, allowUnknown)) continue;
          const turn = advanceRestrictionState(
            restrictionIndex,
            current.restrictions,
            current.lastEdge,
            edgeIndex,
            current.node
          );
          if (!turn.allowed) continue;
          const nextCost = current.cost + Math.max(0, Number(pack.edgeMeters[edgeIndex]) || 0);
          if (nextCost > MAX_FUEL_RETRACE_M + 1) continue;
          let stationMatch = current.stationMatch;
          if (!stationMatch && edgeIndex === match.edgeIndex &&
              current.node === stationFrom && next === stationTo) stationMatch = match;
          const usedEdges = new Set(current.usedEdges);
          usedEdges.add(edgeIndex);
          heap.push({
            node: next,
            cost: nextCost,
            lastEdge: edgeIndex,
            restrictions: turn.active,
            stationMatch,
            path: current.path.concat({ edgeIndex, from: current.node, to: next }),
            usedEdges
          });
        }
      }
    }
  }
  return best;
}

function sliceFoundationRoute(route, layout, fromPlacement, toPlacement, urbanBoxes = []) {
  const fromMeters = fromPlacement ? fromPlacement.exitAlongMeters : 0;
  const toMeters = toPlacement ? toPlacement.alongMeters : layout.meters;
  const routeSegments = [];
  for (const row of layout.rows) {
    const overlapStart = Math.max(fromMeters, row.startMeters);
    const overlapEnd = Math.min(toMeters, row.endMeters);
    if (overlapEnd <= overlapStart + 0.01) continue;
    const fromFraction = (overlapStart - row.startMeters) / row.meters;
    const toFraction = (overlapEnd - row.startMeters) / row.meters;
    const geometry = sliceCoordinatePolyline(row.coords, fromFraction, toFraction);
    if (geometry.length < 2) continue;
    routeSegments.push({
      ...row.segment,
      distanceMeters: overlapEnd - overlapStart,
      geometry,
      ...(Object.prototype.hasOwnProperty.call(row.segment, "coords") ? { coords: geometry } : {})
    });
  }
  const segments = [];
  if (fromPlacement) segments.push(...(fromPlacement.departureSegments || []));
  segments.push(...routeSegments);
  if (toPlacement) segments.push(...(toPlacement.arrivalSegments || []));
  const geometry = [];
  for (const segment of segments) appendCoordinates(geometry, routeSegmentCoordinates(segment));
  const onRouteMeters = Math.max(0, toMeters - fromMeters);
  const distanceMeters = segments.reduce(
    (sum, segment) => sum + Math.max(0, Number(segment.distanceMeters) || 0),
    0
  );
  const stats = aggregateRouteSurfaceStats(segments, distanceMeters);
  const startCoord = geometry[0] || locationCoordinate(fromPlacement && fromPlacement.target.location);
  const endCoord = geometry.at(-1) || locationCoordinate(toPlacement && toPlacement.target.location);
  const shape = routeShapeMetrics(geometry, startCoord, endCoord);
  const baseMeters = Math.max(1, Number(route.distanceMeters) || layout.meters);
  const movingSeconds = Math.max(0, Number(route.estimatedMovingSeconds) || 0) *
    (onRouteMeters / baseMeters) + Math.max(0, distanceMeters - onRouteMeters) / 8.3;
  const restrictedMeters = segments.reduce((sum, segment) =>
    sum + (String(segment.accessClass) === "motorized_unknown"
      ? Math.max(0, Number(segment.distanceMeters) || 0)
      : 0)
  , 0);
  const debug = route.debug || {};
  const sliced = {
    ...route,
    routeId: `${route.routeId || "route"}-fuel-${Math.round(fromMeters)}-${Math.round(toMeters)}`,
    geometry,
    segments,
    distanceMeters: Math.round(distanceMeters),
    estimatedMovingSeconds: Math.round(movingSeconds),
    estimatedElapsedSeconds: Math.round(movingSeconds * 1.15),
    stats,
    dirtPercent: stats.dirtPercent,
    pavedPercent: stats.pavedPercent,
    maneuvers: buildManeuvers(geometry),
    backtrackMeters: shape.backwardMeters,
    backtrackPct: shape.backwardPercent,
    restrictedMeters: Math.round(restrictedMeters),
    restrictedReason: restrictedMeters > 0 ? "motorized_unknown" : "none",
    debug: {
      ...debug,
      searchMeta: {
        ...(debug.searchMeta || {}),
        routeShape: shape,
        foundationSlice: true,
        foundationFromMeters: Math.round(fromMeters),
        foundationToMeters: Math.round(toMeters)
      }
    }
  };
  sliced.quality = summarizeRouteQuality(sliced, {
    profile: route.profile,
    urbanBoxes
  });
  return sliced;
}

/**
 * Reuse a proved profile route when on-route pumps can make the whole journey
 * range-safe. The selected geometry is partitioned, not re-searched, so adding
 * fuel cannot lower Dirt quality or manufacture a lateral/backtracking detour.
 *
 * The fewest valid stops wins. This matters when the mathematically minimum
 * stop count has no pump in its narrow range-overlap band: two pumps on the
 * selected ride are preferable to abandoning that ride and independently
 * routing paved-heavy legs to an unrelated one-pump chain.
 */
function foundationFuelPlan({
  foundationRoute,
  targets,
  start,
  firstLegMaxMeters,
  usableRangeMeters,
  destinationFuelUsedLimitMeters,
  minimumFuelStops,
  requireFuelStopBeforeEnd,
  requiredFirstStationId,
  preferredStationIds,
  excludedStationIds,
  maxStops,
  runtime,
  allowUnknown,
  urbanBoxes = [],
  destination
}) {
  if (!foundationRoute || foundationRoute.status !== "complete") return null;
  const layout = foundationRouteLayout(foundationRoute);
  if (!(layout.meters > 0) || !layout.rows.length) return null;
  if (!prepareFoundationTopology(layout, runtime)) return null;
  const firstCap = Number(firstLegMaxMeters);
  const usable = Number(usableRangeMeters);
  if (!(firstCap > 0) || !(usable > 0)) return null;
  const initialFuelUsed = Math.max(0, usable - firstCap);
  const configuredArrivalLimit = destinationFuelUsedLimitMeters == null
    ? NaN
    : Number(destinationFuelUsedLimitMeters);
  const directArrivalLimit = Number.isFinite(configuredArrivalLimit)
    ? Math.max(0, configuredArrivalLimit - initialFuelUsed)
    : usable;
  const directSatisfies = requireFuelStopBeforeEnd !== true &&
    (Number(minimumFuelStops) || 0) === 0 &&
    layout.meters <= firstCap + 1 && layout.meters <= directArrivalLimit + 1;
  if (directSatisfies) return null;
  const arrivalLimit = Number.isFinite(configuredArrivalLimit)
    ? Math.min(usable, configuredArrivalLimit)
    : usable;
  const required = requiredFirstStationId == null ? null : String(requiredFirstStationId);
  const preferred = new Set((preferredStationIds || []).map(String));
  const excluded = new Set((excludedStationIds || []).map(String));
  const foundationTargets = targets.fuelTargetsNear(
    start,
    // A multi-stop partition needs pumps across the complete selected ride,
    // not only those geographically reachable on the first tank. The target
    // preparation still ranks actual foundation cells first and remains
    // bounded, so this does not turn into an all-pack routing search.
    Math.max(firstCap, usable, layout.meters)
  );
  targets.prepareDiagnostics.foundationLayout = {
    meters: Math.round(layout.meters),
    rows: layout.rows.length,
    edgeIds: layout.byEdge.size,
    targets: foundationTargets.length,
    exactTargetEdges: foundationTargets.filter((target) => [
      target.match,
      ...((target.match && target.match.candidates) || [])
    ].some((match) => match && layout.byEdge.has(String(match.edgeId)))).length
  };
  const placements = foundationTargets.map((target) => foundationPlacement(target, layout)
    || forecourtFoundationPlacement(target, layout, runtime, allowUnknown)).filter(Boolean)
    .map((placement) => ({
      ...placement,
      approachMeters: placement.alongMeters + placement.arrivalMeters,
      continuationMeters: layout.meters - placement.exitAlongMeters +
        placement.departureMeters,
      urbanEntry: fuelStopRequiresUrbanEntry(
        placement.target.location,
        locationCoordinate(start),
        locationCoordinate(destination),
        urbanBoxes
      )
    }))
    .filter((placement) =>
      placement.alongMeters >= MIN_FORWARD_PROGRESS_M &&
      layout.meters - placement.exitAlongMeters >= MIN_DESTINATION_FUEL_CLEARANCE_M &&
      placement.accessMeters <= MAX_FUEL_RETRACE_M + 1 &&
      placement.snapDistanceMeters <= MAX_FUEL_RETRACE_M + 1 &&
      !excluded.has(String(placement.target.station.id))
    )
    .sort((a, b) => a.alongMeters - b.alongMeters ||
      a.accessMeters - b.accessMeters ||
      String(a.target.station.id).localeCompare(String(b.target.station.id)));
  targets.prepareDiagnostics.foundationPlacementCount = placements.length;
  targets.prepareDiagnostics.foundationPlacementAlongMeters = placements.map((placement) => ({
    id: String(placement.target.station.id),
    along: Math.round(placement.alongMeters),
    access: Math.round(placement.accessMeters)
  }));
  if (!placements.length) return null;

  const minimumStops = Math.max(
    requireFuelStopBeforeEnd === true ? 1 : 0,
    Number(minimumFuelStops) || 0
  );
  const stopLimit = Math.max(0, Math.min(12, Number(maxStops) || 12));
  if (minimumStops > stopLimit) return null;
  const legMeters = (from, to) => from
    ? from.departureMeters + (to.alongMeters - from.exitAlongMeters) + to.arrivalMeters
    : to.alongMeters + to.arrivalMeters;
  const finishMeters = (from) =>
    from.departureMeters + layout.meters - from.exitAlongMeters;
  const stateRank = (state) => [
    state.urbanStops,
    -state.preferredStops,
    state.commitPenalty,
    state.accessMeters,
    -state.path.at(-1).alongMeters
  ];
  const compareState = (a, b) => {
    const left = stateRank(a);
    const right = stateRank(b);
    for (let index = 0; index < left.length; index += 1) {
      if (left[index] !== right[index]) return left[index] - right[index];
    }
    return String(a.path.map((row) => row.target.station.id).join("|"))
      .localeCompare(String(b.path.map((row) => row.target.station.id).join("|")));
  };
  let frontier = [{
    lastIndex: -1,
    path: [],
    urbanStops: 0,
    preferredStops: 0,
    commitPenalty: 0,
    accessMeters: 0
  }];
  let complete = [];
  const exhaustedFewerStopCounts = [];
  const constraintIneligibleStopCounts = [];
  for (let depth = 1; depth <= stopLimit; depth += 1) {
    const nextByPlacement = new Map();
    for (const state of frontier) {
      const previous = state.path.at(-1) || null;
      const cap = previous ? usable : firstCap;
      for (let index = state.lastIndex + 1; index < placements.length; index += 1) {
        const placement = placements[index];
        if (previous && placement.alongMeters - previous.exitAlongMeters < MIN_STOP_SEPARATION_M) {
          continue;
        }
        if (!previous && required && String(placement.target.station.id) !== required) continue;
        const meters = legMeters(previous, placement);
        if (meters > cap + 1) continue;
        const next = {
          lastIndex: index,
          path: state.path.concat(placement),
          urbanStops: state.urbanStops + (placement.urbanEntry ? 1 : 0),
          preferredStops: state.preferredStops +
            (preferred.has(String(placement.target.station.id)) ? 1 : 0),
          commitPenalty: state.commitPenalty + Math.abs(meters / cap - FUEL_COMFORT_HI),
          accessMeters: state.accessMeters + placement.accessMeters
        };
        const existing = nextByPlacement.get(index);
        if (!existing || compareState(next, existing) < 0) nextByPlacement.set(index, next);
      }
    }
    frontier = [...nextByPlacement.values()];
    const feasibleAtDepth = frontier.filter((state) =>
      finishMeters(state.path.at(-1)) <= arrivalLimit + 1
    );
    if (depth < minimumStops) {
      constraintIneligibleStopCounts.push(depth);
    } else {
      complete = feasibleAtDepth;
      if (complete.length) break;
      exhaustedFewerStopCounts.push(depth);
    }
    if (!frontier.length) break;
  }
  if (!complete.length) {
    targets.prepareDiagnostics.foundationPartitionFailure = {
      arrivalLimit: Math.round(arrivalLimit),
      firstCap: Math.round(firstCap),
      usable: Math.round(usable),
      minimumStops,
      stopLimit,
      finalFrontier: frontier.length
    };
    return null;
  }
  complete.sort(compareState);
  const selectedState = complete[0];
  const selectedPlacements = selectedState.path;
  const selected = selectedPlacements[0];
  const routeBoundaries = [null, ...selectedPlacements, null];
  const routes = [];
  for (let index = 0; index < routeBoundaries.length - 1; index += 1) {
    routes.push(sliceFoundationRoute(
      foundationRoute,
      layout,
      routeBoundaries[index],
      routeBoundaries[index + 1],
      urbanBoxes
    ));
  }
  const graphMeters = routes.map((route) => route.distanceMeters);
  if (graphMeters.some((meters, index) =>
    meters > (index === 0 ? firstCap : usable) + 1
  )) return null;
  if (graphMeters.at(-1) > arrivalLimit + 1) return null;
  const chainMeters = graphMeters.reduce((sum, meters) => sum + Number(meters), 0);
  const detourCap = Math.max(
    layout.meters * MAX_FUEL_CHAIN_DETOUR_RATIO,
    layout.meters + MAX_FUEL_CHAIN_DETOUR_ABS_M
  );
  if (chainMeters > detourCap + 1) return null;
  // A fuel waypoint partitions one already-proved ride; it does not create two
  // unrelated route-quality decisions. A short slice can legitimately miss a
  // whole-journey percentage threshold even though the geometry and aggregate
  // Dirt quality are unchanged. Never discard the proved foundation merely
  // because either partition is labelled degraded in isolation.
  const stationCandidates = complete.slice(0, MAX_STATION_ALTERNATIVES)
    .map((state, rank) => {
      const placement = state.path[0];
      const candidateChainMeters = layout.meters + state.path.reduce((sum, row) =>
        sum + row.arrivalMeters + row.departureMeters -
          (row.exitAlongMeters - row.alongMeters), 0
      );
      return {
        id: String(placement.target.station.id),
        departureId: "start",
        latitude: Number(placement.target.location.lat),
        longitude: Number(placement.target.location.lon),
        name: placement.target.station.name || placement.target.station.brand || "Fuel stop",
        meters: Math.round(placement.approachMeters),
        graphMeters: Math.round(placement.approachMeters),
        // Every option partitions this same already-selected profile route. Use
        // its whole-route quality here; borrowing the selected pump's first-slice
        // percentage made the alternatives tray report misleading values.
        dirtPct: Number(foundationRoute.stats && foundationRoute.stats.dirtPercent) || 0,
        validForward: true,
        commitBand: tankCommitBand(placement.approachMeters, firstCap, usable),
        canFinish: true,
        rank,
        approachElapsedMs: 0,
        approachStatus: "reused",
        continuationElapsedMs: 0,
        continuationStatus: "reused",
        continuationStrategy: "foundation_route_partition",
        remainingGraphMeters: Math.round(placement.continuationMeters),
        backtrackMeters: 0,
        rejectedReason: null,
        totalElapsedMs: 0,
        candidateSource: "foundation_route",
        foundationAlongMeters: Math.round(placement.alongMeters),
        foundationOffRouteMeters: Math.round(placement.offRouteMeters),
        foundationAccessProof: placement.accessProof || "same-foundation-directed-edge",
        foundationSnapDistanceMeters: Math.round(placement.snapDistanceMeters),
        foundationAccessEdgeIds: placement.accessEdgeIds || [],
        foundationPriorityCellDistance: Number.isFinite(Number(
          placement.target.foundationCellDistance
        )) ? Number(placement.target.foundationCellDistance) : null,
        chainMeters: Math.round(candidateChainMeters),
        chainDirtPct: Number(foundationRoute.stats && foundationRoute.stats.dirtPercent) || 0,
        continuationBacktrackMeters: 0,
        urbanEntry: placement.urbanEntry,
        foundationStopIds: state.path.map((row) => String(row.target.station.id))
      };
    });
  const stops = selectedPlacements.map((placement, index) => ({
    ...placement.target.station,
    graphMeters: routes[index].distanceMeters,
    dirtPercent: Number(routes[index].stats && routes[index].stats.dirtPercent) || 0
  }));
  const dirtMeters = routes.reduce((sum, route) =>
    sum + Number(route.distanceMeters) * Number(route.stats && route.stats.dirtPercent || 0), 0
  );
  return {
    stops,
    routes,
    graphMeters,
    stationCandidates,
    firstReachableStationMeters: Math.min(...placements.map((row) => row.approachMeters)),
    diagnostics: {
      strategy: "foundation_route_partition",
      foundationRouteReused: true,
      foundationRouteMeters: Math.round(layout.meters),
      foundationRouteDirtPercent: Number.isFinite(Number(
        foundationRoute.stats && foundationRoute.stats.dirtPercent
      )) ? Number(foundationRoute.stats.dirtPercent) : null,
      foundationMatchedStations: placements.length,
      foundationSelectedStationId: String(selected.target.station.id),
      foundationSelectedStationIds: selectedPlacements.map((placement) =>
        String(placement.target.station.id)
      ),
      foundationStopCount: selectedPlacements.length,
      foundationMinimumFeasibleStops: selectedPlacements.length,
      foundationFewerStopCountsExhausted: exhaustedFewerStopCounts,
      foundationConstraintIneligibleStopCounts: constraintIneligibleStopCounts,
      foundationMinimumStopProof: true,
      foundationFirstLegLimitMeters: Math.round(firstCap),
      foundationFullTankLimitMeters: Math.round(usable),
      foundationDestinationFuelUsedLimitMeters: Math.round(arrivalLimit),
      foundationFuelLegMeters: graphMeters.slice(),
      foundationFuelAccess: selectedPlacements.map((placement) => ({
        stationId: String(placement.target.station.id),
        proof: placement.accessProof,
        arrivalMeters: Math.round(placement.arrivalMeters),
        departureMeters: Math.round(placement.departureMeters),
        edgeIds: (placement.accessEdgeIds || []).slice()
      })),
      foundationChainMeters: Math.round(chainMeters),
      foundationChainDirtPercent: chainMeters > 0 ? Math.round(dirtMeters / chainMeters) : 0,
      profileRouteSavings: 2,
      selectedUrbanEntry: selected.urbanEntry,
      ruralAlternativeAvailable: complete.some((state) =>
        state.path.some((placement) => !placement.urbanEntry)
      )
    }
  };
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
  backtrackFactor = 4,
  deadlineAtMs = Infinity,
  abortSignal = null
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
  let deadlineExceeded = false;

  while (heap.items.length) {
    const current = heap.pop();
    if (!current || current.cost !== scores[current.node]) continue;
    if (distances[current.node] > maxMeters) continue;
    pops += 1;
    if ((pops & 255) === 0 && (
      (abortSignal && abortSignal.aborted) ||
      (Number.isFinite(Number(deadlineAtMs)) && Date.now() >= Number(deadlineAtMs))
    )) {
      deadlineExceeded = true;
      break;
    }
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

  return { distances, pops, deadlineExceeded };
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
  avoidEdgeIds = [],
  deadlineAtMs = Infinity,
  abortSignal = null
}) {
  const deadlineExceeded = () =>
    (abortSignal && abortSignal.aborted) ||
    (Number.isFinite(Number(deadlineAtMs)) && Date.now() >= Number(deadlineAtMs));
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
      if ((pops & 255) === 0 && deadlineExceeded()) {
        return { meters: null, pops, deadlineExceeded: true };
      }
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
    return {
      meters: Number.isFinite(best) && best <= maxMeters ? best : null,
      pops,
      deadlineExceeded: false
    };
  }

  let best = null;
  let timedOut = false;
  for (const batchEnd of batchEnds) {
    for (; considered < batchEnd; considered += 1) {
      if ((considered & 31) === 0 && deadlineExceeded()) {
        timedOut = true;
        break;
      }
      const row = ordered[considered];
      const match = matchPoint(
        runtime, row.location, policy, HARD_MATCH_METERS, avoid, null, resolvedProfile, "end"
      );
      if (match.ok) targetMatches.push({ ...row, match });
    }
    const result = searchMatchedTargets();
    totalPops += result.pops;
    if (result.deadlineExceeded) timedOut = true;
    if (result.meters != null) {
      best = result.meters;
      const nextLowerBound = ordered[considered]?.straightMeters ?? Infinity;
      if (nextLowerBound >= best) break;
    }
    if (timedOut) break;
  }
  return {
    meters: best,
    pops: totalPops,
    matched: targetMatches.length,
    considered,
    deadlineExceeded: timedOut
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

function prepareTargets(
  runtime, stations, destination, policy, profile, avoid,
  deadlineAtMs = Infinity, abortSignal = null, foundationRoute = null,
  snapMeters = HARD_MATCH_METERS, snapHints = null
) {
  const started = Date.now();
  const foundationCells = foundationRouteCells(foundationRoute);
  const destinationMatch = matchPoint(
    runtime,
    destination,
    policy,
    snapMeters,
    avoid,
    null,
    profile,
    "end",
    snapHints
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
    stationsMatched: 0,
    deadlineExceeded: false,
    stationsInRange: 0,
    stationsMatchLimited: false,
    stationCacheMatches: 0,
    stationFreshMatches: 0,
    foundationPriorityStations: 0,
    targetPasses: []
  };
  const matchedStationIDs = new Set();

  function fuelTargetsNear(origin, maxMeters) {
    const originCoordinate = locationCoordinate(origin);
    // Road distance cannot be shorter than the geographic chord. The extra
    // snap allowance covers both endpoint projections, so this removes only
    // pumps that are physically incapable of fitting in the current tank.
    const geographicLimit = Math.max(0, Number(maxMeters) || 0) + HARD_MATCH_METERS * 2;
    const destinationCoordinate = locationCoordinate(destination);
    const nearby = stationRows.map((row) => {
      const point = [row.location.lon, row.location.lat];
      const straightMeters = haversineMeters(originCoordinate, point);
      return {
        ...row,
        straightMeters,
        progressMeters: projectedProgressMeters(point, originCoordinate, destinationCoordinate),
        crossTrack: Math.abs(crossTrackMeters(point, originCoordinate, destinationCoordinate)),
        foundationCellDistance: foundationCellDistance(row.location, foundationCells)
      };
    }).filter((row) => row.straightMeters <= geographicLimit)
      .sort((a, b) => {
        const aFoundation = Number.isFinite(a.foundationCellDistance) ? 0 : 1;
        const bFoundation = Number.isFinite(b.foundationCellDistance) ? 0 : 1;
        if (aFoundation !== bFoundation) return aFoundation - bFoundation;
        if (aFoundation === 0 && a.foundationCellDistance !== b.foundationCellDistance) {
          return a.foundationCellDistance - b.foundationCellDistance;
        }
        const aForward = a.progressMeters >= -5_000 ? 0 : 1;
        const bForward = b.progressMeters >= -5_000 ? 0 : 1;
        if (aForward !== bForward) return aForward - bForward;
        const cross = a.crossTrack - b.crossTrack;
        if (Math.abs(cross) > 2_000) return cross;
        return b.progressMeters - a.progressMeters || a.straightMeters - b.straightMeters;
      });
    prepareDiagnostics.stationsInRange = Math.max(
      prepareDiagnostics.stationsInRange,
      nearby.length
    );
    prepareDiagnostics.foundationPriorityStations = Math.max(
      prepareDiagnostics.foundationPriorityStations,
      nearby.filter((row) => Number.isFinite(row.foundationCellDistance)).length
    );
    const fuelTargets = [];
    const matchStarted = Date.now();
    let newlyConsidered = 0;
    let cacheMatches = 0;
    let freshMatches = 0;
    for (let rowIndex = 0; rowIndex < nearby.length; rowIndex += 1) {
      if ((rowIndex & 31) === 0 && (
        (abortSignal && abortSignal.aborted) ||
        (Number.isFinite(Number(deadlineAtMs)) && Date.now() >= Number(deadlineAtMs))
      )) {
        prepareDiagnostics.deadlineExceeded = true;
        break;
      }
      const row = nearby[rowIndex];
      const stationID = String(row.station.id || row.station.stationId || "");
      const cached = targetCache.get(stationID);
      if (cached !== undefined) {
        if (cached) {
          matchedStationIDs.add(stationID);
          // The road snap is stable for this graph/policy and belongs in the
          // cache. Proximity to the selected foundation route is request-
          // specific, so decorate a copy instead of letting one route's cell
          // distance leak into a later route.
          fuelTargets.push({
            ...cached,
            foundationCellDistance: row.foundationCellDistance
          });
          cacheMatches += 1;
        }
        continue;
      }
      if (
        nearby.length > DENSE_TARGET_MATCH_LIMIT &&
        newlyConsidered >= DENSE_TARGET_MATCH_LIMIT &&
        fuelTargets.length >= DENSE_TARGET_MIN_MATCHES
      ) {
        prepareDiagnostics.stationsMatchLimited = true;
        break;
      }
      prepareDiagnostics.stationsConsidered += 1;
      newlyConsidered += 1;
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
      fuelTargets.push({
        ...target,
        foundationCellDistance: row.foundationCellDistance
      });
      freshMatches += 1;
    }
    prepareDiagnostics.stationsMatched = matchedStationIDs.size;
    const elapsedMs = Date.now() - matchStarted;
    prepareDiagnostics.elapsedMs += elapsedMs;
    prepareDiagnostics.stationCacheMatches += cacheMatches;
    prepareDiagnostics.stationFreshMatches += freshMatches;
    prepareDiagnostics.targetPasses.push({
      origin: `${Number(origin && origin.lat).toFixed(5)},${Number(
        origin && (origin.lon != null ? origin.lon : origin.lng)
      ).toFixed(5)}`,
      pool: nearby.length,
      considered: newlyConsidered,
      cacheMatches,
      freshMatches,
      returned: fuelTargets.length,
      limited: prepareDiagnostics.stationsMatchLimited,
      elapsedMs
    });
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
 * 0 = selection zone (75%+ consumed), 1 is retained for wire compatibility,
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
  const aBand = tankCommitBand(aMeters, capMeters, usableRangeMeters);
  const bBand = tankCommitBand(bMeters, capMeters, usableRangeMeters);
  const band = aBand - bBand;
  if (band !== 0) return band;
  const ma = Number(aMeters) || 0;
  const mb = Number(bMeters) || 0;
  // Inside the final quarter, the first sensible pump wins. Before that
  // boundary (used only when a corridor is sparse), the farthest safe fallback
  // wins so we do not manufacture unnecessary stops.
  if (Math.abs(ma - mb) > 2_000) {
    return aBand === 0 ? ma - mb : mb - ma;
  }
  const pa = Number(aProgress) || 0;
  const pb = Number(bProgress) || 0;
  if (Math.abs(pa - pb) > 2_000) return aBand === 0 ? pa - pb : pb - pa;
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
  fullUsableRangeMeters = capMeters,
  urbanBoxes = []
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
      const urbanEntry = fuelStopRequiresUrbanEntry(
        row.location,
        current,
        destination,
        urbanBoxes
      );
      const arrivalLimit = destinationFuelUsedLimitMeters == null
        ? Number(fullUsableRangeMeters)
        : Math.min(Number(fullUsableRangeMeters), Number(destinationFuelUsedLimitMeters));
      const remainingGraphMeters = Number(row.remainingGraphMeters);
      const oneStopCapable = Number.isFinite(remainingGraphMeters) &&
        Number.isFinite(arrivalLimit)
        ? remainingGraphMeters <= arrivalLimit + 1
        : null;
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
        urbanEntry,
        oneStopCapable,
        score
      };
  });
  const forward = scored.filter((row) => row.eligibility.forward);
  const normal = forward.slice().sort((a, b) =>
    (Number(b.oneStopCapable === true) - Number(a.oneStopCapable === true)) ||
      (Number(a.urbanEntry) - Number(b.urbanEntry)) ||
      (Number.isFinite(a.foundationCellDistance) ? a.foundationCellDistance : 99) -
      (Number.isFinite(b.foundationCellDistance) ? b.foundationCellDistance : 99) ||
      // A gross lateral excursion is not a sensible final-quarter pump. Keep
      // a coherent earlier fallback ahead of a fuel-only detour.
      (Math.abs(a.crossTrack - b.crossTrack) > CORRIDOR_SOFT_WIDTH_M
        ? a.crossTrack - b.crossTrack
        : 0) ||
      (tankCommitBand(a.graphMeters, capMeters, fullUsableRangeMeters) -
        tankCommitBand(b.graphMeters, capMeters, fullUsableRangeMeters)) ||
      (Math.abs(a.crossTrack - b.crossTrack) > 5_000 ? a.crossTrack - b.crossTrack : 0) ||
      compareTankCommit(
        a.graphMeters, a.progressMeters, b.graphMeters, b.progressMeters,
        capMeters, fullUsableRangeMeters
      ) || a.crossTrack - b.crossTrack || a.graphMeters - b.graphMeters
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
  foundationRoute = null,
  graphResolution = null,
  routeOnLoadedRuntime = null,
  deadlineAtMs = null,
  abortSignal = null,
  mapZoom = null,
  matchLimitMeters = null
}) {
  profile = resolveProfile(profile);
  const policy = normalizePolicy(rawPolicy, profile);
  const started = Date.now();
  const searchBudgetMs = Number(timeBudgetMs) > 0 ? Number(timeBudgetMs) : null;
  const suppliedDeadline = Number(deadlineAtMs);
  const hasSuppliedDeadline = deadlineAtMs != null && Number.isFinite(suppliedDeadline);
  const deadline = hasSuppliedDeadline
    ? suppliedDeadline
    : (searchBudgetMs != null ? started + searchBudgetMs : Infinity);
  let timeBudgetExceeded = false;
  const avoid = new Set((avoidEdgeIds || []).map(String));
  const destLat = Number(destination && destination.lat);
  const startLat = Number(start && start.lat);
  const snapMeters = tapRadiusMeters({
    zoom: mapZoom,
    lat: Number.isFinite(destLat) ? destLat : startLat,
    requestedMeters: matchLimitMeters,
    graphBinaryVersion: (runtime.pack && runtime.pack.graphBinaryVersion) || 3,
    defaultMeters: HARD_MATCH_METERS
  });
  const intentBearing = Number.isFinite(Number(start && (start.lon ?? start.lng)))
    && Number.isFinite(Number(destination && (destination.lon ?? destination.lng)))
    ? require("./legal-topology/snap").bearingDeg(
      [Number(start.lon ?? start.lng), Number(start.lat)],
      [Number(destination.lon ?? destination.lng), Number(destination.lat)]
    )
    : null;
  const startHints = { headingDeg: Number(start && start.headingDeg), intentBearingDeg: intentBearing };
  const endHints = {
    headingDeg: Number(destination && destination.headingDeg),
    intentBearingDeg: intentBearing != null ? (intentBearing + 180) % 360 : null
  };
  let startMatch = matchPoint(
    runtime,
    start,
    policy,
    snapMeters,
    avoid,
    null,
    profile,
    "start",
    startHints
  );
  if (!startMatch.ok) {
    return {
      ok: false,
      error: "match_failed",
      message: "Point 1 is not close enough to an eligible road in the live pack.",
      allowUnknown: !!policy.motorizedUnknown
    };
  }

  const targets = prepareTargets(
    runtime, stations, destination, policy, profile, avoid, deadline, abortSignal, foundationRoute,
    snapMeters, endHints
  );
  if (!targets.destinationMatch.ok) {
    return {
      ok: false,
      error: "match_failed",
      message: "Point 2 is not close enough to an eligible road in the live pack.",
      allowUnknown: !!policy.motorizedUnknown
    };
  }
  if (runtime.pack && runtime.pack.graphBinaryVersion >= 4) {
    const picked = selectConnectedSnapPair(
      runtime.pack,
      startMatch.candidates || [startMatch],
      targets.destinationMatch.candidates || [targets.destinationMatch],
      { allowUnknown: !!policy.motorizedUnknown }
    );
    if (!picked.ok) {
      return {
        ok: false,
        error: "match_failed",
        message: "Point 2 is not close enough to an eligible connected road in the live pack.",
        allowUnknown: !!policy.motorizedUnknown
      };
    }
    startMatch = Object.assign({}, startMatch, picked.start, { ok: true });
    targets.destinationMatch = Object.assign({}, targets.destinationMatch, picked.end, { ok: true });
  }

  let states = 0;
  let dijkstraPops = 0;
  const destinationLimitForDiagnostics = destinationFuelUsedLimitMeters == null
    ? NaN : Number(destinationFuelUsedLimitMeters);
  const fuelDecisionDiagnostics = {
    selectionPolicy: FUEL_SELECTION_POLICY,
    graphOnlySelection: !!graphOnlyFeeler,
    stationAlternativesLimit: MAX_STATION_ALTERNATIVES,
    watchStartMeters: Math.round(fuelSearchStartMeters(firstLegMaxMeters, usableRangeMeters)),
    preferredStartMeters: Math.round(fuelPreferredStartMeters(firstLegMaxMeters, usableRangeMeters)),
    hardRangeMeters: Math.round(firstLegMaxMeters),
    destinationEscapeMeters: Number.isFinite(destinationLimitForDiagnostics)
      ? Math.max(0, Math.round(usableRangeMeters - destinationLimitForDiagnostics))
      : null,
    profileRoutesSharedRuntime: !!graphResolution && !routeCandidate,
    targetPrepareMs: targets.prepareDiagnostics.elapsedMs,
    targetCacheHit: targets.prepareDiagnostics.cacheHit,
    foundationPriorityStations: targets.prepareDiagnostics.foundationPriorityStations,
    allowUnknown: !!policy.motorizedUnknown,
    tapRadiusMeters: snapMeters,
    mapZoom: Number.isFinite(Number(mapZoom)) ? Number(mapZoom) : null,
    snap: {
      start: snapEndpointRecord(
        { lon: Number(start && (start.lon ?? start.lng)), lat: Number(start && start.lat) },
        startMatch && startMatch.ok ? startMatch : null,
        {
          candidateCount: ((startMatch && startMatch.candidates) || []).length,
          rejectionReasons: Array.from(new Set(((startMatch && startMatch.rejections) || []).map((row) => row.reason).filter(Boolean)))
        }
      ),
      end: snapEndpointRecord(
        {
          lon: Number(destination && (destination.lon ?? destination.lng)),
          lat: Number(destination && destination.lat)
        },
        targets.destinationMatch && targets.destinationMatch.ok ? targets.destinationMatch : null,
        {
          candidateCount: ((targets.destinationMatch && targets.destinationMatch.candidates) || []).length,
          rejectionReasons: Array.from(new Set(((targets.destinationMatch && targets.destinationMatch.rejections) || []).map((row) => row.reason).filter(Boolean)))
        }
      )
    }
  };
  const memo = new Map();
  const stationCandidates = [];
  const preferredStations = new Set((preferredStationIds || []).map(String));
  let effectiveK = Math.max(1, Math.min(6, Number(candidateK) || 6));
  let maxHopMs = 0;
  let firstReachableStationMeters = null;
  let stationsReachableWithinRange = 0;
  const physicalStart = locationCoordinate(start);
  const physicalDestination = locationCoordinate(destination);
  const urbanBoxes = fuelUrbanBoxesForRuntime(runtime);
  const physicalTotal = haversineMeters(physicalStart, physicalDestination);
  let planningStage = "destination_graph";
  let bestPartial = { progressMeters: 0, stops: [], graphMeters: [], location: start };
  const returnedStopLimit = Math.max(1, Math.min(12, Number(maxStops) || 12));
  // A graph-only incremental window commits one pump, then lets the next
  // request start from that real fuel anchor with a fresh clock. Profile-
  // routed allocation may retain bounded look-ahead for rural dead ends.
  const searchStopLimit = graphOnlyFeeler && allowPartialWindow
    ? returnedStopLimit
    : allowPartialWindow
    ? Math.min(4, Math.max(
        returnedStopLimit + 2,
        (Number(minimumFuelStops) || 0) + 1
      ))
    : returnedStopLimit;
  if (!graphOnlyFeeler && !probeFirstReachableStation && foundationRoute) {
    planningStage = "foundation_route_partition";
    const completedRoutes = [
      foundationRoute,
      ...(Array.isArray(foundationRoute._completedFoundationRoutes)
        ? foundationRoute._completedFoundationRoutes
        : [])
    ];
    const seenFoundations = new Set();
    const rankedFoundations = completedRoutes.filter((route) => {
      if (!route || route.status !== "complete" || !Array.isArray(route.segments)) return false;
      const signature = route.segments.map((segment) => String(segment.edgeId || "")).join(">");
      if (!signature || seenFoundations.has(signature)) return false;
      seenFoundations.add(signature);
      return true;
    }).sort((a, b) =>
      Number(b.stats && b.stats.dirtPercent || 0) -
        Number(a.stats && a.stats.dirtPercent || 0) ||
      Number(a.distanceMeters || Infinity) - Number(b.distanceMeters || Infinity)
    );
    const foundationAttempts = [];
    let reusedFoundation = null;
    let reusedFoundationRoute = null;
    for (const candidateRoute of rankedFoundations) {
      if (Number.isFinite(deadline) && Date.now() >= deadline) break;
      targets.prepareDiagnostics.foundationPartitionFailure = null;
      const candidatePlan = foundationFuelPlan({
        foundationRoute: candidateRoute,
        targets,
        start,
        firstLegMaxMeters,
        usableRangeMeters,
        destinationFuelUsedLimitMeters,
        minimumFuelStops,
        requireFuelStopBeforeEnd,
        requiredFirstStationId,
        preferredStationIds,
        excludedStationIds,
        maxStops: searchStopLimit,
        runtime,
        allowUnknown: !!(policy && policy.motorizedUnknown),
        urbanBoxes,
        destination
      });
      foundationAttempts.push({
        routeMeters: Math.round(Number(candidateRoute.distanceMeters) || 0),
        dirtPercent: Number(candidateRoute.stats && candidateRoute.stats.dirtPercent) || 0,
        matchedStations: Number(targets.prepareDiagnostics.foundationPlacementCount) || 0,
        feasible: !!candidatePlan,
        failure: candidatePlan ? null :
          (targets.prepareDiagnostics.foundationPartitionFailure || "no_eligible_on_route_station")
      });
      if (candidatePlan) {
        reusedFoundation = candidatePlan;
        reusedFoundationRoute = candidateRoute;
        break;
      }
    }
    fuelDecisionDiagnostics.foundationLayout = targets.prepareDiagnostics.foundationLayout || null;
    fuelDecisionDiagnostics.foundationPlacementCount =
      Number(targets.prepareDiagnostics.foundationPlacementCount) || 0;
    fuelDecisionDiagnostics.foundationPlacementAlongMeters =
      targets.prepareDiagnostics.foundationPlacementAlongMeters || [];
    fuelDecisionDiagnostics.foundationPartitionFailure =
      targets.prepareDiagnostics.foundationPartitionFailure || null;
    fuelDecisionDiagnostics.foundationCandidateAttempts = foundationAttempts;
    if (reusedFoundation) {
      const reusedCandidates = reusedFoundation.stationCandidates || [];
      const reusedResponse = {
        ok: true,
        stops: reusedFoundation.stops,
        graphMeters: reusedFoundation.graphMeters,
        routes: reusedFoundation.routes,
        stationCandidates: reusedCandidates,
        firstReachableStationMeters: reusedFoundation.firstReachableStationMeters,
        windowComplete: true,
        diagnostics: enrichFuelDiagnostics({
          ...fuelDecisionDiagnostics,
          ...reusedFoundation.diagnostics,
          targetPrepareMs: targets.prepareDiagnostics.elapsedMs,
          targetCacheHit: targets.prepareDiagnostics.cacheHit,
          stationsConsidered: targets.prepareDiagnostics.stationsConsidered,
          stationsInRange: targets.prepareDiagnostics.stationsInRange,
          stationsMatchLimited: targets.prepareDiagnostics.stationsMatchLimited,
          stationCacheMatches: targets.prepareDiagnostics.stationCacheMatches,
          stationFreshMatches: targets.prepareDiagnostics.stationFreshMatches,
          foundationPriorityStations: targets.prepareDiagnostics.foundationPriorityStations,
          targetPasses: targets.prepareDiagnostics.targetPasses,
          states: 1,
          dijkstraPops: 0,
          matchedFuel: targets.prepareDiagnostics.stationsMatched,
          candidateK: effectiveK,
          elapsedMs: Date.now() - started,
          maxHopMs: 0,
          profileRouteAttempts: 0,
          slowestProfileRoutes: [],
          searchDeadlineOverrunMs: Number.isFinite(deadline)
            ? Math.max(0, Date.now() - deadline)
            : 0,
          timeBudgetExceeded: false,
          deadlinePhase: null,
          cancelled: false,
          selectedReason: reusedFoundationRoute === foundationRoute
            ? "foundation_route_fuel"
            : "fuel_feasible_complete_profile_candidate",
          originalFoundationRouteMeters: Math.round(Number(foundationRoute.distanceMeters) || 0),
          originalFoundationDirtPercent:
            Number(foundationRoute.stats && foundationRoute.stats.dirtPercent) || 0,
          fuelAwareFoundationAlternative: reusedFoundationRoute !== foundationRoute
        }, {
          stationsReachableWithinRange: reusedCandidates.length,
          candidatesEvaluated: reusedCandidates.length,
          stationCandidates: reusedCandidates
        })
      };
      return reusedResponse;
    }
  }
  const destinationGraph = boundedGraphDistances(
    runtime, targets.destinationMatch, policy, usableRangeMeters,
    avoidEdgeIds, [], null, 1, deadline, abortSignal
  );
  dijkstraPops += destinationGraph.pops;
  if (destinationGraph.deadlineExceeded) timeBudgetExceeded = true;

  function reachableFrom(currentKey, currentLocation, currentMatch, capMeters, history, arrival) {
    planningStage = "reachability_graph";
    const historyKey = [...history].sort().join(",");
    const memoKey = `${currentKey}:${Math.round(capMeters)}:${arrival || "-"}:${historyKey}`;
    if (memo.has(memoKey)) return memo.get(memoKey);
    const graph = boundedGraphDistances(
      runtime, currentMatch, policy, capMeters, avoidEdgeIds,
      [...history], arrival, backtrackFactor, deadline, abortSignal
    );
    dijkstraPops += graph.pops;
    if (graph.deadlineExceeded) timeBudgetExceeded = true;
    const destinationMeters = distanceToMatch(
      runtime,
      currentMatch,
      targets.destinationMatch,
      graph.distances
    );
    const fuel = [];
    planningStage = "target_matching";
    for (const target of targets.fuelTargetsNear(currentLocation, capMeters)) {
      const graphMeters = distanceToMatch(runtime, currentMatch, target.match, graph.distances);
      if (Number.isFinite(graphMeters) && graphMeters <= capMeters) {
        const remainingGraphMeters = distanceToMatch(
          runtime, targets.destinationMatch, target.match, destinationGraph.distances
        );
        fuel.push({ ...target, graphMeters, remainingGraphMeters });
      }
    }
    if (targets.prepareDiagnostics.deadlineExceeded) timeBudgetExceeded = true;
    const result = { destinationMeters, fuel };
    memo.set(memoKey, result);
    return result;
  }

  const defaultProfileHop = async ({
    candidate,
    from,
    maxMeters,
    priorEdgeIds: evaluationHistory,
    arrivalEdgeId: evaluationArrival,
    startEndpointKind,
    deadlineAtMs: hopDeadlineAtMs
  }) => {
    const activeDeadline = Number.isFinite(Number(hopDeadlineAtMs))
      ? Number(hopDeadlineAtMs)
      : deadline;
    if (
      (abortSignal && abortSignal.aborted) ||
      (Number.isFinite(activeDeadline) && Date.now() >= activeDeadline)
    ) {
      timeBudgetExceeded = true;
      return {
        status: "failed",
        error: "window_time_budget",
        message: "Fuel candidate routing reached the planning deadline.",
        distanceMeters: 0,
        debug: {
          failureReason: "timeout",
          searchOutcome: abortSignal && abortSignal.aborted ? "cancelled" : "timeCap"
        }
      };
    }
    const usesFoundation = foundationRoute && candidate.station.id === "__destination__" &&
      Math.abs(Number(from.lat) - Number(start.lat)) < 1e-7 &&
      Math.abs(Number(from.lon) - Number(start.lon)) < 1e-7;
    if (usesFoundation) return foundationRoute;
    const routeBody = {
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
        startEndpointKind: startEndpointKind || null,
        endEndpointKind: candidate.station.id === "__destination__" ? null : "customers",
        directExtraBudgetMeters: undefined,
        maxPathMeters: maxMeters,
        deadlineAtMs: activeDeadline,
        abortSignal
      }
    };
    return graphResolution
      ? (routeOnLoadedRuntime || routeOnRuntime)(routeBody, graphResolution, runtime)
      : routeRequest(routeBody);
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
        const attemptDeadlineAtMs = Number(options && options.deadlineAtMs);
        const deadlineRemainingAtStartMs = Number.isFinite(attemptDeadlineAtMs)
          ? attemptDeadlineAtMs - attemptStarted
          : null;
        try {
          const response = await profileRoute(options);
          const responseDiagnostics = response && response.debug && response.debug.diagnostics;
          profileRouteTimings.push({
            candidateId,
            elapsedMs: Date.now() - attemptStarted,
            status: response && response.status || "unknown",
            distanceMeters: Number.isFinite(Number(response && response.distanceMeters))
              ? Math.round(Number(response.distanceMeters))
              : null,
            maxMeters: Number.isFinite(Number(options && options.maxMeters))
              ? Math.round(Number(options.maxMeters))
              : null,
            deadlineRemainingAtStartMs,
            deadlineRemainingAtEndMs: Number.isFinite(attemptDeadlineAtMs)
              ? attemptDeadlineAtMs - Date.now()
              : null,
            searchMs: finiteDiagnosticNumber(
              responseDiagnostics && responseDiagnostics.searchMs != null
                ? responseDiagnostics.searchMs
                : response && response.debug && response.debug.searchMs
            ),
            snapMs: finiteDiagnosticNumber(responseDiagnostics && responseDiagnostics.snapMs),
            postprocessMs: finiteDiagnosticNumber(
              responseDiagnostics && responseDiagnostics.postprocessMs
            ),
            pops: finiteDiagnosticNumber(
              responseDiagnostics && responseDiagnostics.pops != null
                ? responseDiagnostics.pops
                : response && response.debug && response.debug.pops
            ),
            fallbacks: responseDiagnostics && Array.isArray(responseDiagnostics.profileFallbacks)
              ? responseDiagnostics.profileFallbacks
              : []
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
              : null,
            deadlineRemainingAtStartMs,
            deadlineRemainingAtEndMs: Number.isFinite(attemptDeadlineAtMs)
              ? attemptDeadlineAtMs - Date.now()
              : null,
            searchMs: null,
            snapMs: null,
            postprocessMs: null,
            pops: null,
            fallbacks: []
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
    return timeBudgetExceeded ||
      (abortSignal && abortSignal.aborted) ||
      (Number.isFinite(deadline) && Date.now() >= deadline);
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
      // Once the final quarter begins, the first sensible pump is the primary
      // choice. A pump that happens to eliminate a later stop may fill the
      // shortlist, but it must not jump ahead and consume the whole current
      // tank. One early candidate is retained only as a sparse-corridor
      // fallback.
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
      fillFrom(preferred, watchedLimit);
      fillFrom(watched, watchedLimit);
      fillFrom(canFinishNextTank, watchedLimit);
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
      const candidateStarted = Date.now();
      const approachDeadlineAtMs = candidateApproachDeadlineAtMs(deadline, candidateStarted);
      const approachBudgetMs = Number.isFinite(approachDeadlineAtMs)
        ? Math.max(0, approachDeadlineAtMs - candidateStarted)
        : null;
      let approachElapsedMs = null;
      let continuationElapsedMs = null;
      let continuationStrategy = null;
      try {
        planningStage = "candidate_route";
        const approachStarted = Date.now();
        const response = await evaluateProfileHop({
          candidate,
          from: currentLocation,
          maxMeters: hopCap,
          profile,
          accessPolicy: rawPolicy,
          priorEdgeIds: [...history],
          arrivalEdgeId: arrival,
          backtrackFactor,
          startEndpointKind: depth > 0 ? "customers" : null,
          deadlineAtMs: approachDeadlineAtMs,
          abortSignal
        });
        approachElapsedMs = Date.now() - approachStarted;
        const meters = Number(response && response.distanceMeters);
        const dirtPct = Number(response && response.stats && response.stats.dirtPercent);
        const firstBacktrackMeters = responseBacktrackMeters(response);
        const fits = response && response.status === "complete"
          && Number.isFinite(meters) && meters <= hopCap + 1
          && firstBacktrackMeters <= MAX_FUEL_RETRACE_M + 1;
        const approachProvenWithinBudget = fits && (
          !Number.isFinite(approachDeadlineAtMs) || Date.now() <= approachDeadlineAtMs
        );
        if (fits && !approachProvenWithinBudget) timeBudgetExceeded = true;
        row = {
          candidate,
          response,
          rank,
          meters: Number.isFinite(meters) ? meters : candidate.graphMeters,
          dirtPct: Number.isFinite(dirtPct) ? dirtPct : 0,
          chainDirtPct: Number.isFinite(dirtPct) ? dirtPct : 0,
          fits,
          approachProvenWithinBudget,
          continuationDestinationMeters: null,
          continuationResponse: null,
          continuationBacktrackMeters: null,
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
        const canContinueEvaluation =
          !(abortSignal && abortSignal.aborted) && Date.now() < deadline;
        if (fits && !canContinueEvaluation) timeBudgetExceeded = true;
        if (fits && canContinueEvaluation) {
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
          const configuredArrivalLimit = destinationFuelUsedLimitMeters == null
            ? NaN
            : Number(destinationFuelUsedLimitMeters);
          const continuationCap = Number.isFinite(configuredArrivalLimit)
            ? Math.min(usableRangeMeters, configuredArrivalLimit)
            : usableRangeMeters;
          let directContinuationAttempted = false;
          const proveDirectContinuation = async (lowerBoundMeters) => {
            if (
              !Number.isFinite(lowerBoundMeters) ||
              lowerBoundMeters > continuationCap + 1 ||
              Date.now() >= deadline ||
              (abortSignal && abortSignal.aborted)
            ) return false;
            directContinuationAttempted = true;
            planningStage = "candidate_continuation";
            const continuationStarted = Date.now();
            const continuationResponse = await evaluateProfileHop({
              candidate: destinationCandidate(lowerBoundMeters),
              from: candidate.location,
              maxMeters: continuationCap,
              profile,
              accessPolicy: rawPolicy,
              priorEdgeIds: [...nextHistory],
              arrivalEdgeId: nextArrival,
              backtrackFactor,
              startEndpointKind: "customers",
              deadlineAtMs: deadline,
              abortSignal
            });
            continuationElapsedMs = Date.now() - continuationStarted;
            const continuationProvenWithinBudget = completedContinuationWithinWindow(
              continuationResponse,
              deadline
            );
            if (!continuationProvenWithinBudget) timeBudgetExceeded = true;
            const routedContinuationMeters = Number(
              continuationResponse && continuationResponse.distanceMeters
            );
            const continuationBacktrackMeters = responseBacktrackMeters(continuationResponse);
            row.continuationBacktrackMeters = continuationBacktrackMeters;
            const hasMeasuredFoundationProximity = candidate.foundationCellDistance != null &&
              Number.isFinite(Number(candidate.foundationCellDistance));
            const continuationBacktrackCap = hasMeasuredFoundationProximity
              ? MAX_FOUNDATION_NEARBY_CONTINUATION_BACKTRACK_M
              : MAX_FUEL_RETRACE_M;
            if (
              continuationResponse && continuationResponse.status === "complete" &&
              continuationProvenWithinBudget &&
              Number.isFinite(routedContinuationMeters) &&
              routedContinuationMeters <= continuationCap + 1 &&
              continuationBacktrackMeters <= continuationBacktrackCap + 1
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
              return true;
            } else {
              row.continuationDestinationMeters = null;
            }
            return false;
          };

          // Destination-rooted graph distance is already available from the
          // one shared destination search. When it fits the next full tank,
          // prove that active-profile continuation immediately. Re-running a
          // province-wide reachability search from every candidate before this
          // proof multiplied dense Ontario work by the shortlist size.
          continuationStrategy = "direct_remaining_graph";
          const directProved = await proveDirectContinuation(
            Number(candidate.remainingGraphMeters)
          );
          let forwardStations = [];
          if (!directProved && Date.now() < deadline && !(abortSignal && abortSignal.aborted)) {
            continuationStrategy += "+forward_reachability";
            const continuation = reachableFrom(
              String(candidate.station.id), candidate.location, candidate.match, usableRangeMeters,
              nextHistory, nextArrival
            );
            forwardStations = rankForwardFuel(
              continuation.fuel,
              candidate.location,
              destination,
              usableRangeMeters,
              new Set([...visited, String(candidate.station.id)]),
              profile,
              null,
              null,
              false,
              usableRangeMeters,
              urbanBoxes
            );
            row.continuationDestinationMeters = Number.isFinite(continuation.destinationMeters)
              ? continuation.destinationMeters
              : null;
            if (!directContinuationAttempted) {
              await proveDirectContinuation(Number(continuation.destinationMeters));
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
          rank,
          approachBudgetMs,
          approachElapsedMs,
          approachStatus: response && response.status || null,
          approachProvenWithinBudget,
          approachSearchOutcome: response && response.debug && response.debug.searchOutcome || null,
          approachFailureReason: response && response.debug && response.debug.failureReason || null,
          continuationElapsedMs,
          continuationStatus: row.continuationResponse && row.continuationResponse.status || null,
          continuationStrategy,
          candidateDeadlineRemainingMs: Number.isFinite(deadline)
            ? deadline - Date.now()
            : null,
          backtrackMeters: Math.round(firstBacktrackMeters),
          rejectedReason: !fits
            ? (response && response.status !== "complete" ? "approach_incomplete"
              : (!Number.isFinite(meters) ? "approach_distance_missing"
                : (meters > hopCap + 1 ? "approach_over_range" : "approach_backtrack")))
            : (!validForward ? "continuation_unproved" : null),
          totalElapsedMs: Date.now() - candidateStarted,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null,
          chainMeters: row.continuationResponse
            ? Math.round(row.meters + Number(row.continuationDestinationMeters || 0))
            : null,
          chainDirtPct: Number.isFinite(Number(row.chainDirtPct)) ? row.chainDirtPct : null,
          continuationBacktrackMeters: Number.isFinite(Number(row.continuationBacktrackMeters))
            ? Math.round(Number(row.continuationBacktrackMeters))
            : null,
          urbanEntry: !!candidate.urbanEntry,
          oneStopCapable: candidate.oneStopCapable,
          foundationPriorityCellDistance: Number.isFinite(Number(
            candidate.foundationCellDistance
          )) ? Number(candidate.foundationCellDistance) : null
        };
      } catch (error) {
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
          rank,
          approachBudgetMs,
          approachElapsedMs,
          approachStatus: "error",
          approachSearchOutcome: null,
          approachFailureReason: error && error.message || "candidate_error",
          continuationElapsedMs,
          continuationStatus: null,
          continuationStrategy,
          candidateDeadlineRemainingMs: Number.isFinite(deadline)
            ? deadline - Date.now()
            : null,
          backtrackMeters: null,
          rejectedReason: "candidate_error",
          totalElapsedMs: Date.now() - candidateStarted,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null,
          chainMeters: null,
          continuationBacktrackMeters: null,
          urbanEntry: !!candidate.urbanEntry,
          oneStopCapable: candidate.oneStopCapable,
          foundationPriorityCellDistance: Number.isFinite(Number(
            candidate.foundationCellDistance
          )) ? Number(candidate.foundationCellDistance) : null
        };
        row = {
          candidate,
          response: null,
          rank,
          meters: candidate.graphMeters,
          dirtPct: 0,
          fits: false,
          approachProvenWithinBudget: false,
          continuationDestinationMeters: null,
          continuationResponse: null,
          continuationBacktrackMeters: null,
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
      // A graph-only window has no ride-quality evidence with which to
      // overrule the 75%-then-first-pump ordering. Preserve the selector rank;
      // the app routes that one committed hop using the requested profile.
      if (graphOnlyFeeler && a.rank !== b.rank) return a.rank - b.rank;
      const aStops = a.continuationResponse ? 1 : 2;
      const bStops = b.continuationResponse ? 1 : 2;
      if (aStops !== bStops) return aStops - bStops;
      if (!!a.candidate.urbanEntry !== !!b.candidate.urbanEntry) {
        return a.candidate.urbanEntry ? 1 : -1;
      }
      const aq = a.chainQuality || combineChainQuality();
      const bq = b.chainQuality || combineChainQuality();
      if (Math.abs(aq.urbanCoreMeters - bq.urbanCoreMeters) > 100) {
        return aq.urbanCoreMeters - bq.urbanCoreMeters;
      }
      // Never trade the established final-quarter fueling policy for a nicer
      // surface mix. Profile quality decides between pumps in the same tank
      // window; an early pump remains a sparse-corridor or urban-avoidance
      // fallback only.
      const commitBand = tankCommitBand(a.meters, cap, usableRangeMeters) -
        tankCommitBand(b.meters, cap, usableRangeMeters);
      if (commitBand !== 0) return commitBand;
      const tankOrder = compareTankCommit(
        a.meters, hopProgress(a), b.meters, hopProgress(b), cap, usableRangeMeters
      );
      if (tankOrder !== 0) return tankOrder;
      switch (resolveProfile(profile)) {
        case "dirt": {
          const dirtDelta = b.chainDirtPct - a.chainDirtPct;
          if (Math.abs(dirtDelta) > 0.5) return dirtDelta;
          if (Math.abs(aq.minimumSectionDirtPercent - bq.minimumSectionDirtPercent) > 2) {
            return bq.minimumSectionDirtPercent - aq.minimumSectionDirtPercent;
          }
          if (Math.abs(aq.longestPavedRunMeters - bq.longestPavedRunMeters) > 2_000) {
            return aq.longestPavedRunMeters - bq.longestPavedRunMeters;
          }
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
          break;
        }
        default:
          break;
      }
      const aFoundationCell = Number.isFinite(Number(a.candidate.foundationCellDistance))
        ? Number(a.candidate.foundationCellDistance)
        : 99;
      const bFoundationCell = Number.isFinite(Number(b.candidate.foundationCellDistance))
        ? Number(b.candidate.foundationCellDistance)
        : 99;
      if (aFoundationCell !== bFoundationCell) return aFoundationCell - bFoundationCell;
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
        case "cleanest": {
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

      if (!!candidate.urbanEntry !== !!winner.candidate.urbanEntry) {
        return !candidate.urbanEntry;
      }

      const candidateBand = tankCommitBand(
        candidate.graphMeters, cap, usableRangeMeters
      );
      const winnerBand = tankCommitBand(winner.meters, cap, usableRangeMeters);
      if (candidateBand !== winnerBand) return candidateBand < winnerBand;

      if (!evaluatedProfileTargetMet(winner)) return true;

      // Clean's product rule is the first proved pump in the final-quarter
      // window. Once it completes safely, a later pump in the same band cannot
      // beat it merely by being farther through the tank. Dirt and Balanced
      // still compare profile quality within the band.
      if (resolveProfile(profile) === "cleanest") return false;

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

    function evaluatedProfileTargetMet(row) {
      if (!row || !row.chainQuality) return false;
      if (row.chainQuality.urbanCoreMeters > 100) return false;
      const dirtPercent = row.chainQuality.meters > 0
        ? row.chainQuality.dirtMeters / row.chainQuality.meters * 100
        : 0;
      switch (resolveProfile(profile)) {
        case "dirt":
          return dirtPercent >= 70 && row.chainQuality.minimumSectionDirtPercent >= 35;
        case "balanced":
          return dirtPercent >= 45 && dirtPercent <= 55;
        default:
          return true;
      }
    }

    // Profile-route probes dominate fuel latency. Prove the strongest graph-
    // ranked option first and reassess before spending time on another one.
    // Running two province-scale profile searches together made both miss the
    // same deadline, leaving no proved pump even when the first choice was
    // sensible. Serial proof also makes cancellation and diagnostics exact.
    const batchSize = 1;
    const watchedAvailable = unique.some((row) => tankCommitBand(
      row.graphMeters, cap, usableRangeMeters
    ) <= 1);
    const earlyAvailable = unique.some((row) => tankCommitBand(
      row.graphMeters, cap, usableRangeMeters
    ) === 2);
    // Profile-routed live work may finish after one unbeatable proof. A
    // graph-only cross-region result is different: the client still has to
    // prove the actual Dirt/Balanced/Clean route across the authored seam.
    // Retain a few graph-valid alternatives from this already-built
    // reachability result so one rejected pump does not trigger another full
    // target-matching pass with only the watchdog remainder available.
    const minimumCandidateComparisons = graphOnlyFeeler
      ? Math.min(GRAPH_ONLY_RECOVERY_CANDIDATES, candidates.length)
      : Number.isFinite(deadline)
        ? 1
        : Math.min(2, candidates.length);
    for (let startRank = 0; startRank < candidates.length; startRank += batchSize) {
      if ((abortSignal && abortSignal.aborted) || Date.now() >= deadline) {
        timeBudgetExceeded = true;
        break;
      }
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
      if (rows.length >= minimumCandidateComparisons &&
          provenComplete &&
          requiredStopsSatisfied && (!watchedAvailable || tankCommitBand(
        provenComplete.meters, cap, usableRangeMeters
      ) <= 1)) {
        // A proved chain may stop the search only when the remaining bounded
        // shortlist cannot beat it. In particular, do not freeze a paved-heavy
        // Dirt chain merely because it was the first one proved inside a live
        // deadline; an earlier rural pump can be the choice that preserves the
        // requested ride profile without adding another fuel stop.
        const remaining = candidates.slice(startRank + batch.length);
        if (!remaining.some((candidate) =>
          canUnevaluatedCandidateBeatComplete(candidate, provenComplete)
        )) break;
      }
      // Graph-only probes have no ride-quality signal. Real fuel allocation
      // keeps routing candidates until either their profile rides are compared
      // or the remaining choices are proven unable to beat a complete winner.
      if (
        graphOnlyFeeler && rows.length >= minimumCandidateComparisons &&
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
    // compete with a valid route-connected pump after the 75% selection point.
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
    if ((abortSignal && abortSignal.aborted) || Date.now() >= deadline) {
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
          usableRangeMeters,
          urbanBoxes
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
        planningStage = "destination_route";
        const response = await evaluateProfileHop({
          candidate: destinationCandidate(reach.destinationMeters),
          from: currentLocation,
          maxMeters: cap,
          profile,
          accessPolicy: rawPolicy,
          priorEdgeIds: [...history],
          arrivalEdgeId: arrival,
          backtrackFactor,
          startEndpointKind: depth > 0 ? "customers" : null
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
            urbanStopCount: 0,
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
      usableRangeMeters,
      urbanBoxes
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
    const routedApproachPlans = [];
    for (const evaluation of evaluated.slice(0, graphOnlyFeeler ? 1 : 2)) {
      if (states >= maxStates) break;
      if (!evaluation.fits) continue;
      const candidate = evaluation.candidate;
      const stop = {
        ...candidate.station,
        graphMeters: evaluation.meters,
        dirtPercent: evaluation.dirtPct
      };
      if (evaluation.approachProvenWithinBudget) {
        routedApproachPlans.push({
          evaluation,
          plan: {
            stops: [stop],
            graphMeters: [evaluation.meters],
            routes: [evaluation.response],
            quality: evaluation.firstQuality,
            urbanStopCount: candidate.urbanEntry ? 1 : 0,
            directionalDetourMeters: Number(evaluation.candidate.crossTrack) || 0,
            progressMeters: Number(evaluation.candidate.progressMeters) || 0,
            complete: false,
            partial: true,
            partialReason: "approach_proved_continuation_timeout"
          }
        });
      }
      if (!evaluation.validForward) continue;
      const continuationMeters = Number(evaluation.continuationDestinationMeters);
      const requiredStopsSatisfied = depth + 1 >= Math.max(
        0, Number(minimumFuelStops) || 0
      );
      // `destinationLimit` above applies only to reaching B before another
      // pump at the current depth. This candidate is itself a refuel, so its
      // continuation starts from a full tank and must use the configured
      // full-tank arrival allowance. Subtracting fuel consumed before this
      // pump forced a duplicate continuation proof (and sometimes a phantom
      // second stop) after an already-valid one-stop chain had been proved.
      const postRefuelDestinationLimit = Number.isFinite(configuredDestinationLimit)
        ? configuredDestinationLimit
        : NaN;
      if (
        evaluation.continuationResponse &&
        Number.isFinite(continuationMeters) &&
        requiredStopsSatisfied &&
        (!Number.isFinite(postRefuelDestinationLimit) ||
          continuationMeters <= postRefuelDestinationLimit + 1)
      ) {
        stationPlans.push({
          stops: [stop],
          graphMeters: [evaluation.meters, continuationMeters],
          routes: [evaluation.response, evaluation.continuationResponse],
          quality: evaluation.chainQuality,
          urbanStopCount: candidate.urbanEntry ? 1 : 0,
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
      if ((abortSignal && abortSignal.aborted) || Date.now() >= deadline) {
        if (!stationPlans.length && allowPartialWindow && evaluation.validForward) {
          stationPlans.push({
            stops: [stop],
            graphMeters: [evaluation.meters],
            routes: [evaluation.response],
            quality: evaluation.firstQuality,
            urbanStopCount: candidate.urbanEntry ? 1 : 0,
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
          urbanStopCount: (candidate.urbanEntry ? 1 : 0) +
            (Number(tail.urbanStopCount) || 0),
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
          urbanStopCount: candidate.urbanEntry ? 1 : 0,
          complete: false,
          partial: true
        });
      }
    }
    // The visible fuel window is incremental, but a route to a pump alone is
    // not enough. A resumable timeout prefix must also have graph/profile proof
    // of a sensible forward continuation. Otherwise return an inconclusive
    // fuel result and preserve the road route without inventing a safe stop.
    if (!stationPlans.length && allowPartialWindow && exceededSearchBudget() &&
        routedApproachPlans.length) {
      const safePartial = selectSafeTimeoutPartial(routedApproachPlans);
      if (safePartial) {
        stationPlans.push(safePartial.plan);
        timeBudgetExceeded = true;
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

  let chain = await search(
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
        stationsInRange: targets.prepareDiagnostics.stationsInRange,
        stationsMatchLimited: targets.prepareDiagnostics.stationsMatchLimited,
        stationCacheMatches: targets.prepareDiagnostics.stationCacheMatches,
        stationFreshMatches: targets.prepareDiagnostics.stationFreshMatches,
        foundationPriorityStations: targets.prepareDiagnostics.foundationPriorityStations,
        targetPasses: targets.prepareDiagnostics.targetPasses,
        states,
        dijkstraPops,
        matchedFuel: targets.prepareDiagnostics.stationsMatched,
        candidateK: effectiveK,
        stationCandidates,
        stationAlternativesReturned: stationCandidates.length,
        elapsedMs: Date.now() - started,
        maxHopMs,
        profileRouteAttempts,
        slowestProfileRoutes: slowestProfileRoutes(),
        searchDeadlineOverrunMs: Number.isFinite(deadline)
          ? Math.max(0, Date.now() - deadline)
          : 0,
        timeBudgetExceeded: exceededSearchBudget(),
        deadlinePhase: exceededSearchBudget() ? planningStage : null,
        cancelled: !!(abortSignal && abortSignal.aborted)
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
      stationCandidates,
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
  const selectedStationId = returnedStops.length ? String(returnedStops[0].id) : null;
  const selectedCandidate = selectedStationId == null ? null : stationCandidates.find((candidate) =>
    String(candidate.id) === selectedStationId
  );
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
      stationsInRange: targets.prepareDiagnostics.stationsInRange,
      stationsMatchLimited: targets.prepareDiagnostics.stationsMatchLimited,
      stationCacheMatches: targets.prepareDiagnostics.stationCacheMatches,
      stationFreshMatches: targets.prepareDiagnostics.stationFreshMatches,
      foundationPriorityStations: targets.prepareDiagnostics.foundationPriorityStations,
      targetPasses: targets.prepareDiagnostics.targetPasses,
      stationAlternativesReturned: stationCandidates.length,
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
      deadlinePhase: exceededSearchBudget() ? planningStage : null,
      cancelled: !!(abortSignal && abortSignal.aborted),
      partialReason: chain.partialReason || null,
      selectedReason: chain.partial
        ? "routed_prefix_timeout"
        : returnedStops.length
          ? "minimum_stops_forward"
        : "direct_destination",
      selectedUrbanEntry: !!(selectedCandidate && selectedCandidate.urbanEntry),
      ruralAlternativeAvailable: stationCandidates.some((candidate) =>
        candidate.validForward && !candidate.urbanEntry
      )
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
      // A bounded cross-region window is a next-anchor query. Graph
      // reachability selects a connected pump; the client then proves the
      // requested profile to that pump and starts a fresh window there. Full
      // profile-routing every candidate here duplicates the client's work and
      // lets one slow candidate starve all of the other reachable stations.
      graphOnlyFeeler: allowPartialWindow || fuelOptions.forwardFeeler === true
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
    const regionalPrefixMeters = graphMeters.slice();
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
    stationCandidates.push(...(planned.stationCandidates || []).map((candidate) => ({
      ...candidate,
      // The candidate's own `meters` value belongs to this regional segment.
      // Carry the preceding seam minima with every alternative so the client
      // can prove it immediately without applying the selected pump's regional
      // budget to a different location.
      regionalGraphMeters: regionalPrefixMeters.concat([Number(candidate.meters)])
    })));
    totalStates += Number(planned.diagnostics && planned.diagnostics.states) || 0;
    totalPops += Number(planned.diagnostics && planned.diagnostics.dijkstraPops) || 0;
    matchedFuel += Number(planned.diagnostics && planned.diagnostics.matchedFuel) || 0;
    maxHopMs = Math.max(maxHopMs, Number(planned.diagnostics && planned.diagnostics.maxHopMs) || 0);
    if (
      allowPartialWindow &&
      (planned.windowComplete === false || allStops.length >= windowMaxStops)
    ) {
      const selectedStationId = allStops.length ? String(allStops[0].id) : null;
      const selectedCandidate = selectedStationId == null ? null : stationCandidates.find((candidate) =>
        String(candidate.id) === selectedStationId
      );
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
          selectionPolicy: FUEL_SELECTION_POLICY,
          graphOnlySelection: true,
          stationAlternativesLimit: MAX_STATION_ALTERNATIVES,
          stationAlternativesReturned: stationCandidates.length,
          states: totalStates,
          dijkstraPops: totalPops,
          matchedFuel,
          elapsedMs: Date.now() - started,
          maxHopMs,
          partialReason: planned.diagnostics && planned.diagnostics.partialReason || null,
          selectedReason: planned.diagnostics && planned.diagnostics.selectedReason ||
            "regional_window_progress",
          selectedUrbanEntry: !!(selectedCandidate && selectedCandidate.urbanEntry),
          ruralAlternativeAvailable: stationCandidates.some((candidate) =>
            candidate.validForward && !candidate.urbanEntry
          )
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
  const selectedStationId = allStops.length ? String(allStops[0].id) : null;
  const selectedCandidate = selectedStationId == null ? null : stationCandidates.find((candidate) =>
    String(candidate.id) === selectedStationId
  );

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
      selectionPolicy: FUEL_SELECTION_POLICY,
      graphOnlySelection: allowPartialWindow || fuelOptions.forwardFeeler === true,
      stationAlternativesLimit: MAX_STATION_ALTERNATIVES,
      stationAlternativesReturned: stationCandidates.length,
      states: totalStates,
      dijkstraPops: totalPops,
      matchedFuel,
      elapsedMs: Date.now() - started,
      maxHopMs,
      selectedUrbanEntry: !!(selectedCandidate && selectedCandidate.urbanEntry),
      ruralAlternativeAvailable: stationCandidates.some((candidate) =>
        candidate.validForward && !candidate.urbanEntry
      )
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
  const endpointStarted = Date.now();
  const endpointResolution = await resolveLocationsByEligibleEdge(body, {
    probeRegion: dependencies.probeRegion,
    regionOwner: dependencies.regionOwner
  });
  const endpointResolutionDiagnostics = {
    endpointResolutionMs: Date.now() - endpointStarted,
    endpointProbeCount: endpointResolution.resolutions.reduce(
      (sum, row) => sum + (Array.isArray(row.probes) ? row.probes.length : 0),
      0
    ),
    endpointResolutionSources: endpointResolution.resolutions
      .map((row) => row.source || "unknown")
      .join(",")
  };
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
    ? Math.min(MAX_FUEL_PLANNING_BUDGET_MS, Number(rawFuelOptions.windowTimeBudgetMs))
    : null;
  const windowDeadlineAtMs = windowBudgetMs == null
    ? Infinity
    : requestStarted + windowBudgetMs;
  // Reserve part of every fuel window for pump matching and chain proof. A
  // profile refinement may use most of the window, but it may not consume the
  // entire request before fuel planning even begins.
  const routeFirstBudgetMs = routeFirstBudgetForWindow(windowBudgetMs);
  let routeFirstDeadlineAtMs = routeFirstBudgetMs == null
    ? Infinity
    : Math.min(windowDeadlineAtMs, requestStarted + routeFirstBudgetMs);
  const abortSignal = body.options && body.options.abortSignal;
  const windowBudgetOverrunMs = () => windowBudgetMs == null
    ? 0
    : Math.max(0, Date.now() - requestStarted - windowBudgetMs);
  const forwardFeeler = rawFuelOptions.forwardFeeler === true;
  const routeFirstPlan = rawFuelOptions.routeFirstPlan === true && !forwardFeeler &&
    selection.mode !== "canada-chain";
  let fuelOptions = windowBudgetMs == null
    ? rawFuelOptions
    : { ...rawFuelOptions, windowTimeBudgetMs: windowBudgetMs };
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
      rawFuelOptions: fuelOptions,
      dependencies
    });
  }

  let profileMeters = fuelOptions.profileMeters == null
    ? NaN : Number(fuelOptions.profileMeters);
  let foundationRoute = null;
  let fuel = null;
  let runtime = null;
  let routeFirstMs = 0;
  let routeFirstSharedRuntime = false;
  let routeFirstAttempted = false;
  let routeFirstSkippedReason = null;
  let planningDataLoadMs = 0;
  let routeFirstBuildMs = null;
  let routeFirstSearchMs = null;
  let routeFirstSnapMs = null;
  let routeFirstPostprocessMs = null;
  let routeFirstPops = null;
  let routeFirstSearchOutcome = null;
  let routeFirstFallbacks = [];
  let routeFirstDeadlineRemainingAfterLoadMs = null;
  let routeFirstWindowRemainingAfterLoadMs = null;
  let routeFirstSearchBudgetGrantedMs = null;
  let routeFirstLoadBudgetReliefMs = null;
  const routeFirstPhaseDiagnostics = () => ({
    routeFirstBuildMs,
    routeFirstSearchMs,
    routeFirstSnapMs,
    routeFirstPostprocessMs,
    routeFirstPops,
    routeFirstSearchOutcome,
    routeFirstFallbacks,
    routeFirstDeadlineRemainingAfterLoadMs,
    routeFirstWindowRemainingAfterLoadMs,
    routeFirstSearchBudgetGrantedMs,
    routeFirstLoadBudgetReliefMs,
    routeFirstBudgetStartsAfterRuntimeLoad: routeFirstAttempted ? true : null
  });
  const directLowerBoundMeters = haversineMeters(
    locationCoordinate(locations[0]),
    locationCoordinate(locations[locations.length - 1])
  );
  // A cross-region request is already divided at topology-authored seams and
  // every regional hop is subsequently proved with the active profile under
  // the real tank cap. Measuring the entire multi-province Dirt/Balanced/Clean
  // ride first is therefore redundant, and on a long ride it can consume the
  // fuel window before the first pump is considered. The endpoint chord is a
  // conservative minimum-stop hint only; regional route proofs still add every
  // additional pump the actual profile geometry requires.
  if (selection.mode === "canada-chain" && !(profileMeters >= 0)) {
    profileMeters = directLowerBoundMeters;
    routeFirstSkippedReason = "cross_region_incremental_lower_bound";
  }
  // A routed ride can never be shorter than the geographic distance between
  // its endpoints. If that lower bound already exceeds the fuel remaining in
  // the tank, a full active-profile route cannot prove a zero-stop journey.
  // Do not spend most of a bounded fuel window proving the impossible; load
  // the shared data once and give the complete window to the forward pump
  // search. The exact active-profile legs are still proved before selection.
  const directImpossibleOnRemainingFuel = routeFirstPlan &&
    directLowerBoundMeters > firstLegMaxMeters + 1;
  if (directImpossibleOnRemainingFuel) {
    routeFirstSkippedReason = "destination_beyond_remaining_fuel_lower_bound";
    profileMeters = directLowerBoundMeters;
    const loadStarted = Date.now();
    try {
      [runtime, fuel] = await Promise.all([
        loadRuntime(selection, {
          locations,
          profile: body.profile
        }),
        loadFuel(locations)
      ]);
      const loadedAtMs = Date.now();
      planningDataLoadMs = loadedAtMs - loadStarted;
      routeFirstWindowRemainingAfterLoadMs = Number.isFinite(windowDeadlineAtMs)
        ? windowDeadlineAtMs - loadedAtMs
        : null;
      routeFirstDeadlineRemainingAfterLoadMs = Number.isFinite(routeFirstDeadlineAtMs)
        ? routeFirstDeadlineAtMs - loadedAtMs
        : null;
    } catch (error) {
      const message = error && error.message ? error.message : String(error);
      const corridorClip = /corridor clip/i.test(message);
      return {
        status: "failed",
        error: corridorClip ? "corridor_clip" : "graph_load_failed",
        message,
        routes: [],
        diagnostics: {
          totalElapsedMs: Date.now() - requestStarted,
          windowBudgetMs,
          windowBudgetOverrunMs: windowBudgetOverrunMs(),
          routeFirstMs: 0,
          routeFirstBudgetMs,
          routeFirstSharedRuntime: false,
          routeFirstAttempted,
          routeFirstSkippedReason,
          directLowerBoundMeters: Math.round(directLowerBoundMeters),
          firstLegMaxMeters: Math.round(firstLegMaxMeters),
          planningDataLoadMs: Date.now() - loadStarted,
          ...endpointResolutionDiagnostics,
          failureReason: corridorClip ? "corridor_clip" : "graph_load_failed",
          deadlinePhase: "planning_runtime_load"
        }
      };
    }
  }
  if (routeFirstPlan && !directImpossibleOnRemainingFuel) {
    routeFirstAttempted = true;
    const routeBody = {
      ...body,
      options: {
        ...(body.options || {}),
        deadlineAtMs: Number.isFinite(routeFirstDeadlineAtMs)
          ? routeFirstDeadlineAtMs
          : undefined,
        abortSignal
      }
    };
    delete routeBody.options.maxPathMeters;
    delete routeBody.options.internalFuelProbe;
    const routeStarted = Date.now();
    const loadStarted = Date.now();
    // The same immutable runtime drives both the foundational ride and fuel
    // selection. Vercel deliberately disables cross-operation graph retention
    // for province-scale memory safety; calling routeRequest here therefore
    // inflated Ontario once for the route and again below for fuel. Load once
    // inside this request, route directly on it, and carry it forward.
    try {
      [runtime, fuel] = await Promise.all([
        loadRuntime(selection, {
          locations,
          profile: body.profile
        }),
        loadFuel(locations)
      ]);
      const loadedAtMs = Date.now();
      planningDataLoadMs = loadedAtMs - loadStarted;
      const deadlineBeforeLoadRelief = routeFirstDeadlineAtMs;
      // Runtime inflation is prerequisite I/O, not active-profile search.
      // Counting a cold Ontario load against the ten-second route allowance
      // made an identical request fail cold and pass warm. Start that bounded
      // search allowance only once the immutable graph and fuel data exist,
      // while the outer fuel-window deadline remains an absolute hard cap.
      routeFirstDeadlineAtMs = routeFirstDeadlineAfterLoad(
        windowDeadlineAtMs,
        routeFirstBudgetMs,
        loadedAtMs
      );
      routeFirstWindowRemainingAfterLoadMs = Number.isFinite(windowDeadlineAtMs)
        ? windowDeadlineAtMs - loadedAtMs
        : null;
      routeFirstDeadlineRemainingAfterLoadMs = Number.isFinite(routeFirstDeadlineAtMs)
        ? routeFirstDeadlineAtMs - loadedAtMs
        : null;
      routeFirstSearchBudgetGrantedMs = routeFirstDeadlineRemainingAfterLoadMs;
      routeFirstLoadBudgetReliefMs = Number.isFinite(deadlineBeforeLoadRelief) &&
        Number.isFinite(routeFirstDeadlineAtMs)
        ? Math.max(0, routeFirstDeadlineAtMs - deadlineBeforeLoadRelief)
        : null;
    } catch (error) {
      const message = error && error.message ? error.message : String(error);
      const corridorClip = /corridor clip/i.test(message);
      return {
        status: "failed",
        error: corridorClip ? "corridor_clip" : "graph_load_failed",
        message,
        routes: [],
        diagnostics: {
          totalElapsedMs: Date.now() - requestStarted,
          windowBudgetMs,
          windowBudgetOverrunMs: windowBudgetOverrunMs(),
          routeFirstMs: Date.now() - routeStarted,
          routeFirstBudgetMs,
          routeFirstSharedRuntime: false,
          routeFirstAttempted,
          routeFirstSkippedReason,
          directLowerBoundMeters: Math.round(directLowerBoundMeters),
          firstLegMaxMeters: Math.round(firstLegMaxMeters),
          planningDataLoadMs: Date.now() - loadStarted,
          ...endpointResolutionDiagnostics,
          failureReason: corridorClip ? "corridor_clip" : "graph_load_failed",
          deadlinePhase: "route_first_runtime_load"
        }
      };
    }
    routeBody.options.deadlineAtMs = Number.isFinite(routeFirstDeadlineAtMs)
      ? routeFirstDeadlineAtMs
      : undefined;
    const routeProfile = dependencies.routeRequest;
    const routeOnLoadedRuntime = dependencies.routeOnRuntime || routeOnRuntime;
    foundationRoute = routeProfile
      ? await routeProfile(routeBody)
      : echoLegId(await routeOnLoadedRuntime(routeBody, selection, runtime), routeBody.legId);
    routeFirstSharedRuntime = !routeProfile;
    routeFirstMs = Date.now() - routeStarted;
    const foundationDiagnostics = foundationRoute && foundationRoute.debug &&
      foundationRoute.debug.diagnostics;
    routeFirstBuildMs = finiteDiagnosticNumber(foundationDiagnostics && foundationDiagnostics.buildMs);
    routeFirstSearchMs = finiteDiagnosticNumber(
      foundationDiagnostics && foundationDiagnostics.searchMs != null
        ? foundationDiagnostics.searchMs
        : foundationRoute && foundationRoute.debug && foundationRoute.debug.searchMs
    );
    routeFirstSnapMs = finiteDiagnosticNumber(foundationDiagnostics && foundationDiagnostics.snapMs);
    routeFirstPostprocessMs = finiteDiagnosticNumber(
      foundationDiagnostics && foundationDiagnostics.postprocessMs
    );
    routeFirstPops = finiteDiagnosticNumber(
      foundationDiagnostics && foundationDiagnostics.pops != null
        ? foundationDiagnostics.pops
        : foundationRoute && foundationRoute.debug && foundationRoute.debug.pops
    );
    routeFirstSearchOutcome = foundationDiagnostics && foundationDiagnostics.searchOutcome ||
      foundationRoute && foundationRoute.debug && foundationRoute.debug.searchOutcome || null;
    routeFirstFallbacks = foundationDiagnostics &&
      Array.isArray(foundationDiagnostics.profileFallbacks)
      ? foundationDiagnostics.profileFallbacks
      : [];
    profileMeters = Number(foundationRoute && foundationRoute.distanceMeters);
    if (!foundationRoute || foundationRoute.status !== "complete" || !(profileMeters >= 0)) {
      const routeDiagnostics = foundationRoute && foundationRoute.debug &&
        foundationRoute.debug.diagnostics;
      const routeSearchOutcome =
        foundationRoute && foundationRoute.debug && foundationRoute.debug.searchOutcome ||
        routeDiagnostics && routeDiagnostics.searchOutcome || null;
      const deadlineExceeded =
        (abortSignal && abortSignal.aborted) ||
        (Number.isFinite(routeFirstDeadlineAtMs) && Date.now() >= routeFirstDeadlineAtMs) ||
        routeSearchOutcome === "timeCap" ||
        routeSearchOutcome === "cancelled";
      return {
        // A planning deadline is not evidence of a fuel gap or a disconnected
        // road graph. Keep it explicitly failed/unknown so the UI never tells
        // the rider that a timed-out proof is an unsafe route conclusion.
        status: "failed",
        error: deadlineExceeded ? "window_time_budget" : "profile_ride_unavailable",
        message: deadlineExceeded
          ? "The selected ride did not finish inside this planning window."
          : (foundationRoute && (foundationRoute.message || foundationRoute.error) ||
            "The selected ride could not be built before fuel planning."),
        routes: foundationRoute ? [foundationRoute] : [],
        diagnostics: {
          totalElapsedMs: Date.now() - requestStarted,
          windowBudgetMs,
          windowBudgetOverrunMs: windowBudgetOverrunMs(),
          timeBudgetExceeded: deadlineExceeded,
          routeFirstMs,
          routeFirstBudgetMs,
          routeFirstSharedRuntime,
          routeFirstAttempted,
          routeFirstSkippedReason,
          directLowerBoundMeters: Math.round(directLowerBoundMeters),
          firstLegMaxMeters: Math.round(firstLegMaxMeters),
          planningDataLoadMs,
          ...routeFirstPhaseDiagnostics(),
          ...endpointResolutionDiagnostics,
          profileRouteFailureReason:
            routeDiagnostics && routeDiagnostics.failureReason ||
            foundationRoute && foundationRoute.debug && foundationRoute.debug.failureReason || null,
          profileRouteSearchOutcome:
            routeSearchOutcome,
          profileRouteSearchMs:
            routeDiagnostics && routeDiagnostics.searchMs ||
            foundationRoute && foundationRoute.debug && foundationRoute.debug.searchMs || null,
          profileRoutePops:
            routeDiagnostics && routeDiagnostics.pops ||
            foundationRoute && foundationRoute.debug && foundationRoute.debug.pops || null
        }
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
    const options = {
      ...(body.options || {}),
      deadlineAtMs: Number.isFinite(routeFirstDeadlineAtMs)
        ? routeFirstDeadlineAtMs
        : undefined,
      abortSignal
    };
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
    ...fuelOptions,
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

  if (!runtime) {
    runtime = await loadRuntime(selection, {
      locations,
      profile: body.profile
    });
  }
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
        avoidEdgeIds: options.avoidEdgeIds || [],
        deadlineAtMs: windowDeadlineAtMs,
        abortSignal
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
      const foundationDiagnostics = foundationRoute && foundationRoute.debug &&
        foundationRoute.debug.diagnostics || {};
      const requestPolicy = normalizePolicy(body.accessPolicy, body.profile);
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
          routeFirstBudgetMs,
          routeFirstSharedRuntime,
          routeFirstAttempted,
          routeFirstSkippedReason,
          directLowerBoundMeters: Math.round(directLowerBoundMeters),
          firstLegMaxMeters: Math.round(firstLegMaxMeters),
          planningDataLoadMs,
          ...routeFirstPhaseDiagnostics(),
          ...endpointResolutionDiagnostics,
          graphFetchMs: runtime.loadDiagnostics && runtime.loadDiagnostics.fetchMs,
          graphDecodeMs: runtime.loadDiagnostics && runtime.loadDiagnostics.decodeMs,
          graphGridMs: runtime.loadDiagnostics && runtime.loadDiagnostics.gridMs,
          fuelFetchMs: fuel.loadDiagnostics && fuel.loadDiagnostics.fetchMs,
          fuelCacheHit: fuel.loadDiagnostics && fuel.loadDiagnostics.cacheHit,
          destinationEscapeSearchMs: destinationEscapeDiagnostics && destinationEscapeDiagnostics.elapsedMs,
          destinationEscapePops: destinationEscapeDiagnostics && destinationEscapeDiagnostics.pops,
          allowUnknown: !!requestPolicy.motorizedUnknown,
          tapRadiusMeters: foundationDiagnostics.tapRadiusMeters,
          mapZoom: Number.isFinite(Number(options.mapZoom))
            ? Number(options.mapZoom)
            : foundationDiagnostics.mapZoom,
          snap: foundationDiagnostics.snap
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
    foundationRoute,
    graphResolution: selection,
    deadlineAtMs: windowDeadlineAtMs,
    abortSignal,
    mapZoom: options.mapZoom,
    matchLimitMeters: options.matchLimitMeters
  });

  // Do not offer auxiliary fuel for an incomplete computation. A timeout is a
  // retryable planning failure; only an exhausted graph search proves a gap.
  const plannedStatus = fuelPlanStatus(planned);
  return {
    status: plannedStatus,
    error: planned.error || null,
    message: planned.message || null,
    serviceVersion: FUEL_CHAIN_SERVICE_VERSION,
    regionIds: fuel.regionIds,
    packIdentity: mergePackIdentities(runtime.packIdentity || [], fuel.packIdentity || []),
    stops: planned.stops || [],
    graphMeters: planned.graphMeters || [],
    routes: planned.routes || [],
    // If fuel proof fails, give the client the exact already-built rider line
    // for advisory display. This prevents a second identical 20-second Dirt
    // search merely to repaint the route after an honest fuel failure.
    foundationRoute: plannedStatus === "complete" ? undefined : foundationRoute || undefined,
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
      routeFirstBudgetMs,
      routeFirstSharedRuntime,
      routeFirstAttempted,
      routeFirstSkippedReason,
      directLowerBoundMeters: Math.round(directLowerBoundMeters),
      firstLegMaxMeters: Math.round(firstLegMaxMeters),
      planningDataLoadMs,
      ...routeFirstPhaseDiagnostics(),
      ...endpointResolutionDiagnostics,
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
  fuelUrbanBoxesForRuntime,
  fuelStopRequiresUrbanEntry,
  stationEligibility,
  fuelNeedForProfileRide,
  routeFirstBudgetForWindow,
  routeFirstDeadlineAfterLoad,
  comfortCapMeters,
  compareChainPlans,
  fuelPlanStatus,
  planFuelChainOnRuntime,
  planCrossRegionFuelChain,
  planItineraryFuelChain,
  deriveWaypointFuelStation,
  deriveWaypointRefuels,
  WAYPOINT_FUEL_SNAP_METERS,
  fuelChainRequest,
  foundationPlacement,
  foundationRouteLayout,
  prepareFoundationTopology,
  forecourtFoundationPlacement,
  selectSafeTimeoutPartial,
  completedContinuationWithinWindow
};
