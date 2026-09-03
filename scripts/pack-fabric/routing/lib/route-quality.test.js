"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { summarizeRouteQuality } = require("./route-quality");

function segment(surfaceClass, distanceMeters, geometry = null) {
  return { surfaceClass, distanceMeters, structureType: "none", geometry };
}

test("journey quality exposes front-loaded pavement hidden by the route total", () => {
  const quality = summarizeRouteQuality({
    profile: "dirt",
    segments: [
      segment("paved", 25_000),
      segment("gravel", 25_000),
      segment("gravel", 50_000),
      segment("gravel", 50_000),
      segment("gravel", 50_000)
    ]
  });

  assert.equal(quality.knownDirtPercent, 87.5);
  assert.equal(quality.firstSectionDirtPercent, 50);
  assert.equal(quality.minimumSectionDirtPercent, 50);
  assert.equal(quality.longestPavedRunMeters, 25_000);
  assert.equal(quality.state, "degraded");
  assert.deepEqual(quality.reasons, ["long_paved_run"]);
});

test("unknown surface does not masquerade as known dirt quality", () => {
  const quality = summarizeRouteQuality({
    profile: "dirt",
    segments: [segment("unknown", 50_000), segment("gravel", 50_000)]
  });

  assert.equal(quality.knownDirtPercent, 50);
  assert.equal(quality.unknownSurfaceMeters, 50_000);
  assert.ok(quality.reasons.includes("low_overall_known_dirt"));
  assert.ok(quality.reasons.includes("weak_dirt_section"));
});

test("a consistently dirt-forward ride satisfies the journey contract", () => {
  const quality = summarizeRouteQuality({
    profile: "dirt",
    segments: Array.from({ length: 8 }, (_, index) =>
      segment(index % 4 === 0 ? "paved" : "gravel", 10_000)
    )
  });

  assert.equal(quality.knownDirtPercent, 75);
  assert.equal(quality.minimumSectionDirtPercent, 50);
  assert.equal(quality.state, "ready");
  assert.deepEqual(quality.reasons, []);
});
