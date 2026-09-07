"use strict";

/**
 * Road-legal motorcycle access for graph.v4.
 * Hierarchy: access → vehicle → motor_vehicle → motorcycle (more specific wins).
 * ATV permission never overrides motorcycle=no or motor_vehicle=no.
 */

const ALLOWED = new Set(["yes", "designated", "permissive", "official"]);
const DENIED = new Set([
  "no",
  "private",
  "permit",
  "delivery",
  "agricultural",
  "forestry",
  "emergency",
  "employees",
  "military",
  "psv",
  "foot"
]);
const ENDPOINT_DESTINATION = new Set(["destination", "residents"]);
const ENDPOINT_CUSTOMERS = new Set(["customers"]);
const HIERARCHY = ["access", "vehicle", "motor_vehicle", "motorcycle"];

function tag(tags, key) {
  if (!tags || tags[key] == null || tags[key] === "") return "";
  return String(tags[key]).toLowerCase().trim();
}

function sideKeys(base, side) {
  if (!side) return [base];
  return [`${base}:${side}`, `${base}:${side}`];
}

function rawFor(tags, base, side) {
  if (side) {
    const direct = tag(tags, `${base}:${side}`);
    if (direct) return direct;
  }
  return tag(tags, base);
}

function classifyValue(value) {
  if (!value) return null;
  if (ALLOWED.has(value)) return { code: 0, kind: null };
  if (DENIED.has(value)) return { code: 2, kind: null };
  if (ENDPOINT_DESTINATION.has(value)) return { code: 3, kind: "destination" };
  if (ENDPOINT_CUSTOMERS.has(value)) return { code: 4, kind: "customers" };
  if (value === "unknown" || value === "discouraged") return { code: 1, kind: null };
  return null;
}

/**
 * Evaluate one travel side (`""`, `"forward"`, `"backward"`).
 * Returns { code, kind, source }.
 */
function evaluateSide(tags, side) {
  let result = { code: 1, kind: null, source: "missing" };
  for (const base of HIERARCHY) {
    const value = rawFor(tags, base, side);
    const classified = classifyValue(value);
    if (!classified) continue;
    result = { ...classified, source: side ? `${base}:${side}` : base };
  }
  return result;
}

function defaultUntaggedCode(tags) {
  const highway = tag(tags, "highway");
  const route = tag(tags, "route");
  if (route === "ferry") return 0;
  if (
    [
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
      "service"
    ].includes(highway)
  ) {
    return 0;
  }
  return 1;
}

function smoothnessBlocks(tags) {
  return tag(tags, "smoothness") === "impassable";
}

/**
 * @returns {{
 *   forward: { code: number, kind: string|null, source: string },
 *   reverse: { code: number, kind: string|null, source: string },
 *   impassable: boolean,
 *   atvPositive: boolean
 * }}
 */
function evaluateMotorcycleAccess(tags = {}) {
  const impassable = smoothnessBlocks(tags);
  const atvPositive = ["yes", "designated", "permissive"].includes(tag(tags, "atv"));
  const both = evaluateSide(tags, "");
  const forwardTag = evaluateSide(tags, "forward");
  const reverseTag = evaluateSide(tags, "backward");
  const untagged = defaultUntaggedCode(tags);

  function merge(base, directional) {
    if (directional.source !== "missing") return directional;
    if (base.source !== "missing") return base;
    return { code: untagged, kind: null, source: "untagged_highway" };
  }

  const forward = merge(both, forwardTag);
  const reverse = merge(both, reverseTag);

  if (impassable) {
    return {
      forward: { code: 2, kind: null, source: "smoothness=impassable" },
      reverse: { code: 2, kind: null, source: "smoothness=impassable" },
      impassable: true,
      atvPositive
    };
  }

  // ATV must not reopen motorcycle=no / motor_vehicle=no / access deny.
  return { forward, reverse, impassable: false, atvPositive };
}

function accessCodeName(code) {
  return ["through", "unknown", "denied", "destination", "customers", "fail_closed"][code] || "denied";
}

function throughAllowed(code, { allowUnknown = false, isEndpoint = false, endpointKind = null } = {}) {
  if (code === 0) return true;
  if (code === 1) return !!allowUnknown;
  if (code === 2 || code === 5) return false;
  if (code === 3) return !!isEndpoint && endpointKind !== "customers";
  if (code === 4) return !!isEndpoint && endpointKind === "customers";
  return false;
}

module.exports = {
  ALLOWED,
  DENIED,
  HIERARCHY,
  evaluateMotorcycleAccess,
  accessCodeName,
  throughAllowed,
  smoothnessBlocks
};
