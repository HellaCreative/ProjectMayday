const { allows: v4DirectionAllowed } = require("./v4-access-policy");
"use strict";

/**
 * Minimal Stage 2 CSR search for graph.v2.
 * Inlined relax loop: no neighbor object, no geometry during search.
 */

const {
  unpackSurface,
  unpackAccess,
  unpackStructure,
  unpackConfidence,
  unpackSeasonal,
  unpackRoadClass,
  ROAD_CLASS_NAME
} = require("./pack-v2");
const {
  compileRestrictionIndex,
  indexedTurnAllowed
} = require("./legal-topology/restrictions");
const {
  surfaceMultiplier,
  classSpeedKmh,
  costPerKmView,
  approachAwayExtraCost,
  roadClassMultiplier,
  cleanCityStreetMult,
  isMajorHighwayClass,
  pinMatchesMajorHighway,
  majorHighwayAvoidMult,
  corridorCrossTrackExtra,
  resolveProfile
} = require("./profile-costs");
const { pruneGeographicLoops } = require("./path-pruning");
const {
  considerRelax,
  applyRelax,
  shouldPush,
  createsCycle,
  isDirtSurface,
  isBlockedForCleanPavement,
  dirtRideCostPerKm,
  DIRT_RIDE_PAVED_PER_KM,
  DIRT_RIDE_GRAVEL_PER_KM,
  DIRT_RIDE_RESOURCE_PER_KM,
  DIRT_RIDE_UNKNOWN_TRACK_PER_KM,
  DIRT_RIDE_XT_SCALE,
  DIRT_RIDE_AWAY_SCALE,
  hopBlocked,
  urbanCoreFallbackMultiplier,
  resolveMetroFallbackPenalty,
  resolveSettlementFallbackPenalty,
  settlementBlocks,
  settlementFallbackMultiplier,
  metroEdgeBlocks,
  outsideCorridor,
  projectedProgressMeters,
  maxProgressRegressionMeters,
  progressRegressionForAttempt,
  coincidentSiblingLists,
  annotateCorridorMeta,
  corridorMetersForProfile,
  VARIETY_SLOTS,
  BALANCED_BUCKETS,
  dirtBucket,
  PASS2_TIME_MS,
  PASS2_POP_CAP,
  METRO_CORE_WALL
} = require("./hop-search");

// Regional graph runtimes reuse the same coordinate array for the lifetime of
// a warm planning operation. Building the duplicate-node topology once avoids
// rescanning a province-sized graph for each profile/corridor attempt.
const coincidentSiblingCache = new WeakMap();

function urbanBoxesForPack(pack) {
  const embedded = pack && pack.meta && Array.isArray(pack.meta.urbanCores)
    ? pack.meta.urbanCores
    : [];
  const rows = METRO_CORE_WALL.concat(embedded);
  const seen = new Set();
  return rows.filter((box) => {
    const key = [box.minLat, box.maxLat, box.minLon, box.maxLon].join(":");
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function cachedCoincidentSiblingLists(nodeCoords, n) {
  if (!nodeCoords || typeof nodeCoords !== "object") {
    return coincidentSiblingLists(nodeCoords, n);
  }
  const cached = coincidentSiblingCache.get(nodeCoords);
  if (cached && cached.n === n) return cached.lists;
  const lists = coincidentSiblingLists(nodeCoords, n);
  coincidentSiblingCache.set(nodeCoords, { n, lists });
  return lists;
}
const { settlementBoxesForPack } = require("./urban-settlements");
const { applyHonestSurfaceStats } = require("./surface-family");
const { summarizeRouteQuality } = require("./route-quality");
const {
  isFerryStructureCode,
  ferryRelaxStepCost,
  ferryCrossingSeconds
} = require("./ferry");
const { segmentStructureFields } = require("./structure");
const { packHasDirectedArc } = require("./travel-direction");

function v4AccessCode(pack, ei, fromNode, toNode) {
  if (!pack.edgeAccess || ei == null || ei < 0) return 0;
  const forward = pack.edgeFrom[ei] === fromNode && pack.edgeTo[ei] === toNode;
  return pack.edgeAccess[ei * 2 + (forward ? 0 : 1)];
}

function v4HopIllegal(pack, ei, fromNode, toNode, startEi, endEi, incomingEi) {
  if (!pack || pack.graphBinaryVersion < 4) return false;
  const code = v4AccessCode(pack, ei, fromNode, toNode);
  if (code === 2 || code === 5) return true;
  if ((code === 3 || code === 4) && ei !== startEi && ei !== endEi) return true;
  if (incomingEi == null || incomingEi < 0 || !pack.restrictions || !pack.restrictions.length) {
    return false;
  }
  return !indexedTurnAllowed(
    compileRestrictionIndex(pack.restrictions),
    incomingEi,
    ei,
    fromNode
  );
}

function incomingUndirected(prevKind, prevData, virt, node) {
  if (prevKind[node] === 0) return prevData[node];
  if (prevKind[node] === 1) {
    const v = virt[prevData[node]];
    return v && Number.isInteger(v.ei) ? v.ei : -1;
  }
  return -1;
}

function buildTurnAwareState(pack, n, startNode, endNode) {
  const identity = {
    stateCount: n + 2,
    graphNodeOf: (state) => state,
    stateForArrival: (node) => node
  };
  if (!pack || pack.graphBinaryVersion < 4 || !pack.restrictions || !pack.restrictions.length) {
    return identity;
  }
  const restrictionIndex = compileRestrictionIndex(pack.restrictions);
  const statefulEdges = restrictionIndex.statefulIncomingEdges;
  if (!statefulEdges || !statefulEdges.size) return identity;

  const stateByArrival = new Map();
  const nodeByExtraState = [];
  for (let source = 0; source < n; source += 1) {
    for (let arc = pack.nodeOffsets[source]; arc < pack.nodeOffsets[source + 1]; arc += 1) {
      const incomingEdge = Number(pack.edgeUndirectedIndex[arc]);
      if (!statefulEdges.has(incomingEdge)) continue;
      const target = Number(pack.edgeTargets[arc]);
      const key = `${target}:${incomingEdge}`;
      if (stateByArrival.has(key)) continue;
      stateByArrival.set(key, n + 2 + nodeByExtraState.length);
      nodeByExtraState.push(target);
    }
  }
  const graphNodeOf = (state) => {
    if (state === startNode || state === endNode || state < n) return state;
    return nodeByExtraState[state - (n + 2)];
  };
  const stateForArrival = (node, incomingEdge) =>
    stateByArrival.get(`${node}:${Number(incomingEdge)}`) ?? node;
  return {
    stateCount: n + 2 + nodeByExtraState.length,
    graphNodeOf,
    stateForArrival
  };
}

const MINIMUM_EARNED_DIRT_EXCURSION_METERS = 1_000;
const MAX_SHORT_DIRT_REPAIR_PASSES = 3;
const DIRT_BASE_SEARCH_BUDGET_MS = 3_500;
const DIRT_MAX_SEARCH_BUDGET_MS = 18_000;
const BALANCED_BASE_SEARCH_BUDGET_MS = 8_000;
const BALANCED_MAX_SEARCH_BUDGET_MS = 45_000;
const LARGE_GRAPH_BASE_SEARCH_BUDGET_MS = 12_000;
const CLEAN_BASE_SEARCH_BUDGET_MS = 12_000;
const CLEAN_MAX_SEARCH_BUDGET_MS = 18_000;
const BALANCED_LONG_ROUTE_METERS = 500_000;
const BALANCED_LARGE_GRAPH_NODES = 500_000;
const PROVINCE_SCALE_GRAPH_NODES = 1_500_000;
// Low-DIRT recovery may widen laterally, but it may not turn a proven ride
// into an open-ended mileage search. Forty kilometres preserves the fixed
// Halifax recovery; the proportional allowance scales the same rule to long
// rides. A real fuel/tank cap always remains the harder ceiling.
const DIRT_RECOVERY_EXTRA_METERS = 40_000;
const DIRT_RECOVERY_DISTANCE_RATIO = 1.5;

function largeGraphPressure(nodeCount) {
  const nodes = Math.max(0, Number(nodeCount) || 0);
  if (nodes <= BALANCED_LARGE_GRAPH_NODES) return 0;
  return Math.min(
    1,
    (nodes - BALANCED_LARGE_GRAPH_NODES) /
      (PROVINCE_SCALE_GRAPH_NODES - BALANCED_LARGE_GRAPH_NODES)
  );
}

/**
 * Balanced's old 2.2-second wall-clock ceiling was calibrated on small packs.
 * A ride on a province-sized graph needs enough time to finish the same
 * bounded A* work on slower serverless CPU. Large graphs receive a modest
 * floor even for short rides; long rides continue to scale to the established
 * 45-second ceiling. Small regional graphs remain byte-for-byte unchanged.
 */
function balancedSearchBudgetMs(straightLineMeters, nodeCount) {
  const routeMeters = Math.max(0, Number(straightLineMeters) || 0);
  const graphPressure = largeGraphPressure(nodeCount);
  if (graphPressure === 0) return BALANCED_BASE_SEARCH_BUDGET_MS;
  const graphFloor =
    BALANCED_BASE_SEARCH_BUDGET_MS +
    (LARGE_GRAPH_BASE_SEARCH_BUDGET_MS - BALANCED_BASE_SEARCH_BUDGET_MS) *
      graphPressure;
  if (routeMeters <= BALANCED_LONG_ROUTE_METERS) return Math.round(graphFloor);
  const routePressure = Math.min(
    1,
    (routeMeters - BALANCED_LONG_ROUTE_METERS) / 500_000
  );
  const pressure = Math.min(routePressure, graphPressure);
  const longRouteBudget =
    BALANCED_BASE_SEARCH_BUDGET_MS +
    (BALANCED_MAX_SEARCH_BUDGET_MS - BALANCED_BASE_SEARCH_BUDGET_MS) * pressure;
  return Math.round(Math.max(graphFloor, longRouteBudget));
}

function profileSearchBudgetMs(profile, straightLineMeters, nodeCount) {
  if (profile === "balanced") {
    return balancedSearchBudgetMs(straightLineMeters, nodeCount);
  }
  const graphPressure = largeGraphPressure(nodeCount);
  if (profile === "cleanest") {
    return Math.round(
      CLEAN_BASE_SEARCH_BUDGET_MS +
        (CLEAN_MAX_SEARCH_BUDGET_MS - CLEAN_BASE_SEARCH_BUDGET_MS) * graphPressure
    );
  }
  return Math.round(
    DIRT_BASE_SEARCH_BUDGET_MS +
      (DIRT_MAX_SEARCH_BUDGET_MS - DIRT_BASE_SEARCH_BUDGET_MS) * graphPressure
  );
}

function profileSearchPopCap(profile, nodeCount, dirtComparison = false) {
  const base = profile === "balanced"
    ? PASS2_POP_CAP * 4
    : profile === "dirt" && dirtComparison
      ? Math.ceil(PASS2_POP_CAP / 2)
      : PASS2_POP_CAP;
  return Math.ceil(base * (1 + largeGraphPressure(nodeCount)));
}

function dirtRecoveryPathCap(primaryRideMeters, activePathCap = Infinity) {
  const primary = Number(primaryRideMeters);
  const hardCap = Number(activePathCap);
  if (!(primary > 0)) return Number.isFinite(hardCap) ? hardCap : Infinity;
  const coherentCap = Math.max(
    primary + DIRT_RECOVERY_EXTRA_METERS,
    primary * DIRT_RECOVERY_DISTANCE_RATIO
  );
  return Number.isFinite(hardCap) ? Math.min(hardCap, coherentCap) : coherentCap;
}

/** Skip the provably undersized 40 km tier for long Balanced rides. */
function balancedCorridorMultipliers(straightLineMeters) {
  return Number(straightLineMeters) > BALANCED_LONG_ROUTE_METERS
    ? [2, 3, 4, 6, 8]
    : [1, 2, 3, 4, 6, 8];
}

function isKnownUnpavedSurface(surfaceName) {
  return (
    surfaceName === "gravel" ||
    surfaceName === "access" ||
    surfaceName === "resource" ||
    surfaceName === "track" ||
    surfaceName === "double_track" ||
    surfaceName === "single" ||
    surfaceName === "unpaved" ||
    surfaceName === "dirt"
  );
}

/**
 * Find optional paved-to-paved excursions that have not earned one continuous
 * kilometre of known unpaved riding. Unknown surface can connect known dirt,
 * but contributes zero metres to the threshold. Route-start/end approaches
 * are deliberately excluded; necessary connectors remain eligible because the
 * returned edges are re-priced, never blocked.
 */
function shortDirtExcursionEdgeIds(
  segments,
  minimumMeters = MINIMUM_EARNED_DIRT_EXCURSION_METERS
) {
  const result = new Set();
  if (!Array.isArray(segments) || segments.length < 3) return result;
  const isPavedBoundary = (segment) =>
    segment && segment.structureType !== "ferry" && segment.surfaceClass === "paved";
  let index = 0;
  while (index < segments.length) {
    if (isPavedBoundary(segments[index]) || segments[index].structureType === "ferry") {
      index += 1;
      continue;
    }
    const start = index;
    let knownUnpavedMeters = 0;
    const edgeIds = [];
    while (
      index < segments.length &&
      !isPavedBoundary(segments[index]) &&
      segments[index].structureType !== "ferry"
    ) {
      const segment = segments[index];
      if (isKnownUnpavedSurface(segment.surfaceClass)) {
        knownUnpavedMeters += Math.max(0, Number(segment.distanceMeters) || 0);
      }
      const edgeId = String(segment.edgeId || "");
      if (
        edgeId &&
        !edgeId.startsWith("soft-stitch-") &&
        !edgeId.startsWith("perm-stitch-")
      ) {
        edgeIds.push(edgeId);
      }
      index += 1;
    }
    const boundedByPavement =
      start > 0 &&
      index < segments.length &&
      isPavedBoundary(segments[start - 1]) &&
      isPavedBoundary(segments[index]);
    if (boundedByPavement && knownUnpavedMeters < minimumMeters) {
      for (const edgeId of edgeIds) result.add(edgeId);
    }
  }
  return result;
}

function repairShortDirtExcursions(
  ride,
  runtime,
  startMatch,
  endMatch,
  profile,
  policy,
  avoidEdgeIds,
  pavedBias,
  rideOpts
) {
  if (!ride || profile !== "dirt" || rideOpts.skipShortDirtRepair === true) return ride;
  let repaired = ride;
  const penaltyEdgeIds = new Set(rideOpts.shortDirtPenaltyEdgeIds || []);
  let passes = 0;
  for (let pass = 0; pass < MAX_SHORT_DIRT_REPAIR_PASSES; pass += 1) {
    const found = shortDirtExcursionEdgeIds(repaired.segments);
    const additions = [...found].filter((edgeId) => !penaltyEdgeIds.has(edgeId));
    if (!additions.length) break;
    for (const edgeId of additions) penaltyEdgeIds.add(edgeId);
    const next = findPathV2(
      runtime,
      startMatch,
      endMatch,
      profile,
      policy,
      avoidEdgeIds,
      pavedBias,
      { ...rideOpts, shortDirtPenaltyEdgeIds: penaltyEdgeIds }
    );
    if (!next) break;
    repaired = next;
    passes += 1;
  }
  repaired.searchMeta = repaired.searchMeta || {};
  repaired.searchMeta.minimumEarnedDirtExcursionMeters =
    MINIMUM_EARNED_DIRT_EXCURSION_METERS;
  repaired.searchMeta.shortDirtRepairPasses = passes;
  repaired.searchMeta.shortDirtPenaltyEdgeCount = penaltyEdgeIds.size;
  return repaired;
}

function ferrySecondsForPackEdge(pack, ei, meters) {
  if (pack.crossingSeconds) {
    const xs = pack.crossingSeconds(ei);
    if (xs > 0) return xs;
  }
  return ferryCrossingSeconds(meters, null);
}

function ferryStepForPackEdge(pack, ei, meters) {
  return ferryRelaxStepCost(ferrySecondsForPackEdge(pack, ei, meters));
}
const {
  roadTierOf,
  isBlockedForCleanLeaf,
  cleanLeafCostMult,
  e4LeafCostMult,
  e4MajorHighwayEntryCost,
  e4FlagsForProfile,
  ROAD_TIER
} = require("./road-tier");
const { surfaceFamilyOf } = require("./surface-family");

/** Attach surfaceLeaf / structureLeaf / layer for post-selection stats and labels. */
function withSurfaceLeaf(edge, pack, ei) {
  if (!pack || !pack.hasLeaves || typeof pack.edgeLeaves !== "function") {
    return edge;
  }
  const leaves = pack.edgeLeaves(ei);
  return Object.assign({}, edge, {
    undirectedEdgeIndex: ei,
    surfaceLeaf: leaves && leaves.surfaceLeaf != null ? leaves.surfaceLeaf : null,
    structureLeaf: leaves && leaves.structureLeaf != null ? leaves.structureLeaf : null,
    layer: leaves && leaves.layer != null ? leaves.layer : 0
  });
}

/** Phase E2 Clean leaf gate. Returns null → use coarse isBlockedForCleanPavement. */
function cleanLeafBlocked(pack, ei, pavedOnly, startEi, endEi) {
  if (!pack || !pack.hasLeaves) return null;
  if (ei === startEi || ei === endEi) return false;
  const leaves = pack.edgeLeaves(ei);
  const family = surfaceFamilyOf(leaves.surfaceLeaf, pack.surfaceFamilyMap);
  const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
  return isBlockedForCleanLeaf({
    family,
    tier,
    pavedOnly: !!pavedOnly,
    isEndpointEdge: false
  });
}

function cleanLeafStepCost(
  pack, ei, edgeM, toLL, startLL, endLL, startOnHwy, endOnHwy, e4Opts
) {
  const leaves = pack.edgeLeaves(ei);
  const family = surfaceFamilyOf(leaves.surfaceLeaf, pack.surfaceFamilyMap);
  const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
  let step = (edgeM / 1000) * cleanLeafCostMult(tier, family);
  if (toLL) {
    step *= e4LeafCostMult({
      tier,
      avoidMotorways: !!(e4Opts && e4Opts.avoidMotorways),
      preferBackRoads: !!(e4Opts && e4Opts.preferBackRoads),
      metersFromStart: haversineMeters(toLL, startLL),
      metersToDestination: haversineMeters(toLL, endLL),
      startOnHighway: !!startOnHwy,
      endOnHighway: !!endOnHwy
    });
  }
  return step;
}

/** Apply E4 knobs on leaf packs (Clean-only flags; no-op when both off or no leaves). */
function applyE4LeafMult(pack, ei, step, toLL, startLL, endLL, startOnHwy, endOnHwy, e4Opts) {
  if (!pack || !pack.hasLeaves || !e4Opts) return step;
  if (!e4Opts.avoidMotorways && !e4Opts.preferBackRoads) return step;
  const leaves = pack.edgeLeaves(ei);
  const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
  const metersFromStart = toLL ? haversineMeters(toLL, startLL) : 1e9;
  const metersToDestination = toLL ? haversineMeters(toLL, endLL) : 1e9;
  return step * e4LeafCostMult({
    tier,
    avoidMotorways: !!e4Opts.avoidMotorways,
    preferBackRoads: !!e4Opts.preferBackRoads,
    metersFromStart,
    metersToDestination,
    startOnHighway: !!startOnHwy,
    endOnHighway: !!endOnHwy
  });
}

function leafPinIsHighway(pack, match) {
  if (!pack || !pack.hasLeaves || !match || match.edgeIndex == null) return false;
  const leaves = pack.edgeLeaves(match.edgeIndex);
  const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
  return tier === ROAD_TIER.MOTORWAY || tier === ROAD_TIER.TRUNK || tier === ROAD_TIER.ARTERIAL;
}

function finalizeReportedStats(stats, routeEdges, distanceMeters, pack) {
  if (!pack || !pack.hasLeaves) return stats;
  const rows = (routeEdges || []).map((edge) => ({
    meters: edge.meters,
    surfaceLeaf: edge.surfaceLeaf
  }));
  return applyHonestSurfaceStats(stats, rows, distanceMeters, true);
}

function haversineMeters(a, b) {
  const R = 6371000;
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function accessAllowed(accessCode, policy, enums, edgeOrSource, profile) {
  // Eligibility gate (not a cost). Purple motorized_unknown edges are in the
  // search graph only when Allow unknown is on. Clean never opens them.
  void edgeOrSource;
  const name = enums.ACCESS_NAME[accessCode];
  if (name === "motorized_restricted" || name === "motorized_excluded") return false;
  if (name === "motorized_unknown") {
    if (String(profile || "").toLowerCase() === "cleanest") return false;
    return !!policy.motorizedUnknown;
  }
  if (name === "motorized_verified") return true;
  if (name === "motorized_permissive") return policy.motorizedPermissive !== false;
  return false;
}

class MinHeap {
  constructor() {
    this.items = [];
  }
  push(item) {
    this.items.push(item);
    let i = this.items.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.items[p].cost <= this.items[i].cost) break;
      const t = this.items[p];
      this.items[p] = this.items[i];
      this.items[i] = t;
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
      let s = i;
      const l = i * 2 + 1;
      const r = l + 1;
      if (l < this.items.length && this.items[l].cost < this.items[s].cost) s = l;
      if (r < this.items.length && this.items[r].cost < this.items[s].cost) s = r;
      if (s === i) break;
      const t = this.items[s];
      this.items[s] = this.items[i];
      this.items[i] = t;
      i = s;
    }
    return top;
  }
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
  // Only used for between-match virtual edge length when needed.
  let total = 0;
  const EARTH = 6371000;
  for (let i = 1; i < coords.length; i += 1) {
    const a = coords[i - 1];
    const b = coords[i];
    const toRad = (d) => (d * Math.PI) / 180;
    const dLat = toRad(b[1] - a[1]);
    const dLng = toRad(b[0] - a[0]);
    const lat1 = toRad(a[1]);
    const lat2 = toRad(b[1]);
    const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
    total += 2 * EARTH * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
  }
  return total;
}

function coordsFromAToMatch(coords, match) {
  const out = [];
  for (let i = 0; i <= match.segmentIndex; i += 1) out.push(coords[i]);
  const last = out[out.length - 1];
  if (!last || last[0] !== match.coord[0] || last[1] !== match.coord[1]) out.push(match.coord);
  return dedupe(out);
}

function coordsFromMatchToB(coords, match) {
  const out = [match.coord];
  for (let i = match.segmentIndex + 1; i < coords.length; i += 1) out.push(coords[i]);
  return dedupe(out);
}

function coordsBetweenMatches(coords, startMatch, endMatch) {
  if (startMatch.distanceAlongM <= endMatch.distanceAlongM) {
    const forward = [startMatch.coord];
    for (let i = startMatch.segmentIndex + 1; i <= endMatch.segmentIndex; i += 1) {
      forward.push(coords[i]);
    }
    forward.push(endMatch.coord);
    return dedupe(forward);
  }
  return coordsBetweenMatches(coords, endMatch, startMatch).reverse();
}

function exceedsLengthSlack(newMeters, toNode, slackToDest, cap) {
  if (newMeters > cap) return true;
  if (!slackToDest) return false;
  const rem = slackToDest[toNode];
  if (!Number.isFinite(rem)) return true;
  return newMeters + rem > cap + 1;
}

function blockedForRide(
  point,
  startLL,
  endLL,
  cityWall,
  corridorM,
  hardCorridor,
  urbanBoxes,
  settlementWall,
  settlementBoxes,
  fromPoint
) {
  if (hopBlocked(point, startLL, endLL, cityWall, urbanBoxes)) return true;
  if (
    cityWall && fromPoint && point &&
    metroEdgeBlocks(fromPoint, point, startLL, endLL, urbanBoxes)
  ) return true;
  if (
    settlementWall && point &&
    settlementBlocks(point[0], point[1], startLL, endLL, settlementBoxes)
  ) return true;
  return !!hardCorridor && outsideCorridor(point, startLL, endLL, corridorM);
}

function fillShortestMeters(args) {
  const {
    n,
    total,
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeMeters,
    pack,
    policy,
    enums,
    avoid,
    virt,
    virtAdj,
    startLL,
    endLL,
    cityWall,
    corridorM,
    hardCorridor,
    pavedOnly,
    urbanBoxes,
    settlementWall,
    settlementFallback,
    settlementBoxes,
    origin,
    capMeters,
    nodeLL,
    coincidentSiblings,
    deadlineAtMs,
    abortSignal
  } = args;
  const absoluteDeadline = Number(deadlineAtMs);
  const deadlineExceeded = () =>
    (abortSignal && abortSignal.aborted) ||
    (Number.isFinite(absoluteDeadline) && Date.now() >= absoluteDeadline);
  const dist = new Float64Array(total);
  dist.fill(Infinity);
  const heap = new MinHeap();
  // The pack CSR contains directed arcs. Build its transpose so these are true
  // node -> destination lower bounds; using destination's outgoing arcs can
  // over-prune valid routes at one-way roads.
  const arcCount = edgeTargets.length;
  const incomingCounts = new Uint32Array(n);
  for (let i = 0; i < arcCount; i += 1) {
    if ((i & 8191) === 0 && deadlineExceeded()) return null;
    const target = edgeTargets[i];
    if (target < n) incomingCounts[target] += 1;
  }
  const incomingOffsets = new Uint32Array(n + 1);
  for (let node = 0; node < n; node += 1) {
    if ((node & 8191) === 0 && deadlineExceeded()) return null;
    incomingOffsets[node + 1] = incomingOffsets[node] + incomingCounts[node];
  }
  const incomingSources = new Uint32Array(arcCount);
  const incomingEdges = new Uint32Array(arcCount);
  const cursors = incomingOffsets.slice(0, n);
  for (let source = 0; source < n; source += 1) {
    if ((source & 2047) === 0 && deadlineExceeded()) return null;
    for (let i = nodeOffsets[source]; i < nodeOffsets[source + 1]; i += 1) {
      const target = edgeTargets[i];
      if (target >= n) continue;
      const slot = cursors[target]++;
      incomingSources[slot] = source;
      incomingEdges[slot] = edgeUndirectedIndex[i];
    }
  }
  dist[origin] = 0;
  heap.push({ node: origin, cost: 0 });
  let pops = 0;
  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    if (cur.cost > capMeters) continue;
    pops += 1;
    if ((pops & 255) === 0 && deadlineExceeded()) return null;
    if (cur.node < n) {
      const start = incomingOffsets[cur.node];
      const end = incomingOffsets[cur.node + 1];
      for (let i = start; i < end; i += 1) {
        const to = incomingSources[i];
        const ei = incomingEdges[i];
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (pack.graphBinaryVersion >= 4 ? !v4DirectionAllowed(pack, ei, to, cur.node, policy.motorizedUnknown) : !accessAllowed(access, policy, enums)) continue;
        if (pavedOnly) {
          const leafBlock = cleanLeafBlocked(pack, ei, true, -1, -1);
          if (leafBlock === true) continue;
          if (leafBlock == null) {
            const surfaceName = enums.SURFACE_NAME[unpackSurface(attr)] || "unknown";
            const roadName = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
            if (isBlockedForCleanPavement(surfaceName, roadName)) continue;
          }
        }
        if (avoid && avoid.has(pack.edgeId(ei))) continue;
        const toLL = nodeLL(to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(cur.node)
        )) continue;
        const cand = cur.cost + edgeMeters[ei];
        if (cand > capMeters) continue;
        if (cand < dist[to]) {
          dist[to] = cand;
          heap.push({ node: to, cost: cand });
        }
      }
      const siblings = coincidentSiblings && coincidentSiblings[cur.node];
      if (siblings) {
        for (let si = 0; si < siblings.length; si += 1) {
          const to = siblings[si];
          if (cur.cost < dist[to]) {
            dist[to] = cur.cost;
            heap.push({ node: to, cost: cur.cost });
          }
        }
      }
    }
    const vlist = virtAdj.get(cur.node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        if (pavedOnly) {
          const leafBlock = cleanLeafBlocked(pack, v.ei, true, -1, -1);
          if (leafBlock === true) continue;
          if (leafBlock == null) {
            const attr = edgeAttrs[v.ei];
            const surfaceName = enums.SURFACE_NAME[unpackSurface(attr)] || "unknown";
            const roadName = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
            if (isBlockedForCleanPavement(surfaceName, roadName)) continue;
          }
        }
        const toLL = nodeLL(item.to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(cur.node)
        )) continue;
        const cand = cur.cost + v.meters;
        if (cand > capMeters) continue;
        if (cand < dist[item.to]) {
          dist[item.to] = cand;
          heap.push({ node: item.to, cost: cand });
        }
      }
    }
  }
  return dist;
}

function dirtCandidateSummary(ride, width, searchObjective = "pavement") {
  const distanceMeters = Number(ride && ride.distanceMeters) || 0;
  const dirtPercent = Number(ride && ride.stats && ride.stats.dirtPercent) || 0;
  const pavedMeters = distanceMeters * Math.max(0, 100 - dirtPercent) / 100;
  const shape = (ride && ride.searchMeta && ride.searchMeta.routeShape) || {};
  const quality = summarizeRouteQuality(ride, { profile: "dirt" });
  return {
    ride,
    width,
    searchObjective,
    dirtPercent,
    pavedMeters,
    quality,
    firstSectionDirtPercent: quality.firstSectionDirtPercent,
    minimumSectionDirtPercent: quality.minimumSectionDirtPercent,
    longestPavedRunMeters: quality.longestPavedRunMeters,
    urbanCoreMeters: quality.urbanCoreMeters,
    routeMeters: Number(shape.routeMeters) || distanceMeters,
    backwardMeters: Number(shape.backwardMeters) || 0,
    lateralMeters: Number(shape.lateralMeters) || 0
  };
}

/**
 * Dirt works back from 100%. Distance is deliberately absent: once candidates
 * are within two percentage points, choose the more consistently enjoyable
 * journey before aggregate pavement and purposeless movement. One paved stem
 * or urban crossing must not hide behind a strong total Dirt percentage.
 */
function chooseDirtRideCandidate(candidates) {
  if (!candidates.length) return null;
  const coherent = candidates.filter((candidate) =>
    candidate.backwardMeters <= Math.max(5_000, candidate.routeMeters * 0.08)
  );
  const bestDirt = Math.max(...candidates.map((candidate) => candidate.dirtPercent));
  const bestCoherentDirt = coherent.length
    ? Math.max(...coherent.map((candidate) => candidate.dirtPercent))
    : -Infinity;
  // A visibly looping ride cannot win for a marginal dirt improvement. Keep
  // the wider adventure only when it earns a material (10-point) dirt gain,
  // or when every connected candidate necessarily bends backward.
  const pool = coherent.length && bestDirt - bestCoherentDirt < 10
    ? coherent
    : candidates;
  return pool.slice().sort((a, b) => {
    const dirtDelta = b.dirtPercent - a.dirtPercent;
    if (Math.abs(dirtDelta) > 2) return dirtDelta;
    const urbanDelta = (Number(a.urbanCoreMeters) || 0) - (Number(b.urbanCoreMeters) || 0);
    if (Math.abs(urbanDelta) > 100) return urbanDelta;
    const weakSectionDelta =
      (Number(b.minimumSectionDirtPercent) || 0) -
      (Number(a.minimumSectionDirtPercent) || 0);
    if (Math.abs(weakSectionDelta) >= 5) return weakSectionDelta;
    const pavedRunDelta =
      (Number(a.longestPavedRunMeters) || 0) -
      (Number(b.longestPavedRunMeters) || 0);
    if (Math.abs(pavedRunDelta) > 2_000) return pavedRunDelta;
    const pavedDelta = a.pavedMeters - b.pavedMeters;
    if (Math.abs(pavedDelta) > 2000) return pavedDelta;
    const meanderA = a.backwardMeters + a.lateralMeters * 0.25;
    const meanderB = b.backwardMeters + b.lateralMeters * 0.25;
    if (Math.abs(meanderA - meanderB) > 1000) return meanderA - meanderB;
    if (b.dirtPercent !== a.dirtPercent) return b.dirtPercent - a.dirtPercent;
    return a.width - b.width;
  })[0];
}

function findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, searchOpts) {
  searchOpts = searchOpts || {};
  profile = resolveProfile(profile);
  const sessionSeed = Number(searchOpts.sessionSeed) || 0;
  if (!searchOpts.costMode) {
    const baseCorridor = corridorMetersForProfile(profile);
    const straightLineMeters = haversineMeters(startMatch.coord, endMatch.coord);
    const graphNodeCount = Number(runtime && runtime.pack && runtime.pack.nodeCount) || 0;
    // Balanced/Clean keep the narrowest viable band. Dirt scores only
    // 120 km + 60 km; 180/240/unbounded are connectivity fallbacks if those
    // two bands find no path. The corridor is an outer permission, never
    // distance the route must consume.
    const widthMultipliers = profile === "dirt" ? [2, 1, 3, 4]
      : profile === "cleanest"
        // Clean: no corridor ladder — one fabric search.
        ? [Infinity]
        : balancedCorridorMultipliers(straightLineMeters); // balanced
    const widths = profile === "cleanest"
      ? [Infinity]
      : widthMultipliers.map((m) => baseCorridor * m).concat(Infinity);
    const requestedCap = Number(searchOpts.maxPathMeters);
    const budgetedProfile = profile === "balanced";
    // Fuel planning supplies one absolute wall-clock deadline. Every helper,
    // corridor attempt and repair pass must share it; none may restart a fresh
    // local clock after the outer request has expired.
    const deadlineStartedAt = Date.now();
    const requestHasDeadline = Number.isFinite(Number(searchOpts.deadlineAtMs));
    const adaptiveBudgetMs = profileSearchBudgetMs(
      profile,
      straightLineMeters,
      graphNodeCount
    );
    const outerDeadline = requestHasDeadline
      ? Number(searchOpts.deadlineAtMs)
      : deadlineStartedAt + adaptiveBudgetMs;
    const effectiveBudgetMs = Math.max(0, outerDeadline - deadlineStartedAt);
    const directShortest = budgetedProfile
      ? findPathV2(
          runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias,
          {
            ...searchOpts,
            costMode: "distance",
            corridorMeters: 0,
            hardCorridor: false,
            boundedSearch: requestHasDeadline,
            variety: false,
            settlementWall: false,
            settlementFallback: false,
            priorEdgeIds: [],
            arrivalEdgeId: null,
            backtrackFactor: 1,
            progressRegressionMeters: Number.MAX_SAFE_INTEGER,
            maxPathMeters: undefined,
            timeCapMs: requestHasDeadline
              ? Math.max(1, outerDeadline - Date.now())
              : undefined,
            deadlineAtMs: requestHasDeadline ? outerDeadline : undefined,
            abortSignal: searchOpts.abortSignal
          }
        )
      : null;
    const directShortestMeters = Number(directShortest && directShortest.distanceMeters);
    const directBudget = Number.isFinite(directShortestMeters)
      ? directShortestMeters + 40_000
      : Infinity;
    const activePathCap = budgetedProfile
      ? Math.min(Number.isFinite(requestedCap) ? requestedCap : Infinity, directBudget)
      : requestedCap;
    const dirtCandidates = [];
    const balancedCandidates = [];
    const attemptDiagnostics = [];
    let containedBaseDirtCandidate = null;
    // Keep one absolute ceiling across corridor attempts and any internal
    // fallback recursion. A failed hop must not receive a fresh clock merely
    // because the search widens or relaxes a scored preference.
    let liveDeadline = outerDeadline;
    searchOpts.deadlineAtMs = liveDeadline;
    for (const width of widths) {
      if (
        profile === "dirt" && width === baseCorridor && containedBaseDirtCandidate
      ) {
        dirtCandidates.push(containedBaseDirtCandidate);
        attemptDiagnostics.push({
          corridorMeters: baseCorridor,
          searchObjective: "pavement",
          outcome: "reused",
          pops: 0,
          searchMs: 0,
          reusedFromCorridorMeters: baseCorridor * 2
        });
        continue;
      }
      if (Date.now() >= liveDeadline) {
        attemptDiagnostics.push({
          corridorMeters: null, outcome: "timeCap", pops: 0, searchMs: 0
        });
        break;
      }
      // Once Dirt has compared 60/120 km, wider bands are connectivity
      // fallbacks only. Stop at the first one that connects.
      const dirtComparisonWidth = profile === "dirt" && Number.isFinite(width) && width <= baseCorridor * 2;
      if (profile === "dirt" && dirtCandidates.length && !dirtComparisonWidth) break;
      const diagnostics = {};
      const rideOpts = {
        // Each profile searches for the ride it promises. There is deliberately
        // no preliminary shortest route and no shortest-derived length ceiling.
        costMode:
          profile === "balanced" ? "balancedResource" :
          profile === "dirt" ? "pavement" : "profile",
        corridorMeters: Number.isFinite(width) ? width : 0,
        hardCorridor: Number.isFinite(width),
        boundedSearch: true,
        sessionSeed,
        variety: false,
        // Preserve Clean's paved-only gate across corridor widen attempts.
        pavedOnly: searchOpts.pavedOnly === true,
        cityWall: searchOpts.cityWall !== false,
        urbanCoreFallback: searchOpts.urbanCoreFallback === true,
        // Width is lateral permission, not permission to head away from the
        // next pin. Keep the forward-progress guard fixed while widening; only
        // the final unbounded attempt may relax it to prove connectivity.
        progressRegressionMeters: progressRegressionForAttempt(profile, width),
        diagnostics,
        settlementWall: searchOpts.settlementWall === true,
        settlementFallback: searchOpts.settlementFallback !== false,
        priorEdgeIds: searchOpts.priorEdgeIds || [],
        arrivalEdgeId: searchOpts.arrivalEdgeId == null ? null : searchOpts.arrivalEdgeId,
        backtrackFactor: searchOpts.backtrackFactor,
        skipShortDirtRepair: searchOpts.skipShortDirtRepair === true,
        popCap: profileSearchPopCap(profile, graphNodeCount, dirtComparisonWidth),
        deadlineAtMs: requestHasDeadline ? liveDeadline : undefined,
        abortSignal: searchOpts.abortSignal
      };
      if (dirtComparisonWidth) {
        // Comparison candidates share roughly one old pass-2 budget.
        rideOpts.timeCapMs = 7000;
      }
      rideOpts.timeCapMs = Math.min(
        Number(rideOpts.timeCapMs) || PASS2_TIME_MS,
        Math.max(250, liveDeadline - Date.now())
      );
      // A real per-hop constraint (fuel range) remains a hard safety limit. It
      // is not a shortest-path-derived product objective.
      if (Number.isFinite(activePathCap)) rideOpts.maxPathMeters = activePathCap;
      if (Number.isFinite(directShortestMeters)) rideOpts.shortestMeters = directShortestMeters;
      const attemptStarted = Date.now();
      const initialRide = findPathV2(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, rideOpts
      );
      const ride = repairShortDirtExcursions(
        initialRide,
        runtime,
        startMatch,
        endMatch,
        profile,
        policy,
        avoidEdgeIds,
        pavedBias,
        rideOpts
      );
      attemptDiagnostics.push({
        corridorMeters: Number.isFinite(width) ? width : null,
        searchObjective: rideOpts.costMode,
        outcome: ride
          ? ((ride.searchMeta && ride.searchMeta.pass2Outcome) || "completed")
          : (diagnostics.outcome || "noPath"),
        pops: diagnostics.pops || (ride && ride.searchMeta && ride.searchMeta.pops) || 0,
        searchMs: Date.now() - attemptStarted,
        rejections: diagnostics.rejections || null
      });
      if (!ride) continue;
      ride.searchMeta = ride.searchMeta || {};
      ride.searchMeta.rideObjective =
        profile === "dirt" ? "earned-dirt-detour" :
        profile === "balanced" ? "surface-balance" :
        profile === "cleanest" ? "practical-pavement" :
        "crow-flies-adventure";
      ride.searchMeta.corridorMeters = Number.isFinite(width) ? width : null;
      ride.searchMeta.corridorWidened = Number.isFinite(width) && width > baseCorridor;
      ride.searchMeta.searchBudgetMs = effectiveBudgetMs;
      ride.searchMeta.searchBudgetPolicy = requestHasDeadline
        ? "request-deadline"
        : "adaptive-profile";
      if (directShortest) {
        ride.searchMeta.directReference = {
          algorithm: directShortest.searchMeta && directShortest.searchMeta.searchAlgorithm,
          distanceMeters: Math.round(directShortestMeters),
          pops: Number(directShortest.searchMeta && directShortest.searchMeta.pops) || 0
        };
      }
      if (profile === "balanced") {
        const quality = summarizeRouteQuality(ride, {
          profile,
          urbanBoxes: urbanBoxesForPack(runtime.pack)
        });
        balancedCandidates.push({
          ride,
          width,
          quality,
          miss: Math.abs(Number(quality.knownDirtPercent) - 50)
        });
        if (quality.state === "ready") {
          ride.searchMeta.corridorCandidates = attemptDiagnostics;
          return ride;
        }
        continue;
      }
      if (profile === "dirt") {
        ride.searchMeta.dirtSelection = "highest-coherent-dirt-share";
        const summary = dirtCandidateSummary(ride, width, rideOpts.costMode);
        dirtCandidates.push(summary);
        const maxCrossTrack = Number(ride.searchMeta.maxCrossTrackMeters);
        if (
          width === baseCorridor * 2 &&
          Number.isFinite(maxCrossTrack) && maxCrossTrack <= baseCorridor
        ) {
          // The wide result is already feasible inside the next narrower
          // corridor. Both attempts use the same objective and forward-progress
          // guard, so solving that contained candidate again cannot improve it.
          containedBaseDirtCandidate = {
            ...summary,
            width: baseCorridor
          };
        }
        if (dirtComparisonWidth) continue;
      }
      ride.searchMeta.corridorCandidates = attemptDiagnostics;
      return ride;
    }
    if (profile === "balanced" && balancedCandidates.length) {
      balancedCandidates.sort((a, b) => {
        const urbanDelta = a.quality.urbanCoreMeters - b.quality.urbanCoreMeters;
        if (Math.abs(urbanDelta) > 100) return urbanDelta;
        if (Math.abs(a.miss - b.miss) > 0.1) return a.miss - b.miss;
        return Number(a.ride.distanceMeters) - Number(b.ride.distanceMeters);
      });
      const best = balancedCandidates[0];
      best.ride.searchMeta = best.ride.searchMeta || {};
      best.ride.searchMeta.corridorMeters = Number.isFinite(best.width) ? best.width : null;
      best.ride.searchMeta.corridorWidened = Number.isFinite(best.width) && best.width > baseCorridor;
      best.ride.searchMeta.corridorCandidates = attemptDiagnostics;
      best.ride.searchMeta.balancedSelection = "closest-feasible-to-50-without-urban-core";
      best.ride.searchMeta.balancedTargetMet = best.quality.state === "ready";
      return best.ride;
    }
    if (profile === "dirt" && dirtCandidates.length) {
      const primaryBestDirt = Math.max(...dirtCandidates.map((candidate) => candidate.dirtPercent));
      if (primaryBestDirt < 70) {
        const primary = chooseDirtRideCandidate(dirtCandidates);
        const recoveryCap = dirtRecoveryPathCap(
          primary && primary.ride && primary.ride.distanceMeters,
          activePathCap
        );
        const diagnostics = {};
        const recoveryBudgetMs = Math.min(
          7_000,
          profileSearchBudgetMs(profile, straightLineMeters, graphNodeCount)
        );
        const resourceOpts = {
          ...searchOpts,
          costMode: "balancedResource",
          corridorMeters: baseCorridor,
          hardCorridor: true,
          boundedSearch: true,
          variety: false,
          pavedOnly: false,
          cityWall: searchOpts.cityWall !== false,
          urbanCoreFallback: searchOpts.urbanCoreFallback === true,
          progressRegressionMeters: maxProgressRegressionMeters(profile),
          diagnostics,
          settlementWall: searchOpts.settlementWall === true,
          settlementFallback: searchOpts.settlementFallback !== false,
          priorEdgeIds: searchOpts.priorEdgeIds || [],
          arrivalEdgeId: searchOpts.arrivalEdgeId == null ? null : searchOpts.arrivalEdgeId,
          backtrackFactor: searchOpts.backtrackFactor,
          skipShortDirtRepair: searchOpts.skipShortDirtRepair === true,
          popCap: profileSearchPopCap(profile, graphNodeCount, false),
          timeCapMs: recoveryBudgetMs,
          deadlineAtMs: requestHasDeadline
            ? Math.min(liveDeadline, Date.now() + recoveryBudgetMs)
            : Date.now() + recoveryBudgetMs,
          abortSignal: searchOpts.abortSignal
        };
        if (Number.isFinite(recoveryCap)) resourceOpts.maxPathMeters = recoveryCap;
        const recoveryStarted = Date.now();
        const initialRecovery = findPathV2(
          runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, resourceOpts
        );
        const recoveredRide = repairShortDirtExcursions(
          initialRecovery,
          runtime,
          startMatch,
          endMatch,
          profile,
          policy,
          avoidEdgeIds,
          pavedBias,
          resourceOpts
        );
        attemptDiagnostics.push({
          corridorMeters: baseCorridor,
          searchObjective: "balancedResource",
          outcome: recoveredRide ? "completed" : (diagnostics.outcome || "noPath"),
          pops: diagnostics.pops ||
            (recoveredRide && recoveredRide.searchMeta && recoveredRide.searchMeta.pops) || 0,
          searchMs: Date.now() - recoveryStarted,
          maxPathMeters: Number.isFinite(recoveryCap) ? Math.round(recoveryCap) : null
        });
        if (recoveredRide) {
          recoveredRide.searchMeta = recoveredRide.searchMeta || {};
          recoveredRide.searchMeta.rideObjective = "earned-dirt-detour";
          recoveredRide.searchMeta.corridorMeters = baseCorridor;
          recoveredRide.searchMeta.corridorWidened = false;
          recoveredRide.searchMeta.searchBudgetMs = recoveryBudgetMs;
          recoveredRide.searchMeta.searchBudgetPolicy = "low-dirt-resource-recovery";
          recoveredRide.searchMeta.dirtSelection = "highest-coherent-dirt-share";
          dirtCandidates.push(
            dirtCandidateSummary(recoveredRide, baseCorridor, "balancedResource")
          );
        }
      }
      const best = chooseDirtRideCandidate(dirtCandidates);
      best.ride.searchMeta.corridorMeters = best.width;
      best.ride.searchMeta.corridorWidened =
        Number.isFinite(best.width) && best.width > baseCorridor;
      best.ride.searchMeta.corridorCandidates = attemptDiagnostics.map((attempt) => {
        const candidate = dirtCandidates.find((item) =>
          item.width === attempt.corridorMeters &&
          item.searchObjective === attempt.searchObjective
        );
        return candidate ? {
          ...attempt,
          dirtPercent: candidate.dirtPercent,
          distanceMeters: Math.round(candidate.ride.distanceMeters || 0),
          pavedMeters: Math.round(candidate.pavedMeters),
          firstSectionDirtPercent: candidate.firstSectionDirtPercent,
          minimumSectionDirtPercent: candidate.minimumSectionDirtPercent,
          longestPavedRunMeters: Math.round(candidate.longestPavedRunMeters),
          urbanCoreMeters: Math.round(candidate.urbanCoreMeters),
          backwardMeters: Math.round(candidate.backwardMeters),
          lateralMeters: Math.round(candidate.lateralMeters)
        } : attempt;
      });
      best.ride.searchMeta.corridorSelection =
        "highest-dirt-then-journey-continuity-pavement-meander";
      return best.ride;
    }
    const incompleteAttempt = attemptDiagnostics.find((attempt) =>
      attempt.outcome === "timeCap" || attempt.outcome === "popCap"
    );
    const directFitsRequest = directShortest && Number.isFinite(directShortestMeters) && (
      !Number.isFinite(requestedCap) || directShortestMeters <= requestedCap + 1
    );
    if (
      profile === "balanced" && directFitsRequest &&
      !(searchOpts.abortSignal && searchOpts.abortSignal.aborted)
    ) {
      // A bounded Balanced preference search is allowed to lose refinement,
      // never connectivity. The distance pass has already proved a legal road
      // ride under the same access policy and hard fuel cap. Return it with an
      // explicit diagnostic rather than falsely reporting that no route exists.
      directShortest.searchMeta = directShortest.searchMeta || {};
      directShortest.searchMeta.rideObjective = "surface-balance-bounded-fallback";
      directShortest.searchMeta.balancedSearchFallbackUsed = true;
      directShortest.searchMeta.balancedSearchFallbackReason = incompleteAttempt
        ? incompleteAttempt.outcome
        : "no_balanced_candidate";
      directShortest.searchMeta.corridorMeters = null;
      directShortest.searchMeta.corridorWidened = false;
      directShortest.searchMeta.corridorCandidates = attemptDiagnostics;
      directShortest.searchMeta.searchBudgetMs = effectiveBudgetMs;
      directShortest.searchMeta.searchBudgetPolicy = requestHasDeadline
        ? "request-deadline"
        : "adaptive-profile";
      directShortest.searchMeta.directReference = {
        algorithm: directShortest.searchMeta.searchAlgorithm,
        distanceMeters: Math.round(directShortestMeters),
        pops: Number(directShortest.searchMeta.pops) || 0
      };
      return directShortest;
    }
    const allProvedNoPath = attemptDiagnostics.length > 0
      && attemptDiagnostics.every((attempt) => attempt.outcome === "noPath");
    if (
      searchOpts.settlementWall === true && !searchOpts._settlementRelaxed &&
      allProvedNoPath
    ) {
      const relaxed = findPathV2(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias,
        {
          ...searchOpts,
          settlementWall: false,
          settlementFallback: true,
          _settlementRelaxed: true
        }
      );
      if (relaxed) {
        relaxed.searchMeta = relaxed.searchMeta || {};
        relaxed.searchMeta.settlementFallbackUsed = true;
      }
      return relaxed;
    }
    if (searchOpts.diagnostics) {
      const incomplete = attemptDiagnostics.find((attempt) =>
        attempt.outcome === "timeCap" || attempt.outcome === "popCap"
      );
      searchOpts.diagnostics.outcome = incomplete ? incomplete.outcome : "noPath";
      searchOpts.diagnostics.attempts = attemptDiagnostics;
      searchOpts.diagnostics.pops = attemptDiagnostics.reduce(
        (sum, attempt) => sum + (Number(attempt.pops) || 0),
        0
      );
    }
    return null;
  }

  const pack = runtime.pack;
  // The embedded pack cores add precision; they do not replace the established
  // metropolitan safety wall. Replacing the broad Halifax wall with the
  // smaller OSM city polygon allowed routes to skim through the metro area.
  const urbanBoxes = urbanBoxesForPack(pack);
  const settlementBoxes = settlementBoxesForPack(pack, profile);
  const geom = runtime.geom;
  const enums = runtime.enums;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
  const shortDirtPenaltyEdgeIds = searchOpts.shortDirtPenaltyEdgeIds instanceof Set
    ? searchOpts.shortDirtPenaltyEdgeIds
    : new Set(searchOpts.shortDirtPenaltyEdgeIds || []);
  const prior = new Set((searchOpts.priorEdgeIds || []).map(String));
  const arrival = searchOpts.arrivalEdgeId == null ? null : String(searchOpts.arrivalEdgeId);
  const backtrackFactor = Number.isFinite(Number(searchOpts.backtrackFactor))
    ? Math.max(1, Number(searchOpts.backtrackFactor))
    : 4;
  const penalizeBacktrack = (cost, edgeId) => {
    const id = String(edgeId == null ? "" : edgeId);
    if (arrival != null && id === arrival) return cost * 12;
    if (prior.has(id)) return cost * backtrackFactor;
    return cost;
  };
  const n = pack.nodeCount;
  const startNode = n;
  const endNode = n + 1;
  const baseTotal = n + 2;
  const regionId =
    (pack && (pack.regionId || pack.province)) ||
    (runtime.data && (runtime.data.regionId || runtime.data.province)) ||
    (runtime.meta && (runtime.meta.regionId || runtime.meta.province)) ||
    "";
  const costView = costPerKmView(profile, regionId, pavedBias == null ? 1 : pavedBias);
  const {
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeMeters,
    edgeFrom,
    edgeTo,
    nodeCoords
  } = pack;
  const turnState = buildTurnAwareState(pack, n, startNode, endNode);
  const total = turnState.stateCount;
  const graphNodeOf = turnState.graphNodeOf;
  const stateForArrival = turnState.stateForArrival;

  const startLL = startMatch.coord;
  const endLL = endMatch.coord;
  const abMeters = haversineMeters(startLL, endLL);
  const startOnMajorHighway = profile === "cleanest" && pack.hasLeaves
    ? leafPinIsHighway(pack, startMatch) || pinMatchesMajorHighway(startMatch, profile)
    : pinMatchesMajorHighway(startMatch, profile);
  const endOnMajorHighway = profile === "cleanest" && pack.hasLeaves
    ? leafPinIsHighway(pack, endMatch) || pinMatchesMajorHighway(endMatch, profile)
    : pinMatchesMajorHighway(endMatch, profile);
  const e4Opts = e4FlagsForProfile(profile, {
    avoidMotorways: searchOpts.avoidMotorways === true,
    preferBackRoads: searchOpts.preferBackRoads === true
  });

  function nodeLL(node) {
    if (node === startNode) return startLL;
    if (node === endNode) return endLL;
    const graphNode = graphNodeOf(node);
    if (graphNode >= 0 && graphNode < n && nodeCoords) {
      return [nodeCoords[graphNode * 2], nodeCoords[graphNode * 2 + 1]];
    }
    return null;
  }

  function awayExtra(fromNode, toNode) {
    const a = nodeLL(fromNode);
    const b = nodeLL(toNode);
    if (!a || !b) return 0;
    return approachAwayExtraCost(
      profile,
      haversineMeters(a, endLL),
      haversineMeters(b, endLL),
      abMeters,
      50,
      regionId
    );
  }

  // Virtual edges: small fixed set with coords for reconstruct only.
  const virt = [];
  function addVirt(a, b, meters, accessLeg, coords, ei) {
    const id = virt.length;
    virt.push({ a, b, meters, accessLeg, coords, ei });
    return id;
  }

  const startEi = startMatch.edgeIndex;
  const endEi = endMatch.edgeIndex;
  const startCoords = geom.polyline(startEi);
  const endCoords = endEi === startEi ? startCoords : geom.polyline(endEi);
  const sA = edgeFrom[startEi];
  const sB = edgeTo[startEi];
  const eA = edgeFrom[endEi];
  const eB = edgeTo[endEi];
  const toSA = coordsFromAToMatch(startCoords, startMatch);
  const toSB = coordsFromMatchToB(startCoords, startMatch);
  const mSA = Math.max(0, Number(startMatch.distanceAlongM) || 0);
  const mSB = Math.max(0, (Number(startMatch.edgeMeters) || edgeMeters[startEi]) - mSA);
  const vStartA = addVirt(startNode, sA, mSA, true, toSA.slice().reverse(), startEi);
  const vStartB = addVirt(startNode, sB, mSB, true, toSB, startEi);

  const toEA = coordsFromAToMatch(endCoords, endMatch);
  const toEB = coordsFromMatchToB(endCoords, endMatch);
  const mEA = Math.max(0, Number(endMatch.distanceAlongM) || 0);
  const mEB = Math.max(0, (Number(endMatch.edgeMeters) || edgeMeters[endEi]) - mEA);
  const vEndA = addVirt(endNode, eA, mEA, true, toEA.slice().reverse(), endEi);
  const vEndB = addVirt(endNode, eB, mEB, true, toEB, endEi);

  let vBetween = -1;
  if (startEi === endEi) {
    const between = coordsBetweenMatches(startCoords, startMatch, endMatch);
    vBetween = addVirt(startNode, endNode, lineMeters(between), false, between, startEi);
  }

  const virtAdj = new Map();
  const virtAdjRev = new Map();
  function linkVirtArc(id, from, to, forward) {
    if (from == null || to == null || from < 0 || to < 0) return;
    if (!virtAdj.has(from)) virtAdj.set(from, []);
    virtAdj.get(from).push({ to, id, forward });
    if (!virtAdjRev.has(to)) virtAdjRev.set(to, []);
    virtAdjRev.get(to).push({ to: from, id, forward: !forward });
  }
  function linkVirt(id) {
    const v = virt[id];
    linkVirtArc(id, v.a, v.b, true);
    linkVirtArc(id, v.b, v.a, false);
  }
  if (packHasDirectedArc(pack, sB, sA, startEi)) {
    linkVirtArc(vStartA, startNode, sA, true);
  }
  if (packHasDirectedArc(pack, sA, sB, startEi)) {
    linkVirtArc(vStartB, startNode, sB, true);
  }
  if (packHasDirectedArc(pack, eA, eB, endEi)) {
    linkVirtArc(vEndA, eA, endNode, false);
  }
  if (packHasDirectedArc(pack, eB, eA, endEi)) {
    linkVirtArc(vEndB, eB, endNode, false);
  }
  if (vBetween >= 0) {
    const alongForward = (Number(startMatch.distanceAlongM) || 0)
      <= (Number(endMatch.distanceAlongM) || 0);
    const betweenLegal = alongForward
      ? packHasDirectedArc(pack, sA, sB, startEi)
      : packHasDirectedArc(pack, sB, sA, startEi);
    if (betweenLegal) linkVirtArc(vBetween, startNode, endNode, true);
  }

  // Bridge pack duplicate nodes on continuous OSM ways for every profile.
  // A topology seam is not a surface preference: if Clean can cross the same
  // two-metre OSM join, Dirt and Balanced must see that connected road too.
  const coincidentSiblings =
    pack && pack.graphBinaryVersion >= 4 ? null : cachedCoincidentSiblingLists(nodeCoords, n);

  const costMode = searchOpts.costMode || "profile";
  const distanceAStar = costMode === "distance";
  const maxPathMeters = Number.isFinite(Number(searchOpts.maxPathMeters))
    ? Number(searchOpts.maxPathMeters)
    : Infinity;
  const varietyOn = searchOpts.variety !== false && profile !== "cleanest";
  // Major urban cores are walls during the primary search. The caller may
  // relax the wall only after a proved no-path result; the relaxed search
  // still pays the strong fallback penalty below.
  const cityWall = searchOpts.cityWall !== false;
  const metroFallbackPenalty =
    resolveMetroFallbackPenalty(profile, searchOpts.cleanMetroMultiplier, e4Opts.avoidMotorways);
  const settlementFallbackPenalty = resolveSettlementFallbackPenalty(
    profile, searchOpts.cleanMetroMultiplier, e4Opts.avoidMotorways
  );
  const corridorM = Number.isFinite(Number(searchOpts.corridorMeters))
    ? Number(searchOpts.corridorMeters)
    : corridorMetersForProfile(profile);
  const hardCorridor = searchOpts.hardCorridor === true;
  const pavedOnly = searchOpts.pavedOnly === true;
  const urbanCoreFallback = searchOpts.urbanCoreFallback === true;
  void urbanCoreFallback;
  const settlementWall = searchOpts.settlementWall === true;
  // Clean uses the pack town layer as a finite scored preference, never a wall.
  const settlementFallback = profile === "cleanest"
    ? searchOpts.settlementFallback === true
    : searchOpts.settlementFallback !== false;
  const requestedRegression = Number(searchOpts.progressRegressionMeters);
  const regressionLimit = profile === "cleanest" || requestedRegression === Infinity
    ? Number.MAX_SAFE_INTEGER
    : (Number.isFinite(requestedRegression)
      ? requestedRegression
      : maxProgressRegressionMeters(profile));
  const applyAwayXt = costMode === "profile";
  // Balanced keeps centreline pull. Clean uses toward-B gravity only — no chord XT.
  const applySoftCorridor = applyAwayXt
    && profile !== "cleanest"
    && !(corridorM > 0);
  const isHunt = Number.isFinite(maxPathMeters);
  const absoluteDeadline = Number(searchOpts.deadlineAtMs);
  const hasAbsoluteDeadline = Number.isFinite(absoluteDeadline);
  const abortSignal = searchOpts.abortSignal;
  const boundedSearch = isHunt || searchOpts.boundedSearch === true || hasAbsoluteDeadline;
  const slackToDest = isHunt
    ? fillShortestMeters({
        n,
        total: baseTotal,
        nodeOffsets,
        edgeTargets,
        edgeUndirectedIndex,
        edgeAttrs,
        edgeMeters,
        pack,
        policy,
        enums,
        avoid,
        virt,
        virtAdj: virtAdjRev,
        startLL,
        endLL,
        cityWall,
        corridorM,
        hardCorridor,
        pavedOnly,
        urbanBoxes,
        settlementWall,
        settlementBoxes,
        origin: endNode,
        capMeters: maxPathMeters,
        nodeLL,
        coincidentSiblings,
        deadlineAtMs: absoluteDeadline,
        abortSignal
      })
    : null;

  // A bounded search cannot safely continue without its lower-bound table.
  // Building that table is deliberately deadline-aware in large packs; when
  // it is interrupted, report the real terminal condition instead of later
  // treating a missing table as either a route miss or an unbounded search.
  if (isHunt && !slackToDest) {
    if (searchOpts.diagnostics) {
      searchOpts.diagnostics.searchOutcome =
        abortSignal && abortSignal.aborted ? "cancelled" : "timeCap";
      searchOpts.diagnostics.failureReason =
        abortSignal && abortSignal.aborted ? "cancelled" : "timeout";
    }
    return null;
  }

  if (costMode === "balancedResource") {
    return searchBalancedResource({
      pack,
      geom,
      enums,
      n,
      startNode,
      endNode,
      total,
      virt,
      virtAdj,
      nodeOffsets,
      edgeTargets,
      edgeUndirectedIndex,
      edgeAttrs,
      edgeMeters,
      edgeFrom,
      nodeCoords,
      startLL,
      endLL,
      startEi,
      endEi,
      policy,
      avoid,
      profile,
      sessionSeed,
      maxPathMeters,
      shortestMeters: Number(searchOpts.shortestMeters) || 1,
      cityWall,
      urbanBoxes,
      settlementWall,
      settlementFallback,
      settlementBoxes,
      corridorM,
      varietyOn,
      slackToDest,
      boundedSearch,
      diagnostics: searchOpts.diagnostics || null,
      hardCorridor,
      progressRegressionMeters: regressionLimit,
      timeCapMs: searchOpts.timeCapMs,
      deadlineAtMs: absoluteDeadline,
      abortSignal,
      popCap: searchOpts.popCap,
      prior,
      arrival,
      backtrackFactor,
      cleanMetroMultiplier: searchOpts.cleanMetroMultiplier,
      avoidMotorways: e4Opts.avoidMotorways,
      coincidentSiblings,
      shortDirtPenaltyEdgeIds,
      turnState
    });
  }

  // Distance A* usually touches only a small fraction of a province-sized
  // graph. Clearing every full-size work array before the first pop cost
  // several seconds on Ontario Vercel workers. A seen bitmap gives untouched
  // distance nodes their logical Infinity/-1 defaults without faulting every
  // page into memory. Profile/resource searches keep their established dense
  // array behaviour.
  const sparseDistanceState = distanceAStar;
  const seen = sparseDistanceState ? new Uint8Array(total) : null;
  const dist = new Float64Array(total);
  if (!sparseDistanceState) dist.fill(Infinity);
  const peakProgress = new Float64Array(total);
  if (!sparseDistanceState) peakProgress.fill(-Infinity);
  const prev = new Int32Array(total);
  if (!sparseDistanceState) prev.fill(-1);
  const prevKind = new Uint8Array(total);
  const prevData = new Int32Array(total);
  const prevForward = new Uint8Array(total);
  const pathMeters = new Float64Array(total);
  if (!sparseDistanceState) pathMeters.fill(Infinity);
  const slots = new Uint8Array(total);
  const heap = new MinHeap();

  // Preserve the arrival road tier across virtual snap stubs and zero-cost
  // duplicate-node stitches so the transition toll is charged at the real
  // low-road -> trunk/motorway boundary, not once per highway edge.
  function predecessorGraphEdgeIndex(node) {
    let cursor = node;
    for (let hops = 0; hops < 8 && cursor >= 0 && prev[cursor] >= 0; hops += 1) {
      if (prevKind[cursor] === 0) return prevData[cursor];
      if (prevKind[cursor] === 1) {
        const v = virt[prevData[cursor]];
        return v && Number.isInteger(v.ei) ? v.ei : -1;
      }
      if (prevKind[cursor] !== 2) return -1;
      cursor = prev[cursor];
    }
    return -1;
  }

  const knownDistance = (node) =>
    !sparseDistanceState || seen[node] === 1 ? dist[node] : Infinity;
  const knownPreviousEdge = (node) =>
    !sparseDistanceState || seen[node] === 1 ? prevData[node] : -1;

  if (seen) seen[startNode] = 1;
  dist[startNode] = 0;
  prev[startNode] = -1;
  if (sparseDistanceState) prevData[startNode] = -1;
  pathMeters[startNode] = 0;
  peakProgress[startNode] = 0;
  const queuePriority = (node, pathCost) => {
    if (!distanceAStar) return pathCost;
    const coordinate = nodeLL(node);
    return pathCost + (coordinate ? haversineMeters(coordinate, endLL) / 1000 : 0);
  };
  heap.push({ node: startNode, cost: queuePriority(startNode, 0), pathCost: 0 });
  let pops = 0;
  let abort = "completed";
  const rejected = searchOpts.diagnostics ? {
    immediateReverse: 0,
    legalTurn: 0,
    access: 0,
    avoid: 0,
    geography: 0,
    progress: 0,
    length: 0
  } : null;
  const configuredPopCap = Number(searchOpts.popCap);
  const configuredTimeCapMs = Number(searchOpts.timeCapMs);
  const popCap = boundedSearch
    ? (Number.isFinite(configuredPopCap) ? configuredPopCap : PASS2_POP_CAP)
    : Math.min(8_000_000, total * (VARIETY_SLOTS + 2) * 8);
  const localDeadline = boundedSearch
    ? Date.now() + (Number.isFinite(configuredTimeCapMs) ? configuredTimeCapMs : PASS2_TIME_MS)
    : Infinity;
  const deadline = Math.min(
    localDeadline,
    hasAbsoluteDeadline ? absoluteDeadline : Infinity
  );

  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur) continue;
    const curPathCost = distanceAStar ? cur.pathCost : cur.cost;
    if (curPathCost !== dist[cur.node]) continue;
    pops += 1;
    if (pops > popCap) {
      abort = "popCap";
      break;
    }
    if ((pops & 255) === 0 && (
      (abortSignal && abortSignal.aborted) ||
      (Number.isFinite(deadline) && Date.now() >= deadline)
    )) {
      abort = abortSignal && abortSignal.aborted ? "cancelled" : "timeCap";
      break;
    }
    if (cur.node === endNode) break;
    const currentGraphNode = graphNodeOf(cur.node);

    if (currentGraphNode < n) {
      const start = nodeOffsets[currentGraphNode];
      const end = nodeOffsets[currentGraphNode + 1];
      for (let i = start; i < end; i += 1) {
        const to = edgeTargets[i];
        const ei = edgeUndirectedIndex[i];
        if (prevKind[cur.node] === 0 && prevData[cur.node] === ei) {
          if (rejected) rejected.immediateReverse += 1;
          continue;
        }
        if (v4HopIllegal(
          pack,
          ei,
          currentGraphNode,
          to,
          startEi,
          endEi,
          incomingUndirected(prevKind, prevData, virt, cur.node)
        )) {
          if (rejected) rejected.legalTurn += 1;
          continue;
        }
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (pack.graphBinaryVersion >= 4 ? !v4DirectionAllowed(pack, ei, currentGraphNode, to, policy.motorizedUnknown, startEi, endEi) : !accessAllowed(access, policy, enums)) {
          if (rejected) rejected.access += 1;
          continue;
        }
        if (avoid && avoid.has(pack.edgeId(ei))) {
          if (rejected) rejected.avoid += 1;
          continue;
        }
        const toLL = nodeLL(to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(cur.node)
        )) {
          if (rejected) rejected.geography += 1;
          continue;
        }
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) {
          if (rejected) rejected.progress += 1;
          continue;
        }
        const edgeM = edgeMeters[ei];
        const newMeters = pathMeters[cur.node] + edgeM;
        if (exceedsLengthSlack(newMeters, to, slackToDest, maxPathMeters)) {
          if (rejected) rejected.length += 1;
          continue;
        }
        const toState = stateForArrival(to, ei);
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        const structureCode = unpackStructure(attr);
        const isFerryEdge = isFerryStructureCode(structureCode);
        const leafBlock = !isFerryEdge && profile === "cleanest"
          ? cleanLeafBlocked(pack, ei, pavedOnly, startEi, endEi)
          : null;
        if (leafBlock === true) continue;
        if (
          !isFerryEdge &&
          leafBlock == null &&
          pavedOnly &&
          isBlockedForCleanPavement(surfaceName, road) &&
          ei !== startEi &&
          ei !== endEi
        ) continue;
        let step;
        if (isFerryEdge) {
          step = ferryStepForPackEdge(pack, ei, edgeM);
        } else if (costMode === "distance") {
          step = edgeM / 1000;
        } else if (costMode === "pavement") {
          // Earned-detour objective: Dirt still strongly prefers unpaved, but
          // every kilometre carries cost and off-line/backward motion is taxed.
          // Corridor width is an outer permission, never free space to consume.
          const edgeId = pack.edgeId(ei);
          step = (edgeM / 1000) * (
            shortDirtPenaltyEdgeIds.has(edgeId)
              ? DIRT_RIDE_PAVED_PER_KM
              : dirtRideCostPerKm(surfaceName, road, unpackConfidence(attr))
          );
          if (toLL) {
            step *= majorHighwayAvoidMult(
              profile,
              road,
              haversineMeters(toLL, startLL),
              haversineMeters(toLL, endLL),
              startOnMajorHighway,
              endOnMajorHighway,
              !pack.hasLeaves && e4Opts.avoidMotorways
            );
            step += awayExtra(cur.node, toState) * DIRT_RIDE_AWAY_SCALE;
            step += corridorCrossTrackExtra(profile, toLL, startLL, endLL, edgeM) * DIRT_RIDE_XT_SCALE;
          }
          step = applyE4LeafMult(
            pack, ei, step, toLL, startLL, endLL, startOnMajorHighway, endOnMajorHighway, e4Opts
          );
        } else if (profile === "cleanest" && pack.hasLeaves) {
          step = cleanLeafStepCost(
            pack, ei, edgeM, toLL, startLL, endLL, startOnMajorHighway, endOnMajorHighway, e4Opts
          );
          if (toLL && applyAwayXt) {
            step += awayExtra(cur.node, toState);
          }
        } else {
          step = (edgeM / 1000) * costView[surface] * roadClassMultiplier(road, profile);
          if (toLL) {
            step *= majorHighwayAvoidMult(
              profile,
              road,
              haversineMeters(toLL, startLL),
              haversineMeters(toLL, endLL),
              startOnMajorHighway,
              endOnMajorHighway,
              !pack.hasLeaves && e4Opts.avoidMotorways
            );
            step *= cleanCityStreetMult(profile, road, haversineMeters(toLL, endLL));
          } else {
            step *= majorHighwayAvoidMult(
              profile, road, 1e9, 1e9, false, false, !pack.hasLeaves && e4Opts.avoidMotorways
            );
          }
          if (policy.motorizedUnknown && profile !== "cleanest") {
            const accessName = enums.ACCESS_NAME[access] || "";
            if (accessName === "motorized_unknown") {
              if (profile === "dirt") step *= 0.5;
            }
            const id = pack.edgeId(ei);
            if (
              String(id).startsWith("ns-") ||
              String(id).startsWith("nb-fr") ||
              /nstdb|Topographic|Forest Roads/i.test(String(id))
            ) {
              if (profile === "dirt") step *= 0.68;
            }
          }
          if (applyAwayXt) {
            step += awayExtra(cur.node, toState);
            if (toLL && applySoftCorridor) {
              step += corridorCrossTrackExtra(profile, toLL, startLL, endLL, edgeM);
            }
          }
          step = applyE4LeafMult(
            pack, ei, step, toLL, startLL, endLL, startOnMajorHighway, endOnMajorHighway, e4Opts
          );
        }
        if (toLL) {
          step *= urbanCoreFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, urbanBoxes, nodeLL(cur.node), metroFallbackPenalty
          );
        }
        if (settlementFallback && toLL) {
          step *= settlementFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, settlementBoxes, settlementFallbackPenalty
          );
        }
        step = penalizeBacktrack(step, pack.edgeId(ei));
        if (!isFerryEdge && profile === "cleanest" && pack.hasLeaves && e4Opts.avoidMotorways) {
          const fromEi = predecessorGraphEdgeIndex(cur.node);
          if (fromEi >= 0) {
            const fromLeaves = pack.edgeLeaves(fromEi);
            const toLeaves = pack.edgeLeaves(ei);
            step += e4MajorHighwayEntryCost({
              fromTier: roadTierOf(fromLeaves.roadClassLeaf, pack.roadTierMap),
              toTier: roadTierOf(toLeaves.roadClassLeaf, pack.roadTierMap),
              enabled: true,
              metersFromStart: toLL ? haversineMeters(toLL, startLL) : 1e9,
              metersToDestination: toLL ? haversineMeters(toLL, endLL) : 1e9,
              startOnHighway: startOnMajorHighway,
              endOnHighway: endOnMajorHighway
            });
          }
        }
        const cost = curPathCost + step;
        const dirt = isDirtSurface(surfaceName, road);
        let action = considerRelax(
          cost,
          knownDistance(toState),
          ei,
          knownPreviousEdge(toState),
          toState,
          sessionSeed,
          varietyOn,
          slots[toState],
          dirt,
          false
        );
        if (action === "steal" && createsCycle(prev, cur.node, toState)) action = "reject";
        if (applyRelax(action, slots, toState)) {
          prev[toState] = cur.node;
          prevKind[toState] = 0;
          prevData[toState] = ei;
          prevForward[toState] = edgeFrom[ei] === currentGraphNode ? 1 : 0;
          if (shouldPush(action)) {
            if (seen) seen[toState] = 1;
            dist[toState] = cost;
            pathMeters[toState] = newMeters;
            peakProgress[toState] = newPeakProgress;
            heap.push({
              node: toState,
              cost: queuePriority(toState, cost),
              pathCost: cost
            });
          }
        }
      }
      // Zero-cost transfer onto coincident duplicate nodes.
      if (coincidentSiblings) {
        const sibs = coincidentSiblings[currentGraphNode];
        if (sibs) {
          for (let si = 0; si < sibs.length; si += 1) {
            const to = sibs[si];
            const cost = curPathCost;
            const newMeters = pathMeters[cur.node];
            const newPeakProgress = peakProgress[cur.node];
            let action = considerRelax(
              cost,
              knownDistance(to),
              -1,
              knownPreviousEdge(to),
              to,
              sessionSeed,
              false,
              slots[to],
              false,
              false
            );
            if (action === "steal" && createsCycle(prev, cur.node, to)) action = "reject";
            if (applyRelax(action, slots, to)) {
              prev[to] = cur.node;
              prevKind[to] = 2; // coincident stitch
              prevData[to] = -1;
              prevForward[to] = 1;
              if (shouldPush(action)) {
                if (seen) seen[to] = 1;
                dist[to] = cost;
                pathMeters[to] = newMeters;
                peakProgress[to] = newPeakProgress;
                heap.push({
                  node: to,
                  cost: queuePriority(to, cost),
                  pathCost: cost
                });
              }
            }
          }
        }
      }
    }

    const vlist = virtAdj.get(currentGraphNode);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        const toState = item.to < n ? stateForArrival(item.to, v.ei) : item.to;
        const toLL = nodeLL(item.to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(cur.node)
        )) continue;
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) continue;
        const newMeters = pathMeters[cur.node] + v.meters;
        if (exceedsLengthSlack(newMeters, item.to, slackToDest, maxPathMeters)) continue;
        const vAttr = edgeAttrs[v.ei];
        const vSurface = unpackSurface(vAttr);
        const vRoad = ROAD_CLASS_NAME[unpackRoadClass(vAttr)] || "unknown";
        const vSurfaceName = enums.SURFACE_NAME[vSurface] || "unknown";
        const vStructure = unpackStructure(vAttr);
        const isFerryVirt = isFerryStructureCode(vStructure);
        const vLeafBlock = !isFerryVirt && profile === "cleanest"
          ? cleanLeafBlocked(pack, v.ei, pavedOnly, startEi, endEi)
          : null;
        if (vLeafBlock === true) continue;
        if (
          !isFerryVirt &&
          vLeafBlock == null &&
          pavedOnly &&
          isBlockedForCleanPavement(vSurfaceName, vRoad) &&
          v.ei !== startEi &&
          v.ei !== endEi
        ) continue;
        let step;
        if (isFerryVirt) {
          step = ferryStepForPackEdge(pack, v.ei, v.meters);
        } else if (costMode === "pavement") {
          const edgeId = pack.edgeId(v.ei);
          step = (v.meters / 1000) * (
            shortDirtPenaltyEdgeIds.has(edgeId)
              ? DIRT_RIDE_PAVED_PER_KM
              : dirtRideCostPerKm(vSurfaceName, vRoad, unpackConfidence(vAttr))
          );
        } else if (profile === "cleanest" && pack.hasLeaves) {
          step = cleanLeafStepCost(
            pack, v.ei, v.meters, toLL, startLL, endLL, startOnMajorHighway, endOnMajorHighway, e4Opts
          );
        } else {
          step = v.meters / 1000;
          step = applyE4LeafMult(
            pack, v.ei, step, toLL, startLL, endLL, startOnMajorHighway, endOnMajorHighway, e4Opts
          );
        }
        if (costMode === "pavement") {
          step += awayExtra(cur.node, toState) * DIRT_RIDE_AWAY_SCALE;
          if (toLL) {
            step += corridorCrossTrackExtra(profile, toLL, startLL, endLL, v.meters) * DIRT_RIDE_XT_SCALE;
          }
        } else if (applyAwayXt) {
          step += awayExtra(cur.node, toState);
        }
        if (toLL) {
          step *= urbanCoreFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, urbanBoxes, nodeLL(cur.node), metroFallbackPenalty
          );
        }
        if (settlementFallback && toLL) {
          step *= settlementFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, settlementBoxes, settlementFallbackPenalty
          );
        }
        step = penalizeBacktrack(step, pack.edgeId(v.ei));
        const cost = curPathCost + step;
        let action = considerRelax(
          cost,
          knownDistance(toState),
          v.ei,
          knownPreviousEdge(toState),
          toState,
          sessionSeed,
          varietyOn,
          slots[toState],
          false,
          false
        );
        if (action === "steal" && createsCycle(prev, cur.node, toState)) action = "reject";
        if (applyRelax(action, slots, toState)) {
          prev[toState] = cur.node;
          prevKind[toState] = 1;
          prevData[toState] = item.id;
          prevForward[toState] = item.forward ? 1 : 0;
          if (shouldPush(action)) {
            if (seen) seen[toState] = 1;
            dist[toState] = cost;
            pathMeters[toState] = newMeters;
            peakProgress[toState] = newPeakProgress;
            heap.push({
              node: toState,
              cost: queuePriority(toState, cost),
              pathCost: cost
            });
          }
        }
      }
    }
  }

  if (!Number.isFinite(knownDistance(endNode))) {
    if (searchOpts.diagnostics) {
      searchOpts.diagnostics.outcome = abort === "completed" ? "noPath" : abort;
      searchOpts.diagnostics.pops = pops;
    }
    return null;
  }

  const used = [];
  let hops = 0;
  for (let node = endNode; node !== startNode; ) {
    hops += 1;
    if (hops > total + 4) return null;
    const parent = prev[node];
    if (parent < 0) return null;
    if (prevKind[node] === 1) {
      const v = virt[prevData[node]];
      const forward = prevForward[node] === 1;
      used.push(
        withSurfaceLeaf(
          {
            coords: forward ? v.coords : v.coords.slice().reverse(),
            meters: v.meters,
            surface: unpackSurface(edgeAttrs[v.ei]),
            access: unpackAccess(edgeAttrs[v.ei]),
            structure: unpackStructure(edgeAttrs[v.ei]),
            roadClass: ROAD_CLASS_NAME[unpackRoadClass(edgeAttrs[v.ei])] || "unknown",
            edgeId: pack.edgeId(v.ei),
            accessLeg: v.accessLeg,
            confidence: unpackConfidence(edgeAttrs[v.ei]),
            seasonal: unpackSeasonal(edgeAttrs[v.ei])
          },
          pack,
          v.ei
        )
      );
    } else if (prevKind[node] === 2) {
      // Coincident duplicate-node stitch — no geometry.
    } else {
      const ei = prevData[node];
      const forward = prevForward[node] === 1;
      used.push(
        withSurfaceLeaf(
          {
            coords: geom.polylineMaybeReversed(ei, forward),
            meters: edgeMeters[ei],
            surface: unpackSurface(edgeAttrs[ei]),
            access: unpackAccess(edgeAttrs[ei]),
            structure: unpackStructure(edgeAttrs[ei]),
            roadClass: ROAD_CLASS_NAME[unpackRoadClass(edgeAttrs[ei])] || "unknown",
            edgeId: pack.edgeId(ei),
            accessLeg: false,
            confidence: unpackConfidence(edgeAttrs[ei]),
            seasonal: unpackSeasonal(edgeAttrs[ei])
          },
          pack,
          ei
        )
      );
    }
    node = parent;
  }
  used.reverse();
  // All profiles: remove geographic loops / out-and-backs after search.
  const pruned = pruneGeographicLoops(used, (edge) => edge.coords);
  const routeEdges = pruned.edges;

  const geometry = [];
  const segments = [];
  let distanceMeters = 0;
  let unknownAccessMeters = 0;
  let movingSeconds = 0;
  let profileCost = 0;
  let dirtMeters = 0;
  let pavedMeters = 0;
  let surfaceDistanceMeters = 0;
  const bySurfaceM = { paved: 0, gravel: 0, access: 0, track: 0, unknown: 0, single: 0 };
  const byAccessM = {
    motorized_verified: 0,
    motorized_permissive: 0,
    motorized_unknown: 0
  };

  for (const edge of routeEdges) {
    for (const c of edge.coords) {
      const last = geometry[geometry.length - 1];
      if (last && last[0] === c[0] && last[1] === c[1]) continue;
      geometry.push(c);
    }
    distanceMeters += edge.meters;
    const isFerry = isFerryStructureCode(edge.structure);
    const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
    const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
    if (!isFerry) {
      surfaceDistanceMeters += edge.meters;
      bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + edge.meters;
      if (isDirtSurface(surfaceName, edge.roadClass)) dirtMeters += edge.meters;
      else pavedMeters += edge.meters;
      if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
      if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
      movingSeconds += (edge.meters / 1000) / classSpeedKmh(edge.surface) * 3600;
    } else {
      movingSeconds += ferrySecondsForPackEdge(pack, edge.undirectedEdgeIndex, edge.meters);
    }
    const mult = edge.accessLeg ? 1 : surfaceMultiplier(edge.surface, profile, regionId);
    profileCost += isFerry
      ? ferryStepForPackEdge(pack, edge.undirectedEdgeIndex, edge.meters)
      : (edge.meters / 1000) * mult;
    const structFields = segmentStructureFields({
      structureCode: edge.structure,
      structureLeaf: edge.structureLeaf,
      layer: edge.layer
    });
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
      trackClass: edge.roadClass,
      structureType: enums.STRUCTURE_NAME[edge.structure] || "none",
      accessClass: accessName,
      surfaceLeaf: edge.surfaceLeaf != null ? edge.surfaceLeaf : null,
      structureLeaf: structFields.structureLeaf,
      layer: structFields.layer,
      crossingLabel: structFields.crossingLabel,
      waterCrossing: structFields.waterCrossing,
      source: null,
      sourceRecordId: null,
      sourceDescription: null,
      confidence: edge.confidence,
      seasonal: !!edge.seasonal,
      distanceMeters: Math.round(edge.meters),
      componentId: -1,
      accessLeg: !!edge.accessLeg,
      geometry: edge.coords
    });
  }

  const pct = (m) => (surfaceDistanceMeters > 0 ? Math.round((m / surfaceDistanceMeters) * 100) : 0);
  const settlementCrossingUsed = settlementFallback && geometry.some((point) =>
    settlementBlocks(point[0], point[1], startLL, endLL, settlementBoxes)
  );
  const csrResult = {
    geometry,
    segments,
    distanceMeters,
    unknownAccessMeters,
    movingSeconds,
    profileCost: dist[endNode],
    searchMeta: {
      bidir: false,
      packFormat: pack.hasLeaves ? "v3" : "v2",
      ellipseFactor: Infinity,
      ellipseLabel: "csr-uni",
      ellipseEscalation: "v2_uni",
      profileCost: dist[endNode],
      prunedLoopCount: pruned.prunedLoopCount,
      prunedLoopMeters: Math.round(pruned.prunedMeters),
      pops,
      timedOut: abort === "timeCap" || abort === "popCap",
      pass2Outcome: abort,
      searchAlgorithm: distanceAStar ? "astar-distance" : "dijkstra-profile",
      settlementFallbackUsed: settlementCrossingUsed
    },
    // Coarse dirt% kept for Balanced mix selection; honest overlay applied after pick.
    stats: {
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
    }
  };
  return annotateCorridorMeta(
    csrResult,
    startLL,
    endLL,
    profile,
    Number(searchOpts.shortestMeters)
  );
}

function searchBalancedResource(ctx) {
  const {
    pack,
    geom,
    enums,
    n,
    startNode,
    endNode,
    virt,
    virtAdj,
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeMeters,
    edgeFrom,
    startLL,
    endLL,
    startEi = -1,
    endEi = -1,
    policy,
    avoid,
    profile,
    sessionSeed,
    maxPathMeters,
    shortestMeters,
    cityWall,
    urbanBoxes,
    settlementWall,
    settlementFallback,
    settlementBoxes,
    corridorM,
    varietyOn,
    slackToDest,
    boundedSearch,
    diagnostics,
    hardCorridor,
    progressRegressionMeters,
    timeCapMs,
    deadlineAtMs,
    abortSignal,
    popCap: requestedPopCap,
    prior,
    arrival,
    backtrackFactor,
    cleanMetroMultiplier,
    avoidMotorways,
    coincidentSiblings,
    shortDirtPenaltyEdgeIds,
    turnState
  } = ctx;
  const metroFallbackPenalty =
    resolveMetroFallbackPenalty(profile, cleanMetroMultiplier, avoidMotorways === true);
  const settlementFallbackPenalty = resolveSettlementFallbackPenalty(
    profile, cleanMetroMultiplier, avoidMotorways === true
  );
  const penalizeBacktrack = (cost, edgeId) => {
    const id = String(edgeId == null ? "" : edgeId);
    if (arrival != null && id === arrival) return cost * 12;
    if (prior && prior.has(id)) return cost * backtrackFactor;
    return cost;
  };
  const B = BALANCED_BUCKETS;
  const stateCount = turnState ? turnState.stateCount : n + 2;
  const graphNodeOf = turnState ? turnState.graphNodeOf : (state) => state;
  const stateForArrival = turnState ? turnState.stateForArrival : (node) => node;
  const labels = stateCount * B;
  const lab = (node, b) => node * B + b;
  const nid = (label) => Math.floor(label / B);
  const dist = new Float64Array(labels);
  dist.fill(Infinity);
  const score = new Float64Array(labels);
  score.fill(Infinity);
  const dirtAt = new Float64Array(labels);
  const peakProgress = new Float64Array(labels);
  peakProgress.fill(-Infinity);
  const prev = new Int32Array(labels);
  prev.fill(-1);
  const prevKind = new Uint8Array(labels);
  const prevData = new Int32Array(labels);
  const prevForward = new Uint8Array(labels);
  const slots = new Uint8Array(labels);
  const heap = new MinHeap();
  const startLab = lab(startNode, 0);
  dist[startLab] = 0;
  score[startLab] = 0;
  peakProgress[startLab] = 0;
  heap.push({ node: startLab, g: 0, searchCost: 0, cost: haversineMeters(startLL, endLL) });
  const regressionLimit = Number.isFinite(Number(progressRegressionMeters))
    ? Number(progressRegressionMeters)
    : maxProgressRegressionMeters(profile);
  let pops = 0;
  let abort = "completed";
  const rejected = diagnostics ? {
    immediateReverse: 0,
    legalTurn: 0,
    access: 0,
    avoid: 0,
    geography: 0,
    progress: 0,
    length: 0
  } : null;
  const isHunt = Number.isFinite(maxPathMeters);
  const absoluteDeadline = Number(deadlineAtMs);
  const hasAbsoluteDeadline = Number.isFinite(absoluteDeadline);
  const cappedSearch = isHunt || boundedSearch === true || hasAbsoluteDeadline;
  // Balanced carries a surface-ratio label set, so it legitimately needs more
  // expansions than the single-label Dirt searches. The time deadline
  // remains the ultimate guardrail.
  const popCap = cappedSearch
    ? (Number.isFinite(Number(requestedPopCap)) ? Number(requestedPopCap) : PASS2_POP_CAP * 10)
    : 8_000_000;
  const localDeadline = cappedSearch
    ? Date.now() + (Number.isFinite(Number(timeCapMs)) ? Number(timeCapMs) : PASS2_TIME_MS)
    : Infinity;
  const deadline = Math.min(
    localDeadline,
    hasAbsoluteDeadline ? absoluteDeadline : Infinity
  );

  function nodeLL(node) {
    if (node === startNode) return startLL;
    if (node === endNode) return endLL;
    const graphNode = graphNodeOf(node);
    if (graphNode >= 0 && graphNode < n && ctx.nodeCoords) {
      return [ctx.nodeCoords[graphNode * 2], ctx.nodeCoords[graphNode * 2 + 1]];
    }
    return null;
  }

  const abMeters = haversineMeters(startLL, endLL);
  function awayExtra(fromNode, toNode) {
    const a = nodeLL(fromNode);
    const b = nodeLL(toNode);
    if (!a || !b) return 0;
    return approachAwayExtraCost(
      profile,
      haversineMeters(a, endLL),
      haversineMeters(b, endLL),
      abMeters,
      50
    );
  }

  while (heap.items.length) {
    pops += 1;
    if (pops > popCap) {
      abort = "popCap";
      break;
    }
    if ((pops & 255) === 0 && (
      (abortSignal && abortSignal.aborted) ||
      (Number.isFinite(deadline) && Date.now() >= deadline)
    )) {
      abort = abortSignal && abortSignal.aborted ? "cancelled" : "timeCap";
      break;
    }
    const cur = heap.pop();
    if (!cur || cur.g !== dist[cur.node] || cur.searchCost !== score[cur.node]) continue;
    if (cur.g > maxPathMeters) continue;
    const state = nid(cur.node);
    const node = graphNodeOf(state);
    const dirtSoFar = dirtAt[cur.node];
    if (state === endNode) {
      const ratio = cur.g > 0 ? dirtSoFar / cur.g : 0;
      // Half a percentage point is visually and practically 50/50. Once A*
      // settles such a destination label, further expansion can only buy a
      // cosmetically smaller deviation at the cost of a much larger search.
      if (Math.abs(ratio - 0.5) <= 0.005) break;
      continue;
    }
    if (node < n) {
      const start = nodeOffsets[node];
      const end = nodeOffsets[node + 1];
      for (let i = start; i < end; i += 1) {
        const to = edgeTargets[i];
        const ei = edgeUndirectedIndex[i];
        if (prevKind[cur.node] === 0 && prevData[cur.node] === ei) {
          if (rejected) rejected.immediateReverse += 1;
          continue;
        }
        if (v4HopIllegal(
          pack,
          ei,
          node,
          to,
          startEi,
          endEi,
          incomingUndirected(prevKind, prevData, virt, cur.node)
        )) {
          if (rejected) rejected.legalTurn += 1;
          continue;
        }
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (pack.graphBinaryVersion >= 4 ? !v4DirectionAllowed(pack, ei, node, to, policy.motorizedUnknown, startEi, endEi) : !accessAllowed(access, policy, enums)) {
          if (rejected) rejected.access += 1;
          continue;
        }
        if (avoid && avoid.has(pack.edgeId(ei))) {
          if (rejected) rejected.avoid += 1;
          continue;
        }
        const toLL = nodeLL(to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(node)
        )) {
          if (rejected) rejected.geography += 1;
          continue;
        }
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) {
          if (rejected) rejected.progress += 1;
          continue;
        }
        const edgeM = edgeMeters[ei];
        const newMeters = cur.g + edgeM;
        if (exceedsLengthSlack(newMeters, to, slackToDest, maxPathMeters)) {
          if (rejected) rejected.length += 1;
          continue;
        }
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        const structureCode = unpackStructure(attr);
        const isFerryEdge = isFerryStructureCode(structureCode);
        const edgeId = pack.edgeId(ei);
        const shortDirtPenalized = profile === "dirt" && shortDirtPenaltyEdgeIds.has(edgeId);
        const addDirt = !isFerryEdge && !shortDirtPenalized && isDirtSurface(surfaceName, road)
          ? edgeM
          : 0;
        const newDirt = dirtSoFar + addDirt;
        const b = dirtBucket(newDirt, newMeters);
        const toState = stateForArrival(to, ei);
        const toLab = lab(toState, b);
        const settlementMult = settlementFallback && toLL
          ? settlementFallbackMultiplier(
              toLL[0], toLL[1], startLL, endLL, settlementBoxes, settlementFallbackPenalty
            )
          : 1;
        const urbanMult = toLL
          ? urbanCoreFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, urbanBoxes, nodeLL(node), metroFallbackPenalty
          )
          : 1;
        let edgeBase = isFerryEdge
          ? ferryStepForPackEdge(pack, ei, edgeM)
          : edgeM * settlementMult * urbanMult;
        if (shortDirtPenalized) edgeBase *= DIRT_RIDE_PAVED_PER_KM;
        const newScore = cur.searchCost
          + penalizeBacktrack(
            edgeBase + awayExtra(node, to),
            edgeId
          );
        let action = considerRelax(
          newScore,
          score[toLab],
          ei,
          prevData[toLab],
          to,
          sessionSeed,
          varietyOn,
          slots[toLab],
          addDirt > 0,
          dirtAt[toLab] > (Number.isFinite(dist[toLab]) ? dist[toLab] * 0.4 : 0)
        );
        if (action === "steal" && createsCycle(prev, cur.node, toLab)) action = "reject";
        if (applyRelax(action, slots, toLab)) {
          prev[toLab] = cur.node;
          prevKind[toLab] = 0;
          prevData[toLab] = ei;
          prevForward[toLab] = edgeFrom[ei] === node ? 1 : 0;
          if (shouldPush(action)) {
            dist[toLab] = newMeters;
            score[toLab] = newScore;
            dirtAt[toLab] = newDirt;
            peakProgress[toLab] = newPeakProgress;
            const h = toLL ? haversineMeters(toLL, endLL) : 0;
            heap.push({ node: toLab, g: newMeters, searchCost: newScore, cost: newScore + h });
          }
        }
      }
      const siblings = coincidentSiblings && coincidentSiblings[node];
      if (siblings) {
        for (let si = 0; si < siblings.length; si += 1) {
          const to = siblings[si];
          const toLL = nodeLL(to);
          const toProgress = projectedProgressMeters(toLL, startLL, endLL);
          const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
          if (newPeakProgress - toProgress > regressionLimit) continue;
          const toState = stateForArrival(to, -1);
          const toLab = lab(toState, dirtBucket(dirtSoFar, cur.g));
          if (cur.searchCost < score[toLab]) {
            dist[toLab] = cur.g;
            score[toLab] = cur.searchCost;
            dirtAt[toLab] = dirtSoFar;
            peakProgress[toLab] = newPeakProgress;
            prev[toLab] = cur.node;
            prevKind[toLab] = 2;
            prevData[toLab] = -1;
            prevForward[toLab] = 1;
            const h = toLL ? haversineMeters(toLL, endLL) : 0;
            heap.push({
              node: toLab,
              g: cur.g,
              searchCost: cur.searchCost,
              cost: cur.searchCost + h
            });
          }
        }
      }
    }
    const vlist = virtAdj.get(node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        const toLL = nodeLL(item.to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(node)
        )) continue;
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) continue;
        const newMeters = cur.g + v.meters;
        if (exceedsLengthSlack(newMeters, item.to, slackToDest, maxPathMeters)) continue;
        const b = dirtBucket(dirtSoFar, newMeters);
        const toState = item.to < n ? stateForArrival(item.to, v.ei) : item.to;
        const toLab = lab(toState, b);
        const settlementMult = settlementFallback && toLL
          ? settlementFallbackMultiplier(
              toLL[0], toLL[1], startLL, endLL, settlementBoxes, settlementFallbackPenalty
            )
          : 1;
        const urbanMult = toLL
          ? urbanCoreFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, urbanBoxes, nodeLL(node), metroFallbackPenalty
          )
          : 1;
        const newScore = cur.searchCost
          + penalizeBacktrack(
            v.meters * settlementMult * urbanMult + awayExtra(node, item.to),
            pack.edgeId(v.ei)
          );
        if (newScore < score[toLab]) {
          dist[toLab] = newMeters;
          score[toLab] = newScore;
          dirtAt[toLab] = dirtSoFar;
          peakProgress[toLab] = newPeakProgress;
          prev[toLab] = cur.node;
          prevKind[toLab] = 1;
          prevData[toLab] = item.id;
          prevForward[toLab] = item.forward ? 1 : 0;
          const h = toLL ? haversineMeters(toLL, endLL) : 0;
          heap.push({ node: toLab, g: newMeters, searchCost: newScore, cost: newScore + h });
        }
      }
    }
  }

  const cands = [];
  for (let b = 0; b < B; b += 1) {
    const endLab = lab(endNode, b);
    const len = dist[endLab];
    if (!Number.isFinite(len) || len <= 0) continue;
    cands.push({ lab: endLab, len, dirt: dirtAt[endLab], score: score[endLab] });
  }
  if (!cands.length) {
    if (diagnostics) {
      diagnostics.outcome = abort === "completed" ? "noPath" : abort;
      diagnostics.pops = pops;
      diagnostics.rejections = rejected;
    }
    return null;
  }

  function materializeCandidate(candidate) {
    const used = [];
    let hops = 0;
    for (let label = candidate.lab; nid(label) !== startNode; ) {
      hops += 1;
      if (hops > labels + 4) return null;
      const parent = prev[label];
      if (parent < 0) return null;
      if (prevKind[label] === 1) {
        const v = virt[prevData[label]];
        const forward = prevForward[label] === 1;
        used.push(
          withSurfaceLeaf(
            {
              coords: forward ? v.coords : v.coords.slice().reverse(),
              meters: v.meters,
              surface: unpackSurface(edgeAttrs[v.ei]),
              access: unpackAccess(edgeAttrs[v.ei]),
              structure: unpackStructure(edgeAttrs[v.ei]),
              roadClass: ROAD_CLASS_NAME[unpackRoadClass(edgeAttrs[v.ei])] || "unknown",
              edgeId: pack.edgeId(v.ei),
              accessLeg: v.accessLeg,
              confidence: unpackConfidence(edgeAttrs[v.ei]),
              seasonal: unpackSeasonal(edgeAttrs[v.ei])
            },
            pack,
            v.ei
          )
        );
      } else if (prevKind[label] === 2) {
        // Coincident duplicate-node stitch — no geometry.
      } else {
        const ei = prevData[label];
        const forward = prevForward[label] === 1;
        used.push(
          withSurfaceLeaf(
            {
              coords: geom.polylineMaybeReversed(ei, forward),
              meters: edgeMeters[ei],
              surface: unpackSurface(edgeAttrs[ei]),
              access: unpackAccess(edgeAttrs[ei]),
              structure: unpackStructure(edgeAttrs[ei]),
              roadClass: ROAD_CLASS_NAME[unpackRoadClass(edgeAttrs[ei])] || "unknown",
              edgeId: pack.edgeId(ei),
              accessLeg: false,
              confidence: unpackConfidence(edgeAttrs[ei]),
              seasonal: unpackSeasonal(edgeAttrs[ei])
            },
            pack,
            ei
          )
        );
      }
      label = parent;
    }
    used.reverse();
    const pruned = pruneGeographicLoops(used, (edge) => edge.coords);
    const meters = pruned.edges.reduce((sum, edge) => sum + edge.meters, 0);
    const dirt = pruned.edges.reduce((sum, edge) => {
      if (isFerryStructureCode(edge.structure)) return sum;
      const surface = enums.SURFACE_NAME[edge.surface] || "unknown";
      return sum + (isDirtSurface(surface, edge.roadClass) ? edge.meters : 0);
    }, 0);
    return { candidate, pruned, dirtPercent: meters > 0 ? dirt / meters * 100 : 0, meters };
  }
  const materialized = cands.map(materializeCandidate).filter(Boolean);
  materialized.sort((a, b) => {
    if (profile === "dirt") {
      const dirtDelta = b.dirtPercent - a.dirtPercent;
      if (Math.abs(dirtDelta) > 0.1) return dirtDelta;
      const pavedA = a.meters * Math.max(0, 100 - a.dirtPercent) / 100;
      const pavedB = b.meters * Math.max(0, 100 - b.dirtPercent) / 100;
      if (Math.abs(pavedA - pavedB) > 50) return pavedA - pavedB;
    } else {
      const miss = Math.abs(a.dirtPercent - 50) - Math.abs(b.dirtPercent - 50);
      if (Math.abs(miss) > 0.1) return miss;
    }
    if (Math.abs(a.candidate.score - b.candidate.score) > 50) {
      return a.candidate.score - b.candidate.score;
    }
    return a.meters - b.meters;
  });
  const selected = materialized[0];
  if (!selected) return null;
  const bestLab = selected.candidate.lab;
  const pruned = selected.pruned;
  const routeEdges = pruned.edges;
  const geometry = [];
  const segments = [];
  let distanceMeters = 0;
  let unknownAccessMeters = 0;
  let movingSeconds = 0;
  let dirtMeters = 0;
  let pavedMeters = 0;
  let surfaceDistanceMeters = 0;
  const bySurfaceM = { paved: 0, gravel: 0, access: 0, track: 0, unknown: 0, single: 0 };
  const byAccessM = {
    motorized_verified: 0,
    motorized_permissive: 0,
    motorized_unknown: 0
  };
  for (const edge of routeEdges) {
    for (const c of edge.coords) {
      const last = geometry[geometry.length - 1];
      if (last && last[0] === c[0] && last[1] === c[1]) continue;
      geometry.push(c);
    }
    distanceMeters += edge.meters;
    const isFerry = isFerryStructureCode(edge.structure);
    const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
    const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
    if (!isFerry) {
      surfaceDistanceMeters += edge.meters;
      bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + edge.meters;
      if (isDirtSurface(surfaceName, edge.roadClass)) dirtMeters += edge.meters;
      else pavedMeters += edge.meters;
      if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
      if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
      movingSeconds += ((edge.meters / 1000) / classSpeedKmh(edge.surface)) * 3600;
    } else {
      movingSeconds += ferrySecondsForPackEdge(pack, edge.undirectedEdgeIndex, edge.meters);
    }
    const structFields = segmentStructureFields({
      structureCode: edge.structure,
      structureLeaf: edge.structureLeaf,
      layer: edge.layer
    });
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
      trackClass: edge.roadClass,
      structureType: enums.STRUCTURE_NAME[edge.structure] || "none",
      accessClass: accessName,
      surfaceLeaf: edge.surfaceLeaf != null ? edge.surfaceLeaf : null,
      structureLeaf: structFields.structureLeaf,
      layer: structFields.layer,
      crossingLabel: structFields.crossingLabel,
      waterCrossing: structFields.waterCrossing,
      source: null,
      sourceRecordId: null,
      sourceDescription: null,
      confidence: edge.confidence,
      seasonal: !!edge.seasonal,
      distanceMeters: Math.round(edge.meters),
      componentId: -1,
      accessLeg: !!edge.accessLeg,
      geometry: edge.coords
    });
  }
  const pct = (m) => (surfaceDistanceMeters > 0 ? Math.round((m / surfaceDistanceMeters) * 100) : 0);
  const settlementCrossingUsed = ctx.settlementFallback && geometry.some((point) =>
    settlementBlocks(point[0], point[1], startLL, endLL, settlementBoxes)
  );
  const mixResult = {
    geometry,
    segments,
    distanceMeters,
    unknownAccessMeters,
    movingSeconds,
    profileCost: score[bestLab],
    searchMeta: {
      bidir: false,
      packFormat: pack.hasLeaves ? "v3" : "v2",
      ellipseFactor: Infinity,
      ellipseLabel: "balanced-resource",
      balancedResource: profile === "balanced",
      dirtResource: profile === "dirt",
      dirtPercent: pct(dirtMeters),
      balancedCandidateBuckets: cands.map((candidate) => ({
        dirtPercent: Math.round(candidate.dirt / candidate.len * 1000) / 10,
        distanceMeters: Math.round(candidate.len)
      })),
      prunedLoopCount: pruned.prunedLoopCount,
      prunedLoopMeters: Math.round(pruned.prunedMeters),
      pops,
      timedOut: abort === "timeCap" || abort === "popCap",
      pass2Outcome: abort,
      settlementFallbackUsed: settlementCrossingUsed,
      balancedMiss: profile === "balanced" ? Math.abs(pct(dirtMeters) - 50) : null
    },
    // Coarse dirt% for candidate pick; honest overlay after path selection.
    stats: {
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
    }
  };
  return annotateCorridorMeta(mixResult, startLL, endLL, profile);
}

/** Phase E1: rewrite reported Dirt%/paved%/unknownSurface% from surfaceLeaf after path pick. */
function applyHonestReportedStats(path) {
  if (!path || !path.stats || !Array.isArray(path.segments)) return path;
  const hasLeaf = path.segments.some((s) => Object.prototype.hasOwnProperty.call(s, "surfaceLeaf"));
  if (!hasLeaf) return path;
  const rows = path.segments
    .filter((s) => s.structureType !== "ferry")
    .map((s) => ({
      meters: s.distanceMeters,
      surfaceLeaf: s.surfaceLeaf
    }));
  const surfaceMeters = rows.reduce((sum, row) => sum + (Number(row.meters) || 0), 0);
  path.stats = applyHonestSurfaceStats(path.stats, rows, surfaceMeters, true);
  return path;
}

module.exports = {
  findPathV2,
  chooseDirtRideCandidate,
  dirtCandidateSummary,
  shortDirtExcursionEdgeIds,
  MINIMUM_EARNED_DIRT_EXCURSION_METERS,
  DIRT_BASE_SEARCH_BUDGET_MS,
  DIRT_MAX_SEARCH_BUDGET_MS,
  BALANCED_BASE_SEARCH_BUDGET_MS,
  BALANCED_MAX_SEARCH_BUDGET_MS,
  LARGE_GRAPH_BASE_SEARCH_BUDGET_MS,
  CLEAN_BASE_SEARCH_BUDGET_MS,
  CLEAN_MAX_SEARCH_BUDGET_MS,
  BALANCED_LONG_ROUTE_METERS,
  BALANCED_LARGE_GRAPH_NODES,
  PROVINCE_SCALE_GRAPH_NODES,
  DIRT_RECOVERY_EXTRA_METERS,
  DIRT_RECOVERY_DISTANCE_RATIO,
  balancedSearchBudgetMs,
  profileSearchBudgetMs,
  profileSearchPopCap,
  urbanBoxesForPack,
  dirtRecoveryPathCap,
  balancedCorridorMultipliers,
  applyHonestReportedStats
};
