"use strict";

/**
 * Profile surface (+ road-class) weight tables (Stage 2c).
 * Neutral edge facts live in the pack; costs are derived here at load or relax.
 * Tuning a profile never rebuilds packs.
 *
 * Mental model — dirt is the default fabric except Clean:
 *   Clean / Cleanest → cleanest — pavement only. Avoid town cores unless
 *                       A/B (or a stage waypoint) sits in that town.
 *   Balanced         → dual-sport mix (~35–50% dirt when fabric allows).
 *                       may meander off the crow-flies cut to pick up dirt.
 *   Dirt             → dirt     — maximize purple NSTDB + OSM dirt/gravel/track;
 *                       pavement only when forced. Longer OK; no destination loops.
 *
 * Packed surface codes: paved=0 gravel=1 access=2 (resource) track=3 unknown=4.
 * Road-class (`rt` on v1 edges): Clean's rider control decides whether major
 * highways are ordinary pavement or strongly avoided. Adventure profiles retain
 * their own freeway/arterial penalties.
 *
 * SoT: Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift (phone). Dirt surface
 * values here already include iOS `dirtUnpavedMult` so live API matches.
 *
 * Deploy `/api/route` with `node scripts/pack-fabric/scripts/ship-routing.js --live`
 * whenever the tables change. Live and the phone pack are one fabric.
 * Dirt arrival clamp (last ~2.5 km of B) must match OnDeviceProfileCosts.approachAwayExtra.
 */

const KNOWN_PROFILES = Object.freeze(["cleanest", "balanced", "dirt"]);

/** Missing or unknown profile names use Balanced. */
function resolveProfile(profile) {
  const p = String(profile || "balanced").toLowerCase();
  return KNOWN_PROFILES.includes(p) ? p : "balanced";
}

const PROFILE_SURFACE_WEIGHTS = Object.freeze({
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
  // Base paved surface cost. Major-highway policy is applied during search.
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
  const table = PROFILE_SURFACE_WEIGHTS[resolveProfile(profile)] || PROFILE_SURFACE_WEIGHTS.balanced;
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
  const table = PROFILE_ROAD_CLASS_WEIGHTS[resolveProfile(profile)];
  if (!table) return 1;
  const key = roadTrackClass || "unknown";
  return table[key] != null ? table[key] : table.unknown != null ? table.unknown : 1;
}

function classSpeedKmh(surfaceCode) {
  const name = SURFACE_CODE_NAME[surfaceCode] || "unknown";
  return SURFACE_SPEED_KMH[name] || 30;
}

/**
 * Extra cost for meters walked *away* from B (distance-to-destination increases).
 * Strong soft forward fan (~45°): regressing must cost more than grazing a city
 * (×120) or a short highway connector (~×3), so the forward route wins.
 * Slight backtracks around water remain possible — not a hard reject.
 */
function approachAwayExtraCost(profile, dFromMeters, dToMeters, abMeters, minAwayMeters, _regionId) {
  const away = dToMeters - dFromMeters;
  const minAway = minAwayMeters == null ? 50 : minAwayMeters;
  if (!(away > minAway)) return 0;
  const dFrom = Math.max(0, dFromMeters);
  const ab = abMeters > 0 ? abMeters : 0;
  const kmAway = away / 1000;
  profile = resolveProfile(profile);
  if (profile === "dirt") {
    // Applied with DIRT_RIDE_AWAY_SCALE (×10) in pavement mode → ~95–150/km.
    const mid = kmAway * 9.5;
    const horizon = 2500;
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (2.0 + t * t * 6.0);
    }
    return mid + near;
  }
  if (profile === "balanced") {
    const mid = kmAway * 180;
    const horizon = Math.max(4000, ab * 0.2);
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (20 + t * t * 60);
    }
    return mid + near;
  }
  // cleanest — gravity toward B only (edges moving away from B). Never chord XT.
  // ~2/km keeps a 15 km dip (~30) below ~60 km extra pavement (~70).
  if (profile === "cleanest") {
    const nearBand = Math.max(2500, ab * 0.08);
    const w = dFrom < nearBand ? 2.5 : 2.0;
    return kmAway * w;
  }
  return 0;
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

/**
 * Major-highway class in coarse packs. These packs collapse trunk and primary
 * into arterial, so Clean applies the approved primary ×8 approximation there.
 */
function isMajorHighwayClass(road, profile) {
  void profile;
  if (road === "freeway" || road === "ramp") return true;
  return road === "arterial";
}

function pinMatchesMajorHighway(match, profile) {
  if (!match || !isMajorHighwayClass(match.roadTrack, profile)) return false;
  return Number(match.distanceM) < MAJOR_HIGHWAY_PIN_METERS;
}

/** Avoid motorways except the last/first ~6 km when that pin sits on one. */
function majorHighwayAvoidMult(
  profile,
  roadTrackClass,
  metersFromStart,
  metersToDestination,
  startOnMajorHighway,
  endOnMajorHighway,
  avoidMajorHighways = true
) {
  if (!isMajorHighwayClass(roadTrackClass, profile)) return 1;
  profile = resolveProfile(profile);
  if (profile === "cleanest" && !avoidMajorHighways) return 1;
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
  if (profile === "cleanest") {
    return roadTrackClass === "arterial" ? 8 : 40;
  }
  // Preserve the proven Dirt/Balanced baseline. Clean's rider control must not
  // retune adventure profiles as a side effect.
  const target = 3.0;
  if (current >= target) return 1;
  return target / current;
}

function isBcDirt(_profile, _regionId) {
  return false;
}

function maxSurfaceMultiplier(profile) {
  profile = resolveProfile(profile);
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

function distanceToPolylineMeters(point, coordinates) {
  if (!point || !Array.isArray(coordinates) || coordinates.length < 2) return Infinity;
  let best = Infinity;
  for (let index = 1; index < coordinates.length; index += 1) {
    const a = coordinates[index - 1];
    const b = coordinates[index];
    const lat0 = ((point[1] + a[1] + b[1]) / 3) * Math.PI / 180;
    const scaleX = EARTH_RADIUS_M * Math.cos(lat0) * Math.PI / 180;
    const scaleY = EARTH_RADIUS_M * Math.PI / 180;
    const px = (point[0] - a[0]) * scaleX;
    const py = (point[1] - a[1]) * scaleY;
    const bx = (b[0] - a[0]) * scaleX;
    const by = (b[1] - a[1]) * scaleY;
    const denom = bx * bx + by * by;
    const t = denom > 0 ? Math.max(0, Math.min(1, (px * bx + py * by) / denom)) : 0;
    best = Math.min(best, Math.hypot(px - t * bx, py - t * by));
  }
  return best;
}

/** Corridor off-line tax. Balanced then Dirt. Clean has none. */
function corridorCrossTrackExtra(
  profile, point, lineFrom, lineTo, edgeMeters, landPathCoordinates
) {
  if (!(edgeMeters > 0) || !point || !lineFrom || !lineTo) return 0;
  profile = resolveProfile(profile);
  if (profile === "cleanest") return 0;
  const k =
    profile === "balanced" ? 0.014
      : profile === "dirt" ? 0.005
        : 0;
  if (!k) return 0;
  const crossTrack = Array.isArray(landPathCoordinates) && landPathCoordinates.length > 1
    ? distanceToPolylineMeters(point, landPathCoordinates)
    : Math.abs(crossTrackMeters(point, lineFrom, lineTo));
  const xtKm = crossTrack / 1000;
  return (edgeMeters / 1000) * xtKm * xtKm * k;
}

module.exports = {
  KNOWN_PROFILES,
  resolveProfile,
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
  corridorCrossTrackExtra
};
