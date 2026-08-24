"use strict";

/**
 * Phase E2 — read-time road tiers for Clean (from roadClassLeaf).
 * Embedded in enumsJson as `roadTierMap` so JS + Swift stay lockstep.
 *
 * Tiers: motorway | trunk | arterial | collector | local_paved |
 *        destination | service | adventure | unknown
 */

const ROAD_TIER = Object.freeze({
  MOTORWAY: "motorway",
  TRUNK: "trunk",
  ARTERIAL: "arterial",
  COLLECTOR: "collector",
  LOCAL_PAVED: "local_paved",
  DESTINATION: "destination",
  SERVICE: "service",
  ADVENTURE: "adventure",
  UNKNOWN: "unknown"
});

/** OSM highway leaf → Clean tier. */
const ROAD_TIER_MAP = Object.freeze({
  motorway: ROAD_TIER.MOTORWAY,
  motorway_link: ROAD_TIER.MOTORWAY,
  trunk: ROAD_TIER.TRUNK,
  trunk_link: ROAD_TIER.TRUNK,
  primary: ROAD_TIER.ARTERIAL,
  primary_link: ROAD_TIER.ARTERIAL,
  secondary: ROAD_TIER.COLLECTOR,
  secondary_link: ROAD_TIER.COLLECTOR,
  tertiary: ROAD_TIER.LOCAL_PAVED,
  tertiary_link: ROAD_TIER.LOCAL_PAVED,
  unclassified: ROAD_TIER.LOCAL_PAVED,
  unclassified_link: ROAD_TIER.LOCAL_PAVED,
  residential: ROAD_TIER.DESTINATION,
  living_street: ROAD_TIER.DESTINATION,
  service: ROAD_TIER.SERVICE,
  track: ROAD_TIER.ADVENTURE,
  path: ROAD_TIER.ADVENTURE,
  unknown: ROAD_TIER.UNKNOWN
});

/**
 * Clean km multipliers by tier (profile=cleanest + leaves only).
 * Collector/local_paved preferred; arterial is a mild connector (1.4, not a
 * near-ban); trunk/motorway avoided.
 */
const CLEAN_TIER_COST = Object.freeze({
  [ROAD_TIER.COLLECTOR]: 0.86,
  [ROAD_TIER.LOCAL_PAVED]: 0.92,
  [ROAD_TIER.ARTERIAL]: 1.4,
  [ROAD_TIER.SERVICE]: 2.8,
  [ROAD_TIER.DESTINATION]: 1.15,
  [ROAD_TIER.TRUNK]: 16.0,
  [ROAD_TIER.MOTORWAY]: 70.0,
  [ROAD_TIER.ADVENTURE]: 120.0,
  [ROAD_TIER.UNKNOWN]: 2.2
});

/** Clean surface-family km multipliers (leaves). */
const CLEAN_FAMILY_COST = Object.freeze({
  paved: 1.0,
  gravel: 14.0,
  loose: 90.0,
  unknown: 1.05
});

function roadTierOf(roadClassLeaf, tierMap = ROAD_TIER_MAP) {
  if (roadClassLeaf == null) return ROAD_TIER.UNKNOWN;
  const key = String(roadClassLeaf).trim().toLowerCase();
  if (!key) return ROAD_TIER.UNKNOWN;
  return tierMap[key] || ROAD_TIER.UNKNOWN;
}

function tierIsPavedCapable(tier) {
  return (
    tier === ROAD_TIER.MOTORWAY ||
    tier === ROAD_TIER.TRUNK ||
    tier === ROAD_TIER.ARTERIAL ||
    tier === ROAD_TIER.COLLECTOR ||
    tier === ROAD_TIER.LOCAL_PAVED
  );
}

/**
 * Clean passability from leaves.
 * @param {object} opts
 * @param {string} opts.family surface family (paved|gravel|loose|unknown)
 * @param {string} opts.tier road tier
 * @param {boolean} opts.pavedOnly first Clean pass (pavement fabric)
 * @param {boolean} opts.isEndpointEdge true when edge is A/B snap edge
 */
function isBlockedForCleanLeaf(opts) {
  const family = opts.family || "unknown";
  const tier = opts.tier || ROAD_TIER.UNKNOWN;
  const pavedOnly = !!opts.pavedOnly;
  if (opts.isEndpointEdge) return false;

  // Residential / living_street: never a through-route.
  if (tier === ROAD_TIER.DESTINATION) return true;

  // track / atv-path: not Clean surface.
  if (tier === ROAD_TIER.ADVENTURE) return pavedOnly;

  if (pavedOnly) {
    if (family === "paved") return false;
    if (family === "gravel" || family === "loose") return true;
    // Missing/unknown leaf on a paved-capable highway → inferred pavement.
    if (family === "unknown") return !tierIsPavedCapable(tier);
    return true;
  }

  // Fallback pass: gravel connectors OK; loose still last-resort (high cost, not hard-block
  // except adventure already handled). Service/destination still blocked above.
  if (family === "loose" && !tierIsPavedCapable(tier)) return true;
  return false;
}

function cleanLeafCostMult(tier, family) {
  const t = CLEAN_TIER_COST[tier] != null ? CLEAN_TIER_COST[tier] : CLEAN_TIER_COST[ROAD_TIER.UNKNOWN];
  const f = CLEAN_FAMILY_COST[family] != null ? CLEAN_FAMILY_COST[family] : CLEAN_FAMILY_COST.unknown;
  return t * f;
}

/** Motorway/trunk hard-avoid with pin join relief (leaf Clean). */
function cleanLeafHighwayAvoidMult(tier, metersFromStart, metersToDestination, startOnHighway, endOnHighway) {
  if (tier !== ROAD_TIER.MOTORWAY && tier !== ROAD_TIER.TRUNK) return 1;
  const join = 6000;
  const near =
    (endOnHighway && metersToDestination < join) ||
    (startOnHighway && metersFromStart < join);
  if (near) return 1;
  // Push toward CLEAN_TIER_COST already high; extra avoid on mid-route motorway/trunk.
  return tier === ROAD_TIER.MOTORWAY ? 1.8 : 1.35;
}

/**
 * Phase E4 — rider knobs (default OFF → Dirt/Balanced/Direct + Clean E2 unchanged).
 * Soft costs only: never remove edges from the graph.
 */
const E4_AVOID_MOTORWAY_MULT = 40;
const E4_AVOID_TRUNK_MULT = 18;
const E4_PREFER_BACK_ARTERIAL_MULT = 4.5;
const E4_PREFER_BACK_COLLECTOR_MULT = 0.82;
const E4_HIGHWAY_JOIN_METERS = 6000;

/** Strong soft-hard avoid of motorway + trunk (+links). Pin-join relief near A/B. */
function e4AvoidMotorwaysMult(
  tier,
  enabled,
  metersFromStart,
  metersToDestination,
  startOnHighway,
  endOnHighway
) {
  if (!enabled) return 1;
  if (tier !== ROAD_TIER.MOTORWAY && tier !== ROAD_TIER.TRUNK) return 1;
  const near =
    (endOnHighway && metersToDestination < E4_HIGHWAY_JOIN_METERS) ||
    (startOnHighway && metersFromStart < E4_HIGHWAY_JOIN_METERS);
  if (near) return 1;
  return tier === ROAD_TIER.MOTORWAY ? E4_AVOID_MOTORWAY_MULT : E4_AVOID_TRUNK_MULT;
}

/**
 * Prefer back roads: penalize arterial (primary); mild collector preference vs primary.
 * Never excludes primary/secondary — connectivity preserved.
 */
function e4PreferBackRoadsMult(tier, enabled) {
  if (!enabled) return 1;
  if (tier === ROAD_TIER.ARTERIAL) return E4_PREFER_BACK_ARTERIAL_MULT;
  if (tier === ROAD_TIER.COLLECTOR) return E4_PREFER_BACK_COLLECTOR_MULT;
  return 1;
}

function e4LeafCostMult(opts) {
  const tier = opts.tier || ROAD_TIER.UNKNOWN;
  let m = 1;
  m *= e4AvoidMotorwaysMult(
    tier,
    !!opts.avoidMotorways,
    Number(opts.metersFromStart) || 0,
    Number(opts.metersToDestination) || 0,
    !!opts.startOnHighway,
    !!opts.endOnHighway
  );
  m *= e4PreferBackRoadsMult(tier, !!opts.preferBackRoads);
  return m;
}

/**
 * E4 knobs are Clean-only. Dirt / Balanced / Direct ignore rider flags so
 * costing matches pre-E4. Clean always prefers back roads; avoid-motorways
 * is the Clean toggle.
 */
function e4FlagsForProfile(profile, flags) {
  if (profile !== "cleanest") {
    return { avoidMotorways: false, preferBackRoads: false };
  }
  return {
    avoidMotorways: !!(flags && flags.avoidMotorways),
    preferBackRoads: true
  };
}

module.exports = {
  ROAD_TIER,
  ROAD_TIER_MAP,
  CLEAN_TIER_COST,
  CLEAN_FAMILY_COST,
  roadTierOf,
  tierIsPavedCapable,
  isBlockedForCleanLeaf,
  cleanLeafCostMult,
  cleanLeafHighwayAvoidMult,
  e4AvoidMotorwaysMult,
  e4PreferBackRoadsMult,
  e4LeafCostMult,
  e4FlagsForProfile,
  E4_AVOID_MOTORWAY_MULT,
  E4_AVOID_TRUNK_MULT,
  E4_PREFER_BACK_ARTERIAL_MULT,
  E4_PREFER_BACK_COLLECTOR_MULT
};
