"use strict";

/**
 * Profile surface weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * `direct` is surface-neutral (rev 2.1). Dirt preference belongs to `dirt` only.
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  direct: Object.freeze({ paved: 1, gravel: 1, access: 1, track: 1, unknown: 1.02 }),
  balanced: Object.freeze({ paved: 1.85, gravel: 0.9, access: 0.82, track: 0.75, unknown: 0.95 }),
  dirt: Object.freeze({ paved: 6.5, gravel: 0.72, access: 0.58, track: 0.48, unknown: 0.7 }),
  cleanest: Object.freeze({ paved: 0.85, gravel: 1.55, access: 1.8, track: 2.4, unknown: 1.9 })
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

function classSpeedKmh(surfaceCode) {
  const name = SURFACE_CODE_NAME[surfaceCode] || "unknown";
  return SURFACE_SPEED_KMH[name] || 30;
}

function maxSurfaceMultiplier(profile) {
  const table = PROFILE_SURFACE_WEIGHTS[profile] || PROFILE_SURFACE_WEIGHTS.balanced;
  return Math.max(...Object.values(table));
}

/**
 * Build a Float64Array length 5 (surface codes 0..4) for fast relax.
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
  SURFACE_SPEED_KMH,
  SURFACE_CODE_NAME,
  surfaceMultiplier,
  classSpeedKmh,
  maxSurfaceMultiplier,
  costPerKmView
};
