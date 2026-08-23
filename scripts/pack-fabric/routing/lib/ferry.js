"use strict";

/**
 * Ferry connectors — shared JS/Swift contract (Phase G1).
 * Ferries are timed crossings, not distance-dirt fabric.
 */

/** OSM estimate when duration=* is absent (km/h). */
const FERRY_SPEED_KMH = 18;

/** Converts crossing seconds to Dijkstra cost units (lockstep with Swift). */
const FERRY_COST_REFERENCE_KMH = 50;

/** Snap ferry terminals onto road graph nodes (harbour landings). */
const FERRY_TERMINAL_SNAP_METERS = 500;

/** Packed structure enum code for ferry (regional/package.js STRUCTURE.ferry). */
const STRUCTURE_FERRY = 4;

const LEAF_NOT_APPLICABLE = "n/a";

const FERRY_CROSSING_LABEL = "Ferry crossing";

/**
 * Parse OSM duration tag (HH:MM, M:SS, bare minutes, or seconds).
 * @returns {number|null} seconds, or null when unparseable
 */
function parseOsmDuration(raw) {
  if (raw == null || raw === "") return null;
  const s = String(raw).trim().toLowerCase();
  if (!s) return null;

  const hm = s.match(/^(\d+):(\d{1,2})$/);
  if (hm) {
    const h = Number(hm[1]);
    const m = Number(hm[2]);
    if (Number.isFinite(h) && Number.isFinite(m) && m < 60) {
      return Math.max(1, Math.round(h * 3600 + m * 60));
    }
  }

  const bare = Number(s.replace(/[^0-9.]/g, ""));
  if (Number.isFinite(bare) && bare > 0) {
    // Bare numbers under 10 are treated as minutes (OSM convention for short ferries).
    if (bare < 10) return Math.max(60, Math.round(bare * 60));
    if (bare < 180) return Math.max(60, Math.round(bare * 60));
    return Math.max(60, Math.round(bare));
  }

  return null;
}

function ferryCrossingSeconds(distanceMeters, osmDuration) {
  const parsed = parseOsmDuration(osmDuration);
  if (parsed != null && parsed > 0) return parsed;
  const meters = Number(distanceMeters) || 0;
  if (!(meters > 0)) return 300;
  return Math.max(
    60,
    Math.round(((meters / 1000) / FERRY_SPEED_KMH) * 3600)
  );
}

function isFerryStructureCode(code) {
  return Number(code) === STRUCTURE_FERRY;
}

/** Path-search step cost from crossing time (not surface-weighted). */
function ferryRelaxStepCost(crossingSeconds) {
  const sec = Number(crossingSeconds) || 0;
  if (!(sec > 0)) return 0;
  return (sec / 3600) * FERRY_COST_REFERENCE_KMH;
}

function ferryCrossingLabel() {
  return FERRY_CROSSING_LABEL;
}

module.exports = {
  FERRY_SPEED_KMH,
  FERRY_COST_REFERENCE_KMH,
  FERRY_TERMINAL_SNAP_METERS,
  STRUCTURE_FERRY,
  LEAF_NOT_APPLICABLE,
  FERRY_CROSSING_LABEL,
  parseOsmDuration,
  ferryCrossingSeconds,
  isFerryStructureCode,
  ferryRelaxStepCost,
  ferryCrossingLabel
};
