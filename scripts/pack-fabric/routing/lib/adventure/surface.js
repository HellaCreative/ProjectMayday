"use strict";

const { surfaceFamilyOf } = require("../surface-family");

// Use the shared leaf dictionary, but never its legacy 'unknown is dirt' sum.
function surfaceKind(leaf) {
  const family = surfaceFamilyOf(leaf);
  return family === "gravel" || family === "loose" ? "dirt" : family;
}

function summarizeSurface(segments, budget = null) {
  const meters = { dirt: 0, paved: 0, unknown: 0 };
  let longestDirtRunMeters = 0, run = 0;
  for (const segment of segments) {
    if (budget && !budget.consume()) return null;
    const distance = segment.distanceMeters;
    if (!Number.isFinite(distance) || distance < 0) throw new TypeError("Invalid segment distance");
    const kind = surfaceKind(segment.surfaceLeaf);
    meters[kind] += distance;
    run = kind === "dirt" ? run + distance : 0;
    longestDirtRunMeters = Math.max(longestDirtRunMeters, run);
  }
  const distanceMeters = meters.dirt + meters.paved + meters.unknown;
  if (!Number.isFinite(distanceMeters)) throw new TypeError("Invalid aggregate distance");
  const percent = value => distanceMeters ? value / distanceMeters * 100 : 0;
  return Object.freeze({ distanceMeters, knownDirtMeters: meters.dirt,
    pavedMeters: meters.paved, unknownSurfaceMeters: meters.unknown,
    knownDirtPercent: percent(meters.dirt), pavedPercent: percent(meters.paved),
    unknownSurfacePercent: percent(meters.unknown), longestDirtRunMeters });
}

// Compare already feasible, legally valid candidates with equivalent mandatory
// constraints. No corridor rules, urban waivers or fuel resets belong here.
function compareSurface(profile, a, b) {
  if (profile === "dirt") return b.knownDirtPercent - a.knownDirtPercent;
  if (profile === "clean") return b.pavedPercent - a.pavedPercent;
  if (profile !== "balanced") throw new TypeError(`Unknown profile ${profile}`);
  // Unknown cannot satisfy either half. This also favours known 50/50 over
  // 50% dirt + 50% unknown instead of treating both as a balanced success.
  const miss = s => Math.abs(s.knownDirtPercent - 50) + Math.abs(s.pavedPercent - 50);
  return miss(a) - miss(b) || b.knownDirtPercent - a.knownDirtPercent;
}
module.exports = { surfaceKind, summarizeSurface, compareSurface };
