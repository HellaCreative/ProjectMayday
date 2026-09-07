"use strict";

/**
 * Zoom-aware tap radius. Screen distance, not a second road network.
 *
 * metersPerPoint ≈ 156543.03392 * cos(lat) / 2^zoom  (Web Mercator, 1 CSS point)
 * A 28-point finger (~7 mm) at that resolution is the intended tap.
 *
 * Safe upper bound: 2000 m. That covers the Yarmouth harbour coarse-zoom
 * miss (~1.7 km to the connected town road) without province-wide fishing.
 * V3 stays capped at 750 m (frozen).
 */

const MIN_SNAP_M = 80;
const DEFAULT_SNAP_M = 550;
const V3_SNAP_CAP_M = 750;
const V4_SNAP_CAP_M = 2000;
const TAP_FINGER_POINTS = 28;
const MERCATOR_M_PER_POINT_AT_ZOOM_0 = 156543.03392;

function metersPerPoint(zoom, lat) {
  const z = Number(zoom);
  const latitude = Number(lat);
  if (!Number.isFinite(z) || !Number.isFinite(latitude)) return null;
  return MERCATOR_M_PER_POINT_AT_ZOOM_0 * Math.cos((latitude * Math.PI) / 180) / 2 ** z;
}

function snapCapMeters(graphBinaryVersion) {
  return Number(graphBinaryVersion) >= 4 ? V4_SNAP_CAP_M : V3_SNAP_CAP_M;
}

function tapRadiusMeters(options = {}) {
  const cap = snapCapMeters(options.graphBinaryVersion);
  const requested = Number(options.requestedMeters);
  if (Number.isFinite(requested) && requested > 0) {
    return Math.min(cap, Math.max(MIN_SNAP_M, requested));
  }
  const mpp = metersPerPoint(options.zoom, options.lat);
  if (mpp != null) {
    return Math.min(cap, Math.max(MIN_SNAP_M, TAP_FINGER_POINTS * mpp));
  }
  const fallback = Number(options.defaultMeters);
  const base = Number.isFinite(fallback) && fallback > 0 ? fallback : DEFAULT_SNAP_M;
  return Math.min(cap, Math.max(MIN_SNAP_M, base));
}

module.exports = {
  MIN_SNAP_M,
  DEFAULT_SNAP_M,
  V3_SNAP_CAP_M,
  V4_SNAP_CAP_M,
  TAP_FINGER_POINTS,
  metersPerPoint,
  snapCapMeters,
  tapRadiusMeters
};
