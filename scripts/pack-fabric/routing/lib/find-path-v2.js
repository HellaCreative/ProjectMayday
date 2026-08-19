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
  isDirtSurface,
  varietyHash,
  hopBlocked,
  annotateCorridorMeta,
  corridorMetersForProfile,
  VARIETY_SLOTS,
  BALANCED_STRETCH,
  BALANCED_DIRT_LO,
  BALANCED_DIRT_HI,
  BALANCED_BUCKETS,
  dirtBucket
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

function isOpenStreetMapSource(source) {
  return /openstreetmap/i.test(String(source || ""));
}

function accessAllowed(accessCode, policy, enums, edgeOrSource) {
  const source =
    typeof edgeOrSource === "string"
      ? edgeOrSource
      : edgeOrSource && (edgeOrSource.src || edgeOrSource.source);
  if (isOpenStreetMapSource(source)) {
    return policy.motorizedPermissive !== false;
  }
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

function findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, searchOpts) {
  searchOpts = searchOpts || {};
  const sessionSeed = Number(searchOpts.sessionSeed) || 0;
  if (profile === "direct" && !searchOpts.costMode) {
    return findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, {
      costMode: "pavement",
      sessionSeed,
      variety: true
    });
  }
  if (profile === "balanced" && !searchOpts.costMode) {
    const shortest = findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, {
      costMode: "distance",
      sessionSeed,
      variety: false
    });
    if (!shortest) return null;
    const mix = findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds, pavedBias, {
      costMode: "balancedResource",
      maxPathMeters: shortest.distanceMeters * BALANCED_STRETCH,
      shortestMeters: shortest.distanceMeters,
      sessionSeed,
      variety: true
    });
    if (mix) {
      mix.searchMeta = mix.searchMeta || {};
      mix.searchMeta.balancedResource = true;
      mix.searchMeta.lengthStretch =
        shortest.distanceMeters > 0 ? mix.distanceMeters / shortest.distanceMeters : 1;
      return mix;
    }
    return shortest;
  }

  const pack = runtime.pack;
  const geom = runtime.geom;
  const enums = runtime.enums;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
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
  const cityWall = profile !== "cleanest";
  const corridorM = Number.isFinite(Number(searchOpts.corridorMeters))
    ? Number(searchOpts.corridorMeters)
    : corridorMetersForProfile(profile);
  const applyAwayXt = costMode === "profile" && profile !== "cleanest";
  const applySoftCorridor = applyAwayXt && !(corridorM > 0);

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
      corridorM,
      varietyOn
    });
  }

  const dist = new Float64Array(total);
  dist.fill(Infinity);
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
  heap.push({ node: startNode, cost: 0 });
  let pops = 0;
  const popCap = Math.min(8_000_000, total * (VARIETY_SLOTS + 2) * 8);

  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    pops += 1;
    if (pops > popCap) break;
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
        if (hopBlocked(toLL, startLL, endLL, cityWall, corridorM)) continue;
        const edgeM = edgeMeters[ei];
        const newMeters = pathMeters[cur.node] + edgeM;
        if (newMeters > maxPathMeters) continue;
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        let step;
        if (costMode === "distance") {
          step = edgeM / 1000;
        } else if (costMode === "pavement") {
          const dirt = isDirtSurface(surfaceName, road);
          step = dirt ? (edgeM / 1000) * 0.02 : edgeM / 1000;
          if (toLL) {
            step *= majorHighwayAvoidMult(
              profile,
              road,
              haversineMeters(toLL, startLL),
              haversineMeters(toLL, endLL),
              startOnMajorHighway,
              endOnMajorHighway
            );
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
        const cost = cur.cost + step;
        const dirt = isDirtSurface(surfaceName, road);
        const action = considerRelax(
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
        if (applyRelax(action, slots, to)) {
          dist[to] = cost;
          pathMeters[to] = newMeters;
          prev[to] = cur.node;
          prevKind[to] = 0;
          prevData[to] = ei;
          prevForward[to] = edgeFrom[ei] === cur.node ? 1 : 0;
          heap.push({ node: to, cost });
        }
      }
    }

    const vlist = virtAdj.get(cur.node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        const toLL = nodeLL(item.to);
        if (hopBlocked(toLL, startLL, endLL, cityWall, corridorM)) continue;
        const newMeters = pathMeters[cur.node] + v.meters;
        if (newMeters > maxPathMeters) continue;
        let step = v.meters / 1000;
        if (applyAwayXt) {
          step += awayExtra(cur.node, item.to);
        }
        const cost = cur.cost + step;
        const action = considerRelax(
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
        if (applyRelax(action, slots, item.to)) {
          dist[item.to] = cost;
          pathMeters[item.to] = newMeters;
          prev[item.to] = cur.node;
          prevKind[item.to] = 1;
          prevData[item.to] = item.id;
          prevForward[item.to] = item.forward ? 1 : 0;
          heap.push({ node: item.to, cost });
        }
      }
    }
  }

  if (!Number.isFinite(dist[endNode])) return null;

  const used = [];
  for (let node = endNode; node !== startNode; ) {
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
    if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
    movingSeconds += (edge.meters / 1000) / classSpeedKmh(edge.surface) * 3600;
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
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
  // Adventure / dirt share: gravel + access/resource + track + unknown.
  const dirtMeters =
    (bySurfaceM.gravel || 0) +
    (bySurfaceM.access || 0) +
    (bySurfaceM.resource || 0) +
    (bySurfaceM.track || 0) +
    (bySurfaceM.double_track || 0) +
    (bySurfaceM.unknown || 0) +
    (bySurfaceM.single || 0);
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
      prunedLoopMeters: Math.round(pruned.prunedMeters)
    },
    stats: {
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
    corridorM,
    varietyOn
  } = ctx;
  const B = BALANCED_BUCKETS;
  const labels = (n + 2) * B;
  const lab = (node, b) => node * B + b;
  const nid = (label) => Math.floor(label / B);
  const dist = new Float64Array(labels);
  dist.fill(Infinity);
  const dirtAt = new Float64Array(labels);
  const prev = new Int32Array(labels);
  prev.fill(-1);
  const prevKind = new Uint8Array(labels);
  const prevData = new Int32Array(labels);
  const prevForward = new Uint8Array(labels);
  const slots = new Uint8Array(labels);
  const heap = new MinHeap();
  const startLab = lab(startNode, 0);
  dist[startLab] = 0;
  heap.push({ node: startLab, cost: 0 });
  let pops = 0;

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
    if (pops > 8000000) break;
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    if (cur.cost > maxPathMeters) continue;
    const node = nid(cur.node);
    const dirtSoFar = dirtAt[cur.node];
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
        if (hopBlocked(toLL, startLL, endLL, cityWall, corridorM)) continue;
        const edgeM = edgeMeters[ei];
        const newMeters = cur.cost + edgeM;
        if (newMeters > maxPathMeters) continue;
        const surface = unpackSurface(attr);
        const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
        const surfaceName = enums.SURFACE_NAME[surface] || "unknown";
        const addDirt = isDirtSurface(surfaceName, road) ? edgeM : 0;
        const newDirt = dirtSoFar + addDirt;
        const b = dirtBucket(newDirt, shortestMeters);
        const toLab = lab(to, b);
        const action = considerRelax(
          newMeters,
          dist[toLab],
          ei,
          prevData[toLab],
          to,
          sessionSeed,
          varietyOn,
          slots[toLab],
          addDirt > 0,
          dirtAt[toLab] > (Number.isFinite(dist[toLab]) ? dist[toLab] * 0.4 : 0)
        );
        if (applyRelax(action, slots, toLab)) {
          dist[toLab] = newMeters;
          dirtAt[toLab] = newDirt;
          prev[toLab] = cur.node;
          prevKind[toLab] = 0;
          prevData[toLab] = ei;
          prevForward[toLab] = edgeFrom[ei] === node ? 1 : 0;
          heap.push({ node: toLab, cost: newMeters });
        }
      }
    }
    const vlist = virtAdj.get(node);
    if (vlist) {
      for (let vi = 0; vi < vlist.length; vi += 1) {
        const item = vlist[vi];
        const v = virt[item.id];
        const toLL = nodeLL(item.to);
        if (hopBlocked(toLL, startLL, endLL, cityWall, corridorM)) continue;
        const newMeters = cur.cost + v.meters;
        if (newMeters > maxPathMeters) continue;
        const b = dirtBucket(dirtSoFar, shortestMeters);
        const toLab = lab(item.to, b);
        if (newMeters < dist[toLab]) {
          dist[toLab] = newMeters;
          dirtAt[toLab] = dirtSoFar;
          prev[toLab] = cur.node;
          prevKind[toLab] = 1;
          prevData[toLab] = item.id;
          prevForward[toLab] = item.forward ? 1 : 0;
          heap.push({ node: toLab, cost: newMeters });
        }
      }
    }
  }

  let bestLab = -1;
  let bestLen = Infinity;
  let bestDelta = Infinity;
  const inBand = [];
  for (let b = 0; b < B; b += 1) {
    const endLab = lab(endNode, b);
    const len = dist[endLab];
    if (!Number.isFinite(len) || len <= 0) continue;
    const ratio = dirtAt[endLab] / len;
    if (ratio >= BALANCED_DIRT_LO && ratio <= BALANCED_DIRT_HI) {
      inBand.push({ lab: endLab, len, dirt: dirtAt[endLab] });
    }
    const delta = Math.abs(ratio - 0.5);
    if (delta < bestDelta || (Math.abs(delta - bestDelta) < 1e-6 && len < bestLen)) {
      bestDelta = delta;
      bestLen = len;
      bestLab = endLab;
    }
  }
  if (inBand.length) {
    const minLen = Math.min.apply(
      null,
      inBand.map((x) => x.len)
    );
    const near = inBand.filter((x) => x.len <= minLen * (1 + 0.08));
    near.sort((a, c) => {
      const ha = varietyHash(sessionSeed, nid(a.lab), a.lab);
      const hb = varietyHash(sessionSeed, nid(c.lab), c.lab);
      if (ha !== hb) return ha - hb;
      return c.dirt - a.dirt;
    });
    bestLab = near[0].lab;
  }
  if (bestLab < 0 || !Number.isFinite(dist[bestLab])) return null;

  const used = [];
  for (let label = bestLab; nid(label) !== startNode; ) {
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
    if (byAccessM[accessName] != null) byAccessM[accessName] += edge.meters;
    if (accessName === "motorized_unknown") unknownAccessMeters += edge.meters;
    movingSeconds += ((edge.meters / 1000) / classSpeedKmh(edge.surface)) * 3600;
    segments.push({
      edgeId: edge.edgeId,
      surfaceClass: surfaceName,
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
  const dirtMeters =
    (bySurfaceM.gravel || 0) +
    (bySurfaceM.access || 0) +
    (bySurfaceM.resource || 0) +
    (bySurfaceM.track || 0) +
    (bySurfaceM.double_track || 0) +
    (bySurfaceM.unknown || 0) +
    (bySurfaceM.single || 0);
  const mixResult = {
    geometry,
    segments,
    distanceMeters,
    unknownAccessMeters,
    movingSeconds,
    profileCost: dist[bestLab],
    searchMeta: {
      bidir: false,
      packFormat: "v2",
      ellipseFactor: Infinity,
      ellipseLabel: "balanced-resource",
      balancedResource: true,
      dirtPercent: pct(dirtMeters),
      prunedLoopCount: pruned.prunedLoopCount,
      prunedLoopMeters: Math.round(pruned.prunedMeters)
    },
    stats: {
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
    }
  };
  return annotateCorridorMeta(mixResult, startLL, endLL, profile);
}

module.exports = { findPathV2 };
