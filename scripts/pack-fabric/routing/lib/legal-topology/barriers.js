"use strict";

/**
 * Motorcycle barrier / access-node matrix.
 * Explicit motorcycle/access/locked/conditional tags win.
 * Ambiguous gates fail closed. Not every gate is blocked; not every gate is open.
 */

const { evaluateMotorcycleAccess } = require("./motorcycle-access");

const ALWAYS_BLOCK = new Set([
  "bollard",
  "block",
  "jersey_barrier",
  "cycle_barrier",
  "turnstile",
  "stile",
  "kissing_gate",
  "debris",
  "planter"
]);
const ALWAYS_ALLOW_IF_UNTAGGED = new Set([
  "cattle_grid",
  "entrance",
  "border_control",
  "sally_port"
]);
const GATE_LIKE = new Set([
  "gate",
  "lift_gate",
  "swing_gate",
  "chain",
  "sliding_gate",
  "wicket_gate"
]);

function tag(tags, key) {
  if (!tags || tags[key] == null) return "";
  return String(tags[key]).toLowerCase().trim();
}

function isBarrierNode(tags = {}) {
  return Boolean(tag(tags, "barrier") || tag(tags, "access") || tag(tags, "locked"));
}

/**
 * @returns {{ decision: "allow"|"block"|"fail_closed", reason: string, barrier: string }}
 */
function evaluateBarrier(tags = {}) {
  const barrier = tag(tags, "barrier");
  const locked = tag(tags, "locked");
  const access = evaluateMotorcycleAccess(tags);
  const motorcycle = tag(tags, "motorcycle");

  if (motorcycle === "yes" || motorcycle === "designated" || motorcycle === "permissive") {
    if (access.forward.code === 2 && access.forward.source.startsWith("motorcycle")) {
      return { decision: "block", reason: "motorcycle_denied", barrier };
    }
    if (locked === "yes" && motorcycle !== "yes") {
      return { decision: "fail_closed", reason: "locked", barrier };
    }
    return { decision: "allow", reason: "motorcycle_explicit", barrier };
  }
  if (motorcycle === "no" || motorcycle === "private") {
    return { decision: "block", reason: "motorcycle_no", barrier };
  }
  if (access.forward.code === 2 || access.reverse.code === 2) {
    return { decision: "block", reason: access.forward.source || access.reverse.source, barrier };
  }
  if (access.forward.code === 5 || access.reverse.code === 5) {
    return { decision: "fail_closed", reason: "conditional", barrier };
  }
  if (locked === "yes") {
    return { decision: "fail_closed", reason: "locked", barrier };
  }
  if (ALWAYS_BLOCK.has(barrier) && access.forward.code !== 0) {
    return { decision: "block", reason: "type_default_block", barrier };
  }
  if (ALWAYS_ALLOW_IF_UNTAGGED.has(barrier) && access.forward.code === 1) {
    return { decision: "allow", reason: "type_default_allow", barrier };
  }
  if (GATE_LIKE.has(barrier)) {
    if (access.forward.code === 0) return { decision: "allow", reason: "access_yes", barrier };
    return { decision: "fail_closed", reason: "ambiguous_gate", barrier };
  }
  if (barrier) {
    return { decision: "fail_closed", reason: "ambiguous_barrier", barrier };
  }
  if (access.forward.code === 0) return { decision: "allow", reason: "access_yes", barrier: "" };
  if (access.forward.code === 2) return { decision: "block", reason: "access_denied", barrier: "" };
  return { decision: "fail_closed", reason: "ambiguous_access_node", barrier: "" };
}

function decisionCode(decision) {
  if (decision === "allow") return 0;
  if (decision === "block") return 1;
  return 2;
}

module.exports = {
  ALWAYS_BLOCK,
  GATE_LIKE,
  isBarrierNode,
  evaluateBarrier,
  decisionCode
};
