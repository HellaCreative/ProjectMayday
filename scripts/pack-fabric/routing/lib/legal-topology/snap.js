"use strict";

/**
 * Multi-candidate legal snap. Never invents a median/barrier/grade connector.
 * V4 scores (distance + heading + intent) stay on each directed candidate
 * through pair selection. Connectivity is a later filter, not a rescore.
 */

const { tapRadiusMeters, DEFAULT_SNAP_M } = require("./tap-radius");

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

function projectOnSegment(point, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy || 1e-12;
  let t = ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  const lon = a[0] + dx * t;
  const lat = a[1] + dy * t;
  return { t, distanceM: haversineMeters(point, [lon, lat]), lon, lat };
}

function bearingDeg(a, b) {
  const toRad = (d) => (d * Math.PI) / 180;
  const y = Math.sin(toRad(b[0] - a[0])) * Math.cos(toRad(b[1]));
  const x =
    Math.cos(toRad(a[1])) * Math.sin(toRad(b[1])) -
    Math.sin(toRad(a[1])) * Math.cos(toRad(b[1])) * Math.cos(toRad(b[0] - a[0]));
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

function angleDiff(a, b) {
  let d = Math.abs(a - b) % 360;
  if (d > 180) d = 360 - d;
  return d;
}

function polyline(geom, ei) {
  if (!geom || typeof geom.polyline !== "function") return null;
  return geom.polyline(ei);
}

function edgeAccessCode(pack, ei, forward) {
  if (!pack.edgeAccess) return 0;
  return pack.edgeAccess[ei * 2 + (forward ? 0 : 1)];
}

function accessName(code) {
  if (code === 0) return "motorized_verified";
  if (code === 1) return "motorized_unknown";
  if (code === 2) return "motorized_denied";
  if (code === 3) return "motorized_endpoint";
  if (code === 4) return "motorized_destination";
  if (code === 5) return "motorized_impassable";
  return "motorized_unknown";
}

function directionLegal(pack, ei, forward, allowUnknown) {
  const from = forward ? pack.edgeFrom[ei] : pack.edgeTo[ei];
  const to = forward ? pack.edgeTo[ei] : pack.edgeFrom[ei];
  if (!pack.hasDirectedArc(from, to, ei)) return { ok: false, reason: "prohibited_direction" };
  const code = edgeAccessCode(pack, ei, forward);
  if (code === 2) return { ok: false, reason: "inaccessible" };
  if (code === 5) return { ok: false, reason: "impassable" };
  if (code === 1 && !allowUnknown) return { ok: false, reason: "unknown_trail" };
  return { ok: true, code };
}

function weakComponentIds(pack, allowUnknown) {
  const key = allowUnknown ? "_dirtWeakCompAllow" : "_dirtWeakCompStrict";
  if (pack[key]) return pack[key];
  const n = pack.nodeCount || 0;
  const parent = new Int32Array(n);
  for (let i = 0; i < n; i += 1) parent[i] = i;
  function find(i) {
    while (parent[i] !== i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }
  function union(a, b) {
    if (a < 0 || b < 0 || a >= n || b >= n) return;
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  }
  function member(code) {
    if (code === 0) return true;
    if (code === 1) return !!allowUnknown;
    if (code === 3 || code === 4) return true;
    return false;
  }
  const count = pack.undirectedEdgeCount || 0;
  for (let ei = 0; ei < count; ei += 1) {
    const a = pack.edgeFrom[ei];
    const b = pack.edgeTo[ei];
    const fwd = edgeAccessCode(pack, ei, true);
    const rev = edgeAccessCode(pack, ei, false);
    if (member(fwd) || member(rev)) union(a, b);
  }
  const ids = new Int32Array(n);
  for (let i = 0; i < n; i += 1) ids[i] = find(i);
  pack[key] = ids;
  return ids;
}

function candidateComponent(pack, cand, components) {
  if (!components || !pack.edgeFrom) return -1;
  const a = pack.edgeFrom[cand.edgeIndex];
  const b = pack.edgeTo[cand.edgeIndex];
  const node = cand.forward ? a : b;
  if (node < 0 || node >= components.length) return -1;
  return components[node];
}

function legalSnapDetailed(pack, geom, location, options = {}) {
  const point = [Number(location.lon ?? location.lng), Number(location.lat)];
  const allowUnknown = options.allowUnknown === true;
  const maxM = Number.isFinite(Number(options.maxMeters))
    ? Number(options.maxMeters)
    : tapRadiusMeters({
        zoom: options.zoom,
        lat: point[1],
        requestedMeters: options.requestedMeters,
        graphBinaryVersion: pack.graphBinaryVersion || 4,
        defaultMeters: DEFAULT_SNAP_M
      });
  const customer = options.endpointKind === "customers";
  const heading = !customer && Number.isFinite(options.headingDeg) ? Number(options.headingDeg) : null;
  const intent = !customer && Number.isFinite(options.intentBearingDeg) ? Number(options.intentBearingDeg) : null;
  const candidates = [];
  const rejections = [];
  const scan = Array.isArray(options.candidateEdgeIndexes)
    ? options.candidateEdgeIndexes
    : null;
  const limit = scan ? scan.length : pack.undirectedEdgeCount;
  for (let si = 0; si < limit; si += 1) {
    const ei = scan ? scan[si] : si;
    if (ei == null || ei < 0 || ei >= pack.undirectedEdgeCount) continue;
    const coords = polyline(geom, ei);
    if (!coords || coords.length < 2) continue;
    let along = 0;
    let best = null;
    for (let i = 1; i < coords.length; i += 1) {
      const a = coords[i - 1];
      const b = coords[i];
      const segM = haversineMeters(a, b);
      const projected = projectOnSegment(point, a, b);
      if (!best || projected.distanceM < best.distanceM) {
        best = {
          ...projected,
          along: along + projected.t * segM,
          tangent: bearingDeg(a, b),
          segmentIndex: i - 1
        };
      }
      along += segM;
    }
    if (!best) continue;
    if (best.distanceM > maxM) {
      rejections.push({
        edgeIndex: ei,
        osmWayId: pack.osmWayIds ? pack.osmWayIds[ei] : null,
        reason: "outside_tap_radius",
        distanceM: best.distanceM
      });
      continue;
    }
    const layer = pack.edgeLeaves && pack.edgeLeaves(ei) ? pack.edgeLeaves(ei).layer : 0;
    const dirs = [
      { forward: true, tangent: best.tangent },
      { forward: false, tangent: (best.tangent + 180) % 360 }
    ];
    for (const dir of dirs) {
      const legal = directionLegal(pack, ei, dir.forward, allowUnknown);
      if (!legal.ok) {
        rejections.push({
          edgeIndex: ei,
          osmWayId: pack.osmWayIds ? pack.osmWayIds[ei] : null,
          reason: legal.reason,
          forward: dir.forward,
          distanceM: best.distanceM
        });
        continue;
      }
      let score = best.distanceM;
      if (heading != null) score += angleDiff(heading, dir.tangent) * 0.4;
      if (intent != null) score += angleDiff(intent, dir.tangent) * 0.25;
      candidates.push({
        edgeIndex: ei,
        osmWayId: pack.osmWayIds ? pack.osmWayIds[ei] : null,
        distanceM: best.distanceM,
        fraction: pack.edgeMeters[ei] ? best.along / pack.edgeMeters[ei] : 0,
        forward: dir.forward,
        tangent: dir.tangent,
        parentEdge: ei,
        score,
        highway: null,
        lon: best.lon,
        lat: best.lat,
        segmentIndex: best.segmentIndex,
        distanceAlongM: best.along,
        accessCode: legal.code,
        accessClass: accessName(legal.code),
        layer: layer || 0
      });
    }
  }
  candidates.sort((a, b) => a.score - b.score);
  const kept = [];
  for (const cand of candidates) {
    const opposite = kept.find(
      (k) =>
        k.edgeIndex !== cand.edgeIndex &&
        k.distanceM < 80 &&
        cand.distanceM < 80 &&
        angleDiff(k.tangent, cand.tangent) > 140
    );
    const headingRef = heading != null ? heading : intent;
    if (opposite && headingRef != null) {
      if (angleDiff(headingRef, cand.tangent) > 70 && angleDiff(headingRef, opposite.tangent) < 40) {
        rejections.push({
          edgeIndex: cand.edgeIndex,
          osmWayId: cand.osmWayId,
          reason: "median_opposite_carriageway",
          forward: cand.forward,
          distanceM: cand.distanceM
        });
        continue;
      }
    }
    kept.push(cand);
    if (kept.length >= 12) break;
  }
  return {
    // A selected station is a fixed anchor, not a tap that may be moved to a
    // better-facing road. Keep only co-located nearest legal projections.
    candidates: customer && kept.length
      ? kept.filter(c => c.distanceM <= kept[0].distanceM + 2) : kept,
    rejections,
    radiusMeters: maxM,
    raw: { lon: point[0], lat: point[1] }
  };
}

function legalSnap(pack, geom, location, options = {}) {
  return legalSnapDetailed(pack, geom, location, options).candidates;
}

function selectConnectedSnapPair(pack, startCands, endCands, options = {}) {
  const allowUnknown = options.allowUnknown === true;
  const components = weakComponentIds(pack, allowUnknown);
  const starts = Array.isArray(startCands) ? startCands : [];
  const ends = Array.isArray(endCands) ? endCands : [];
  const rejections = [];
  const pairs = [];
  for (const start of starts) {
    start.component = candidateComponent(pack, start, components);
    for (const end of ends) {
      end.component = candidateComponent(pack, end, components);
      pairs.push({
        start,
        end,
        score: Number(start.score) + Number(end.score)
      });
    }
  }
  pairs.sort((a, b) => a.score - b.score);
  for (const pair of pairs) {
    if (pair.start.component !== pair.end.component) {
      rejections.push({
        reason: "disconnected_component",
        startOsmWayId: pair.start.osmWayId,
        endOsmWayId: pair.end.osmWayId,
        startComponent: pair.start.component,
        endComponent: pair.end.component,
        startScore: pair.start.score,
        endScore: pair.end.score
      });
      continue;
    }
    return {
      ok: true,
      start: pair.start,
      end: pair.end,
      rejections,
      pairCount: pairs.length,
      allowUnknown
    };
  }
  return {
    ok: false,
    reason: starts.length && ends.length ? "no_connected_candidate" : "no_legal_snap",
    rejections,
    pairCount: pairs.length,
    allowUnknown
  };
}

function snapEndpointRecord(raw, picked, extras = {}) {
  const snapped = picked
    ? { lon: picked.lon, lat: picked.lat }
    : null;
  return {
    raw: raw || null,
    snapped,
    distanceM: picked && Number.isFinite(picked.distanceM) ? Math.round(picked.distanceM) : null,
    candidateCount: extras.candidateCount != null ? extras.candidateCount : null,
    osmWayId: picked && picked.osmWayId != null ? String(picked.osmWayId) : null,
    accessClass: picked && picked.accessClass ? picked.accessClass : null,
    component: picked && picked.component != null ? picked.component : null,
    rejectionReasons: extras.rejectionReasons || []
  };
}

module.exports = {
  legalSnap,
  legalSnapDetailed,
  selectConnectedSnapPair,
  weakComponentIds,
  snapEndpointRecord,
  haversineMeters,
  bearingDeg,
  angleDiff,
  tapRadiusMeters
};
