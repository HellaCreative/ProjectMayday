"use strict";

/**
 * Turn-aware V4 search. Incoming directed arc is part of visited state.
 * No coincident-node stitches. No proximity repairs.
 */

const { turnAllowed } = require("./restrictions");

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function accessCode(pack, ei, from, to) {
  const forward = pack.edgeFrom[ei] === from && pack.edgeTo[ei] === to;
  return pack.edgeAccess[ei * 2 + (forward ? 0 : 1)];
}

function endpointOk(code, isEndpoint) {
  if (code === 0) return true;
  if (code === 3 || code === 4) return !!isEndpoint;
  return false;
}

function turnPermitted(pack, cur, ei) {
  for (const r of pack.restrictions || []) {
    if (r.viaEdges && r.viaEdges.length) {
      const seq = [r.fromEdge].concat(r.viaEdges);
      const tail = (cur.pathEdges || []).slice(-seq.length);
      const matches = tail.length === seq.length && tail.every((id, i) => id === seq[i]);
      if (r.only && matches && ei !== r.toEdge) return false;
      if (!r.only && matches && ei === r.toEdge) return false;
      continue;
    }
    if (
      !turnAllowed({
        restrictions: [r],
        fromEdge: cur.incomingEdge,
        toEdge: ei,
        viaNode: cur.node
      })
    ) {
      return false;
    }
  }
  return true;
}

function findPathV4(pack, geom, origin, dest, options = {}) {
  const { legalSnapDetailed, selectConnectedSnapPair } = require("./snap");
  const allowUnknown = options.allowUnknown === true;
  const startDetailed = legalSnapDetailed(pack, geom, origin, {
    headingDeg: options.startHeadingDeg,
    intentBearingDeg: options.intentBearingDeg,
    maxMeters: options.maxMeters,
    zoom: options.zoom,
    allowUnknown
  });
  const endDetailed = legalSnapDetailed(pack, geom, dest, {
    headingDeg: options.endHeadingDeg,
    intentBearingDeg: options.intentBearingDeg != null ? (options.intentBearingDeg + 180) % 360 : null,
    maxMeters: options.maxMeters,
    zoom: options.zoom,
    allowUnknown
  });
  const picked = selectConnectedSnapPair(
    pack,
    startDetailed.candidates,
    endDetailed.candidates,
    { allowUnknown }
  );
  if (!picked.ok) {
    return {
      ok: false,
      reason: picked.reason || "no_snap",
      unprovenStitches: 0,
      snap: {
        allowUnknown,
        start: startDetailed,
        end: endDetailed,
        rejections: picked.rejections
      }
    };
  }
  const startSnaps = [picked.start];
  const endSnaps = [picked.end];

  const destEdges = new Set(endSnaps.map((s) => s.edgeIndex));
  const n = pack.nodeCount;
  const dist = new Map();
  const prev = new Map();
  const heap = [];
  function push(node, incomingEdge, cost, pathEdges) {
    const key = node + ":" + incomingEdge;
    const old = dist.get(key);
    if (old != null && old <= cost) return;
    dist.set(key, cost);
    prev.set(key, pathEdges);
    heap.push({ node, incomingEdge, cost, pathEdges });
  }

  for (const snap of startSnaps) {
    const from = snap.forward ? pack.edgeFrom[snap.edgeIndex] : pack.edgeTo[snap.edgeIndex];
    const to = snap.forward ? pack.edgeTo[snap.edgeIndex] : pack.edgeFrom[snap.edgeIndex];
    const remain = snap.forward
      ? (1 - snap.fraction) * pack.edgeMeters[snap.edgeIndex]
      : snap.fraction * pack.edgeMeters[snap.edgeIndex];
    const code = accessCode(pack, snap.edgeIndex, from, to);
    const isDest = destEdges.has(snap.edgeIndex);
    if (!endpointOk(code, isDest) && code !== 0) continue;
    if (code === 2 || code === 5) continue;
    push(to, snap.edgeIndex, Math.max(1, remain), [snap.edgeIndex]);
    if (isDest) {
      return {
        ok: true,
        distanceMeters: Math.max(1, remain),
        edgeIndexes: [snap.edgeIndex],
        osmWayIds: [pack.osmWayIds[snap.edgeIndex]],
        unprovenStitches: 0
      };
    }
  }

  while (heap.length) {
    heap.sort((a, b) => a.cost - b.cost);
    const cur = heap.shift();
    const key = cur.node + ":" + cur.incomingEdge;
    if (dist.get(key) !== cur.cost) continue;
    if (cur.cost > 1e9) break;
    const start = pack.nodeOffsets[cur.node];
    const end = pack.nodeOffsets[cur.node + 1];
    for (let i = start; i < end; i += 1) {
      const to = pack.edgeTargets[i];
      const ei = pack.edgeUndirectedIndex[i];
      if (ei === cur.incomingEdge) continue;
      const from = cur.node;
      const code = accessCode(pack, ei, from, to);
      const isDest = destEdges.has(ei);
      if (code === 2 || code === 5) continue;
      if (code === 1 && !options.allowUnknown) continue;
      if ((code === 3 || code === 4) && !isDest) continue;
      if (!turnPermitted(pack, cur, ei)) continue;
      const nextCost = cur.cost + pack.edgeMeters[ei];
      const pathEdges = cur.pathEdges.concat([ei]);
      if (isDest) {
        const ways = pathEdges.map((id) => pack.osmWayIds[id]);
        return {
          ok: true,
          distanceMeters: nextCost,
          edgeIndexes: pathEdges,
          osmWayIds: ways,
          unprovenStitches: 0
        };
      }
      push(to, ei, nextCost, pathEdges);
    }
  }
  return { ok: false, reason: "no_route", unprovenStitches: 0 };
}

module.exports = { findPathV4, haversineMeters };
