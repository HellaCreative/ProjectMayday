"use strict";

/**
 * Build a V4 graph from lossless OSM objects. Topology identity is OSM ids.
 */

const { evaluateMotorcycleAccess } = require("./motorcycle-access");
const { travelDirectionV4, legalDirectedArcs } = require("./direction");
const { isBarrierNode, evaluateBarrier, decisionCode } = require("./barriers");
const { parseRestrictionRelation } = require("./restrictions");
const { collectConditionalRules, accessCodeFromRules } = require("./conditional");
const { classify, leafFieldsFromProps } = require("../../adapters/osm-roads");
const { surfaceForCosting, accessForPolicy } = require("../../schema/enums");
const { ferryCrossingSeconds } = require("../ferry");

const SURFACE_CODE = {
  paved: 0,
  gravel: 1,
  access: 2,
  track: 3,
  unknown: 4,
  resource: 2,
  double_track: 3
};
const ACCESS_CODE = {
  motorized_verified: 0,
  motorized_permissive: 1,
  motorized_unknown: 2,
  motorized_restricted: 3,
  motorized_excluded: 4,
  restricted: 3,
  excluded: 4
};
const STRUCTURE_CODE = {
  none: 0,
  bridge: 1,
  tunnel: 2,
  ford: 3,
  ferry: 4,
  blocked_passage: 5,
  unknown: 6
};

function frozenCostFields(tags, meters) {
  const classified = classify(tags || {});
  const leaves = leafFieldsFromProps(tags || {});
  const surfaceClass = classified.ok ? classified.surfaceClass : "unknown";
  const accessClass = classified.ok ? classified.accessClass : "motorized_unknown";
  const costSurface = surfaceForCosting(surfaceClass);
  const policyAccess = accessForPolicy(accessClass);
  return {
    s: SURFACE_CODE[costSurface] != null ? SURFACE_CODE[costSurface] : SURFACE_CODE.unknown,
    ac: ACCESS_CODE[policyAccess] != null ? ACCESS_CODE[policyAccess] : ACCESS_CODE.motorized_unknown,
    t: STRUCTURE_CODE[classified.ok ? classified.structureType : "none"] || 0,
    rt: classified.ok ? classified.roadTrackClass : "unknown",
    conf: classified.ok ? classified.confidence : "low",
    seasonal: !!(tags && (tags.seasonal || tags.winter_road || tags.ice_road)),
    surfaceLeaf: leaves.surfaceLeaf,
    roadClassLeaf: leaves.roadClassLeaf,
    tracktype: leaves.tracktype,
    smoothness: leaves.smoothness,
    layer: leaves.layer,
    structureLeaf: leaves.structureLeaf,
    accessLeaf: leaves.accessLeaf,
    atvDesignated: !!leaves.atvDesignated,
    xs: classified.ok && classified.isFerry
      ? ferryCrossingSeconds(meters, tags && (tags.duration || tags["duration:interval"]))
      : 0
  };
}

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

function gradeOf(tags = {}) {
  const bridge = String(tags.bridge || "").toLowerCase();
  const tunnel = String(tags.tunnel || "").toLowerCase();
  if (bridge && bridge !== "no") return "bridge";
  if (tunnel && tunnel !== "no") return "tunnel";
  if (tags.layer != null && String(tags.layer).trim() !== "") return `layer:${tags.layer}`;
  if (tags.level != null && String(tags.level).trim() !== "") return `level:${tags.level}`;
  return "ground";
}

const KEEP_HIGHWAY = new Set([
  "motorway",
  "motorway_link",
  "trunk",
  "trunk_link",
  "primary",
  "primary_link",
  "secondary",
  "secondary_link",
  "tertiary",
  "tertiary_link",
  "unclassified",
  "residential",
  "living_street",
  "road",
  "service",
  "track",
  "path"
]);

function isRoutableWay(way) {
  const tags = way.tags || {};
  if (String(tags.route || "").toLowerCase() === "ferry") return true;
  return KEEP_HIGHWAY.has(String(tags.highway || "").toLowerCase());
}

function buildGraphFromOsm(osm, options = {}) {
  const timezone = options.timezone || "America/Halifax";
  const now = options.now || new Date();
  const rejected = [];
  const nodesById = new Map();
  for (const node of osm.nodes || []) {
    nodesById.set(String(node.id), node);
  }
  const ways = (osm.ways || []).filter(isRoutableWay);
  const wayById = new Map(ways.map((w) => [String(w.id), w]));

  const touch = new Map();
  function touchNode(id) {
    touch.set(id, (touch.get(id) || 0) + 1);
  }
  for (const way of ways) {
    const ids = (way.nodeIds || []).map(String);
    if (!ids.length) continue;
    const seen = new Set();
    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      touchNode(id);
    }
  }

  const split = new Set();
  for (const [id, count] of touch) {
    if (count >= 2) split.add(id);
  }
  for (const way of ways) {
    const ids = (way.nodeIds || []).map(String);
    if (ids.length) {
      split.add(ids[0]);
      split.add(ids[ids.length - 1]);
    }
    for (const id of ids) {
      const node = nodesById.get(id);
      if (node && isBarrierNode(node.tags || {})) split.add(id);
    }
  }

  const restrictionParse = [];
  for (const rel of osm.relations || []) {
    const parsed = parseRestrictionRelation(rel);
    if (!parsed.ok) {
      rejected.push({ kind: "restriction", osmRelationId: parsed.osmRelationId, reason: parsed.reason });
      continue;
    }
    restrictionParse.push(parsed.restriction);
    for (const id of parsed.restriction.viaNodeIds) split.add(String(id));
  }

  const graphNodes = [];
  const graphIndex = new Map();
  function addGraphNode(osmId) {
    const key = String(osmId);
    if (graphIndex.has(key)) return graphIndex.get(key);
    const src = nodesById.get(key);
    if (!src || !Number.isFinite(src.lon) || !Number.isFinite(src.lat)) {
      rejected.push({ kind: "node", osmNodeId: key, reason: "missing_node" });
      return -1;
    }
    const index = graphNodes.length;
    graphNodes.push({
      osmNodeId: key,
      lon: src.lon,
      lat: src.lat,
      tags: src.tags || {}
    });
    graphIndex.set(key, index);
    return index;
  }

  for (const id of split) addGraphNode(id);

  const barriers = [];
  for (const [osmId, gi] of graphIndex) {
    const src = nodesById.get(osmId);
    if (!src || !isBarrierNode(src.tags || {})) continue;
    const ev = evaluateBarrier(src.tags || {});
    barriers.push({
      osmNodeId: osmId,
      graphNode: gi,
      decision: ev.decision,
      decisionCode: decisionCode(ev.decision),
      reason: ev.reason,
      barrier: ev.barrier
    });
    if (ev.decision === "fail_closed") {
      rejected.push({ kind: "barrier", osmNodeId: osmId, reason: ev.reason });
    }
  }
  const blockedNodes = new Set(
    barriers.filter((b) => b.decision !== "allow").map((b) => b.graphNode)
  );

  const edges = [];
  const wayEdgeIndex = new Map();

  for (const way of ways) {
    const ids = (way.nodeIds || []).map(String);
    const splitAt = [];
    for (let i = 0; i < ids.length; i += 1) {
      if (graphIndex.has(ids[i])) splitAt.push(i);
    }
    const wayEdges = [];
    for (let s = 0; s < splitAt.length - 1; s += 1) {
      const i0 = splitAt[s];
      const i1 = splitAt[s + 1];
      const fromOsm = ids[i0];
      const toOsm = ids[i1];
      const from = graphIndex.get(fromOsm);
      const to = graphIndex.get(toOsm);
      if (from == null || to == null || from < 0 || to < 0) continue;
      const coords = [];
      let meters = 0;
      for (let i = i0; i <= i1; i += 1) {
        const n = nodesById.get(ids[i]);
        if (!n) continue;
        const c = [n.lon, n.lat];
        if (coords.length) meters += haversineMeters(coords[coords.length - 1], c);
        coords.push(c);
      }
      if (coords.length < 2) continue;
      const tags = way.tags || {};
      const access = evaluateMotorcycleAccess(tags);
      const cond = collectConditionalRules(tags, timezone);
      for (const row of cond.rejected) {
        rejected.push({ kind: "conditional", osmWayId: String(way.id), reason: row.reason, tag: row.tag });
      }
      const direction = travelDirectionV4(tags);
      const arcs = legalDirectedArcs(direction);
      let forwardCode = accessCodeFromRules(access.forward.code, cond.rules, now);
      let reverseCode = accessCodeFromRules(access.reverse.code, cond.rules, now);
      if (blockedNodes.has(from) || blockedNodes.has(to)) {
        forwardCode = 2;
        reverseCode = 2;
      }
      if (!arcs.forward) forwardCode = 2;
      if (!arcs.reverse) reverseCode = 2;
      const ei = edges.length;
      const cost = frozenCostFields(tags, meters);
      edges.push({
        index: ei,
        osmWayId: String(way.id),
        from,
        to,
        meters,
        coords,
        direction,
        accessForward: forwardCode,
        accessReverse: reverseCode,
        layer: cost.layer,
        grade: gradeOf(tags),
        highway: tags.highway || null,
        smoothness: cost.smoothness,
        surfaceLeaf: cost.surfaceLeaf,
        roadClassLeaf: cost.roadClassLeaf,
        tracktype: cost.tracktype,
        structureLeaf: cost.structureLeaf,
        accessLeaf: cost.accessLeaf,
        atvDesignated: cost.atvDesignated,
        s: cost.s,
        ac: cost.ac,
        t: cost.t,
        rt: cost.rt,
        conf: cost.conf,
        seasonal: cost.seasonal,
        xs: cost.xs,
        tags
      });
      wayEdges.push(ei);
    }
    wayEdgeIndex.set(String(way.id), wayEdges);
  }

  function edgeOnWayTouchingNode(wayId, graphNode) {
    const list = wayEdgeIndex.get(String(wayId)) || [];
    return list.filter((ei) => edges[ei].from === graphNode || edges[ei].to === graphNode);
  }

  const restrictions = [];
  for (const r of restrictionParse) {
    const viaGraph = r.viaNodeIds.map((id) => graphIndex.get(String(id))).filter((v) => v != null);
    const viaNode = viaGraph.length ? viaGraph[0] : null;
    let fromEdges = [];
    let toEdges = [];
    if (viaNode != null) {
      fromEdges = edgeOnWayTouchingNode(r.fromWayId, viaNode);
      toEdges = edgeOnWayTouchingNode(r.toWayId, viaNode);
    } else {
      fromEdges = wayEdgeIndex.get(String(r.fromWayId)) || [];
      toEdges = wayEdgeIndex.get(String(r.toWayId)) || [];
    }
    if (!fromEdges.length || !toEdges.length) {
      rejected.push({ kind: "restriction", osmRelationId: r.osmRelationId, reason: "unresolved_members" });
      continue;
    }
    for (const fromEdge of fromEdges) {
      for (const toEdge of toEdges) {
        restrictions.push({
          ...r,
          fromEdge,
          toEdge,
          viaNode: viaNode == null ? -1 : viaNode,
          viaWayCount: r.viaWayIds.length,
          viaEdges: (r.viaWayIds || []).flatMap((id) => wayEdgeIndex.get(String(id)) || [])
        });
      }
    }
  }

  return {
    nodes: graphNodes,
    edges,
    barriers,
    restrictions,
    rejected,
    timezone,
    unprovenStitches: 0
  };
}

function countsFromGraph(graph) {
  const directional = graph.edges.filter((e) => e.accessForward !== e.accessReverse).length;
  const endpoint = graph.edges.filter(
    (e) => e.accessForward === 3 || e.accessForward === 4 || e.accessReverse === 3 || e.accessReverse === 4
  ).length;
  const impassable = graph.edges.filter((e) => String(e.smoothness || "").toLowerCase() === "impassable").length;
  const oneWay = graph.edges.filter((e) => e.direction === "forward" || e.direction === "reverse").length;
  const closed = graph.edges.filter((e) => e.direction === "closed").length;
  const rejectedBy = {};
  for (const row of graph.rejected || []) {
    const key = `${row.kind}:${row.reason}`;
    rejectedBy[key] = (rejectedBy[key] || 0) + 1;
  }
  return {
    nodes: graph.nodes.length,
    edges: graph.edges.length,
    restrictions: graph.restrictions.length,
    barriers: graph.barriers.length,
    directionalAccess: directional,
    endpointOnly: endpoint,
    impassable,
    oneWay,
    closedDirection: closed,
    unprovenStitches: graph.unprovenStitches || 0,
    rejected: (graph.rejected || []).length,
    rejectedBy
  };
}

module.exports = {
  buildGraphFromOsm,
  countsFromGraph,
  KEEP_HIGHWAY,
  gradeOf,
  haversineMeters
};
