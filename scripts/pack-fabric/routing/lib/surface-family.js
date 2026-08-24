"use strict";

/**
 * Read-time surface family map (Phase E1).
 * Single source of truth — also embedded in graph.v3 enumsJson as `surfaceFamilyMap`
 * so Swift and JS derive identically from surfaceLeaf.
 *
 * Families: paved | gravel | loose | unknown
 * Rider-facing Dirt% = non-paved = gravel + loose + unknown (matches map paint).
 * Selection-time coarse dirt is separate and is not computed here.
 */

const SURFACE_FAMILY = Object.freeze({
  PAVED: "paved",
  GRAVEL: "gravel",
  LOOSE: "loose",
  UNKNOWN: "unknown"
});

/** Canonical leaf → family. Anything absent (incl. compounds / oddballs) → unknown. */
const SURFACE_FAMILY_MAP = Object.freeze({
  asphalt: SURFACE_FAMILY.PAVED,
  paved: SURFACE_FAMILY.PAVED,
  concrete: SURFACE_FAMILY.PAVED,
  chipseal: SURFACE_FAMILY.PAVED,
  paving_stones: SURFACE_FAMILY.PAVED,
  cobblestone: SURFACE_FAMILY.PAVED,
  sett: SURFACE_FAMILY.PAVED,
  brick: SURFACE_FAMILY.PAVED,
  metal: SURFACE_FAMILY.PAVED,
  wood: SURFACE_FAMILY.PAVED,

  gravel: SURFACE_FAMILY.GRAVEL,
  compacted: SURFACE_FAMILY.GRAVEL,
  fine_gravel: SURFACE_FAMILY.GRAVEL,
  pebblestone: SURFACE_FAMILY.GRAVEL,
  unpaved: SURFACE_FAMILY.GRAVEL,

  dirt: SURFACE_FAMILY.LOOSE,
  ground: SURFACE_FAMILY.LOOSE,
  earth: SURFACE_FAMILY.LOOSE,
  grass: SURFACE_FAMILY.LOOSE,
  mud: SURFACE_FAMILY.LOOSE,
  sand: SURFACE_FAMILY.LOOSE,
  rock: SURFACE_FAMILY.LOOSE,
  natural: SURFACE_FAMILY.LOOSE,
  woodchips: SURFACE_FAMILY.LOOSE
});

/**
 * Resolve family for a surfaceLeaf token.
 * null / "" / missing → unknown. Unlisted tokens (compounds, oddballs) → unknown.
 */
function surfaceFamilyOf(surfaceLeaf, familyMap = SURFACE_FAMILY_MAP) {
  if (surfaceLeaf == null) return SURFACE_FAMILY.UNKNOWN;
  const key = String(surfaceLeaf).trim().toLowerCase();
  if (!key) return SURFACE_FAMILY.UNKNOWN;
  return familyMap[key] || SURFACE_FAMILY.UNKNOWN;
}

function isHonestDirtFamily(family) {
  return (
    family === SURFACE_FAMILY.GRAVEL ||
    family === SURFACE_FAMILY.LOOSE ||
    family === SURFACE_FAMILY.UNKNOWN
  );
}

/**
 * Honest route surface stats from per-edge surfaceLeaf + meters.
 * When `hasLeaves` is false, caller should keep coarse stats (v2 fallback).
 */
function honestSurfaceStatsFromLeaves(rows, distanceMeters) {
  let pavedM = 0;
  let gravelM = 0;
  let looseM = 0;
  let unknownM = 0;
  let dirtM = 0;
  const map = SURFACE_FAMILY_MAP;
  for (const row of rows || []) {
    const meters = Number(row.meters) || 0;
    if (!(meters > 0)) continue;
    const family = surfaceFamilyOf(row.surfaceLeaf, map);
    if (family === SURFACE_FAMILY.PAVED) pavedM += meters;
    else if (family === SURFACE_FAMILY.GRAVEL) {
      gravelM += meters;
      dirtM += meters;
    } else if (family === SURFACE_FAMILY.LOOSE) {
      looseM += meters;
      dirtM += meters;
    } else {
      unknownM += meters;
      dirtM += meters;
    }
  }
  const total = Number(distanceMeters) > 0
    ? Number(distanceMeters)
    : pavedM + gravelM + looseM + unknownM;
  const pct = (m) => (total > 0 ? Math.round((m / total) * 100) : 0);
  return {
    pavedPercent: pct(pavedM),
    gravelPercent: pct(gravelM),
    loosePercent: pct(looseM),
    unknownSurfacePercent: pct(unknownM),
    dirtPercent: pct(dirtM),
    pavedMeters: pavedM,
    gravelMeters: gravelM,
    looseMeters: looseM,
    unknownSurfaceMeters: unknownM,
    dirtMeters: dirtM
  };
}

/**
 * Overlay honest Dirt%/paved%/unknownSurface% onto existing route stats when the
 * pack has leaves. Does not mutate selection-time coarse dirt used during search —
 * call only after the path is chosen.
 */
function applyHonestSurfaceStats(stats, leafRows, distanceMeters, hasLeaves) {
  if (!hasLeaves || !leafRows || !leafRows.length) return stats || {};
  const honest = honestSurfaceStatsFromLeaves(leafRows, distanceMeters);
  return {
    ...(stats || {}),
    pavedPercent: honest.pavedPercent,
    gravelPercent: honest.gravelPercent,
    dirtPercent: honest.dirtPercent,
    unknownSurfacePercent: honest.unknownSurfacePercent,
    surfaceFamilyMode: "leaf-v3"
  };
}

module.exports = {
  SURFACE_FAMILY,
  SURFACE_FAMILY_MAP,
  surfaceFamilyOf,
  isHonestDirtFamily,
  honestSurfaceStatsFromLeaves,
  applyHonestSurfaceStats
};
