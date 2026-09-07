"use strict";

const { metroEdgeBlocks, METRO_CORE_WALL } = require("./hop-search");

const EARTH_RADIUS_M = 6_371_000;
const DIRT_TARGET_PERCENT = 70;
const DIRT_SECTION_FLOOR_PERCENT = 35;
const DIRT_LONG_PAVED_ABSOLUTE_M = 20_000;
const DIRT_LONG_PAVED_ROUTE_SHARE = 0.06;
const BALANCED_MIN_DIRT_PERCENT = 45;
const BALANCED_MAX_DIRT_PERCENT = 55;
const DEFAULT_SECTION_COUNT = 4;

const KNOWN_DIRT_SURFACES = new Set([
  "gravel",
  "access",
  "resource",
  "track",
  "double_track",
  "single",
  "unpaved",
  "dirt",
  "loose"
]);

function radians(value) {
  return Number(value) * Math.PI / 180;
}

function haversineMeters(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return 0;
  const dLat = radians(b[1] - a[1]);
  const dLon = radians(b[0] - a[0]);
  const lat1 = radians(a[1]);
  const lat2 = radians(b[1]);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

function segmentMeters(segment) {
  if (!segment || segment.structureType === "ferry") return 0;
  return Math.max(0, Number(segment.distanceMeters) || 0);
}

function isKnownDirtSegment(segment) {
  if (!segment || segment.structureType === "ferry") return false;
  const surface = String(
    segment.surfaceClass || segment.surfaceFamily || segment.surfaceLeaf || "unknown"
  ).toLowerCase();
  return KNOWN_DIRT_SURFACES.has(surface);
}

function isUnknownSurfaceSegment(segment) {
  if (!segment || segment.structureType === "ferry") return false;
  return String(segment.surfaceClass || "unknown").toLowerCase() === "unknown";
}

function routeEndpoints(route) {
  const geometry = route && route.geometry;
  if (Array.isArray(geometry) && geometry.length > 1) {
    return [geometry[0], geometry[geometry.length - 1]];
  }
  const segments = route && route.segments || [];
  const first = segments.find((row) => Array.isArray(row && row.geometry) && row.geometry.length);
  const last = segments.slice().reverse().find((row) =>
    Array.isArray(row && row.geometry) && row.geometry.length
  );
  return first && last
    ? [first.geometry[0], last.geometry[last.geometry.length - 1]]
    : [null, null];
}

function segmentUrbanMeters(segment, startLL, endLL, boxes) {
  const geometry = segment && (segment.geometry || segment.coords);
  if (!Array.isArray(geometry) || geometry.length < 2) return 0;
  let meters = 0;
  for (let index = 1; index < geometry.length; index += 1) {
    const from = geometry[index - 1];
    const to = geometry[index];
    if (metroEdgeBlocks(from, to, startLL, endLL, boxes)) {
      meters += haversineMeters(from, to);
    }
  }
  return meters;
}

/**
 * Describe the ride the rider will actually experience, not just its aggregate
 * percentage. Equal-distance sections expose front-loaded pavement, while the
 * longest paved run catches one bad highway stem hidden by a strong total.
 */
function summarizeRouteQuality(route, options = {}) {
  const profile = String(options.profile || route && route.profile || "balanced").toLowerCase();
  const segments = Array.isArray(route && route.segments) ? route.segments : [];
  const sectionCount = Math.max(1, Math.round(Number(options.sectionCount) || DEFAULT_SECTION_COUNT));
  const routeMeters = segments.reduce((sum, segment) => sum + segmentMeters(segment), 0) ||
    Math.max(0, Number(route && route.distanceMeters) || 0);
  const sectionMeters = routeMeters > 0 ? routeMeters / sectionCount : 0;
  const sections = Array.from({ length: sectionCount }, (_, index) => ({
    index,
    distanceMeters: 0,
    knownDirtMeters: 0,
    pavedMeters: 0,
    unknownSurfaceMeters: 0,
    knownDirtPercent: 0
  }));
  const [startLL, endLL] = routeEndpoints(route);
  const urbanBoxes = options.urbanBoxes || METRO_CORE_WALL;
  let walked = 0;
  let knownDirtMeters = 0;
  let pavedMeters = 0;
  let unknownSurfaceMeters = 0;
  let currentPavedRunMeters = 0;
  let longestPavedRunMeters = 0;
  let urbanCoreMeters = 0;

  for (const segment of segments) {
    let remaining = segmentMeters(segment);
    if (!(remaining > 0)) continue;
    const knownDirt = isKnownDirtSegment(segment);
    const unknownSurface = isUnknownSurfaceSegment(segment);
    if (knownDirt) {
      knownDirtMeters += remaining;
      currentPavedRunMeters = 0;
    } else {
      pavedMeters += remaining;
      if (unknownSurface) unknownSurfaceMeters += remaining;
      currentPavedRunMeters += remaining;
      longestPavedRunMeters = Math.max(longestPavedRunMeters, currentPavedRunMeters);
    }
    if (startLL && endLL) {
      urbanCoreMeters += segmentUrbanMeters(segment, startLL, endLL, urbanBoxes);
    }

    while (remaining > 0 && sectionMeters > 0) {
      const sectionIndex = Math.min(sectionCount - 1, Math.floor(walked / sectionMeters));
      const boundary = (sectionIndex + 1) * sectionMeters;
      const take = Math.min(remaining, Math.max(0, boundary - walked) || remaining);
      const section = sections[sectionIndex];
      section.distanceMeters += take;
      if (knownDirt) section.knownDirtMeters += take;
      else {
        section.pavedMeters += take;
        if (unknownSurface) section.unknownSurfaceMeters += take;
      }
      walked += take;
      remaining -= take;
    }
  }

  for (const section of sections) {
    section.knownDirtPercent = section.distanceMeters > 0
      ? Math.round(section.knownDirtMeters / section.distanceMeters * 1000) / 10
      : 0;
    section.distanceMeters = Math.round(section.distanceMeters);
    section.knownDirtMeters = Math.round(section.knownDirtMeters);
    section.pavedMeters = Math.round(section.pavedMeters);
    section.unknownSurfaceMeters = Math.round(section.unknownSurfaceMeters);
  }

  const knownDirtPercent = routeMeters > 0
    ? Math.round(knownDirtMeters / routeMeters * 1000) / 10
    : 0;
  const minimumSectionDirtPercent = sections.length
    ? Math.min(...sections.map((section) => section.knownDirtPercent))
    : 0;
  const longestPavedLimitMeters = Math.max(
    DIRT_LONG_PAVED_ABSOLUTE_M,
    routeMeters * DIRT_LONG_PAVED_ROUTE_SHARE
  );
  const reasons = [];
  if (profile === "dirt") {
    if (urbanCoreMeters > 100) reasons.push("urban_core_crossing");
    if (knownDirtPercent < DIRT_TARGET_PERCENT) reasons.push("low_overall_known_dirt");
    if (minimumSectionDirtPercent < DIRT_SECTION_FLOOR_PERCENT) reasons.push("weak_dirt_section");
    if (longestPavedRunMeters > longestPavedLimitMeters) reasons.push("long_paved_run");
  } else if (profile === "balanced") {
    if (urbanCoreMeters > 100) reasons.push("urban_core_crossing");
    if (
      knownDirtPercent < BALANCED_MIN_DIRT_PERCENT ||
      knownDirtPercent > BALANCED_MAX_DIRT_PERCENT
    ) {
      reasons.push("balanced_target_miss");
    }
  }

  return {
    contractVersion: "journey-quality-v1",
    profile,
    state: reasons.length ? "degraded" : "ready",
    reasons,
    routeMeters: Math.round(routeMeters),
    knownDirtMeters: Math.round(knownDirtMeters),
    knownDirtPercent,
    pavedMeters: Math.round(pavedMeters),
    unknownSurfaceMeters: Math.round(unknownSurfaceMeters),
    firstSectionDirtPercent: sections[0] ? sections[0].knownDirtPercent : 0,
    minimumSectionDirtPercent,
    longestPavedRunMeters: Math.round(longestPavedRunMeters),
    longestPavedLimitMeters: Math.round(longestPavedLimitMeters),
    urbanCoreMeters: Math.round(urbanCoreMeters),
    sections
  };
}

module.exports = {
  DIRT_TARGET_PERCENT,
  DIRT_SECTION_FLOOR_PERCENT,
  DIRT_LONG_PAVED_ABSOLUTE_M,
  DIRT_LONG_PAVED_ROUTE_SHARE,
  BALANCED_MIN_DIRT_PERCENT,
  BALANCED_MAX_DIRT_PERCENT,
  DEFAULT_SECTION_COUNT,
  isKnownDirtSegment,
  summarizeRouteQuality
};
