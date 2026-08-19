"use strict";

/**
 * Canonical province-independent enums for DIRT routing features.
 * Graph serialization may encode these as integers; names are the contract.
 */

const SURFACE_CLASS = Object.freeze({
  paved: "paved",
  gravel: "gravel",
  resource: "resource",
  double_track: "double_track",
  track: "track",
  unknown: "unknown",
  // Legacy alias kept for existing NS graphs / router costing tables.
  access: "access"
});

const ACCESS_CLASS = Object.freeze({
  motorized_permissive: "motorized_permissive",
  motorized_unknown: "motorized_unknown",
  restricted: "restricted",
  excluded: "excluded",
  // Legacy aliases used by shipped ns-graph.v1
  motorized_verified: "motorized_verified",
  motorized_restricted: "motorized_restricted",
  motorized_excluded: "motorized_excluded"
});

const STRUCTURE_TYPE = Object.freeze({
  none: "none",
  bridge: "bridge",
  tunnel: "tunnel",
  ferry: "ferry",
  blocked_passage: "blocked_passage",
  ford: "ford",
  unknown: "unknown"
});

const ROAD_TRACK_CLASS = Object.freeze({
  freeway: "freeway",
  arterial: "arterial",
  collector: "collector",
  local: "local",
  resource: "resource",
  recreation: "recreation",
  track: "track",
  double_track: "double_track",
  ramp: "ramp",
  service: "service",
  unknown: "unknown"
});

const SOURCE_CONFIDENCE = Object.freeze({
  high: "high",
  medium: "medium",
  low: "low"
});

const PROVINCE_CODES = Object.freeze({
  BC: "BC",
  AB: "AB",
  SK: "SK",
  MB: "MB",
  ON: "ON",
  QC: "QC",
  NB: "NB",
  NS: "NS",
  PE: "PE",
  NL: "NL",
  YT: "YT",
  NT: "NT",
  NU: "NU"
});

/** Map canonical / legacy surface names onto router costing buckets. */
function surfaceForCosting(surfaceClass) {
  if (surfaceClass === "resource") return "access";
  if (surfaceClass === "double_track") return "track";
  if (surfaceClass === "access") return "access";
  return SURFACE_CLASS[surfaceClass] || "unknown";
}

/** Normalize access to the four-policy set used by product rules. */
function accessForPolicy(accessClass) {
  if (accessClass === "motorized_verified" || accessClass === "motorized_permissive") {
    return "motorized_permissive";
  }
  if (accessClass === "motorized_restricted" || accessClass === "restricted") {
    return "motorized_restricted";
  }
  if (accessClass === "motorized_excluded" || accessClass === "excluded") {
    return "motorized_excluded";
  }
  return "motorized_unknown";
}

module.exports = {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE,
  PROVINCE_CODES,
  surfaceForCosting,
  accessForPolicy
};
