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
  surfaceMultiplier,
  classSpeedKmh,
  costPerKmView,
  approachAwayExtraCost,
  roadClassMultiplier,
  cleanCityStreetMult,
  isMajorHighwayClass,
  pinMatchesMajorHighway,
  majorHighwayAvoidMult,
  directCrossTrackExtra
} = require("./profile-costs");
const { pruneGeographicLoops } = require("./path-pruning");
const {
  considerRelax,
  applyRelax,
  shouldPush,
  createsCycle,
  isDirtSurface,
  dirtRideCostPerKm,
  DIRT_RIDE_PAVED_PER_KM,
  DIRT_RIDE_GRAVEL_PER_KM,
  DIRT_RIDE_RESOURCE_PER_KM,
  DIRT_RIDE_UNKNOWN_TRACK_PER_KM,
  DIRT_RIDE_XT_SCALE,
  DIRT_RIDE_AWAY_SCALE,
  hopBlocked,
  urbanCoreFallbackMultiplier,
  settlementBlocks,
  settlementFallbackMultiplier,
  metroEdgeBlocks,
  outsideCorridor,
  projectedProgressMeters,
  maxProgressRegressionMeters,
  progressRegressionForAttempt,
  annotateCorridorMeta,
  corridorMetersForProfile,
  pickResourceEnd,
  VARIETY_SLOTS,
  BALANCED_BUCKETS,
  dirtBucket,
  PASS2_TIME_MS,
  PASS2_POP_CAP
} = require("./hop-search");

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

function accessAllowed(accessCode, policy, enums, edgeOrSource) {
  // Access class, not dataset name, is authoritative. OSM path/cycleway edges
  // with uncertain motorcycle legality must remain behind Allow Unknown.
  void edgeOrSource;
  const name = enums.ACCESS_NAME[accessCode];
  if (name === "motorized_restricted" || name === "motorized_excluded") return false;
  if (name === "motorized_unknown") return !!policy.motorizedUnknown;
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
  if (cityWall && metroEdgeBlocks(fromPoint, point, startLL, endLL, urbanBoxes)) return true;
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
    nodeLL
  } = args;
  const dist = new Float64Array(total);
  dist.fill(Infinity);
  const heap = new MinHeap();
  // The pack CSR contains directed arcs. Build its transpose so these are true
  // node -> destination lower bounds; using destination's outgoing arcs can
  // over-prune valid routes at one-way roads.
  const arcCount = edgeTargets.length;
  const incomingCounts = new Uint32Array(n);
  for (let i = 0; i < arcCount; i += 1) {
    const target = edgeTargets[i];
    if (target < n) incomingCounts[target] += 1;
  }
  const incomingOffsets = new Uint32Array(n + 1);
  for (let node = 0; node < n; node += 1) incomingOffsets[node + 1] = incomingOffsets[node] + incomingCounts[node];
  const incomingSources = new Uint32Array(arcCount);
  const incomingEdges = new Uint32Array(arcCount);
  const cursors = incomingOffsets.slice(0, n);
  for (let source = 0; source < n; source += 1) {
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
  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    if (cur.cost > capMeters) continue;
    if (cur.node < n) {
      const start = incomingOffsets[cur.node];
      const end = incomingOffsets[cur.node + 1];
      for (let i = start; i < end; i += 1) {
        const to = incomingSources[i];
        const ei = incomingEdges[i];
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (!accessAllowed(access, policy, enums)) continue;
        if (pavedOnly) {
          const surfaceName = enums.SURFACE_NAME[unpackSurface(attr)] || "unknown";
          const roadName = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
          if (isDirtSurface(surfaceName, roadName)) continue;
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
    }
    const vlist = virtAdj.get(cur.node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        if (pavedOnly) {
          const attr = edgeAttrs[v.ei];
          const surfaceName = enums.SURFACE_NAME[unpackSurface(attr)] || "unknown";
          const roadName = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
          if (isDirtSurface(surfaceName, roadName)) continue;
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

function dirtCandidateSummary(ride, width) {
  const distanceMeters = Number(ride && ride.distanceMeters) || 0;
  const dirtPercent = Number(ride && ride.stats && ride.stats.dirtPercent) || 0;
  const pavedMeters = distanceMeters * Math.max(0, 100 - dirtPercent) / 100;
  const shape = (ride && ride.searchMeta && ride.searchMeta.routeShape) || {};
  return {
    ride,
    width,
    dirtPercent,
    pavedMeters,
    backwardMeters: Number(shape.backwardMeters) || 0,
    lateralMeters: Number(shape.lateralMeters) || 0
  };
}

/**
 * Dirt works back from 100%. Distance is deliberately absent: once candidates
 * are within two percentage points, choose less pavement, then less purposeless
 * backward/lateral movement. This prevents a corridor from becoming mileage
 * that the route feels obliged to consume.
 */
function chooseDirtRideCandidate(candidates) {
  if (!candidates.length) return null;
  return candidates.slice().sort((a, b) => {
    const dirtDelta = b.dirtPercent - a.dirtPercent;
    if (Math.abs(dirtDelta) > 2) return dirtDelta;
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
  const sessionSeed = Number(searchOpts.sessionSeed) || 0;
  if (!searchOpts.costMode && profile !== "cleanest") {
    const baseCorridor = corridorMetersForProfile(profile);
    // Direct/Balanced keep the narrowest viable band. Dirt first compares
    // coherent rides inside 50/100/150 km envelopes; the corridor is an outer
    // permission, never distance the route must consume.
    const widthMultipliers = profile === "direct"
      ? [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12]
      : profile === "dirt" ? [4, 3, 2, 1, 6, 8] : [1, 2, 3, 4, 6, 8];
    const widths = widthMultipliers.map((m) => baseCorridor * m).concat(Infinity);
    const requestedCap = Number(searchOpts.maxPathMeters);
    const dirtCandidates = [];
    const attemptDiagnostics = [];
    for (const width of widths) {
      // Once Dirt has compared its three deliberate envelopes, wider bands are
      // connectivity fallbacks only. Stop at the first one that connects.
      const dirtComparisonWidth = profile === "dirt" && Number.isFinite(width) && width <= baseCorridor * 4;
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
        // Width is lateral permission, not permission to head away from the
        // next pin. Keep the forward-progress guard fixed while widening; only
        // the final unbounded attempt may relax it to prove connectivity.
        progressRegressionMeters: progressRegressionForAttempt(profile, width),
        diagnostics,
        settlementWall: searchOpts.settlementWall === true,
        settlementFallback: searchOpts.settlementFallback !== false,
        priorEdgeIds: searchOpts.priorEdgeIds || [],
        arrivalEdgeId: searchOpts.arrivalEdgeId == null ? null : searchOpts.arrivalEdgeId,
        backtrackFactor: searchOpts.backtrackFactor
      };
      if (dirtComparisonWidth) {
        // Three candidates share roughly one old pass-2 budget.
        rideOpts.timeCapMs = 7000;
        rideOpts.popCap = Math.ceil(PASS2_POP_CAP / 2);
      }
      // A real per-hop constraint (fuel range) remains a hard safety limit. It
      // is not a shortest-path-derived product objective.
      if (Number.isFinite(requestedCap)) rideOpts.maxPathMeters = requestedCap;
      const ride = findPathV2(
        runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, rideOpts
      );
      attemptDiagnostics.push({
        corridorMeters: Number.isFinite(width) ? width : null,
        outcome: ride ? "completed" : (diagnostics.outcome || "noPath"),
        pops: diagnostics.pops || (ride && ride.searchMeta && ride.searchMeta.pops) || 0
      });
      if (!ride) continue;
      ride.searchMeta = ride.searchMeta || {};
      ride.searchMeta.rideObjective =
        profile === "dirt" ? "earned-dirt-detour" :
        profile === "balanced" ? "surface-balance" : "crow-flies-adventure";
      ride.searchMeta.corridorMeters = Number.isFinite(width) ? width : null;
      ride.searchMeta.corridorWidened = Number.isFinite(width) && width > baseCorridor;
      if (profile === "dirt") {
        ride.searchMeta.dirtRideWeights = {
          paved: DIRT_RIDE_PAVED_PER_KM,
          gravel: DIRT_RIDE_GRAVEL_PER_KM,
          resource: DIRT_RIDE_RESOURCE_PER_KM,
          unknownTrack: DIRT_RIDE_UNKNOWN_TRACK_PER_KM,
          crossTrackScale: DIRT_RIDE_XT_SCALE,
          awayScale: DIRT_RIDE_AWAY_SCALE
        };
        const summary = dirtCandidateSummary(ride, width);
        dirtCandidates.push(summary);
        if (dirtComparisonWidth) continue;
      }
      ride.searchMeta.corridorCandidates = attemptDiagnostics;
      return ride;
    }
    if (profile === "dirt" && dirtCandidates.length) {
      const best = chooseDirtRideCandidate(dirtCandidates);
      best.ride.searchMeta.corridorCandidates = attemptDiagnostics.map((attempt) => {
        const candidate = dirtCandidates.find((item) => item.width === attempt.corridorMeters);
        return candidate ? {
          ...attempt,
          dirtPercent: candidate.dirtPercent,
          distanceMeters: Math.round(candidate.ride.distanceMeters || 0),
          pavedMeters: Math.round(candidate.pavedMeters),
          backwardMeters: Math.round(candidate.backwardMeters),
          lateralMeters: Math.round(candidate.lateralMeters)
        } : attempt;
      });
      best.ride.searchMeta.corridorSelection = "highest-dirt-then-less-pavement-meander";
      return best.ride;
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
    }
    return null;
  }

  const pack = runtime.pack;
  const urbanBoxes =
    pack.meta && Array.isArray(pack.meta.urbanCores) && pack.meta.urbanCores.length
      ? pack.meta.urbanCores
      : undefined;
  const settlementBoxes =
    pack.meta && Array.isArray(pack.meta.settlements)
      ? pack.meta.settlements
      : [];
  const geom = runtime.geom;
  const enums = runtime.enums;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
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
  const total = n + 2;
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

  const startLL = startMatch.coord;
  const endLL = endMatch.coord;
  const abMeters = haversineMeters(startLL, endLL);
  const startOnMajorHighway = pinMatchesMajorHighway(startMatch);
  const endOnMajorHighway = pinMatchesMajorHighway(endMatch);

  function nodeLL(node) {
    if (node === startNode) return startLL;
    if (node === endNode) return endLL;
    if (node >= 0 && node < n && nodeCoords) {
      return [nodeCoords[node * 2], nodeCoords[node * 2 + 1]];
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
  function linkVirt(id) {
    const v = virt[id];
    if (!virtAdj.has(v.a)) virtAdj.set(v.a, []);
    if (!virtAdj.has(v.b)) virtAdj.set(v.b, []);
    virtAdj.get(v.a).push({ to: v.b, id, forward: true });
    virtAdj.get(v.b).push({ to: v.a, id, forward: false });
  }
  linkVirt(vStartA);
  linkVirt(vStartB);
  linkVirt(vEndA);
  linkVirt(vEndB);
  if (vBetween >= 0) linkVirt(vBetween);

  const costMode = searchOpts.costMode || "profile";
  const maxPathMeters = Number.isFinite(Number(searchOpts.maxPathMeters))
    ? Number(searchOpts.maxPathMeters)
    : Infinity;
  const varietyOn = searchOpts.variety !== false && profile !== "cleanest";
  // Every profile treats a recognized urban core as a wall. The caller may
  // explicitly relax the wall only after a wall-respecting search has proved
  // there is no route. A/B inside the same core remain exempt in metroBlocks.
  const cityWall = searchOpts.cityWall !== false;
  const corridorM = Number.isFinite(Number(searchOpts.corridorMeters))
    ? Number(searchOpts.corridorMeters)
    : corridorMetersForProfile(profile);
  const hardCorridor = searchOpts.hardCorridor === true;
  const pavedOnly = searchOpts.pavedOnly === true;
  const urbanCoreFallback = searchOpts.urbanCoreFallback === true;
  const settlementWall = searchOpts.settlementWall === true;
  const settlementFallback = searchOpts.settlementFallback !== false;
  const regressionLimit = Number.isFinite(Number(searchOpts.progressRegressionMeters))
    ? Number(searchOpts.progressRegressionMeters)
    : maxProgressRegressionMeters(profile);
  const applyAwayXt = costMode === "profile" && profile !== "cleanest";
  // Direct means closest practical ride to the A→B great-circle. Its hard
  // corridor is only an outer feasibility wall; keep pulling toward the
  // centreline inside that wall so dirt pricing cannot hug the far edge.
  const applySoftCorridor = applyAwayXt && (profile === "direct" || !(corridorM > 0));
  const isHunt = Number.isFinite(maxPathMeters);
  const boundedSearch = isHunt || searchOpts.boundedSearch === true;
  const slackToDest = isHunt
    ? fillShortestMeters({
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
        settlementBoxes,
        origin: endNode,
        capMeters: maxPathMeters,
        nodeLL
      })
    : null;

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
      popCap: searchOpts.popCap,
      prior,
      arrival,
      backtrackFactor
    });
  }

  const dist = new Float64Array(total);
  dist.fill(Infinity);
  const peakProgress = new Float64Array(total);
  peakProgress.fill(-Infinity);
  const prev = new Int32Array(total);
  prev.fill(-1);
  const prevKind = new Uint8Array(total);
  const prevData = new Int32Array(total);
  const prevForward = new Uint8Array(total);
  const pathMeters = new Float64Array(total);
  pathMeters.fill(Infinity);
  const slots = new Uint8Array(total);
  const heap = new MinHeap();
  dist[startNode] = 0;
  pathMeters[startNode] = 0;
  peakProgress[startNode] = 0;
  heap.push({ node: startNode, cost: 0 });
  let pops = 0;
  let abort = "completed";
  const configuredPopCap = Number(searchOpts.popCap);
  const configuredTimeCapMs = Number(searchOpts.timeCapMs);
  const popCap = boundedSearch
    ? (Number.isFinite(configuredPopCap) ? configuredPopCap : PASS2_POP_CAP)
    : Math.min(8_000_000, total * (VARIETY_SLOTS + 2) * 8);
  const deadline = boundedSearch
    ? Date.now() + (Number.isFinite(configuredTimeCapMs) ? configuredTimeCapMs : PASS2_TIME_MS)
    : 0;

  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    pops += 1;
    if (pops > popCap) {
      abort = "popCap";
      break;
    }
    if (deadline && (pops & 255) === 0 && Date.now() > deadline) {
      abort = "timeCap";
      break;
    }
    if (cur.node === endNode) break;

    if (cur.node < n) {
      const start = nodeOffsets[cur.node];
      const end = nodeOffsets[cur.node + 1];
      for (let i = start; i < end; i += 1) {
        const to = edgeTargets[i];
        const ei = edgeUndirectedIndex[i];
        if (prevKind[cur.node] === 0 && prevData[cur.node] === ei) continue;
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (!accessAllowed(access, policy, enums)) continue;
        if (avoid && avoid.has(pack.edgeId(ei))) continue;
        const toLL = nodeLL(to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(cur.node)
        )) continue;
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) continue;
        const edgeM = edgeMeters[ei];
        const newMeters = pathMeters[cur.node] + edgeM;
        if (exceedsLengthSlack(newMeters, to, slackToDest, maxPathMeters)) continue;
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        if (pavedOnly && isDirtSurface(surfaceName, road)) continue;
        let step;
        if (costMode === "distance") {
          step = edgeM / 1000;
        } else if (costMode === "pavement") {
          // Earned-detour objective: Dirt still strongly prefers unpaved, but
          // every kilometre carries cost and off-line/backward motion is taxed.
          // Corridor width is an outer permission, never free space to consume.
          step = (edgeM / 1000) * dirtRideCostPerKm(
            surfaceName,
            road,
            unpackConfidence(attr)
          );
          if (toLL) {
            step *= majorHighwayAvoidMult(
              profile,
              road,
              haversineMeters(toLL, startLL),
              haversineMeters(toLL, endLL),
              startOnMajorHighway,
              endOnMajorHighway
            );
            step += awayExtra(cur.node, to) * DIRT_RIDE_AWAY_SCALE;
            step += directCrossTrackExtra(profile, toLL, startLL, endLL, edgeM) * DIRT_RIDE_XT_SCALE;
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
              endOnMajorHighway
            );
            step *= cleanCityStreetMult(profile, road, haversineMeters(toLL, endLL));
          } else {
            step *= majorHighwayAvoidMult(profile, road, 1e9, 1e9, false, false);
          }
          if (policy.motorizedUnknown && profile !== "cleanest") {
            const accessName = enums.ACCESS_NAME[access] || "";
            if (accessName === "motorized_unknown") {
              if (profile === "dirt" || profile === "direct") step *= 0.5;
            }
            const id = pack.edgeId(ei);
            if (
              String(id).startsWith("ns-") ||
              String(id).startsWith("nb-fr") ||
              /nstdb|Topographic|Forest Roads/i.test(String(id))
            ) {
              if (profile === "dirt" || profile === "direct") step *= 0.68;
            }
          }
          if (applyAwayXt) {
            step += awayExtra(cur.node, to);
            if (toLL && applySoftCorridor) {
              step += directCrossTrackExtra(profile, toLL, startLL, endLL, edgeM);
            }
          }
        }
        if (urbanCoreFallback && toLL) {
          step *= urbanCoreFallbackMultiplier(toLL[0], toLL[1], startLL, endLL, urbanBoxes);
        }
        if (settlementFallback && toLL) {
          step *= settlementFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, settlementBoxes
          );
        }
        step = penalizeBacktrack(step, pack.edgeId(ei));
        const cost = cur.cost + step;
        const dirt = isDirtSurface(surfaceName, road);
        let action = considerRelax(
          cost,
          dist[to],
          ei,
          prevData[to],
          to,
          sessionSeed,
          varietyOn,
          slots[to],
          dirt,
          false
        );
        if (action === "steal" && createsCycle(prev, cur.node, to)) action = "reject";
        if (applyRelax(action, slots, to)) {
          prev[to] = cur.node;
          prevKind[to] = 0;
          prevData[to] = ei;
          prevForward[to] = edgeFrom[ei] === cur.node ? 1 : 0;
          if (shouldPush(action)) {
            dist[to] = cost;
            pathMeters[to] = newMeters;
            peakProgress[to] = newPeakProgress;
            heap.push({ node: to, cost });
          }
        }
      }
    }

    const vlist = virtAdj.get(cur.node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
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
        if (pavedOnly && isDirtSurface(vSurfaceName, vRoad)) continue;
        let step = costMode === "pavement"
          ? (v.meters / 1000) * dirtRideCostPerKm(vSurfaceName, vRoad, unpackConfidence(vAttr))
          : v.meters / 1000;
        if (costMode === "pavement") {
          step += awayExtra(cur.node, item.to) * DIRT_RIDE_AWAY_SCALE;
          if (toLL) {
            step += directCrossTrackExtra(profile, toLL, startLL, endLL, v.meters) * DIRT_RIDE_XT_SCALE;
          }
        } else if (applyAwayXt) {
          step += awayExtra(cur.node, item.to);
        }
        if (urbanCoreFallback && toLL) {
          step *= urbanCoreFallbackMultiplier(toLL[0], toLL[1], startLL, endLL, urbanBoxes);
        }
        if (settlementFallback && toLL) {
          step *= settlementFallbackMultiplier(
            toLL[0], toLL[1], startLL, endLL, settlementBoxes
          );
        }
        step = penalizeBacktrack(step, pack.edgeId(v.ei));
        const cost = cur.cost + step;
        let action = considerRelax(
          cost,
          dist[item.to],
          v.ei,
          prevData[item.to],
          item.to,
          sessionSeed,
          varietyOn,
          slots[item.to],
          false,
          false
        );
        if (action === "steal" && createsCycle(prev, cur.node, item.to)) action = "reject";
        if (applyRelax(action, slots, item.to)) {
          prev[item.to] = cur.node;
          prevKind[item.to] = 1;
          prevData[item.to] = item.id;
          prevForward[item.to] = item.forward ? 1 : 0;
          if (shouldPush(action)) {
            dist[item.to] = cost;
            pathMeters[item.to] = newMeters;
            peakProgress[item.to] = newPeakProgress;
            heap.push({ node: item.to, cost });
          }
        }
      }
    }
  }

  if (!Number.isFinite(dist[endNode])) {
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
      used.push({
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
      });
    } else {
      const ei = prevData[node];
      const forward = prevForward[node] === 1;
      used.push({
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
      });
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
    const mult = edge.accessLeg ? 1 : surfaceMultiplier(edge.surface, profile, regionId);
    profileCost += (edge.meters / 1000) * mult;
    const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
    const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
    bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + edge.meters;
    if (isDirtSurface(surfaceName, edge.roadClass)) dirtMeters += edge.meters;
    else pavedMeters += edge.meters;
    if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
    movingSeconds += (edge.meters / 1000) / classSpeedKmh(edge.surface) * 3600;
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
      trackClass: edge.roadClass,
      structureType: enums.STRUCTURE_NAME[edge.structure] || "none",
      accessClass: accessName,
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

  const pct = (m) => (distanceMeters > 0 ? Math.round((m / distanceMeters) * 100) : 0);
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
      packFormat: "v2",
      ellipseFactor: Infinity,
      ellipseLabel: "csr-uni",
      ellipseEscalation: "v2_uni",
      profileCost: dist[endNode],
      prunedLoopCount: pruned.prunedLoopCount,
      prunedLoopMeters: Math.round(pruned.prunedMeters),
      pops,
      timedOut: abort === "timeCap" || abort === "popCap",
      pass2Outcome: abort,
      settlementFallbackUsed: settlementCrossingUsed
    },
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
  return annotateCorridorMeta(csrResult, startLL, endLL, profile);
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
    popCap: requestedPopCap,
    prior,
    arrival,
    backtrackFactor
  } = ctx;
  const penalizeBacktrack = (cost, edgeId) => {
    const id = String(edgeId == null ? "" : edgeId);
    if (arrival != null && id === arrival) return cost * 12;
    if (prior && prior.has(id)) return cost * backtrackFactor;
    return cost;
  };
  const B = BALANCED_BUCKETS;
  const labels = (n + 2) * B;
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
  const isHunt = Number.isFinite(maxPathMeters);
  const cappedSearch = isHunt || boundedSearch === true;
  // Balanced carries a surface-ratio label set, so it legitimately needs more
  // expansions than the single-label Dirt/Direct searches. The time deadline
  // remains the ultimate guardrail.
  const popCap = cappedSearch
    ? (Number.isFinite(Number(requestedPopCap)) ? Number(requestedPopCap) : PASS2_POP_CAP * 10)
    : 8_000_000;
  const deadline = cappedSearch
    ? Date.now() + (Number.isFinite(Number(timeCapMs)) ? Number(timeCapMs) : PASS2_TIME_MS)
    : 0;

  function nodeLL(node) {
    if (node === startNode) return startLL;
    if (node === endNode) return endLL;
    if (node >= 0 && node < n && ctx.nodeCoords) {
      return [ctx.nodeCoords[node * 2], ctx.nodeCoords[node * 2 + 1]];
    }
    return null;
  }

  while (heap.items.length) {
    pops += 1;
    if (pops > popCap) {
      abort = "popCap";
      break;
    }
    if (deadline && (pops & 255) === 0 && Date.now() > deadline) {
      abort = "timeCap";
      break;
    }
    const cur = heap.pop();
    if (!cur || cur.g !== dist[cur.node] || cur.searchCost !== score[cur.node]) continue;
    if (cur.g > maxPathMeters) continue;
    const node = nid(cur.node);
    const dirtSoFar = dirtAt[cur.node];
    if (node === endNode) {
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
        if (prevKind[cur.node] === 0 && prevData[cur.node] === ei) continue;
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (!accessAllowed(access, policy, enums)) continue;
        if (avoid && avoid.has(pack.edgeId(ei))) continue;
        const toLL = nodeLL(to);
        if (blockedForRide(
          toLL, startLL, endLL, cityWall, corridorM, hardCorridor, urbanBoxes,
          settlementWall, settlementBoxes, nodeLL(node)
        )) continue;
        const toProgress = projectedProgressMeters(toLL, startLL, endLL);
        const newPeakProgress = Math.max(peakProgress[cur.node], toProgress);
        if (newPeakProgress - toProgress > regressionLimit) continue;
        const edgeM = edgeMeters[ei];
        const newMeters = cur.g + edgeM;
        if (exceedsLengthSlack(newMeters, to, slackToDest, maxPathMeters)) continue;
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        const addDirt = isDirtSurface(surfaceName, road) ? edgeM : 0;
        const newDirt = dirtSoFar + addDirt;
        const b = dirtBucket(newDirt, newMeters);
        const toLab = lab(to, b);
        const settlementMult = settlementFallback && toLL
          ? settlementFallbackMultiplier(toLL[0], toLL[1], startLL, endLL, settlementBoxes)
          : 1;
        const newScore = cur.searchCost
          + penalizeBacktrack(edgeM * settlementMult, pack.edgeId(ei));
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
        const toLab = lab(item.to, b);
        const settlementMult = settlementFallback && toLL
          ? settlementFallbackMultiplier(toLL[0], toLL[1], startLL, endLL, settlementBoxes)
          : 1;
        const newScore = cur.searchCost
          + penalizeBacktrack(v.meters * settlementMult, pack.edgeId(v.ei));
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
  const bestLab = pickResourceEnd(cands, profile, sessionSeed);
  if (bestLab < 0 || !Number.isFinite(dist[bestLab])) {
    if (diagnostics) {
      diagnostics.outcome = abort === "completed" ? "noPath" : abort;
      diagnostics.pops = pops;
    }
    return null;
  }

  const used = [];
  let hops = 0;
  for (let label = bestLab; nid(label) !== startNode; ) {
    hops += 1;
    if (hops > labels + 4) return null;
    const parent = prev[label];
    if (parent < 0) return null;
    if (prevKind[label] === 1) {
      const v = virt[prevData[label]];
      const forward = prevForward[label] === 1;
      used.push({
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
      });
    } else {
      const ei = prevData[label];
      const forward = prevForward[label] === 1;
      used.push({
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
      });
    }
    label = parent;
  }
  used.reverse();
  const pruned = pruneGeographicLoops(used, (edge) => edge.coords);
  const routeEdges = pruned.edges;
  const geometry = [];
  const segments = [];
  let distanceMeters = 0;
  let unknownAccessMeters = 0;
  let movingSeconds = 0;
  let dirtMeters = 0;
  let pavedMeters = 0;
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
    const surfaceName = enums.SURFACE_NAME[edge.surface] || "unknown";
    const accessName = enums.ACCESS_NAME[edge.access] || "motorized_unknown";
    bySurfaceM[surfaceName] = (bySurfaceM[surfaceName] || 0) + edge.meters;
    if (isDirtSurface(surfaceName, edge.roadClass)) dirtMeters += edge.meters;
    else pavedMeters += edge.meters;
    if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
    movingSeconds += ((edge.meters / 1000) / classSpeedKmh(edge.surface)) * 3600;
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
      trackClass: edge.roadClass,
      structureType: enums.STRUCTURE_NAME[edge.structure] || "none",
      accessClass: accessName,
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
  const pct = (m) => (distanceMeters > 0 ? Math.round((m / distanceMeters) * 100) : 0);
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
      packFormat: "v2",
      ellipseFactor: Infinity,
      ellipseLabel: "balanced-resource",
      balancedResource: true,
      dirtPercent: pct(dirtMeters),
      prunedLoopCount: pruned.prunedLoopCount,
      prunedLoopMeters: Math.round(pruned.prunedMeters),
      pops,
      timedOut: abort === "timeCap" || abort === "popCap",
      pass2Outcome: abort,
      settlementFallbackUsed: settlementCrossingUsed
    },
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

module.exports = { findPathV2, chooseDirtRideCandidate, dirtCandidateSummary };
