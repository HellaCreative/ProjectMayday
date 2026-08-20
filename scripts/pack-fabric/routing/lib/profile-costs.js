"use strict";

/**
 * Profile surface (+ road-class) weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * Mental model — dirt is the default fabric except Clean:
 *   Clean / Cleanest → cleanest — pavement only. Avoid town cores unless
 *                       A/B (or a stage waypoint) sits in that town.
 *   Direct           → dirt on the crow-flies line. Pavement when a dirt loop
 *                       would double the ride. Strong away-tax. Not Dirt’s 16× hunt.
 *   Balanced         → dual-sport mix (~35–50% dirt when fabric allows).
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
 * Deploy `/api/route` with `node scripts/pack-fabric/scripts/ship-routing.js --live`
 * whenever the tables change. Live and the phone pack are one fabric.
 * Dirt arrival clamp (last ~2.5 km of B) must match OnDeviceProfileCosts.approachAwayExtra.
 */

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
  // Direct is geometry-first: surface is only a tie-break between similarly
  // aligned roads. A large paved penalty made it behave like a narrower Dirt
  // mode and spend hundreds of kilometres collecting off-line gravel.
  direct: Object.freeze({
    paved: 1.15,
    gravel: 1.00,
    access: 0.95,
    track: 0.90,
    unknown: 1.00
  }),
  // Dual-sport ~50/50. Cross-track stops the Williams Lake hunt.
  balanced: Object.freeze({
    paved: 1.42,
    gravel: 0.98,
    access: 0.92,
    track: 0.88,
    unknown: 0.96
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
    gravel: 60.0,
    access: 80.0,
    track: 100.0,
    unknown: 12.0
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
 * Cleanest: highway around towns; local/service is the city grid.
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
  freeway: 1.7,
  arterial: 1.45,
  collector: 1.06,
  ramp: 1.6,
  local: 0.98,
  service: 1.12,
  resource: 0.9,
  recreation: 0.88,
  track: 0.9,
  double_track: 0.9,
  unknown: 1.0
});

const BALANCED_ROAD_CLASS_WEIGHTS = Object.freeze({
  freeway: 3.2,
  arterial: 2.4,
  collector: 1.08,
  ramp: 2.8,
  local: 1.0,
  service: 1.15,
  resource: 0.92,
  recreation: 0.9,
  track: 0.92,
  double_track: 0.92,
  unknown: 1.0
});

const PROFILE_ROAD_CLASS_WEIGHTS = Object.freeze({
  // Prefer major paved progress over freeway-only backtrack snacks.
  // Freeway still slightly favored among equals, but arterial/collector/local
  // paved in the direction of travel must beat reverse U-turns to the 100-series.
  cleanest: Object.freeze({
    freeway: 0.94,
    arterial: 0.98,
    collector: 1.18,
    ramp: 0.96,
    local: 2.6,
    service: 3.2,
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

function approachAwayExtraCost(profile, dFromMeters, dToMeters, abMeters, minAwayMeters, _regionId) {
  const away = dToMeters - dFromMeters;
  const minAway = minAwayMeters == null ? 50 : minAwayMeters;
  if (!(away > minAway)) return 0;
  const dFrom = Math.max(0, dFromMeters);
  const ab = abMeters > 0 ? abMeters : 0;
  const kmAway = away / 1000;
  if (profile === "dirt") {
    const mid = kmAway * 1.45;
    const horizon = 2500;
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (0.12 + t * t * 0.9);
    }
    const raw = mid + near;
    const cap = kmAway * 16.0 * 0.12;
    return Math.min(raw, cap);
  }
  if (profile === "direct") {
    const nearBand = Math.max(3200, ab * 0.3);
    return kmAway * (dFrom < nearBand ? 12 : 7);
  }
  if (profile === "balanced") {
    const mid = kmAway * 2.2;
    const horizon = Math.max(4000, ab * 0.2);
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (0.4 + t * t * 2.4);
    }
    return mid + near;
  }
  const nearBand = Math.max(2800, ab * 0.28);
  return kmAway * (dFrom < nearBand ? 6.5 : 3.2);
}

/** Clean: local/service expensive unless the pin is in that town (~2.5 km of B). */
function cleanCityStreetMult(profile, roadTrackClass, dToMeters) {
  if (profile !== "cleanest") return 1;
  if (roadTrackClass !== "local" && roadTrackClass !== "service") return 1;
  const nearBand = 2500;
  const dTo = Math.max(0, dToMeters || 0);
  if (dTo <= nearBand) return 1;
  const t = Math.min(1, (dTo - nearBand) / 8000);
  return 1 + 2.4 * t;
}

const MAJOR_HIGHWAY_PIN_METERS = 18;
const MAJOR_HIGHWAY_JOIN_METERS = 6000;

function isMajorHighwayClass(road) {
  return road === "freeway" || road === "arterial" || road === "ramp";
}

function pinMatchesMajorHighway(match) {
  if (!match || !isMajorHighwayClass(match.roadTrack)) return false;
  return Number(match.distanceM) < MAJOR_HIGHWAY_PIN_METERS;
}

/** Avoid motorways except the last/first ~6 km when that pin sits on one. */
function majorHighwayAvoidMult(
  profile,
  roadTrackClass,
  metersFromStart,
  metersToDestination,
  startOnMajorHighway,
  endOnMajorHighway
) {
  if (!isMajorHighwayClass(roadTrackClass)) return 1;
  const join = MAJOR_HIGHWAY_JOIN_METERS;
  const nearPinnedHighway =
    (endOnMajorHighway && metersToDestination < join) ||
    (startOnMajorHighway && metersFromStart < join);
  const current = roadClassMultiplier(roadTrackClass, profile);
  if (nearPinnedHighway) {
    if (profile === "cleanest") return 1;
    const target = 2.0;
    if (current <= target) return 1;
    return target / current;
  }
  const target = 12.0;
  if (current >= target) return 1;
  return target / current;
}

function isBcDirt(_profile, _regionId) {
  return false;
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
function costPerKmView(profile, _regionId, pavedBias) {
  const view = new Float64Array(5);
  const bias = pavedBias == null || !(pavedBias > 0) ? 1 : pavedBias;
  for (let code = 0; code < 5; code += 1) {
    view[code] = surfaceMultiplier(code, profile);
    if (code === 0 && bias !== 1) view[code] *= bias;
  }
  return view;
}

const EARTH_RADIUS_M = 6371000;

function angularDistanceRadians(a, b) {
  const toR = Math.PI / 180;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const dLat = lat2 - lat1;
  const dLon = (b[0] - a[0]) * toR;
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function initialBearingRadians(a, b) {
  const toR = Math.PI / 180;
  const φ1 = a[1] * toR;
  const φ2 = b[1] * toR;
  const Δλ = (b[0] - a[0]) * toR;
  const y = Math.sin(Δλ) * Math.cos(φ2);
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
  return Math.atan2(y, x);
}

function crossTrackMeters(point, a, b) {
  const ab = angularDistanceRadians(a, b);
  if (!(ab > 1e-9)) return 0;
  const d13 = angularDistanceRadians(a, point);
  const t13 = initialBearingRadians(a, point);
  const t12 = initialBearingRadians(a, b);
  return Math.asin(Math.sin(d13) * Math.sin(t13 - t12)) * EARTH_RADIUS_M;
}

/** Corridor off-line tax. Direct strongest, then Balanced, then Dirt. */
function directCrossTrackExtra(profile, point, lineFrom, lineTo, edgeMeters) {
  if (!(edgeMeters > 0) || !point || !lineFrom || !lineTo) return 0;
  const k =
    profile === "direct" ? 0.018 : profile === "balanced" ? 0.014 : profile === "dirt" ? 0.005 : 0;
  if (!k) return 0;
  const xtKm = Math.abs(crossTrackMeters(point, lineFrom, lineTo)) / 1000;
  return (edgeMeters / 1000) * xtKm * xtKm * k;
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
  approachAwayExtraCost,
  cleanCityStreetMult,
  isMajorHighwayClass,
  pinMatchesMajorHighway,
  majorHighwayAvoidMult,
  isBcDirt,
  costPerKmView,
  crossTrackMeters,
  directCrossTrackExtra
};
