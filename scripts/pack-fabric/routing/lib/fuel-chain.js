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
  resolveChainSeamWaypoints
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
function boundedGraphDistances(runtime, startMatch, policy, maxMeters, avoidEdgeIds = []) {
  const count = nodeCount(runtime);
  const distances = new Float64Array(count);
  distances.fill(Infinity);
  const heap = new MinHeap();
  const avoid = new Set((avoidEdgeIds || []).map(String));
  seedMatchDistances(runtime, startMatch, distances, heap);
  let pops = 0;

  while (heap.items.length) {
    const current = heap.pop();
    if (!current || current.cost !== distances[current.node]) continue;
    if (current.cost > maxMeters) break;
    pops += 1;
    forEachNeighbor(runtime, current.node, (next, edgeIndex) => {
      const edge = edgeView(runtime, edgeIndex);
      if (avoid.has(edge.id)) return;
      if (!accessAllowed(edge.access, policy, runtime.enums, null)) return;
      const candidate = current.cost + edge.meters;
      if (candidate > maxMeters || candidate >= distances[next]) return;
      distances[next] = candidate;
      heap.push({ node: next, cost: candidate });
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
  const pool = preferred.length ? preferred : scored;
  return pool.sort((a, b) => b.score - a.score || a.graphMeters - b.graphMeters);
}

function planFuelChainOnRuntime({
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

  function reachableFrom(currentKey, currentMatch, capMeters) {
    const memoKey = `${currentKey}:${Math.round(capMeters)}`;
    if (memo.has(memoKey)) return memo.get(memoKey);
    const graph = boundedGraphDistances(runtime, currentMatch, policy, capMeters, avoidEdgeIds);
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

  function search(currentKey, currentLocation, currentMatch, visited, depth) {
    if (states >= maxStates || depth > maxStops) return null;
    states += 1;
    const cap = depth === 0 ? firstLegMaxMeters : usableRangeMeters;
    if (!(cap > 0)) return null;
    const reach = reachableFrom(currentKey, currentMatch, cap);
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
    for (const candidate of ranked.slice(0, 6)) {
      if (states >= maxStates) break;
      const id = String(candidate.station.id);
      const nextVisited = new Set(visited);
      nextVisited.add(id);
      const tail = search(id, candidate.location, candidate.match, nextVisited, depth + 1);
      if (!tail) continue;
      return {
        stops: [{ ...candidate.station, graphMeters: candidate.graphMeters }].concat(tail.stops),
        graphMeters: [candidate.graphMeters].concat(tail.graphMeters)
      };
    }
    return null;
  }

  const chain = search("start", start, startMatch, new Set(), 0);
  if (!chain) {
    return {
      ok: false,
      error: "no_route_connected_fuel_chain",
      message: "No forward, route-connected fuel chain fits the usable range.",
      diagnostics: {
        states,
        dijkstraPops,
        matchedFuel: targets.fuelTargets.length,
        elapsedMs: Date.now() - started
      }
    };
  }

  return {
    ok: true,
    stops: chain.stops,
    graphMeters: chain.graphMeters,
    diagnostics: {
      strategy: "forward_graph_reachability",
      states,
      dijkstraPops,
      matchedFuel: targets.fuelTargets.length,
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
    const planned = planFuelChainOnRuntime({
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
      avoidEdgeIds: ((body.options || {}).avoidEdgeIds || [])
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
  const planned = planFuelChainOnRuntime({
    runtime,
    stations: fuel.stations,
    start: locations[0],
    destination: locations[locations.length - 1],
    profile: String(body.profile || "dirt").toLowerCase(),
    accessPolicy: body.accessPolicy,
    usableRangeMeters,
    firstLegMaxMeters,
    requireFuelStopBeforeEnd: !!fuelOptions.requireFuelStopBeforeEnd,
    avoidEdgeIds: options.avoidEdgeIds || []
  });

  return {
    status: planned.ok ? "complete" : "failed",
    error: planned.error || null,
    message: planned.message || null,
    regionIds: fuel.regionIds,
    stops: planned.stops || [],
    graphMeters: planned.graphMeters || [],
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
