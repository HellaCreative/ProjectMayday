"use strict";

/**
 * Hop-search constraints. Lockstep: Dirt/Routing/UrbanCore.swift + HopSearchPolicy.swift.
 */

const DIRECT_STRETCH = 1.2; // unused for Direct shaping — corridor replaced stretch-factor
const BALANCED_STRETCH = 1.4; // compute prune only; corridor is the geographic ceiling
const DIRECT_CORRIDOR_M = 15000;
const DIRT_CORRIDOR_M = 50000;
const BALANCED_CORRIDOR_M = 40000;
const VARIETY_MARGIN = 0.08;
const VARIETY_SLOTS = 3;
const BALANCED_DIRT_LO = 0.45;
const BALANCED_DIRT_HI = 0.55;
const BALANCED_BUCKETS = 8;
const EARTH_RADIUS_M = 6371000;

const METRO_CORE_WALL = [
  { minLat: 49.0, maxLat: 49.42, minLon: -123.32, maxLon: -122.7, name: "vancouver" },
  { minLat: 48.4, maxLat: 48.52, minLon: -123.45, maxLon: -123.3, name: "victoria" },
  { minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85, name: "calgary" },
  { minLat: 53.4, maxLat: 53.7, minLon: -113.72, maxLon: -113.28, name: "edmonton" },
  { minLat: 43.58, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, name: "toronto" },
  { minLat: 45.38, maxLat: 45.72, minLon: -73.98, maxLon: -73.48, name: "montreal" },
  { minLat: 45.32, maxLat: 45.48, minLon: -75.85, maxLon: -75.62, name: "ottawa" },
  { minLat: 49.8, maxLat: 50.0, minLon: -97.3, maxLon: -96.95, name: "winnipeg" }
];

function boxContaining(lon, lat) {
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
  for (const box of METRO_CORE_WALL) {
    if (lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon) {
      return box;
    }
  }
  return null;
}

function metroBlocks(lon, lat, startLL, endLL) {
  const box = boxContaining(lon, lat);
  if (!box) return false;
  if (startLL && boxContaining(startLL[0], startLL[1]) === box) return false;
  if (endLL && boxContaining(endLL[0], endLL[1]) === box) return false;
  return true;
}

function varietyHash(seed, node, ei) {
  let x = (Number(seed) + (node | 0) * 2654435761 + (ei | 0) * 1597334677) >>> 0;
  x ^= x >>> 16;
  x = Math.imul(x, 2246822519) >>> 0;
  x ^= x >>> 13;
  return x >>> 0;
}

function dirtBucket(dirtMeters, shortestMeters) {
  const span = Math.max((shortestMeters || 0) * 0.12, 8000);
  const b = Math.floor(dirtMeters / span);
  return Math.min(BALANCED_BUCKETS - 1, Math.max(0, b));
}

function considerRelax(newCost, oldCost, newEi, oldEi, node, seed, variety, slotsUsed, newIsDirt, oldIsDirt) {
  if (!Number.isFinite(oldCost)) return "reset";
  if (!variety) return newCost < oldCost ? "reset" : "reject";
  if (newCost < oldCost * (1 - VARIETY_MARGIN)) return "reset";
  if (newCost > oldCost * (1 + VARIETY_MARGIN)) return "reject";
  if ((slotsUsed | 0) >= VARIETY_SLOTS) return "reject";
  const hn = varietyHash(seed, node, newEi);
  const ho = varietyHash(seed, node, oldEi);
  let preferNew;
  if (hn !== ho) preferNew = hn < ho;
  else if (!!newIsDirt !== !!oldIsDirt) preferNew = !!newIsDirt;
  else preferNew = newCost < oldCost;
  if (!preferNew) return "reject";
  return newCost < oldCost ? "improve" : "steal";
}

function applyRelax(action, slots, index) {
  if (action === "reject") return false;
  if (action === "reset") {
    slots[index] = 1;
    return true;
  }
  slots[index] = (slots[index] | 0) + 1;
  return true;
}

function shouldPush(action) {
  return action === "reset" || action === "improve";
}

function corridorMetersForProfile(profile) {
  if (profile === "direct") return DIRECT_CORRIDOR_M;
  if (profile === "dirt") return DIRT_CORRIDOR_M;
  if (profile === "balanced") return BALANCED_CORRIDOR_M;
  return null;
}

function angularDistanceRadians(a, b) {
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
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
  if (!point || !a || !b) return 0;
  const ab = angularDistanceRadians(a, b);
  if (!(ab > 1e-9)) return 0;
  const d13 = angularDistanceRadians(a, point);
  const t13 = initialBearingRadians(a, point);
  const t12 = initialBearingRadians(a, b);
  return Math.asin(Math.sin(d13) * Math.sin(t13 - t12)) * EARTH_RADIUS_M;
}

function outsideCorridor(point, startLL, endLL, widthMeters) {
  if (!(widthMeters > 0) || !point || !startLL || !endLL) return false;
  return Math.abs(crossTrackMeters(point, startLL, endLL)) > widthMeters;
}

function hopBlocked(toLL, startLL, endLL, cityWall, corridorM) {
  if (!toLL) return false;
  if (cityWall && metroBlocks(toLL[0], toLL[1], startLL, endLL)) return true;
  return outsideCorridor(toLL, startLL, endLL, corridorM);
}

function maxCrossTrackMeters(coords, startLL, endLL) {
  let best = 0;
  if (!Array.isArray(coords)) return 0;
  for (const c of coords) {
    const xt = Math.abs(crossTrackMeters(c, startLL, endLL));
    if (xt > best) best = xt;
  }
  return best;
}

function annotateCorridorMeta(result, startLL, endLL, profile) {
  if (!result) return result;
  const cap = corridorMetersForProfile(profile);
  const maxXT = maxCrossTrackMeters(result.geometry || [], startLL, endLL);
  result.searchMeta = result.searchMeta || {};
  result.searchMeta.corridorMeters = cap;
  result.searchMeta.maxCrossTrackMeters = Math.round(maxXT);
  return result;
}

function isDirtSurface(surfaceName, roadClassName) {
  if (surfaceName === "paved") return false;
  if (surfaceName === "unknown") {
    if (
      roadClassName === "freeway" ||
      roadClassName === "arterial" ||
      roadClassName === "ramp" ||
      roadClassName === "collector" ||
      roadClassName === "local" ||
      roadClassName === "service"
    ) {
      return false;
    }
  }
  return (
    surfaceName === "gravel" ||
    surfaceName === "access" ||
    surfaceName === "resource" ||
    surfaceName === "track" ||
    surfaceName === "double_track" ||
    surfaceName === "single" ||
    surfaceName === "unpaved" ||
    surfaceName === "dirt" ||
    surfaceName === "unknown"
  );
}

module.exports = {
  DIRECT_STRETCH,
  BALANCED_STRETCH,
  DIRECT_CORRIDOR_M,
  DIRT_CORRIDOR_M,
  BALANCED_CORRIDOR_M,
  VARIETY_MARGIN,
  VARIETY_SLOTS,
  BALANCED_DIRT_LO,
  BALANCED_DIRT_HI,
  BALANCED_BUCKETS,
  METRO_CORE_WALL,
  metroBlocks,
  varietyHash,
  dirtBucket,
  considerRelax,
  applyRelax,
  shouldPush,
  isDirtSurface,
  corridorMetersForProfile,
  crossTrackMeters,
  outsideCorridor,
  hopBlocked,
  maxCrossTrackMeters,
  annotateCorridorMeta
};
