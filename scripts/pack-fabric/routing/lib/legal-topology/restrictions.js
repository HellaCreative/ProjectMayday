"use strict";

/**
 * OSM turn restrictions resolved by original OSM ids. Never guess.
 */

const KIND = {
  no_left_turn: 0,
  no_right_turn: 1,
  no_straight_on: 2,
  no_u_turn: 3,
  only_left_turn: 4,
  only_right_turn: 5,
  only_straight_on: 6,
  only_u_turn: 7,
  no_entry: 8,
  no_exit: 9,
  // OSM's no-turn-on-red values are conditional on a signal phase. V4's
  // launch contract conservatively enforces them at all times rather than
  // ever allowing a prohibited red-light turn.
  no_right_turn_on_red: 1,
  no_left_turn_on_red: 0
};

const ONLY_KINDS = new Set([
  "only_left_turn",
  "only_right_turn",
  "only_straight_on",
  "only_u_turn"
]);

function tag(tags, key) {
  if (!tags || tags[key] == null) return "";
  return String(tags[key]).toLowerCase().trim();
}

function restrictionKey(tags = {}) {
  const direct = (
    tag(tags, "restriction:motorcycle") ||
    tag(tags, "restriction:motor_vehicle") ||
    tag(tags, "restriction") ||
    ""
  );
  if (direct) return direct;
  const conditional = tag(tags, "restriction:motorcycle:conditional") ||
    tag(tags, "restriction:motor_vehicle:conditional") ||
    tag(tags, "restriction:conditional");
  if (!conditional) return "";
  return conditional.split("@")[0].trim();
}

function parseExcept(tags = {}) {
  const raw = tag(tags, "except");
  if (!raw) return [];
  return raw.split(";").map((s) => s.trim()).filter(Boolean);
}

function vehicleMask(tags = {}) {
  if (tag(tags, "restriction:motorcycle")) return 1;
  if (tag(tags, "restriction:motor_vehicle")) return 2;
  return 1 | 2 | 4;
}

function exceptExemptsMotorcycle(exceptList) {
  return exceptList.some((v) => v === "motorcycle" || v === "motor_vehicle" || v === "vehicle");
}

/**
 * @returns {{ ok: true, restriction: object } | { ok: false, reason: string, osmRelationId: string }}
 */
function parseRestrictionRelation(relation) {
  const osmRelationId = String(relation.id);
  const tags = relation.tags || {};
  if (tag(tags, "type") !== "restriction" && !String(tag(tags, "type")).startsWith("restriction")) {
    return { ok: false, reason: "not_restriction", osmRelationId };
  }
  const kindName = restrictionKey(tags);
  if (!kindName || KIND[kindName] == null) {
    return { ok: false, reason: "unknown_restriction", osmRelationId };
  }
  const members = Array.isArray(relation.members) ? relation.members : [];
  const from = members.filter((m) => m.role === "from");
  const to = members.filter((m) => m.role === "to");
  const via = members.filter((m) => m.role === "via");
  if (from.length !== 1 || to.length !== 1) {
    return { ok: false, reason: "incomplete_from_to", osmRelationId };
  }
  if (from[0].type !== "way" || to[0].type !== "way") {
    return { ok: false, reason: "from_to_not_way", osmRelationId };
  }
  if (!via.length) {
    return { ok: false, reason: "missing_via", osmRelationId };
  }
  const viaNodes = via.filter((m) => m.type === "node").map((m) => String(m.ref));
  const viaWays = via.filter((m) => m.type === "way").map((m) => String(m.ref));
  if (!viaNodes.length && !viaWays.length) {
    return { ok: false, reason: "via_unsupported_type", osmRelationId };
  }
  const except = parseExcept(tags);
  if (exceptExemptsMotorcycle(except) && vehicleMask(tags) === (1 | 2 | 4) && !tag(tags, "restriction:motorcycle")) {
    return { ok: false, reason: "except_motorcycle", osmRelationId };
  }
  return {
    ok: true,
    restriction: {
      osmRelationId,
      kind: KIND[kindName],
      kindName,
      only: ONLY_KINDS.has(kindName),
      fromWayId: String(from[0].ref),
      toWayId: String(to[0].ref),
      viaNodeIds: viaNodes,
      viaWayIds: viaWays,
      except,
      vehicleMask: vehicleMask(tags),
      tags
    }
  };
}

function restrictionAppliesToMotorcycle(restriction) {
  if (!restriction) return false;
  if (exceptExemptsMotorcycle(restriction.except || []) && restriction.vehicleMask === (1 | 2 | 4)) {
    return false;
  }
  return (restriction.vehicleMask == null ? 7 : restriction.vehicleMask) & 1;
}

const compiledRestrictionCache = new WeakMap();

function addToSetMap(map, key, value) {
  let values = map.get(key);
  if (!values) {
    values = new Set();
    map.set(key, values);
  }
  values.add(Number(value));
}

/**
 * Compile decoded graph.v4 restrictions once per loaded pack. Routing expands
 * hundreds of thousands of arcs; walking the complete restriction table on
 * every expansion turns a small legal-topology check into the dominant search
 * cost.
 */
function compileRestrictionIndex(restrictions) {
  if (!Array.isArray(restrictions) || restrictions.length === 0) {
    return {
      blockedNodeTurns: new Map(),
      onlyNodeTurns: new Map(),
      blockedViaWayExits: new Map(),
      onlyViaWayEntries: new Map(),
      viaPatterns: [],
      viaStarters: new Map(),
      statefulIncomingEdges: new Set()
    };
  }
  const cached = compiledRestrictionCache.get(restrictions);
  if (cached) return cached;

  const index = {
    blockedNodeTurns: new Map(),
    onlyNodeTurns: new Map(),
    blockedViaWayExits: new Map(),
    onlyViaWayEntries: new Map(),
    viaPatterns: [],
    viaStarters: new Map(),
    statefulIncomingEdges: new Set()
  };
  for (const restriction of restrictions) {
    if (!restrictionAppliesToMotorcycle(restriction)) continue;
    const fromEdge = Number(restriction.fromEdge);
    const toEdge = Number(restriction.toEdge);
    const viaEdges = Array.isArray(restriction.viaEdges)
      ? restriction.viaEdges.map(Number)
      : [];
    if (viaEdges.length) {
      index.statefulIncomingEdges.add(fromEdge);
      const id = index.viaPatterns.length;
      index.viaPatterns.push({
        id,
        fromEdge,
        toEdge,
        viaEdges,
        entryNode: Number(restriction.viaNode),
        only: restriction.only === true
      });
      let starters = index.viaStarters.get(fromEdge);
      if (!starters) {
        starters = [];
        index.viaStarters.set(fromEdge, starters);
      }
      starters.push(id);
      continue;
    }

    const viaNodes = restriction.viaNode != null
      ? [Number(restriction.viaNode)]
      : (restriction.viaNodeIds || []).map(Number);
    for (const viaNode of viaNodes) {
      if (!Number.isFinite(viaNode) || !Number.isFinite(fromEdge) || !Number.isFinite(toEdge)) {
        continue;
      }
      const key = `${viaNode}:${fromEdge}`;
      index.statefulIncomingEdges.add(fromEdge);
      addToSetMap(
        restriction.only ? index.onlyNodeTurns : index.blockedNodeTurns,
        key,
        toEdge
      );
    }
  }
  compiledRestrictionCache.set(restrictions, index);
  return index;
}

function indexedTurnAllowed(index, fromEdge, toEdge, viaNode) {
  if (!index || fromEdge == null || Number(fromEdge) < 0) return true;
  const from = Number(fromEdge);
  const to = Number(toEdge);
  const key = `${Number(viaNode)}:${from}`;
  const only = index.onlyNodeTurns.get(key);
  if (only && !only.has(to)) return false;
  const blocked = index.blockedNodeTurns.get(key);
  if (blocked && blocked.has(to)) return false;

  return true;
}

function activeKey(active) {
  return (active || [])
    .map((row) => `${Number(row.id)}:${Number(row.progress)}`)
    .sort()
    .join("|");
}

/**
 * Advance exact via-way restriction progress. A via-way rule is scoped to the
 * complete `from -> ordered via edges -> to` sequence, so traffic that merely
 * reaches the final via edge from another road is never globally blocked.
 */
function advanceRestrictionState(index, active, fromEdge, toEdge, viaNode) {
  if (!indexedTurnAllowed(index, fromEdge, toEdge, viaNode)) {
    return { allowed: false, active: [] };
  }
  const from = Number(fromEdge);
  const to = Number(toEdge);
  const current = Array.isArray(active) ? active : [];
  const next = [];

  const activeOnly = current.filter((row) => {
    const pattern = index.viaPatterns[row.id];
    return pattern && pattern.only;
  });
  if (activeOnly.length && !activeOnly.some((row) => {
    const pattern = index.viaPatterns[row.id];
    const sequence = [pattern.fromEdge, ...pattern.viaEdges, pattern.toEdge];
    return Number(sequence[row.progress + 1]) === to;
  })) {
    return { allowed: false, active: [] };
  }

  for (const row of current) {
    const pattern = index.viaPatterns[row.id];
    if (!pattern) continue;
    const sequence = [pattern.fromEdge, ...pattern.viaEdges, pattern.toEdge];
    const expected = Number(sequence[row.progress + 1]);
    if (expected !== to) continue;
    const completes = row.progress + 1 === sequence.length - 1;
    if (completes) {
      if (!pattern.only) return { allowed: false, active: [] };
      continue;
    }
    next.push({ id: row.id, progress: row.progress + 1 });
  }

  const starters = (index.viaStarters.get(from) || []).filter((id) => {
    const pattern = index.viaPatterns[id];
    return !Number.isFinite(pattern.entryNode) || pattern.entryNode < 0 || pattern.entryNode === Number(viaNode);
  });
  const starterOnly = starters.filter((id) => index.viaPatterns[id].only);
  if (starterOnly.length && !starterOnly.some((id) => index.viaPatterns[id].viaEdges[0] === to)) {
    return { allowed: false, active: [] };
  }
  for (const id of starters) {
    const pattern = index.viaPatterns[id];
    if (Number(pattern.viaEdges[0]) === to) next.push({ id, progress: 1 });
  }

  const unique = new Map(next.map((row) => [`${row.id}:${row.progress}`, row]));
  return { allowed: true, active: [...unique.values()].sort((a, b) => a.id - b.id || a.progress - b.progress) };
}

/**
 * Whether moving fromEdge → toEdge at viaNode is allowed.
 * viaProgress is remaining via-way ids (strings) when tracking a via-way restriction.
 */
function turnAllowed({ restrictions, fromEdge, toEdge, viaNode, viaProgress }) {
  const applicable = (restrictions || []).filter((r) => restrictionAppliesToMotorcycle(r));
  for (const r of applicable) {
    if (r.viaWayIds && r.viaWayIds.length) {
      const progress = viaProgress || r.viaWayIds;
      if (progress.length) continue;
    }
    const viaMatch =
      (r.viaNode != null && viaNode != null && Number(r.viaNode) === Number(viaNode)) ||
      (r.viaNodeIds || []).some((id) => String(id) === String(viaNode));
    if (!viaMatch && r.viaNode == null && !(r.viaNodeIds || []).length) {
      // via-way only; handled by via progress
    } else if (!viaMatch && (r.viaNode != null || (r.viaNodeIds || []).length)) {
      continue;
    }
    const fromMatch = Number(r.fromEdge) === Number(fromEdge) || String(r.fromWayId) === String(fromEdge);
    const toMatch = Number(r.toEdge) === Number(toEdge) || String(r.toWayId) === String(toEdge);
    if (r.only) {
      if (fromMatch && viaMatch && !toMatch) return false;
    } else if (fromMatch && toMatch && (viaMatch || r.kind === KIND.no_entry || r.kind === KIND.no_exit)) {
      return false;
    }
  }
  return true;
}

module.exports = {
  KIND,
  parseRestrictionRelation,
  restrictionAppliesToMotorcycle,
  compileRestrictionIndex,
  indexedTurnAllowed,
  advanceRestrictionState,
  activeKey,
  turnAllowed,
  exceptExemptsMotorcycle
};
