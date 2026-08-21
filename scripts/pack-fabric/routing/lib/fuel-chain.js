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
const { unpackAccess } = require("./pack-v2");
const { projectedProgressMeters, crossTrackMeters } = require("./hop-search");

const HARD_MATCH_METERS = 750;
const MIN_STOP_SEPARATION_M = 800;
const MIN_FORWARD_PROGRESS_M = 2_500;

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
      id: pack.edgeId(edgeIndex)
    };
  }
  const edge = runtime.data.edges[edgeIndex];
  return {
    a: edge.a,
    b: edge.b,
    meters: Number(edge.m),
    access: edge.ac,
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
    fuelTargets.push({ station, location, match });
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
  profile = "balanced"
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
      const crossTrack = crossTrackMeters(point, current, destination);
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
        Math.abs(row.graphMeters - targetUse) * 0.12;
      return { ...row, remainingMeters: remaining, progressMeters: progress, score, useful };
    })
    .filter((row) => row.useful);
  const preferred = scored.filter((row) => row.graphMeters <= preferredMax);
  const overflow = scored.filter((row) => row.graphMeters > preferredMax);
  return preferred
    .sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters)
    .concat(overflow.sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters));
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
  avoidEdgeIds = [],
  priorEdgeIds = [],
  arrivalEdgeId = null,
  backtrackFactor = 4,
  routeCandidate = null,
  candidateK = 6,
  hopTimeBudgetMs = 4_000,
  maxStops = 12,
  maxStates = 24
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
        fuel.push({ ...target, graphMeters });
      }
    }
    const result = { destinationMeters, fuel };
    memo.set(memoKey, result);
    return result;
  }

  async function evaluatedRoutes(ranked, currentLocation, cap, history, arrival) {
    const candidates = ranked.slice(0, effectiveK);
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
          dirtPct: row.dirtPct
        });
        return row;
      } catch (_) {
        stationCandidates.push({
          id: String(candidate.station.id),
          meters: Math.round(candidate.graphMeters),
          dirtPct: 0
        });
        return { candidate, response: null, rank, meters: candidate.graphMeters, dirtPct: 0, fits: false };
      }
    }));
    const elapsed = Date.now() - hopStarted;
    if (elapsed > hopTimeBudgetMs && effectiveK > 3) {
      effectiveK = 3;
      console.warn(`fuel candidate K reduced=3 elapsedMs=${elapsed}`);
    }
    const fitting = rows.filter((row) => row.fits);
    switch (String(profile || "").toLowerCase()) {
      case "dirt":
        fitting.sort((a, b) => b.dirtPct - a.dirtPct || a.meters - b.meters);
        break;
      case "balanced":
        fitting.sort((a, b) =>
          Math.abs(a.dirtPct - 50) - Math.abs(b.dirtPct - 50) || a.meters - b.meters
        );
        break;
      case "cleanest":
        fitting.sort((a, b) => a.dirtPct - b.dirtPct || a.meters - b.meters);
        break;
      default:
        fitting.sort((a, b) => a.rank - b.rank || a.meters - b.meters);
    }
    return fitting;
  }

  async function search(currentKey, currentLocation, currentMatch, visited, depth, history, arrival) {
    if (states >= maxStates || depth > maxStops) return null;
    states += 1;
    const cap = depth === 0 ? firstLegMaxMeters : usableRangeMeters;
    if (!(cap > 0)) return null;
    const reach = reachableFrom(currentKey, currentMatch, cap, history, arrival);
    if (
      Number.isFinite(reach.destinationMeters) &&
      reach.destinationMeters <= cap &&
      !(depth === 0 && requireFuelStopBeforeEnd)
    ) {
      return { stops: [], graphMeters: [reach.destinationMeters] };
    }
    if (depth >= maxStops) return null;

    const ranked = rankForwardFuel(
      reach.fuel,
      currentLocation,
      destination,
      cap,
      visited,
      profile
    );
    // This is bounded graph look-ahead, not full route probing. Six branches
    // are enough to escape a closed service-road pump without exponential work.
    const evaluated = await evaluatedRoutes(ranked, currentLocation, cap, history, arrival);
    for (const evaluation of evaluated) {
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
        graphMeters: [evaluation.meters].concat(tail.graphMeters)
      };
    }
    return null;
  }

  const chain = await search(
    "start", start, startMatch, new Set(), 0,
    new Set((priorEdgeIds || []).map(String)),
    arrivalEdgeId == null ? null : String(arrivalEdgeId)
  );
  if (!chain) {
    return {
      ok: false,
      error: "no_route_connected_fuel_chain",
      message: "No forward, route-connected fuel chain fits the usable range.",
      diagnostics: {
        states,
        dijkstraPops,
        matchedFuel: targets.fuelTargets.length,
        candidateK: effectiveK,
        stationCandidates,
        elapsedMs: Date.now() - started
      }
    };
  }

  return {
    ok: true,
    stops: chain.stops,
    graphMeters: chain.graphMeters,
    stationCandidates,
    diagnostics: {
      strategy: "forward_graph_reachability",
      states,
      dijkstraPops,
      matchedFuel: targets.fuelTargets.length,
      candidateK: effectiveK,
      elapsedMs: Date.now() - started
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
  const started = Date.now();

  for (let i = 0; i < waypoints.length - 1; i += 1) {
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
      avoidEdgeIds: ((body.options || {}).avoidEdgeIds || []),
      priorEdgeIds: ((body.options || {}).priorEdgeIds || []),
      arrivalEdgeId: (body.options || {}).arrivalEdgeId || null,
      backtrackFactor: (body.options || {}).backtrackFactor || 4
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
    diagnostics: {
      strategy: "forward_graph_reachability_across_seams",
      states: totalStates,
      dijkstraPops: totalPops,
      matchedFuel,
      elapsedMs: Date.now() - started
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
  const fuelOptions = body.fuel || {};
  const usableRangeMeters = Number(fuelOptions.usableRangeMeters);
  const firstLegMaxMeters = Number(fuelOptions.firstLegMaxMeters || usableRangeMeters);
  if (!(usableRangeMeters > 0) || !(firstLegMaxMeters > 0)) {
    return {
      status: "error",
      error: "invalid_fuel_range",
      message: "Fuel range must be greater than zero."
    };
  }

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
    avoidEdgeIds: options.avoidEdgeIds || [],
    priorEdgeIds: options.priorEdgeIds || [],
    arrivalEdgeId: options.arrivalEdgeId || null,
    backtrackFactor: options.backtrackFactor || 4
  });

  return {
    status: planned.ok ? "complete" : "failed",
    error: planned.error || null,
    message: planned.message || null,
    regionIds: fuel.regionIds,
    stops: planned.stops || [],
    graphMeters: planned.graphMeters || [],
    stationCandidates: planned.stationCandidates || [],
    diagnostics: planned.diagnostics || null
  };
}

module.exports = {
  boundedGraphDistances,
  distanceToMatch,
  fuelPlanningSpan,
  rankForwardFuel,
  planFuelChainOnRuntime,
  planCrossRegionFuelChain,
  fuelChainRequest
};
