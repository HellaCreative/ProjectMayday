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
  unpackSeasonal
} = require("./pack-v2");
const { surfaceMultiplier, classSpeedKmh, costPerKmView } = require("./profile-costs");

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

function findPathV2(runtime, startMatch, endMatch, profile, policy, avoidEdgeIds) {
  const pack = runtime.pack;
  const geom = runtime.geom;
  const enums = runtime.enums;
  const avoid = avoidEdgeIds instanceof Set ? avoidEdgeIds : null;
  const n = pack.nodeCount;
  const startNode = n;
  const endNode = n + 1;
  const total = n + 2;
  const costView = costPerKmView(profile);
  const {
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeMeters,
    edgeFrom,
    edgeTo
  } = pack;

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

  const dist = new Float64Array(total);
  dist.fill(Infinity);
  const prev = new Int32Array(total);
  prev.fill(-1);
  // prevKind: 0 = graph undirected ei in prevData; 1 = virt id in prevData; high bit of prevData unused
  const prevKind = new Uint8Array(total);
  const prevData = new Int32Array(total);
  const prevForward = new Uint8Array(total);
  const heap = new MinHeap();
  dist[startNode] = 0;
  heap.push({ node: startNode, cost: 0 });

  while (heap.items.length) {
    const cur = heap.pop();
    if (!cur || cur.cost !== dist[cur.node]) continue;
    if (cur.node === endNode) break;

    if (cur.node < n) {
      const start = nodeOffsets[cur.node];
      const end = nodeOffsets[cur.node + 1];
      for (let i = start; i < end; i += 1) {
        const to = edgeTargets[i];
        const ei = edgeUndirectedIndex[i];
        const attr = edgeAttrs[ei];
        const access = unpackAccess(attr);
        if (!accessAllowed(access, policy, enums)) continue;
        if (avoid && avoid.has(pack.edgeId(ei))) continue;
        const surface = unpackSurface(attr);
        let step = (edgeMeters[ei] / 1000) * costView[surface];
        if (policy.motorizedUnknown && profile !== "cleanest") {
          const accessName = enums.ACCESS_NAME[access] || "";
          if (accessName === "motorized_unknown") {
            if (profile === "dirt") step *= 0.5;
            else if (profile === "direct") step *= 0.78;
            else step *= 0.9; // balanced — journey dirt without owning the corridor
          }
          const id = pack.edgeId(ei);
          if (String(id).startsWith("ns-")) {
            if (profile === "dirt") step *= 0.68;
            else if (profile === "direct") step *= 0.86;
            else step *= 0.93;
          }
          if (profile === "balanced") {
            const surfaceName = enums.SURFACE_NAME[surface] || "";
            if (surfaceName === "paved") step *= 0.9;
            else if (
              surfaceName === "gravel" ||
              surfaceName === "access" ||
              surfaceName === "track"
            ) {
              step *= 1.06;
            }
          }
        }
        const cost = cur.cost + step;
        if (cost < dist[to]) {
          dist[to] = cost;
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
        const step = v.meters / 1000;
        const cost = cur.cost + step;
        if (cost < dist[item.to]) {
          dist[item.to] = cost;
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
    for (const c of edge.coords) {
      const last = geometry[geometry.length - 1];
      if (last && last[0] === c[0] && last[1] === c[1]) continue;
      geometry.push(c);
    }
    distanceMeters += edge.meters;
    const mult = edge.accessLeg ? 1 : surfaceMultiplier(edge.surface, profile);
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
  return {
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
      profileCost: dist[endNode]
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
}

module.exports = { findPathV2 };
