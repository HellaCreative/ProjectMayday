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
 *                       pavement only when forced.
 *   Balanced         → balanced — dirt-leaning dual-sport mix (not highway-default).
 *   Direct           → direct   — crow-flies cut on dirt fabric (purple + OSM dirt);
 *                       minimal pavement; length still matters.
 *
 * Packed surface codes: paved=0 gravel=1 access=2 (resource) track=3 unknown=4.
 * Road-class (`rt` on v1 edges): cleanest prefers freeway/arterial; non-cleanest
 * pay hard for freeway/arterial so the engine cannot keep a highway spine and
 * only nibble dirt spurs.
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  // Crow-flies on dirt fabric: length dominates among dirt/unknown/track,
  // but pavement is expensive enough that highway is never the default spine.
  direct: Object.freeze({
    paved: 4.2,
    gravel: 0.82,
    access: 0.66,
    track: 0.55,
    unknown: 0.7
  }),
  // Dirt-leaning dual-sport — leave the highway corridor, not a dirt clone.
  balanced: Object.freeze({
    paved: 2.8,
    gravel: 0.86,
    access: 0.72,
    track: 0.62,
    unknown: 0.78
  }),
  // Maximize undeveloped/gravel/track/resource; pavement only when forced.
  dirt: Object.freeze({
    paved: 12.0,
    gravel: 0.6,
    access: 0.4,
    track: 0.28,
    unknown: 0.48
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
 * Road-track multipliers.
 * Cleanest: prefer freeway/arterial among paved options.
 * Non-cleanest: punish freeway/arterial/collector so dirt fabric wins over
 * "highway spine + dirt snacks"; mild discount for resource/track class.
 */
const ADVENTURE_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 2.8,
  arterial: 2.15,
  collector: 1.45,
  ramp: 2.4,
  local: 1.06,
  service: 1.12,
  resource: 0.88,
  recreation: 0.86,
  track: 0.82,
  double_track: 0.82,
  unknown: 1.0
});

const PROFILE_ROAD_CLASS_WEIGHTS = Object.freeze({
  cleanest: Object.freeze({
    freeway: 0.82,
    arterial: 0.9,
    collector: 0.96,
    ramp: 0.88,
    local: 1.0,
    service: 1.05,
    resource: 1.0,
    recreation: 1.0,
    track: 1.0,
    double_track: 1.0,
    unknown: 1.0
  }),
  direct: ADVENTURE_ROAD_CLASS_WEIGHTS,
  balanced: ADVENTURE_ROAD_CLASS_WEIGHTS,
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
