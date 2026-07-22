"use strict";

/**
 * Profile surface (+ light road-class) weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * Same app, different jobs per stage:
 *   Clean / Cleanest → cleanest — Google/Apple mode: fastest practical A→B on
 *                       pavement/highway. Highway is fine. Dirt only if forced.
 *   Dirt             → dirt     — find dirt between pavement; maximize adventure
 *   Balanced         → balanced — ~50/50 dual-sport journey (not Google, not forest)
 *   Direct           → direct   — crow-flies cut through territory; prefer dirt
 *                       when it shortens the line (not cleanest-highway)
 *
 * Packed surface codes: paved=0 gravel=1 access=2 (resource) track=3 unknown=4.
 * Road-class (`rt` on v1 edges) biases cleanest toward freeway/arterial among
 * paved options. v2 packs omit `rt` — surface weights alone still prefer shortest
 * paved path (highway-ish when the graph allows).
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  // Crow-flies shortcut: length dominates; mild dirt discount when it cuts.
  direct: Object.freeze({
    paved: 1.12,
    gravel: 0.92,
    access: 0.88,
    track: 0.85,
    unknown: 0.95
  }),
  // Dual-sport mix — enough adventure pull to leave the highway corridor,
  // not enough to become a dirt clone. Target mid paved/dirt on dirt-rich NS.
  balanced: Object.freeze({
    paved: 1.45,
    gravel: 0.94,
    access: 0.86,
    track: 0.8,
    unknown: 0.96
  }),
  // Maximize undeveloped/gravel/track/resource; pavement only when forced.
  // Stronger track/access pull so Dirt leaves the NRN corridor for NSTDB/OSM fabric.
  dirt: Object.freeze({
    paved: 12.0,
    gravel: 0.64,
    access: 0.42,
    track: 0.3,
    unknown: 0.52
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
 * Road-track multipliers. Only cleanest differentiates (prefer freeway/arterial).
 * Other profiles stay 1.0 — surface tables already express their journey intent.
 */
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
  })
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
