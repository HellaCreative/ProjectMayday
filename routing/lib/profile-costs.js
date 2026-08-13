"use strict";

/**
 * Profile surface (+ road-class) weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * Mental model — dirt is the default fabric except Clean:
 *   Clean / Cleanest → cleanest — Google/Apple: pavement/highway default.
 *                       Dirt only as a last stitch when forced.
 *   Direct           → direct   — crow-flies length first on adventure fabric;
 *                       mild dirt preference only among near-equal options.
 *                       Shorter / lower dirt% than Balanced. No dirt-tourism.
 *   Balanced         → balanced — dual-sport mix (~35–50% dirt when fabric allows);
 *                       may meander off the crow-flies cut to pick up dirt.
 *   Dirt             → dirt     — maximize purple NSTDB + OSM dirt/gravel/track;
 *                       pavement only when forced. Longer OK; no destination loops.
 *
 * Packed surface codes: paved=0 gravel=1 access=2 (resource) track=3 unknown=4.
 * Road-class (`rt` on v1 edges): cleanest prefers freeway/arterial; non-cleanest
 * pay hard for freeway/arterial so adventure never keeps a highway spine.
 *
 * SoT: Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift (phone). Dirt surface
 * values here already include iOS `dirtUnpavedMult` so live API matches.
 *
 * Copy this file to Mayday `routing/lib/profile-costs.js` and deploy `/api/route`
 * whenever the tables change. Live and the phone pack are one fabric; costs
 * must ship on both engines. See scripts/pack-fabric/scripts/ship-routing.js.
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  // Length dominates. Mild dirt preference among near-equal options only.
  // Must stay WEAKER than Balanced — otherwise Direct out-dirts Balanced.
  direct: Object.freeze({
    paved: 1.18,
    gravel: 0.96,
    access: 0.93,
    track: 0.9,
    unknown: 0.95
  }),
  // Dual-sport mix — stronger dirt pull + wider ellipse (router) so the
  // journey can leave Direct’s crow-flies cut for gravel/track corridors.
  balanced: Object.freeze({
    paved: 4.2,
    gravel: 0.72,
    access: 0.58,
    track: 0.48,
    unknown: 0.68
  }),
  // Maximize tagged gravel/track/resource. Untagged yellow/white OSM roads
  // cost as paved (they paint paved). Includes iOS dirtUnpavedMult
  // (gravel 0.58, access 0.38, track 0.28, unknown 0.55).
  // Paved 16× (not 36×): short paved connectors onto FSRs still work.
  dirt: Object.freeze({
    paved: 16.0,
    gravel: 0.1624,
    access: 0.0456,
    track: 0.0168,
    unknown: 0.154
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
 * Adventure: avoid freeway/arterial + town cores; prefer lower major + tracks.
 */
const ADVENTURE_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 14.0,
  arterial: 9.5,
  collector: 2.4,
  ramp: 12.0,
  local: 0.78,
  service: 1.4,
  resource: 0.4,
  recreation: 0.38,
  track: 0.3,
  double_track: 0.3,
  unknown: 0.95
});

const DIRECT_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 1.55,
  arterial: 1.35,
  collector: 1.06,
  ramp: 1.45,
  local: 0.95,
  service: 1.12,
  resource: 0.92,
  recreation: 0.9,
  track: 0.88,
  double_track: 0.88,
  unknown: 1.0
});

// Balanced: leave upper major harder than Direct so dirt corridors win more often.
const BALANCED_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 5.6,
  arterial: 4.2,
  collector: 1.1,
  ramp: 5.0,
  local: 0.86,
  service: 1.28,
  resource: 0.76,
  recreation: 0.74,
  track: 0.7,
  double_track: 0.7,
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

function paintsAsPavedRoadClass(road) {
  return (
    road === "freeway" ||
    road === "arterial" ||
    road === "ramp" ||
    road === "collector" ||
    road === "local" ||
    road === "service"
  );
}

function surfaceMultiplier(surfaceCode, profile, _regionId, roadTrackClass) {
  const name = SURFACE_CODE_NAME[surfaceCode] || "unknown";
  const table = PROFILE_SURFACE_WEIGHTS[profile] || PROFILE_SURFACE_WEIGHTS.balanced;
  // Untagged OSM highway paints paved — cost it as paved or Dirt≈Balanced.
  if (
    (profile === "dirt" || profile === "balanced") &&
    name === "unknown" &&
    paintsAsPavedRoadClass(roadTrackClass)
  ) {
    return table.paved != null ? table.paved : 1;
  }
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
  paintsAsPavedRoadClass,
  surfaceMultiplier,
  roadClassMultiplier,
  classSpeedKmh,
  maxSurfaceMultiplier,
  costPerKmView
};
