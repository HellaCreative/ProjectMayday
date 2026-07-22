"use strict";

/**
 * Profile surface (+ road-class) weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * Mental model — dirt is the default fabric except Clean:
 *   Clean / Cleanest → cleanest — Google/Apple: pavement/highway default.
 *                       Dirt only as a last stitch when forced.
 *   Dirt             → dirt     — maximize purple NSTDB + OSM dirt/gravel/track;
 *                       pavement only when forced. Longer OK; no destination loops.
 *   Balanced         → balanced — ~40–60% dirt target when Allow + fabric allow;
 *                       not Direct clone, not Dirt-max.
 *   Direct           → direct   — crow-flies length first on dirt fabric;
 *                       mild dirt preference only among near-equal options.
 *                       No “increase dirt%” objective; no dirt-tourism spur near B.
 *
 * Packed surface codes: paved=0 gravel=1 access=2 (resource) track=3 unknown=4.
 * Road-class (`rt` on v1 edges): cleanest prefers freeway/arterial; non-cleanest
 * pay hard for freeway/arterial so the engine cannot keep a highway spine and
 * only nibble dirt spurs.
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  // Length dominates. Mild dirt preference among near-equal options only.
  // Still dirt-fabric default (not highway spine) — ellipse + goal penalty
  // kill tourism spurs near B, not these weights.
  direct: Object.freeze({
    paved: 2.35,
    gravel: 0.88,
    access: 0.78,
    track: 0.68,
    unknown: 0.8
  }),
  // Dual-sport mix — ~50/50 when Allow + fabric allow. Dirt-lean base so
  // highway corridors (NS→NB) are not Direct’s paved cousin; Allow purple
  // open stays milder than Direct so NS gold does not clone crow-flies dirt.
  balanced: Object.freeze({
    paved: 1.72,
    gravel: 0.94,
    access: 0.9,
    track: 0.86,
    unknown: 0.98
  }),
  // Maximize undeveloped/gravel/track/resource; pavement only when forced.
  dirt: Object.freeze({
    paved: 14.0,
    gravel: 0.55,
    access: 0.35,
    track: 0.24,
    unknown: 0.4
  }),
  // Google/Apple: shortest practical pavement. Do not punish highway.
  cleanest: Object.freeze({
    paved: 1.0,
    gravel: 8.0,
    access: 10.0,
    track: 14.0,
    unknown: 6.0
  })
});

/**
 * Road-track multipliers — locked OSM Carto categories for DIRT:
 *   https://wiki.openstreetmap.org/wiki/OpenStreetMap_Carto/Lines
 *   freeway/ramp ≈ motorway
 *   arterial     ≈ trunk / primary (upper major)
 *   collector    ≈ secondary (mid major)
 *   local        ≈ tertiary / unclassified (lower major)
 *   service      ≈ residential / living_street / service (city roads)
 *   track/resource ≈ agricultural/forestry tracks
 *
 * Cleanest: upper major OK through cities.
 * Adventure: prefer lower major + tracks; city roads = connectors only;
 *            avoid town-center magnets via arterial + urban penalties.
 */
const ADVENTURE_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 3.4,
  arterial: 2.85,
  collector: 1.05,
  ramp: 3.0,
  local: 0.88,
  service: 1.28,
  resource: 0.8,
  recreation: 0.78,
  track: 0.72,
  double_track: 0.72,
  unknown: 1.0
});

const DIRECT_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 2.7,
  arterial: 2.25,
  collector: 1.06,
  ramp: 2.4,
  local: 0.92,
  service: 1.18,
  resource: 0.88,
  recreation: 0.86,
  track: 0.82,
  double_track: 0.82,
  unknown: 1.0
});

// Balanced: leave upper major, ride lower major + tracks toward ~50/50.
const BALANCED_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 2.6,
  arterial: 2.15,
  collector: 1.02,
  ramp: 2.3,
  local: 0.9,
  service: 1.22,
  resource: 0.88,
  recreation: 0.86,
  track: 0.84,
  double_track: 0.84,
  unknown: 1.0
});

const PROFILE_ROAD_CLASS_WEIGHTS = Object.freeze({
  // Prefer major paved progress over freeway-only backtrack snacks.
  // Freeway still slightly favored among equals, but arterial/collector/local
  // paved in the direction of travel must beat reverse U-turns to the 100-series.
  cleanest: Object.freeze({
    freeway: 0.94,
    arterial: 0.95,
    collector: 0.97,
    ramp: 0.96,
    local: 1.0,
    service: 1.08,
    resource: 1.0,
    recreation: 1.0,
    track: 1.0,
    double_track: 1.0,
    unknown: 1.0
  }),
  direct: DIRECT_ROAD_CLASS_WEIGHTS,
  balanced: BALANCED_ROAD_CLASS_WEIGHTS,
  dirt: ADVENTURE_ROAD_CLASS_WEIGHTS
});

const SURFACE_SPEED_KMH = Object.freeze({
  paved: 70,
  gravel: 45,
  access: 35,
  track: 25,
  unknown: 30
});

/** Packed surface codes matching regional package.js SURFACE map. */
const SURFACE_CODE_NAME = Object.freeze({
  0: "paved",
  1: "gravel",
  2: "access",
  3: "track",
  4: "unknown"
});

function surfaceMultiplier(surfaceCode, profile) {
  const name = SURFACE_CODE_NAME[surfaceCode] || "unknown";
  const table = PROFILE_SURFACE_WEIGHTS[profile] || PROFILE_SURFACE_WEIGHTS.balanced;
  return table[name] != null ? table[name] : 1;
}

function roadClassMultiplier(roadTrackClass, profile) {
  const table = PROFILE_ROAD_CLASS_WEIGHTS[profile];
  if (!table) return 1;
  const key = roadTrackClass || "unknown";
  return table[key] != null ? table[key] : table.unknown != null ? table.unknown : 1;
}

function classSpeedKmh(surfaceCode) {
  const name = SURFACE_CODE_NAME[surfaceCode] || "unknown";
  return SURFACE_SPEED_KMH[name] || 30;
}

function maxSurfaceMultiplier(profile) {
  const table = PROFILE_SURFACE_WEIGHTS[profile] || PROFILE_SURFACE_WEIGHTS.balanced;
  const surfaceMax = Math.max(...Object.values(table));
  const classTable = PROFILE_ROAD_CLASS_WEIGHTS[profile];
  const classMax = classTable ? Math.max(...Object.values(classTable)) : 1;
  return surfaceMax * classMax;
}

/**
 * Build a Float64Array length 5 (surface codes 0..4) for fast relax.
 * Road-class bias is applied separately when `rt` is available (v1).
 */
function costPerKmView(profile) {
  const view = new Float64Array(5);
  for (let code = 0; code < 5; code += 1) {
    view[code] = surfaceMultiplier(code, profile);
  }
  return view;
}

module.exports = {
  PROFILE_SURFACE_WEIGHTS,
  PROFILE_ROAD_CLASS_WEIGHTS,
  SURFACE_SPEED_KMH,
  SURFACE_CODE_NAME,
  surfaceMultiplier,
  roadClassMultiplier,
  classSpeedKmh,
  maxSurfaceMultiplier,
  costPerKmView
};
