"use strict";

const { resolveProfile } = require("./profile-costs");

/**
 * Hop-search constraints. Lockstep: Dirt/Routing/UrbanCore.swift + HopSearchPolicy.swift.
 */

const BALANCED_STRETCH = 1.4; // compute prune only; corridor is the geographic ceiling
const DIRT_CORRIDOR_M = 60000;
const BALANCED_CORRIDOR_M = 40000;
const VARIETY_MARGIN = 0.08;
const VARIETY_SLOTS = 3;
const BALANCED_DIRT_LO = 0.45;
const BALANCED_DIRT_HI = 0.55;
const BALANCED_BUCKETS = 20;
const PASS2_TIME_MS = 18000;
const PASS2_POP_CAP = 400000;
const EARTH_RADIUS_M = 6371000;
/** Clean has no hard progress-regression gate — soft away-tax only. */
const MAX_PROGRESS_REGRESSION_M = Object.freeze({
  balanced: 10000,
  dirt: 15000
});
/** Merge pack duplicate nodes within this radius (Clean topology bridge). */
const CLEAN_COINCIDENT_NODE_M = 2;
// Dirt works back from 100%, but a kilometre of pavement cannot justify an
// effectively unlimited dirt excursion. These are exchange rates, not a
// shortest-path objective: extra dirt is welcome when it replaces meaningful
// pavement or creates a coherent adventure chain.
const DIRT_RIDE_PAVED_PER_KM = Number(process.env.DIRT_RIDE_PAVED_PER_KM || 150);
const DIRT_RIDE_GRAVEL_PER_KM = Number(process.env.DIRT_RIDE_GRAVEL_PER_KM || 0.7);
const DIRT_RIDE_RESOURCE_PER_KM = Number(process.env.DIRT_RIDE_RESOURCE_PER_KM || 0.5);
const DIRT_RIDE_UNKNOWN_TRACK_PER_KM = Number(process.env.DIRT_RIDE_UNKNOWN_TRACK_PER_KM || 0.9);
const DIRT_RIDE_XT_SCALE = Number(process.env.DIRT_RIDE_XT_SCALE || 1);
const DIRT_RIDE_AWAY_SCALE = Number(process.env.DIRT_RIDE_AWAY_SCALE || 10);
const SETTLEMENT_FALLBACK_MULTIPLIER = Number(process.env.SETTLEMENT_FALLBACK_MULTIPLIER || 20);

const METRO_CORE_WALL = [
  { minLat: 49.0, maxLat: 49.42, minLon: -123.32, maxLon: -122.7, name: "vancouver" },
  { minLat: 49.0, maxLat: 49.14, minLon: -122.45, maxLon: -122.15, name: "abbotsford" },
  { minLat: 49.08, maxLat: 49.2, minLon: -122.05, maxLon: -121.85, name: "chilliwack" },
  { minLat: 48.4, maxLat: 48.52, minLon: -123.45, maxLon: -123.3, name: "victoria" },
  { minLat: 49.8, maxLat: 50.0, minLon: -119.65, maxLon: -119.3, name: "kelowna" },
  { minLat: 50.62, maxLat: 50.75, minLon: -120.5, maxLon: -120.15, name: "kamloops" },
  { minLat: 53.82, maxLat: 54.0, minLon: -122.85, maxLon: -122.65, name: "prince-george" },
  { minLat: 44.55, maxLat: 44.78, minLon: -63.75, maxLon: -63.4, name: "halifax" },
  { minLat: 45.85, maxLat: 46.2, minLon: -64.95, maxLon: -64.55, name: "moncton" },
  { minLat: 45.2, maxLat: 45.35, minLon: -66.2, maxLon: -65.95, name: "saint-john" },
  { minLat: 45.9, maxLat: 46.05, minLon: -66.75, maxLon: -66.55, name: "fredericton" },
  { minLat: 46.75, maxLat: 46.9, minLon: -71.35, maxLon: -71.1, name: "quebec-city" },
  { minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85, name: "calgary" },
  { minLat: 53.4, maxLat: 53.7, minLon: -113.72, maxLon: -113.28, name: "edmonton" },
  { minLat: 43.58, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, name: "toronto" },
  { minLat: 45.38, maxLat: 45.72, minLon: -73.98, maxLon: -73.48, name: "montreal" },
  { minLat: 45.32, maxLat: 45.48, minLon: -75.85, maxLon: -75.62, name: "ottawa" },
  { minLat: 49.8, maxLat: 50.0, minLon: -97.3, maxLon: -96.95, name: "winnipeg" },
  { minLat: 50.38, maxLat: 50.52, minLon: -104.75, maxLon: -104.5, name: "regina" },
  { minLat: 52.05, maxLat: 52.22, minLon: -106.8, maxLon: -106.55, name: "saskatoon" }
];

function boxContaining(lon, lat, boxes = METRO_CORE_WALL) {
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
  for (const box of boxes) {
    if (lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon) {
      return box;
    }
  }
  return null;
}

function metroBlocks(lon, lat, startLL, endLL, boxes = METRO_CORE_WALL) {
  const box = boxContaining(lon, lat, boxes);
  if (!box) return false;
  if (startLL && boxContaining(startLL[0], startLL[1], boxes) === box) return false;
  if (endLL && boxContaining(endLL[0], endLL[1], boxes) === box) return false;
  return true;
}

function segmentIntersectsBox(a, b, box) {
  if (!a || !b || !box) return false;
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  let lo = 0;
  let hi = 1;
  const tests = [
    [-dx, a[0] - box.minLon],
    [dx, box.maxLon - a[0]],
    [-dy, a[1] - box.minLat],
    [dy, box.maxLat - a[1]]
  ];
  for (const [p, q] of tests) {
    if (p === 0) {
      if (q < 0) return false;
      continue;
    }
    const r = q / p;
    if (p < 0) lo = Math.max(lo, r);
    else hi = Math.min(hi, r);
    if (lo > hi) return false;
  }
  return true;
}

function metroEdgeBlocks(fromLL, toLL, startLL, endLL, boxes = METRO_CORE_WALL) {
  if (!fromLL || !toLL) return false;
  for (const box of boxes || []) {
    if (
      (startLL && boxContaining(startLL[0], startLL[1], [box])) ||
      (endLL && boxContaining(endLL[0], endLL[1], [box]))
    ) continue;
    if (segmentIntersectsBox(fromLL, toLL, box)) return true;
  }
  return false;
}

/**
 * Debug-only Clean override: clamp options.cleanMetroMultiplier to 1–20.
 * Null uses the production Clean value from the major-highway control.
 */
function resolveCleanMetroMultiplier(profile, raw) {
  if (String(profile || "").toLowerCase() !== "cleanest") return null;
  if (raw == null || raw === "") return null;
  const n = Number(raw);
  if (!Number.isFinite(n)) return null;
  return Math.min(20, Math.max(1, n));
}

/** Clean ×10 with major highways off, ×2 with them on; other profiles retain ×120. */
function resolveMetroFallbackPenalty(profile, cleanMetroMultiplier, avoidMajorHighways = true) {
  if (String(profile || "").toLowerCase() !== "cleanest") return 120;
  return resolveCleanMetroMultiplier(profile, cleanMetroMultiplier)
    ?? (avoidMajorHighways ? 10 : 2);
}

/** Pack-derived towns share Clean's bounded 1–20 city control; adventure uses the maximum. */
function resolveSettlementFallbackPenalty(
  profile, cleanMetroMultiplier, avoidMajorHighways = true
) {
  if (String(profile || "").toLowerCase() === "cleanest") {
    return resolveMetroFallbackPenalty(profile, cleanMetroMultiplier, avoidMajorHighways);
  }
  return SETTLEMENT_FALLBACK_MULTIPLIER;
}

/**
 * A relaxed wall is still expensive. This makes the last-resort search cross
 * the smallest necessary urban section instead of treating every city as open.
 * Optional fromLL also taxes edges that tunnel through a core between nodes.
 * `penalty` defaults to 120; Clean pin tests may pass 1–20 via cleanMetroMultiplier.
 */
function urbanCoreFallbackMultiplier(
  lon, lat, startLL, endLL, boxes = METRO_CORE_WALL, fromLL = null, penalty = 120
) {
  const p = Number.isFinite(Number(penalty)) && Number(penalty) > 0 ? Number(penalty) : 120;
  if (metroBlocks(lon, lat, startLL, endLL, boxes)) return p;
  if (fromLL && metroEdgeBlocks(fromLL, [lon, lat], startLL, endLL, boxes)) return p;
  return 1;
}

/** Smaller OSM place=city|town boxes receive scored avoidance. */
function settlementBlocks(lon, lat, startLL, endLL, boxes = []) {
  return metroBlocks(lon, lat, startLL, endLL, boxes);
}

/** Town travel remains a finite cost, with an endpoint-inside exemption. */
function settlementFallbackMultiplier(
  lon, lat, startLL, endLL, boxes = [], penalty = SETTLEMENT_FALLBACK_MULTIPLIER
) {
  const p = Number.isFinite(Number(penalty))
    ? Math.min(20, Math.max(1, Number(penalty)))
    : SETTLEMENT_FALLBACK_MULTIPLIER;
  return settlementBlocks(lon, lat, startLL, endLL, boxes)
    ? p
    : 1;
}

function varietyHash(seed, node, ei) {
  let x = (Number(seed) + (node | 0) * 2654435761 + (ei | 0) * 1597334677) >>> 0;
  x ^= x >>> 16;
  x = Math.imul(x, 2246822519) >>> 0;
  x ^= x >>> 13;
  return x >>> 0;
}

function dirtBucket(dirtMeters, pathMeters) {
  if (!(pathMeters > 1)) return 0;
  const r = Math.min(1, Math.max(0, dirtMeters / pathMeters));
  const b = Math.floor(r * BALANCED_BUCKETS);
  return Math.min(BALANCED_BUCKETS - 1, Math.max(0, b));
}

function pickResourceEnd(cands, profile, seed) {
  if (!cands.length) return -1;
  profile = resolveProfile(profile);
  const ratio = (x) => (x.len > 0 ? x.dirt / x.len : 0);
  if (profile === "dirt") {
    cands.sort((a, b) => {
      const dr = ratio(b) - ratio(a);
      if (Math.abs(dr) > 0.005) return dr;
      const pavedA = a.len - a.dirt;
      const pavedB = b.len - b.dirt;
      if (Math.abs(pavedA - pavedB) > 50) return pavedA - pavedB;
      if (Math.abs(a.len - b.len) > 50) return a.len - b.len;
      return varietyHash(seed, a.lab, 0) - varietyHash(seed, b.lab, 0);
    });
    return cands[0].lab;
  }
  const inBand = cands.filter((x) => {
    const r = ratio(x);
    return r >= BALANCED_DIRT_LO && r <= BALANCED_DIRT_HI;
  });
  const pool = inBand.length ? inBand : cands;
  pool.sort((a, b) => {
    const da = Math.abs(ratio(a) - 0.5);
    const db = Math.abs(ratio(b) - 0.5);
    if (Math.abs(da - db) > 0.005) return da - db;
    if (Number.isFinite(a.score) && Number.isFinite(b.score) && Math.abs(a.score - b.score) > 50) {
      return a.score - b.score;
    }
    if (Math.abs(a.len - b.len) > 50) return a.len - b.len;
    const ha = varietyHash(seed, a.lab, 0);
    const hb = varietyHash(seed, b.lab, 0);
    if (ha !== hb) return ha - hb;
    return a.len - b.len;
  });
  return pool[0].lab;
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

function createsCycle(prev, from, through) {
  let n = from;
  let hops = 0;
  const cap = (prev.length || 0) + 2;
  while (n >= 0 && hops < cap) {
    if (n === through) return true;
    n = prev[n];
    hops += 1;
  }
  return hops >= cap;
}

function corridorMetersForProfile(profile) {
  profile = resolveProfile(profile);
  if (profile === "dirt") return DIRT_CORRIDOR_M;
  if (profile === "balanced") return BALANCED_CORRIDOR_M;
  // Clean: no corridor product rule.
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

/** Along-route progress without constructing a shortest/reference path. */
function projectedProgressMeters(point, startLL, endLL) {
  if (!point || !startLL || !endLL) return 0;
  const ab = angularDistanceRadians(startLL, endLL) * EARTH_RADIUS_M;
  if (!(ab > 1)) return 0;
  const ap = angularDistanceRadians(startLL, point) * EARTH_RADIUS_M;
  const pb = angularDistanceRadians(point, endLL) * EARTH_RADIUS_M;
  return (ap * ap + ab * ab - pb * pb) / (2 * ab);
}

function maxProgressRegressionMeters(profile) {
  profile = resolveProfile(profile);
  if (profile === "cleanest") return Infinity;
  return MAX_PROGRESS_REGRESSION_M[profile] || Infinity;
}

/**
 * Corridor width grants lateral room; it must never grant permission to ride
 * farther away from B. Only the final connectivity proof may remove the
 * forward-progress guard. Clean never uses a hard regression continue.
 */
function progressRegressionForAttempt(profile, corridorMeters) {
  profile = resolveProfile(profile);
  if (profile === "cleanest") return Infinity;
  if (!Number.isFinite(corridorMeters)) return Infinity;
  if (profile !== "dirt") return maxProgressRegressionMeters(profile);
  // Dirt can earn a larger initial bend when the search has deliberately been
  // granted a wider adventure corridor. Keeping every finite attempt at 15 km
  // made geographic choke points (Eastern Shore around Halifax is the fixed
  // regression) look disconnected and prematurely opened the urban wall.
  // The allowance remains bounded and proportional to the corridor; it is not
  // an invitation to consume all lateral space or create a sightseeing loop.
  return Math.max(
    maxProgressRegressionMeters(profile),
    Math.min(60_000, Number(corridorMeters) * 0.25)
  );
}

/**
 * Pack builds sometimes leave coincident duplicate nodes on a continuous OSM
 * way with no edge between them. Every profile treats nodes within
 * CLEAN_COINCIDENT_NODE_M as the same place (zero-cost transfer) so the road
 * stays connected regardless of surface preference.
 * Returns Int32Array length n: for each node, first sibling index or -1.
 * Full sibling lists via coincidentSiblingLists.
 */
function coincidentSiblingLists(nodeCoords, n, epsilonMeters = CLEAN_COINCIDENT_NODE_M) {
  const lists = new Array(n);
  lists.fill(null);
  if (!nodeCoords || n <= 0) return lists;
  const qLat = epsilonMeters / 111000;
  // Keep only the first node for the overwhelmingly common one-node bucket.
  // Province-sized packs should allocate sibling arrays only for actual
  // duplicate buckets, not once for every node in the graph.
  const firstByBucket = new Map();
  const latitudeKeyStride = 20_000_001;
  for (let i = 0; i < n; i += 1) {
    const lon = nodeCoords[i * 2];
    const lat = nodeCoords[i * 2 + 1];
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    const cos = Math.max(0.2, Math.cos((lat * Math.PI) / 180));
    const qLon = epsilonMeters / (111000 * cos);
    const key =
      Math.round(lon / qLon) * latitudeKeyStride + Math.round(lat / qLat);
    const encodedFirst = firstByBucket.get(key);
    if (encodedFirst == null) {
      // Store index + 1 so node zero is distinguishable from no entry.
      firstByBucket.set(key, i + 1);
      continue;
    }

    const first = encodedFirst - 1;
    const prior = lists[first];
    if (!prior) {
      lists[first] = [i];
      lists[i] = [first];
      continue;
    }
    const existing = [first].concat(prior);
    for (const sibling of existing) {
      lists[sibling].push(i);
    }
    lists[i] = existing;
  }
  return lists;
}

function hopBlocked(toLL, startLL, endLL, cityWall, boxes = METRO_CORE_WALL) {
  if (!cityWall || !toLL) return false;
  return metroBlocks(toLL[0], toLL[1], startLL, endLL, boxes);
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

function routeShapeMetrics(coords, startLL, endLL) {
  if (!Array.isArray(coords) || coords.length < 2) {
    return { routeMeters: 0, backwardMeters: 0, lateralMeters: 0, p95CrossTrackMeters: 0 };
  }
  let routeMeters = 0;
  let backwardMeters = 0;
  let lateralMeters = 0;
  const crossTrackWeighted = [];
  for (let i = 1; i < coords.length; i += 1) {
    const a = coords[i - 1];
    const b = coords[i];
    const meters = angularDistanceRadians(a, b) * EARTH_RADIUS_M;
    if (!(meters > 0)) continue;
    routeMeters += meters;
    const progressA = projectedProgressMeters(a, startLL, endLL);
    const progressB = projectedProgressMeters(b, startLL, endLL);
    const delta = progressB - progressA;
    if (delta < 0) backwardMeters += meters;
    const along = Math.min(meters, Math.abs(delta));
    lateralMeters += Math.sqrt(Math.max(0, meters * meters - along * along));
    crossTrackWeighted.push({
      meters,
      crossTrack: Math.abs(crossTrackMeters(b, startLL, endLL))
    });
  }
  crossTrackWeighted.sort((a, b) => a.crossTrack - b.crossTrack);
  const target = routeMeters * 0.95;
  let walked = 0;
  let p95CrossTrackMeters = 0;
  for (const item of crossTrackWeighted) {
    walked += item.meters;
    p95CrossTrackMeters = item.crossTrack;
    if (walked >= target) break;
  }
  return {
    routeMeters: Math.round(routeMeters),
    backwardMeters: Math.round(backwardMeters),
    backwardPercent: routeMeters > 0 ? Math.round(backwardMeters / routeMeters * 1000) / 10 : 0,
    lateralMeters: Math.round(lateralMeters),
    lateralPercent: routeMeters > 0 ? Math.round(lateralMeters / routeMeters * 1000) / 10 : 0,
    p95CrossTrackMeters: Math.round(p95CrossTrackMeters)
  };
}

function annotateCorridorMeta(result, startLL, endLL, profile, shortestMeters) {
  if (!result) return result;
  const cap = corridorMetersForProfile(profile);
  const maxXT = maxCrossTrackMeters(result.geometry || [], startLL, endLL);
  result.searchMeta = result.searchMeta || {};
  result.searchMeta.corridorMeters = cap;
  result.searchMeta.maxCrossTrackMeters = Math.round(maxXT);
  result.searchMeta.routeShape = routeShapeMetrics(result.geometry || [], startLL, endLL);
  if (Number.isFinite(shortestMeters) && shortestMeters > 0) {
    result.searchMeta.shortestMeters = Math.round(shortestMeters);
    result.searchMeta.extraUsedMeters = Math.round(result.distanceMeters - shortestMeters);
    result.searchMeta.extraBudgetMeters = cap;
  }
  if (result.searchMeta.timedOut) {
    result.searchMeta.pass2Outcome = result.searchMeta.pass2Outcome || "timedOut";
  }
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

/**
 * Clean pavement gate: only genuine paved, or untagged surface on major
 * paint-as-paved classes (freeway/arterial/ramp/collector). Gravel/track/
 * access and untagged local/service are impassable under pavedOnly.
 */
function isBlockedForCleanPavement(surfaceName, roadClassName) {
  if (surfaceName === "paved") return false;
  if (surfaceName === "unknown") {
    return !(
      roadClassName === "freeway" ||
      roadClassName === "arterial" ||
      roadClassName === "ramp" ||
      roadClassName === "collector"
    );
  }
  return true;
}

function dirtRideCostPerKm(surfaceName, roadClassName, confidence) {
  if (!isDirtSurface(surfaceName, roadClassName)) return DIRT_RIDE_PAVED_PER_KM;
  let cost;
  if (surfaceName === "gravel") cost = DIRT_RIDE_GRAVEL_PER_KM;
  else if (surfaceName === "access" || surfaceName === "resource" || surfaceName === "track") {
    cost = DIRT_RIDE_RESOURCE_PER_KM;
  } else {
    cost = DIRT_RIDE_UNKNOWN_TRACK_PER_KM;
  }
  // Untagged/low-confidence tracks remain useful, but explicit gravel/resource
  // should beat them when both make a similarly coherent ride.
  if (confidence === "low") cost *= 1.2;
  return cost;
}

module.exports = {
  BALANCED_STRETCH,
  DIRT_CORRIDOR_M,
  BALANCED_CORRIDOR_M,
  CLEAN_COINCIDENT_NODE_M,
  VARIETY_MARGIN,
  VARIETY_SLOTS,
  BALANCED_DIRT_LO,
  BALANCED_DIRT_HI,
  BALANCED_BUCKETS,
  PASS2_TIME_MS,
  PASS2_POP_CAP,
  METRO_CORE_WALL,
  metroBlocks,
  segmentIntersectsBox,
  metroEdgeBlocks,
  urbanCoreFallbackMultiplier,
  resolveCleanMetroMultiplier,
  resolveMetroFallbackPenalty,
  resolveSettlementFallbackPenalty,
  settlementBlocks,
  settlementFallbackMultiplier,
  SETTLEMENT_FALLBACK_MULTIPLIER,
  varietyHash,
  dirtBucket,
  pickResourceEnd,
  considerRelax,
  applyRelax,
  shouldPush,
  createsCycle,
  isDirtSurface,
  isBlockedForCleanPavement,
  dirtRideCostPerKm,
  DIRT_RIDE_PAVED_PER_KM,
  DIRT_RIDE_GRAVEL_PER_KM,
  DIRT_RIDE_RESOURCE_PER_KM,
  DIRT_RIDE_UNKNOWN_TRACK_PER_KM,
  DIRT_RIDE_XT_SCALE,
  DIRT_RIDE_AWAY_SCALE,
  corridorMetersForProfile,
  crossTrackMeters,
  outsideCorridor,
  projectedProgressMeters,
  maxProgressRegressionMeters,
  progressRegressionForAttempt,
  coincidentSiblingLists,
  hopBlocked,
  maxCrossTrackMeters,
  routeShapeMetrics,
  annotateCorridorMeta
};
