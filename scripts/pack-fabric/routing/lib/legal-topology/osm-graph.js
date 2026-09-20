"use strict";

/**
 * Build a V4 graph from lossless OSM objects. Topology identity is OSM ids.
 */

const { evaluateMotorcycleAccess } = require("./motorcycle-access");
const { travelDirectionV4, legalDirectedArcs } = require("./direction");
const { isBarrierNode, evaluateBarrier, decisionCode } = require("./barriers");
const { parseRestrictionRelation } = require("./restrictions");
const { repairRepeatedSource } = require("./repeated-source-repair");
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
  // The legacy display adapter excludes pedestrian/cycle classes wholesale.
  // V4 retains a mapped way when motor access is explicitly granted. Use its
  // path surface costs, while retaining the original leaves and evaluating
  // legal access/direction separately from the unmodified source tags.
  const costTags = explicitlyMotorizedSupplemental(tags) ? {
    ...tags, highway: "path", access: "yes", vehicle: "yes", motor_vehicle: "yes", motorcycle: "yes"
  } : tags;
  const classified = classify(costTags || {});
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
  return KEEP_HIGHWAY.has(String(tags.highway || "").toLowerCase()) || explicitlyMotorizedSupplemental(tags);
}

function explicitlyMotorizedSupplemental(tags = {}) {
  if (!["footway", "cycleway", "bridleway", "pedestrian"].includes(String(tags.highway || "").toLowerCase())) return false;
  const positive = ["yes", "designated", "permissive", "official"];
  const explicit = ["vehicle", "motor_vehicle", "motorcycle"].some(base =>
    [base, `${base}:forward`, `${base}:backward`].some(key => positive.includes(String(tags[key] || "").toLowerCase().trim())));
  if (!explicit) return false;
  const legal = evaluateMotorcycleAccess(tags);
  return legal.forward.code === 0 || legal.reverse.code === 0;
}

function nodesForWayEdges(edgeIndexes, edges) {
  const nodes = new Set();
  for (const ei of edgeIndexes || []) {
    const edge = edges[ei];
    if (!edge) continue;
    nodes.add(edge.from);
    nodes.add(edge.to);
  }
  return nodes;
}

function sharedWayNodes(leftEdges, rightEdges, edges) {
  const left = nodesForWayEdges(leftEdges, edges);
  return [...nodesForWayEdges(rightEdges, edges)].filter((node) => left.has(node));
}

/** Return the ordered edge chain on one OSM way between two graph nodes. */
function orderedWayPath(edgeIndexes, edges, startNode, endNode) {
  if (startNode === endNode || !edgeIndexes || !edgeIndexes.length) return null;
  const sequence = [edges[edgeIndexes[0]].from];
  for (const ei of edgeIndexes) {
    const edge = edges[ei];
    if (!edge || sequence[sequence.length - 1] !== edge.from) return null;
    sequence.push(edge.to);
  }
  const starts = [];
  const ends = [];
  for (let i = 0; i < sequence.length; i += 1) {
    if (sequence[i] === startNode) starts.push(i);
    if (sequence[i] === endNode) ends.push(i);
  }
  const candidates = [];
  for (const a of starts) {
    for (const b of ends) {
      if (a === b) continue;
      candidates.push(a < b
        ? edgeIndexes.slice(a, b)
        : edgeIndexes.slice(b, a).reverse());
    }
  }
  const unique = new Map(candidates.map((row) => [row.join(","), row]));
  return unique.size === 1 ? [...unique.values()][0] : null;
}

/**
 * Resolve an OSM via-way relation into exact graph-edge sequences. Relation
 * member order is retained, and each member must connect to its neighbours by
 * shared OSM node identity. Coordinate proximity is never accepted.
 */
function resolveViaWayPaths(restriction, wayEdgeIndex, edges) {
  const viaWayIds = restriction.viaWayIds || [];
  if (!viaWayIds.length) return [];
  const chainWayIds = [restriction.fromWayId, ...viaWayIds, restriction.toWayId];
  const junctionOptions = [];
  for (let i = 0; i < chainWayIds.length - 1; i += 1) {
    const shared = sharedWayNodes(
      wayEdgeIndex.get(String(chainWayIds[i])) || [],
      wayEdgeIndex.get(String(chainWayIds[i + 1])) || [],
      edges
    );
    if (!shared.length) return [];
    junctionOptions.push(shared);
  }

  const results = [];
  const seen = new Set();
  function choose(at, junctions) {
    if (results.length > 64) return;
    if (at < junctionOptions.length) {
      for (const node of junctionOptions[at]) choose(at + 1, junctions.concat(node));
      return;
    }
    const viaEdges = [];
    const expandedWayIds = [];
    for (let i = 0; i < viaWayIds.length; i += 1) {
      const path = orderedWayPath(
        wayEdgeIndex.get(String(viaWayIds[i])) || [],
        edges,
        junctions[i],
        junctions[i + 1]
      );
      if (!path || !path.length) return;
      for (const ei of path) {
        viaEdges.push(ei);
        expandedWayIds.push(String(viaWayIds[i]));
      }
    }
    const key = `${junctions[0]}:${junctions[junctions.length - 1]}:${viaEdges.join(",")}`;
    if (seen.has(key)) return;
    seen.add(key);
    results.push({
      entryNode: junctions[0],
      exitNode: junctions[junctions.length - 1],
      viaEdges,
      viaWayIds: expandedWayIds
    });
  }
  choose(0, []);
  return results;
}

function buildGraphFromOsm(osm, options = {}) {
  const timezone = options.timezone || "America/Halifax";
  const rejected = [];
  const conditionals = [];
  const packedNodes = osm.nodeStore && typeof osm.nodeStore.indexOf === "function"
    ? osm.nodeStore
    : null;
  const nodesById = packedNodes ? null : new Map();
  if (!packedNodes) {
    for (const node of osm.nodes || []) nodesById.set(String(node.id), node);
  }
  const sourceWays = osm.ways || [];
  let ways;
  if (packedNodes) {
    // Compact in place so a multi-million-entry duplicate array is never made.
    let write = 0;
    for (const way of sourceWays) if (isRoutableWay(way)) sourceWays[write++] = way;
    sourceWays.length = write;
    ways = sourceWays;
  } else {
    ways = sourceWays.filter(isRoutableWay);
  }

  const packedGraphIndex = packedNodes ? new Int32Array(packedNodes.count) : null;
  if (packedGraphIndex) packedGraphIndex.fill(-1);
  const graphIndex = packedNodes ? null : new Map();
  let split = packedNodes ? new Uint8Array(packedNodes.count) : new Set();

  function packedIndex(id) {
    return packedNodes ? packedNodes.indexOf(id) : -1;
  }
  function nodeForId(id, knownPackedIndex = -1) {
    if (!packedNodes) return nodesById.get(String(id));
    const index = knownPackedIndex >= 0 ? knownPackedIndex : packedIndex(id);
    return index >= 0 ? packedNodes.getByIndex(index) : null;
  }
  function markSplit(id, knownPackedIndex = -1) {
    if (!packedNodes) {
      split.add(String(id));
      return;
    }
    const index = knownPackedIndex >= 0 ? knownPackedIndex : packedIndex(id);
    if (index >= 0) split[index] = 1;
  }
  function graphNodeFor(id, knownPackedIndex = -1) {
    if (!packedNodes) return graphIndex.get(String(id));
    const index = knownPackedIndex >= 0 ? knownPackedIndex : packedIndex(id);
    if (index < 0) return undefined;
    const value = packedGraphIndex[index];
    return value >= 0 ? value : undefined;
  }

  let touch = packedNodes ? new Uint8Array(packedNodes.count) : new Map();
  function touchNode(id) {
    if (!packedNodes) {
      const key = String(id);
      touch.set(key, (touch.get(key) || 0) + 1);
      return;
    }
    const index = packedIndex(id);
    if (index >= 0 && touch[index] < 2) touch[index] += 1;
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

  if (!packedNodes) {
    for (const [id, count] of touch) if (count >= 2) split.add(id);
  }
  for (const way of ways) {
    const ids = (way.nodeIds || []).map(String);
    const indexes = packedNodes ? ids.map(packedIndex) : null;
    if (ids.length) {
      markSplit(ids[0], indexes ? indexes[0] : -1);
      markSplit(ids[ids.length - 1], indexes ? indexes[indexes.length - 1] : -1);
    }
    for (let i = 0; i < ids.length; i += 1) {
      if (packedNodes && indexes[i] >= 0 && touch[indexes[i]] >= 2) markSplit(ids[i], indexes[i]);
      const node = nodeForId(ids[i], indexes ? indexes[i] : -1);
      if (node && isBarrierNode(node.tags || {})) markSplit(ids[i], indexes ? indexes[i] : -1);
    }
  }

  const restrictionParse = [];
  const repeatedSources = [];
  const restrictionWayIds = new Set();
  for (const rel of osm.relations || []) {
    const parsed = parseRestrictionRelation(rel);
    if (!parsed.ok) {
      rejected.push({ kind: "restriction", osmRelationId: parsed.osmRelationId, reason: parsed.reason });
      continue;
    }
    restrictionParse.push(parsed.restriction);
    if (String(parsed.restriction.fromWayId) === String((parsed.restriction.viaWayIds || [])[0])) repeatedSources.push(rel);
    restrictionWayIds.add(String(parsed.restriction.fromWayId));
    restrictionWayIds.add(String(parsed.restriction.toWayId));
    for (const id of parsed.restriction.viaWayIds || []) restrictionWayIds.add(String(id));
    for (const id of parsed.restriction.viaNodeIds) markSplit(id);
  }
  if (packedNodes) osm.relations.length = 0;
  const repairWayIds = new Set(repeatedSources.flatMap(r => r.members.filter(m => m.type === "way").map(m => String(m.ref))));
  const repairWays = new Map(ways.filter(w => repairWayIds.has(String(w.id))).map(w => [String(w.id), { nodeIds: w.nodeIds.map(String) }]));
  touch = null;

  const graphNodes = [];
  function addGraphNode(osmId, knownPackedIndex = -1) {
    const key = String(osmId);
    const existing = graphNodeFor(key, knownPackedIndex);
    if (existing != null) return existing;
    const src = nodeForId(key, knownPackedIndex);
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
    if (packedNodes) {
      const packedAt = knownPackedIndex >= 0 ? knownPackedIndex : packedIndex(key);
      if (packedAt >= 0) packedGraphIndex[packedAt] = index;
    } else {
      graphIndex.set(key, index);
    }
    return index;
  }

  if (packedNodes) {
    for (let i = 0; i < split.length; i += 1) if (split[i]) addGraphNode(packedNodes.getByIndex(i).id, i);
  } else {
    for (const id of split) addGraphNode(id);
  }
  split = null;

  const barriers = [];
  for (let gi = 0; gi < graphNodes.length; gi += 1) {
    const src = graphNodes[gi];
    if (!isBarrierNode(src.tags || {})) continue;
    const osmId = src.osmNodeId;
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

  for (let wayIndex = 0; wayIndex < ways.length; wayIndex += 1) {
    const way = ways[wayIndex];
    const ids = (way.nodeIds || []).map(String);
    const indexes = packedNodes ? ids.map(packedIndex) : null;
    const splitAt = [];
    for (let i = 0; i < ids.length; i += 1) {
      if (graphNodeFor(ids[i], indexes ? indexes[i] : -1) != null) splitAt.push(i);
    }
    const wayEdges = [];
    const tags = way.tags || {};
    const access = evaluateMotorcycleAccess(tags);
    const cond = collectConditionalRules(tags, timezone);
    const conditionalRecord = cond.rules.length
      ? {
          osmWayId: String(way.id),
          rules: cond.rules,
          policy: "fail_closed"
        }
      : null;
    if (conditionalRecord) conditionals.push(conditionalRecord);
    for (const row of cond.rejected) {
      rejected.push({ kind: "conditional", osmWayId: String(way.id), reason: row.reason, tag: row.tag });
    }
    for (let s = 0; s < splitAt.length - 1; s += 1) {
      const i0 = splitAt[s];
      const i1 = splitAt[s + 1];
      const fromOsm = ids[i0];
      const toOsm = ids[i1];
      const from = graphNodeFor(fromOsm, indexes ? indexes[i0] : -1);
      const to = graphNodeFor(toOsm, indexes ? indexes[i1] : -1);
      if (from == null || to == null || from < 0 || to < 0) continue;
      const coords = [];
      let meters = 0;
      for (let i = i0; i <= i1; i += 1) {
        const n = nodeForId(ids[i], indexes ? indexes[i] : -1);
        if (!n) continue;
        const c = [n.lon, n.lat];
        if (coords.length) meters += haversineMeters(coords[coords.length - 1], c);
        coords.push(c);
      }
      if (coords.length < 2) continue;
      const direction = travelDirectionV4(tags);
      const arcs = legalDirectedArcs(direction);
      let forwardCode = accessCodeFromRules(access.forward.code, cond.rules);
      let reverseCode = accessCodeFromRules(access.reverse.code, cond.rules);
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
        xs: cost.xs
      });
      wayEdges.push(ei);
    }
    if (restrictionWayIds.has(String(way.id))) wayEdgeIndex.set(String(way.id), wayEdges);
    if (packedNodes) {
      way.nodeIds = null;
      way.tags = null;
      ways[wayIndex] = null;
    }
  }

  if (packedNodes) {
    ways.length = 0;
  }

  function edgeOnWayTouchingNode(wayId, graphNode) {
    const list = wayEdgeIndex.get(String(wayId)) || [];
    return list.filter((ei) => edges[ei].from === graphNode || edges[ei].to === graphNode);
  }

  const restrictions = [];
  let onlyTurnExits = null;
  function exitsAtOnlyTurnNode(node) {
    if (!onlyTurnExits) {
      // Sparse and shared across unresolved rules; do not rescan the whole
      // region for every rejected relation or index every node unnecessarily.
      onlyTurnExits = new Map();
      for (const rule of restrictionParse) if (rule.only) {
        for (const id of rule.viaNodeIds) {
          const via = graphNodeFor(id);
          if (via != null) onlyTurnExits.set(via, []);
        }
      }
      for (const edge of edges) {
        onlyTurnExits.get(edge.from)?.push(edge.index);
        if (edge.to !== edge.from) onlyTurnExits.get(edge.to)?.push(edge.index);
      }
    }
    return onlyTurnExits.get(node) || [];
  }
  for (const r of restrictionParse) {
    const viaGraph = r.viaNodeIds.map((id) => graphNodeFor(id)).filter((v) => v != null);
    const viaNode = viaGraph.length ? viaGraph[0] : null;
    let fromEdges = [];
    let toEdges = [];
    let viaPaths = [];
    if (viaNode != null) {
      fromEdges = edgeOnWayTouchingNode(r.fromWayId, viaNode);
      toEdges = edgeOnWayTouchingNode(r.toWayId, viaNode);
    } else {
      viaPaths = resolveViaWayPaths(r, wayEdgeIndex, edges);
      if (!viaPaths.length) {
        rejected.push({ kind: "restriction", osmRelationId: r.osmRelationId, reason: "unresolved_via_path" });
        continue;
      }
    }
    if (viaNode != null && (!fromEdges.length || !toEdges.length)) {
      let failClosedTurns = 0;
      if (r.only && fromEdges.length && !toEdges.length) {
        // The named sole exit is unavailable. Dropping the only-* rule would
        // authorize every other exit. Retain the exact incoming/via scope as
        // denied turns, while keeping other approaches and arrival at the
        // junction available. No road geometry or permission is fabricated.
        for (const fromEdge of fromEdges) for (const toEdge of exitsAtOnlyTurnNode(viaNode)) {
          restrictions.push({ ...r, kind: 8, kindName: "no_entry", only: false,
            toWayId: edges[toEdge].osmWayId, fromEdge, toEdge, viaNode,
            viaWayCount: 0, viaWayIds: [], viaEdges: [] });
          failClosedTurns++;
        }
      }
      rejected.push({ kind: "restriction", osmRelationId: r.osmRelationId, reason: "unresolved_members",
        ...(failClosedTurns ? { originalKind: r.kindName, failClosedTurns } : {}) });
      continue;
    }
    const resolvedPaths = viaNode != null
      ? [{ entryNode: viaNode, exitNode: viaNode, viaEdges: [], viaWayIds: [] }]
      : viaPaths;
    for (const path of resolvedPaths) {
      const resolvedFrom = viaNode != null
        ? fromEdges
        : edgeOnWayTouchingNode(r.fromWayId, path.entryNode);
      const resolvedTo = viaNode != null
        ? toEdges
        : edgeOnWayTouchingNode(r.toWayId, path.exitNode);
      if (!resolvedFrom.length || !resolvedTo.length) {
        rejected.push({ kind: "restriction", osmRelationId: r.osmRelationId, reason: "unresolved_members" });
        continue;
      }
      for (const fromEdge of resolvedFrom) {
        for (const toEdge of resolvedTo) {
          restrictions.push({
            ...r,
            fromEdge,
            toEdge,
            // For a via-way restriction this is the exact entry junction.
            viaNode: path.entryNode,
            viaWayCount: path.viaEdges.length,
            viaWayIds: path.viaWayIds,
            viaEdges: path.viaEdges
          });
        }
      }
    }
  }

  const restrictionRepairs = [];
  if (repeatedSources.length) {
    const indexed = read => new Proxy({}, { get: (_, key) => /^\d+$/.test(String(key)) ? read(Number(key)) : undefined });
    const sourcePack = {
      osmNodeIds: indexed(i => graphNodes[i].osmNodeId),
      edgeFrom: indexed(i => edges[i].from), edgeTo: indexed(i => edges[i].to),
      edgeAccess: indexed(i => i % 2 ? edges[Math.floor(i / 2)].accessReverse : edges[Math.floor(i / 2)].accessForward)
    };
    for (const relation of repeatedSources) {
      const originalRows = restrictions.filter(r => r.osmRelationId === String(relation.id));
      if (!originalRows.length) continue; // Already reported as unresolved above.
      const repair = repairRepeatedSource({ relation, ways: repairWays, nodes: { get: nodeForId }, pack: sourcePack, edgeIndexes: wayEdgeIndex });
      const replacementRows = repair.type === "resolved" ? [{ ...originalRows[0], fromEdge: repair.fromEdge, toEdge: repair.toEdge,
        viaNode: repair.viaNode, viaEdges: repair.viaEdges, viaWayIds: repair.viaWayIds, viaWayCount: repair.viaEdges.length }] : [];
      if (repair.type === "quarantine") {
        repair.excludedEdges = repair.wayIds.flatMap(w => wayEdgeIndex.get(w)).map(i => ({ edge: i, priorAccess: [edges[i].accessForward, edges[i].accessReverse] }));
        for (const row of repair.excludedEdges) { edges[row.edge].accessForward = 2; edges[row.edge].accessReverse = 2; }
      }
      let inserted = false, write = 0;
      for (const row of restrictions) {
        if (row.osmRelationId !== String(relation.id)) restrictions[write++] = row;
        else if (!inserted) { for (const replacement of replacementRows) restrictions[write++] = replacement; inserted = true; }
      }
      restrictions.length = write;
      restrictionRepairs.push({ relation, originalRows, ...repair });
    }
  }
  if (packedNodes) packedNodes.clear();

  return {
    nodes: graphNodes,
    edges,
    barriers,
    restrictions,
    restrictionRepairs,
    conditionals,
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
    conditionals: (graph.conditionals || []).length,
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
  haversineMeters,
  orderedWayPath,
  resolveViaWayPaths
};
