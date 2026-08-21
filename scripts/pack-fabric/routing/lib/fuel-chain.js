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
const { loadFuelForLocations, loadRegionFuel } = require("./fuel-data");
const { unpackAccess, unpackSurface } = require("./pack-v2");
const { projectedProgressMeters, crossTrackMeters } = require("./hop-search");

const HARD_MATCH_METERS = 750;
const MIN_STOP_SEPARATION_M = 800;
const MIN_FORWARD_PROGRESS_M = 2_500;

function fuelNeedForProfileRide(profileMeters, firstLegMaxMeters, usableRangeMeters) {
  const meters = Number(profileMeters);
  const firstCap = Number(firstLegMaxMeters);
  const usable = Number(usableRangeMeters);
  if (!(meters >= 0) || !(firstCap >= 0) || !(usable > 0)) return null;
  if (meters <= firstCap + 1) return 0;
  return Math.ceil((meters - firstCap) / usable);
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
  switch (String(profile || "").toLowerCase()) {
    case "dirt": return 0.78;
    case "balanced": return 0.84;
    case "direct": return 0.91;
    case "cleanest": return 0.95;
    default: return 0.84;
  }
}

function rankForwardFuel(
  reachable,
  currentLocation,
  destinationLocation,
  capMeters,
  visited,
  profile = "balanced",
  destinationFuelUsedLimitMeters = null,
  destinationGraphMeters = null
) {
  const current = locationCoordinate(currentLocation);
  const destination = locationCoordinate(destinationLocation);
  const currentRemaining = haversineMeters(current, destination);
  // The tank is a hard ceiling, not the desired shortest-network spacing.
  // Adventure profiles need physical-distance headroom so the final Dirt or
  // Balanced leg can spend that room on eligible unpaved roads.
  const span = fuelPlanningSpan(profile);
  const preferredMax = capMeters * span;
  const targetUse = preferredMax * 0.94;

  const scored = reachable
    .filter((row) => !visited.has(String(row.station.id)))
    .map((row) => {
      const point = [row.location.lon, row.location.lat];
      const remaining = haversineMeters(point, destination);
      const gain = currentRemaining - remaining;
      const progress = projectedProgressMeters(point, current, destination);
      const crossTrack = Math.abs(crossTrackMeters(point, current, destination));
      const useful =
        row.graphMeters >= MIN_STOP_SEPARATION_M &&
        remaining >= MIN_STOP_SEPARATION_M &&
        progress >= MIN_FORWARD_PROGRESS_M &&
        gain >= -5_000;
      // Progress is the primary objective. Tank use rewards pumps late enough
      // to avoid needless stops; cross-track discourages arbitrary north/south
      // excursions merely because the usable corridor is wide.
      const score =
        progress * 1.0 +
        gain * 0.45 -
        crossTrack * 0.35 -
        Math.abs(row.graphMeters - targetUse) * 0.12 +
        ((profile === "dirt" || profile === "balanced") && row.dirtAdjacent ? 25_000 : 0);
      return { ...row, remainingMeters: remaining, progressMeters: progress, score, useful };
    })
    .filter((row) => row.useful);
  const preferred = scored.filter((row) => row.graphMeters <= preferredMax);
  const overflow = scored.filter((row) => row.graphMeters > preferredMax);
  const normal = preferred
    .sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters)
    .concat(overflow.sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters));
  const arrivalLimit = destinationFuelUsedLimitMeters == null
    ? NaN
    : Number(destinationFuelUsedLimitMeters);
  if (profile === "direct" || profile === "cleanest") {
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
  allowPartialWindow = false,
  timeBudgetMs = null
}) {
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
  let timeBudgetExceeded = false;
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

  async function evaluatedRoutes(ranked, currentLocation, cap, history, arrival) {
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
    for (const candidate of unique) {
      const point = locationCoordinate(candidate.location);
      if (candidates.some((selected) =>
        haversineMeters(point, locationCoordinate(selected.location)) < 15_000
      )) continue;
      candidates.push(candidate);
      if (candidates.length >= effectiveK) break;
    }
    for (const candidate of unique) {
      if (candidates.length >= effectiveK) break;
      if (!candidates.includes(candidate)) candidates.push(candidate);
    }
    const hopStarted = Date.now();
    const evaluate = routeCandidate || (async ({ candidate, from, maxMeters }) => routeRequest({
      profile,
      locations: [from, candidate.location],
      accessPolicy: rawPolicy,
      options: {
        avoidEdgeIds,
        priorEdgeIds: [...history],
        arrivalEdgeId: arrival,
        backtrackFactor,
        directExtraBudgetMeters: profile === "direct" ? 0 : undefined,
        maxPathMeters: maxMeters
      }
    }));
    const rows = await Promise.all(candidates.map(async (candidate, rank) => {
      try {
        const response = await evaluate({
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
        const row = {
          candidate,
          response,
          rank,
          meters: Number.isFinite(meters) ? meters : candidate.graphMeters,
          dirtPct: Number.isFinite(dirtPct) ? dirtPct : 0,
          fits
        };
        stationCandidates.push({
          id: String(candidate.station.id),
          meters: Math.round(row.meters),
          dirtPct: row.dirtPct,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null
        });
        return row;
      } catch (_) {
        stationCandidates.push({
          id: String(candidate.station.id),
          meters: Math.round(candidate.graphMeters),
          dirtPct: 0,
          remainingGraphMeters: Number.isFinite(candidate.remainingGraphMeters)
            ? Math.round(candidate.remainingGraphMeters)
            : null
        });
        return { candidate, response: null, rank, meters: candidate.graphMeters, dirtPct: 0, fits: false };
      }
    }));
    const elapsed = Date.now() - hopStarted;
    maxHopMs = Math.max(maxHopMs, elapsed);
    void hopTimeBudgetMs;
    const fitting = rows.filter((row) => row.fits);
    switch (String(profile || "").toLowerCase()) {
      case "dirt":
        fitting.sort((a, b) => {
          const dirtDelta = b.dirtPct - a.dirtPct;
          if (Math.abs(dirtDelta) > 5) return dirtDelta;
          return b.candidate.graphMeters - a.candidate.graphMeters || a.meters - b.meters;
        });
        break;
      case "balanced":
        fitting.sort((a, b) =>
          Math.abs(a.dirtPct - 50) - Math.abs(b.dirtPct - 50) || a.meters - b.meters
        );
        break;
      case "cleanest":
        // Clean retains its profile-aware station ranking: minimizing the
        // complete trip cannot come at the expense of its paved contract.
        fitting.sort((a, b) => a.rank - b.rank || a.meters - b.meters);
        break;
      default:
        // Direct compares the complete trip through each candidate rather
        // than optimizing only the first fuel hop.
        fitting.sort((a, b) =>
          (a.meters + a.candidate.remainingGraphMeters) -
            (b.meters + b.candidate.remainingGraphMeters) ||
          a.rank - b.rank
        );
    }
    return fitting;
  }

  async function search(currentKey, currentLocation, currentMatch, visited, depth, history, arrival) {
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
      firstReachableStationMeters = reach.fuel.reduce((best, row) =>
        best == null || row.graphMeters < best ? row.graphMeters : best
      , null);
      if (probeFirstReachableStation) {
        const graphFirstReachableStationMeters = firstReachableStationMeters;
        const ranked = rankForwardFuel(
          reach.fuel, currentLocation, destination, cap, visited, profile,
          null, reach.destinationMeters
        );
        const evaluated = await evaluatedRoutes(ranked, currentLocation, cap, history, arrival);
        const evaluatedFirstReachableStationMeters = evaluated.reduce((best, row) =>
          best == null || row.meters < best ? row.meters : best
        , null);
        // K is deliberately bounded. If none of those profile-route probes
        // completes, retain the proven graph-reachable distance instead of
        // incorrectly reporting that the next leg has no fuel at all. The
        // forward chain still has to prove the selected pump route before it
        // is accepted.
        firstReachableStationMeters = evaluatedFirstReachableStationMeters
          ?? graphFirstReachableStationMeters;
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
      return { stops: [], graphMeters: [reach.destinationMeters] };
    }
    if (depth >= maxStops) {
      return allowPartialWindow && depth > 0
        ? { stops: [], graphMeters: [], partial: true }
        : null;
    }

    const ranked = rankForwardFuel(
      reach.fuel,
      currentLocation,
      destination,
      cap,
      visited,
      profile,
      destinationFuelUsedLimitMeters,
      reach.destinationMeters
    );
    // This is bounded graph look-ahead, not full route probing. Six branches
    // are enough to escape a closed service-road pump without exponential work.
    const evaluated = await evaluatedRoutes(ranked, currentLocation, cap, history, arrival);
    for (const evaluation of evaluated) {
      if (Date.now() >= deadline) {
        timeBudgetExceeded = true;
        break;
      }
      if (states >= maxStates) break;
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
        nextHistory, nextArrival
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
    arrivalEdgeId == null ? null : String(arrivalEdgeId)
  );
  if (!chain) {
    return {
      ok: false,
      error: timeBudgetExceeded ? "window_time_budget" : "no_route_connected_fuel_chain",
      message: timeBudgetExceeded
        ? "This fuel window exceeded its six-second planning budget."
        : "No forward, route-connected fuel chain fits the usable range.",
      diagnostics: {
        states,
        dijkstraPops,
        matchedFuel: targets.fuelTargets.length,
        candidateK: effectiveK,
        stationCandidates,
        elapsedMs: Date.now() - started,
        maxHopMs
      },
      firstReachableStationMeters
    };
  }

  return {
    ok: true,
    stops: chain.stops,
    graphMeters: chain.graphMeters,
    stationCandidates,
    firstReachableStationMeters,
    windowComplete: !chain.partial,
    diagnostics: {
      strategy: "forward_graph_reachability",
      states,
      dijkstraPops,
      matchedFuel: targets.fuelTargets.length,
      candidateK: effectiveK,
      elapsedMs: Date.now() - started,
      maxHopMs
    }
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
        status: "failed",
        error: "window_time_budget",
        message: "This fuel window exceeded its six-second planning budget."
      };
    }
    const hopStart = waypoints[i];
    const hopEnd = waypoints[i + 1];
    const startCoord = locationCoordinate(hopStart);
    const endCoord = locationCoordinate(hopEnd);
    const startFamily = provinceFamily(primaryRegionForPoint(startCoord[0], startCoord[1]));
    const endFamily = provinceFamily(primaryRegionForPoint(endCoord[0], endCoord[1]));
    const regionId = i === waypoints.length - 2
      ? endFamily || startFamily
      : startFamily || endFamily;
    if (!regionId) {
      return {
        status: "failed",
        error: "region_unknown",
        message: `Could not resolve the regional fabric for fuel segment ${i + 1}.`
      };
    }

    clearGraphCache();
    const resolution = resolveGraphRequest({
      ...body,
      regionId,
      locations: [hopStart, hopEnd]
    });
    const fuel = await loadRegion(regionId);
    const runtime = await loadRuntime(resolution, {
      locations: [hopStart, hopEnd],
      profile: body.profile
    });
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
      maxStops: Math.max(1, windowMaxStops - allStops.length),
      allowPartialWindow,
      timeBudgetMs: Number.isFinite(windowDeadline)
        ? Math.max(1, windowDeadline - Date.now())
        : null
    });
    if (!planned.ok) {
      clearGraphCache();
      return {
        status: "failed",
        error: planned.error,
        message: `${planned.message || "No fuel chain found"} (regional segment ${i + 1}/${waypoints.length - 1})`,
        diagnostics: planned.diagnostics || null
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
        stops: allStops.slice(0, windowMaxStops),
        graphMeters: graphMeters.slice(0, windowMaxStops),
        stationCandidates,
        windowComplete: false,
        diagnostics: {
          strategy: "forward_graph_reachability_across_seams_window",
          states: totalStates,
          dijkstraPops: totalPops,
          matchedFuel,
          elapsedMs: Date.now() - started,
          maxHopMs
        }
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
        message: "The route reaches a regional boundary after the usable fuel range."
      };
    }
  }
  clearGraphCache();

  if (fuelOptions.requireFuelStopBeforeEnd && !allStops.length) {
    return {
      status: "failed",
      error: "fuel_stop_required",
      message: "A route-connected fuel stop is required before point 2."
    };
  }
  return {
    status: "complete",
    error: null,
    message: null,
    regionIds: selection.regionIds,
    stops: allStops,
    graphMeters,
    stationCandidates,
    windowComplete: true,
    diagnostics: {
      strategy: "forward_graph_reachability_across_seams",
      states: totalStates,
      dijkstraPops: totalPops,
      matchedFuel,
      elapsedMs: Date.now() - started,
      maxHopMs
    }
  };
}

async function fuelChainRequest(body = {}, dependencies = {}) {
  const loadFuel = dependencies.loadFuelForLocations || loadFuelForLocations;
  const loadRuntime = dependencies.loadGraphsForRequest || loadGraphsForRequest;
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
      status: "failed",
      error: "no_packed_fuel",
      message: "No live packed fuel stations were found for this stage.",
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
    maxStops: Math.min(12, Math.max(1, Number(fuelOptions.windowMaxStops) || 12)),
    allowPartialWindow: !!fuelOptions.allowPartialWindow,
    timeBudgetMs: Number(fuelOptions.windowTimeBudgetMs) || null
  });

  return {
    status: planned.ok ? "complete" : "failed",
    error: planned.error || null,
    message: planned.message || null,
    regionIds: fuel.regionIds,
    stops: planned.stops || [],
    graphMeters: planned.graphMeters || [],
    stationCandidates: planned.stationCandidates || [],
    firstReachableStationMeters: planned.firstReachableStationMeters,
    windowComplete: planned.windowComplete,
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
  boundedGraphDistances,
  distanceToMatch,
  fuelPlanningSpan,
  rankForwardFuel,
  fuelNeedForProfileRide,
  planFuelChainOnRuntime,
  planCrossRegionFuelChain,
  planItineraryFuelChain,
  fuelChainRequest
};
