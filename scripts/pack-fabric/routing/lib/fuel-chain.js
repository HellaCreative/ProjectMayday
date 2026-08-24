"use strict";

/**
 * Fuel planning is a forward graph operation, not a repair pass over an
 * already-generated ride. One bounded Dijkstra discovers every pump reachable
 * on the eligible road fabric from the current point. The planner commits the
 * best forward pump, repeats from there, and stops as soon as point 2 is
 * graph-reachable within the remaining tank.
 *
 * This deliberately does not call /api/route for each candidate. The caller
 * routes only the selected point 1 -> F1 -> ... -> point 2 legs.
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
const MIN_FORWARD_PROGRESS_M = 2_500;
/** Bumped when fuel-selection / ranking contracts change. Clients may assert. */
const FUEL_CHAIN_SERVICE_VERSION = "2026-08-23.fuel-coherence.4";
/** Clean rejects pumps whose full chain exceeds foundation by this much. */
const MAX_CLEAN_CHAIN_DETOUR_RATIO = 1.12;
const MAX_CLEAN_CHAIN_DETOUR_ABS_M = 20_000;
/** Soft corridor half-width; beyond this, cross-track dominates clean ranking. */
const CORRIDOR_SOFT_WIDTH_M = 25_000;
const SHORTLIST_MIN_SEPARATION_M = 15_000;

function fuelNeedForProfileRide(profileMeters, firstLegMaxMeters, usableRangeMeters) {
  const meters = Number(profileMeters);
  const firstCap = Number(firstLegMaxMeters);
  const usable = Number(usableRangeMeters);
  if (!(meters >= 0) || !(firstCap >= 0) || !(usable > 0)) return null;
  if (meters <= firstCap + 1) return 0;
  return Math.ceil((meters - firstCap) / usable);
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

function stationLocation(station) {
  return {
    lat: Number(station.lat),
    lon: Number(station.lon),
    label: station.name || station.brand || "Fuel"
  };
}

function prepareTargets(runtime, stations, destination, policy, profile, avoid) {
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
  const fuelTargets = [];
  for (const station of stations || []) {
    const location = stationLocation(station);
    if (!Number.isFinite(location.lat) || !Number.isFinite(location.lon)) continue;
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
    if (!match.ok) continue;
    const surface = edgeView(runtime, match.edgeIndex).surface;
    fuelTargets.push({
      station,
      location,
      match,
      dirtAdjacent: surface !== "paved" && surface !== "unknown"
    });
  }
  return { destinationMatch, fuelTargets };
}

function fuelPlanningSpan(profile) {
  switch (resolveProfile(profile)) {
    case "dirt": return 0.78;
    case "balanced": return 0.84;
    case "cleanest": return 0.95;
    default: return 0.84;
  }
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
    && remainingMeters >= MIN_STOP_SEPARATION_M
    && progressMeters >= MIN_FORWARD_PROGRESS_M
    && gainMeters >= -5_000;
  // A pump is an anchor on the journey, not permission to take a large
  // sideways loop merely to consume the tank. This applies to every profile;
  // Dirt may meander between anchors, but the anchor itself must advance the
  // itinerary unless the explicit near-start recovery below is required.
  if (
    forward &&
    crossTrack > 50_000 &&
    crossTrack > progressMeters * 0.75 &&
    progressMeters < currentRemaining * 0.75
  ) {
    forward = false;
  }
  if (
    forward &&
    progressMeters < Math.max(10_000, currentRemaining * 0.18) &&
    crossTrack > 25_000
  ) {
    forward = false;
  }
  // Clean: reject needless lateral excursions whose full P1→pump→P2
  // chain is dominated by the foundation ride. Score alone was letting a
  // Wallace-class pump win because it used nearly the whole tank.
  const profileKey = resolveProfile(profile);
  if (forward && profileKey === "cleanest") {
    const directMeters = Number(destinationGraphMeters);
    const remainingGraph = Number(row.remainingGraphMeters);
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
  allowNearStartRecovery = false
) {
  const current = locationCoordinate(currentLocation);
  const destination = locationCoordinate(destinationLocation);
  // The tank is a hard ceiling, not the desired shortest-network spacing.
  // Adventure profiles need physical-distance headroom so the final Dirt or
  // Balanced leg can spend that room on eligible unpaved roads.
  const span = fuelPlanningSpan(profile);
  const preferredMax = capMeters * span;
  const targetUse = preferredMax * 0.94;

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
      const tankWeight = profileKey === "cleanest" ? 0.04 : 0.12;
      // Progress/coherence first. Tank use is secondary for Clean so a
      // full-tank lateral excursion cannot outrank a shorter corridor pump.
      const score =
        progress * 1.0 +
        gain * 0.45 -
        crossTrack * crossTrackWeight -
        Math.abs(row.graphMeters - targetUse) * tankWeight +
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
  const preferred = forward.filter((row) => row.graphMeters <= preferredMax);
  const overflow = forward.filter((row) => row.graphMeters > preferredMax);
  const normal = preferred
    .sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters)
    .concat(overflow.sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters));
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
    const exact = normal.filter((row) => Number.isFinite(row.remainingGraphMeters));
    const withinArrival = Number.isFinite(arrivalLimit)
      ? exact.filter((row) => row.remainingGraphMeters <= arrivalLimit + 1)
      : exact;
    const pool = withinArrival.length ? withinArrival : exact;
    if (pool.length) {
      const directMeters = Number(destinationGraphMeters);
      return pool.sort((a, b) => {
        const detourA = a.graphMeters + a.remainingGraphMeters - (Number.isFinite(directMeters) ? directMeters : 0);
        const detourB = b.graphMeters + b.remainingGraphMeters - (Number.isFinite(directMeters) ? directMeters : 0);
        return detourA - detourB || a.remainingGraphMeters - b.remainingGraphMeters;
      });
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
    a.remainingMeters - b.remainingMeters || b.score - a.score
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
  allowPartialWindow = false,
  timeBudgetMs = null,
  profileMeters = null
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
  const memo = new Map();
  const stationCandidates = [];
  let effectiveK = Math.max(1, Math.min(6, Number(candidateK) || 6));
  let maxHopMs = 0;
  let firstReachableStationMeters = null;
  let stationsReachableWithinRange = 0;
  let timeBudgetExceeded = false;
  const physicalStart = locationCoordinate(start);
  const physicalDestination = locationCoordinate(destination);
  const physicalTotal = haversineMeters(physicalStart, physicalDestination);
  let bestPartial = { progressMeters: 0, stops: [], graphMeters: [], location: start };
  const deadline = Number(timeBudgetMs) > 0 ? started + Number(timeBudgetMs) : Infinity;
  const destinationGraph = boundedGraphDistances(
    runtime, targets.destinationMatch, policy, usableRangeMeters,
    avoidEdgeIds, [], null, 1
  );
  dijkstraPops += destinationGraph.pops;

  function reachableFrom(currentKey, currentMatch, capMeters, history, arrival) {
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
    for (const target of targets.fuelTargets) {
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

  const evaluateProfileHop = routeCandidate || (async ({
    candidate, from, maxMeters, priorEdgeIds: evaluationHistory, arrivalEdgeId: evaluationArrival
  }) => routeRequest({
    profile,
    locations: [from, candidate.location],
    accessPolicy: rawPolicy,
    options: {
      avoidEdgeIds,
      priorEdgeIds: [...(evaluationHistory || [])],
      arrivalEdgeId: evaluationArrival,
      backtrackFactor,
      directExtraBudgetMeters: undefined,
      maxPathMeters: maxMeters
    }
  }));

  function destinationCandidate(graphMeters) {
    return {
      station: { id: "__destination__", name: "Destination" },
      location: destination,
      match: targets.destinationMatch,
      graphMeters,
      remainingGraphMeters: 0
    };
  }

  async function evaluatedRoutes(ranked, currentKey, currentLocation, cap, visited, history, arrival) {
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
    const binCount = Math.max(3, effectiveK);
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
    // Pass 1: one candidate per progress bin (best-ranked first).
    for (const candidate of unique) {
      if (candidates.length >= effectiveK) break;
      const bin = progressBin(candidate);
      if (binUsed.has(bin) || tooClose(candidate)) continue;
      binUsed.add(bin);
      candidates.push(candidate);
    }
    // Pass 2: fill remaining slots with geographic diversity.
    for (const candidate of unique) {
      if (candidates.length >= effectiveK) break;
      if (candidates.includes(candidate) || tooClose(candidate)) continue;
      candidates.push(candidate);
    }
    for (const candidate of unique) {
      if (candidates.length >= effectiveK) break;
      if (!candidates.includes(candidate)) candidates.push(candidate);
    }
    const hopStarted = Date.now();
    const rows = [];
    const adventureProfile = profile === "dirt" || profile === "balanced";
    async function evaluateCandidate(candidate, rank) {
      let row;
      let diagnostic;
      try {
        const response = await evaluateProfileHop({
          candidate,
          from: currentLocation,
          maxMeters: cap,
          profile,
          accessPolicy: rawPolicy,
          priorEdgeIds: [...history],
          arrivalEdgeId: arrival,
          backtrackFactor
        });
        const meters = Number(response && response.distanceMeters);
        const dirtPct = Number(response && response.stats && response.stats.dirtPercent);
        const fits = response && response.status === "complete"
          && Number.isFinite(meters) && meters <= cap + 1;
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
          validForward: false
        };
        let validForward = false;
        if (fits) {
          const nextHistory = new Set(history);
          let nextArrival = arrival;
          for (const segment of (response && response.segments) || []) {
            const edgeId = segment && segment.edgeId != null ? String(segment.edgeId) : "";
            if (!edgeId) continue;
            nextHistory.add(edgeId);
            nextArrival = edgeId;
          }
          const continuation = reachableFrom(
            String(candidate.station.id), candidate.match, usableRangeMeters,
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
              routedContinuationMeters <= usableRangeMeters + 1
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
          dirtPct: row.dirtPct,
          validForward,
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
          validForward: false
        };
      }
      return { row, diagnostic };
    }

    // Adventure probes are expensive, but strictly sequential probing lets
    // one slow rejected pump consume the whole window. Evaluate two choices
    // concurrently, preserve rank order, and only launch another pair when no
    // profile-quality forward-valid choice has been proven.
    const batchSize = profile === "dirt"
      ? 2
      : (profile === "balanced" ? Math.min(4, Math.max(1, candidates.length)) : Math.max(1, candidates.length));
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
      const hasProfileQualityChoice = rows.some((evaluated) => {
        if (!(evaluated.fits && evaluated.validForward)) return false;
        // Fuel continuity wins over surface quality. Dirt stops after the
        // first bounded pair proves a usable chain; Balanced probes its small
        // shortlist together so it can choose the closest whole-chain 50/50.
        if (profile === "dirt") return true;
        if (profile === "balanced") return Math.abs(evaluated.chainDirtPct - 50) <= 5;
        return true;
      });
      if (
        adventureProfile &&
        rows.length >= 2 &&
        hasProfileQualityChoice
      ) break;
    }
    const elapsed = Date.now() - hopStarted;
    maxHopMs = Math.max(maxHopMs, elapsed);
    void hopTimeBudgetMs;
    const fitting = rows.filter((row) => row.fits);
    switch (resolveProfile(profile)) {
      case "dirt":
        fitting.sort((a, b) => {
          const dirtDelta = b.chainDirtPct - a.chainDirtPct;
          if (Math.abs(dirtDelta) > 5) return dirtDelta;
          return b.candidate.graphMeters - a.candidate.graphMeters || a.meters - b.meters;
        });
        break;
      case "balanced":
        fitting.sort((a, b) =>
          Math.abs(a.chainDirtPct - 50) - Math.abs(b.chainDirtPct - 50) || a.meters - b.meters
        );
        break;
      case "cleanest":
        // Anchor coherence to the foundation ride, not the shortest forced stop.
        // A stop is required because profileMeters exceeded the tank; among
        // pumps whose complete chain stays near that foundation, prefer the one
        // that actually uses the tank along the corridor (Truro over a 15 km Shell).
        fitting.sort((a, b) => {
          const remainA = Number(a.candidate.remainingGraphMeters);
          const remainB = Number(b.candidate.remainingGraphMeters);
          const chainA = a.meters + (Number.isFinite(remainA) ? remainA : 0);
          const chainB = b.meters + (Number.isFinite(remainB) ? remainB : 0);
          const foundation = Number(profileMeters);
          const cap = Number.isFinite(foundation) && foundation > 0
            ? foundation * 1.12
            : Infinity;
          const aCoherent = chainA <= cap + 1;
          const bCoherent = chainB <= cap + 1;
          if (aCoherent !== bCoherent) return aCoherent ? -1 : 1;
          if (aCoherent && bCoherent) {
            // Prefer fuller tank use / further along the axis within the band.
            const progressA = Number(a.candidate.progressMeters) || a.meters;
            const progressB = Number(b.candidate.progressMeters) || b.meters;
            if (Math.abs(progressA - progressB) > 15_000) return progressB - progressA;
            return chainA - chainB || a.rank - b.rank;
          }
          // Both exceed foundation band: pick the smaller complete detour.
          return chainA - chainB || a.rank - b.rank || a.meters - b.meters;
        });
        break;
      default:
        fitting.sort((a, b) =>
          (a.meters + a.candidate.remainingGraphMeters) -
            (b.meters + b.candidate.remainingGraphMeters) ||
          a.rank - b.rank
        );
    }
    return fitting;
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
    if (states >= maxStates || depth > maxStops) return null;
    states += 1;
    const cap = depth === 0 ? firstLegMaxMeters : usableRangeMeters;
    if (!(cap > 0)) return null;
    const reach = reachableFrom(currentKey, currentMatch, cap, history, arrival);
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
          true
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
    const destinationLimit = destinationFuelUsedLimitMeters == null
      ? NaN
      : Number(destinationFuelUsedLimitMeters);
    if (
      Number.isFinite(reach.destinationMeters) &&
      reach.destinationMeters <= cap &&
      (!Number.isFinite(destinationLimit) || reach.destinationMeters <= destinationLimit + 1) &&
      !(depth === 0 && requireFuelStopBeforeEnd) &&
      !mustContinueForProfileRide
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
          return { stops: [], graphMeters: [routedMeters] };
        }
      } catch (_) {
        // Graph reachability is only a candidate generator. Continue searching
        // for a pump when the active profile cannot complete this final hop.
      }
    }
    if (depth >= maxStops) {
      return allowPartialWindow && depth > 0
        ? { stops: [], graphMeters: [], partial: true }
        : null;
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
      depth === 0 && firstLegMaxMeters + 1 < usableRangeMeters
    );
    if (depth === 0 && requiredFirstStationId != null) {
      const required = String(requiredFirstStationId);
      ranked = ranked.filter((row) => String(row.station.id) === required);
      if (!ranked.length) return null;
    }
    // This is bounded graph look-ahead, not full route probing. Six branches
    // are enough to escape a closed service-road pump without exponential work.
    const evaluated = await evaluatedRoutes(
      ranked, currentKey, currentLocation, cap, visited, history, arrival
    );
    // Inspect every already-routed direct continuation before consulting the
    // wall-clock budget. A slower rejected candidate must not hide a second
    // candidate whose complete two-hop chain has already been proven.
    for (const evaluation of evaluated) {
      const continuationMeters = evaluation.continuationDestinationMeters == null
        ? NaN
        : Number(evaluation.continuationDestinationMeters);
      const destinationLimitSatisfied = !Number.isFinite(destinationLimit)
        || continuationMeters <= destinationLimit + 1;
      const requiredStopsSatisfied = depth + 1 >= Math.max(0, Number(minimumFuelStops) || 0);
      if (
        evaluation.fits &&
        Number.isFinite(continuationMeters) &&
        continuationMeters <= usableRangeMeters + 1 &&
        destinationLimitSatisfied &&
        requiredStopsSatisfied
      ) {
        const candidate = evaluation.candidate;
        return {
          stops: [{
            ...candidate.station,
            graphMeters: evaluation.meters,
            dirtPercent: evaluation.dirtPct
          }],
          graphMeters: [evaluation.meters, continuationMeters]
        };
      }
    }
    for (const evaluation of evaluated) {
      if (Date.now() >= deadline) {
        timeBudgetExceeded = true;
        break;
      }
      if (states >= maxStates) break;
      if (!evaluation.validForward) continue;
      const candidate = evaluation.candidate;
      const id = String(candidate.station.id);
      const nextVisited = new Set(visited);
      nextVisited.add(id);
      const nextHistory = new Set(history);
      let nextArrival = arrival;
      for (const segment of (evaluation.response && evaluation.response.segments) || []) {
        const edgeId = segment && segment.edgeId != null ? String(segment.edgeId) : "";
        if (!edgeId) continue;
        nextHistory.add(edgeId);
        nextArrival = edgeId;
      }
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
      if (!tail) continue;
      return {
        stops: [{
          ...candidate.station,
          graphMeters: evaluation.meters,
          dirtPercent: evaluation.dirtPct
        }].concat(tail.stops),
        graphMeters: [evaluation.meters].concat(tail.graphMeters),
        partial: !!tail.partial
      };
    }
    return null;
  }

  const chain = await search(
    "start", start, startMatch, new Set((excludedStationIds || []).map(String)), 0,
    new Set((priorEdgeIds || []).map(String)),
    arrivalEdgeId == null ? null : String(arrivalEdgeId), [], []
  );
  if (!chain) {
    const routedPrefixMeters = bestPartial.graphMeters.reduce((sum, meters) => sum + Number(meters || 0), 0);
    const knownProfileMeters = Number(profileMeters);
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
        ? "This fuel window exceeded its six-second planning budget."
        : "No forward, route-connected fuel chain fits the usable range.",
      diagnostics: enrichFuelDiagnostics({
        states,
        dijkstraPops,
        matchedFuel: targets.fuelTargets.length,
        candidateK: effectiveK,
        stationCandidates,
        elapsedMs: Date.now() - started,
        maxHopMs
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

  return {
    ok: true,
    stops: chain.stops,
    graphMeters: chain.graphMeters,
    stationCandidates,
    firstReachableStationMeters,
    windowComplete: !chain.partial,
    diagnostics: enrichFuelDiagnostics({
      strategy: "forward_graph_reachability",
      states,
      dijkstraPops,
      matchedFuel: targets.fuelTargets.length,
      candidateK: effectiveK,
      elapsedMs: Date.now() - started,
      maxHopMs
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
  let waypoints = corridorLocationsForRoute(body.locations || [], {
    profile: body.profile,
    forChain: true
  });
  const resolved = await resolveChainSeamWaypoints(waypoints, body);
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
    const planned = await planFuelChainOnRuntime({
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
      priorEdgeIds: ((body.options || {}).priorEdgeIds || []),
      arrivalEdgeId: (body.options || {}).arrivalEdgeId || null,
      backtrackFactor: (body.options || {}).backtrackFactor || 4,
      excludedStationIds: fuelOptions.excludedStationIds || [],
      requiredFirstStationId: i === 0 ? fuelOptions.requiredFirstStationId : null,
      maxStops: Math.max(1, windowMaxStops - allStops.length),
      allowPartialWindow,
      timeBudgetMs: Number.isFinite(windowDeadline)
        ? Math.max(1, windowDeadline - Date.now())
        : null,
      profileMeters: haversineMeters(startCoord, endCoord)
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

    allStops.push(...planned.stops);
    graphMeters.push(...planned.graphMeters);
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
        graphMeters: graphMeters.slice(0, windowMaxStops),
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

async function fuelChainRequest(body = {}, dependencies = {}) {
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

  let profileMeters = Number(rawFuelOptions.profileMeters);
  if (!(profileMeters >= 0)) {
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
  const stopsNeeded = fuelNeedForProfileRide(
    profileMeters,
    firstLegMaxMeters,
    usableRangeMeters
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
    requireFuelStopBeforeEnd:
      !!rawFuelOptions.requireFuelStopBeforeEnd || stopsNeeded > 0,
    minimumFuelStops: Math.max(
      Number(rawFuelOptions.minimumFuelStops) || 0,
      stopsNeeded
    )
  };
  console.log(
    `fuel need riderLeg=${rawFuelOptions.riderLegId || "unknown"} ` +
    `profileMeters=${Math.round(profileMeters)} usable=${Math.round(usableRangeMeters)} ` +
    `stopsNeeded=${stopsNeeded}`
  );

  if (selection.mode === "canada-chain") {
    return planCrossRegionFuelChain(body, selection, fuelOptions, dependencies);
  }

  const fuel = await loadFuel(locations);
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
    priorEdgeIds: options.priorEdgeIds || [],
    arrivalEdgeId: options.arrivalEdgeId || null,
    backtrackFactor: options.backtrackFactor || 4,
    probeFirstReachableStation: !!fuelOptions.probeFirstReachableStation,
    excludedStationIds: fuelOptions.excludedStationIds || [],
    requiredFirstStationId: fuelOptions.requiredFirstStationId || null,
    maxStops: Math.min(12, Math.max(1, Number(fuelOptions.windowMaxStops) || 12)),
    allowPartialWindow: !!fuelOptions.allowPartialWindow,
    timeBudgetMs: Number(fuelOptions.windowTimeBudgetMs) || null,
    profileMeters
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
    stationCandidates: planned.stationCandidates || [],
    firstReachableStationMeters: planned.firstReachableStationMeters,
    windowComplete: planned.windowComplete,
    gapMeters: planned.gapMeters,
    overByMeters: planned.overByMeters,
    gapFrom: planned.gapFrom,
    gapTo: planned.gapTo,
    diagnostics: planned.diagnostics || null
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
    if (leg.waypointReset) waypointResets.push({ legIndex, absoluteMeters: offset, ...leg.waypointReset });
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
      const dirt = Number(b.candidate.dirtPct || 0) - Number(a.candidate.dirtPct || 0);
      if (dirt) return dirt;
      return b.candidate.absoluteMeters - a.candidate.absoluteMeters;
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
  boundedGraphDistances,
  distanceToMatch,
  fuelPlanningSpan,
  rankForwardFuel,
  stationEligibility,
  fuelNeedForProfileRide,
  fuelPlanStatus,
  planFuelChainOnRuntime,
  planCrossRegionFuelChain,
  planItineraryFuelChain,
  fuelChainRequest
};
