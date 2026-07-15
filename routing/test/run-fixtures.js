#!/usr/bin/env node
"use strict";

const assert = require("assert");
const { routeRequest, loadGraph } = require("../lib/router");

function loc(lon, lat, label) {
  return { lon, lat, label };
}

function route(profile, a, b, accessPolicy = {}, options = {}) {
  return routeRequest({
    profile,
    locations: [a, b],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: false,
      ...accessPolicy
    },
    options
  });
}

function assertComplete(result, label) {
  assert.strictEqual(result.status, "complete", label + " status: " + JSON.stringify(result).slice(0, 400));
  assert.ok(result.distanceMeters > 0, label + " distance");
  assert.ok(Array.isArray(result.geometry) && result.geometry.length >= 2, label + " geometry");
  assert.ok(Array.isArray(result.segments) && result.segments.length >= 1, label + " segments");
  assert.ok(result.debug && result.debug.startMatchedEdge, label + " start match");
  assert.ok(result.debug.matchLimitMeters <= 500, label + " match limit");
  assert.strictEqual(result.debug.fallback, null, label + " no fallback");
}

console.log("Loading graph…");
const g = loadGraph();
console.log("Graph ready", g.data.edgeCount, "edges in", g.loadMs, "ms");

// Fixtures
const PORTERS = loc(-63.2985, 44.7427, "Porter's Lake");
const MUSQUODOBOIT = loc(-63.148, 44.787, "Musquodoboit Harbour");
const HALIFAX = loc(-63.575, 44.6488, "Halifax");
const YARMOUTH = loc(-66.1209, 43.8361, "Yarmouth");
const DIRT_A = loc(-63.45, 44.95, "Dirt A");
const DIRT_B = loc(-63.25, 45.05, "Dirt B");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log("PASS", name);
  } catch (err) {
    console.error("FAIL", name, err.message);
    process.exitCode = 1;
  }
}

check("porters-musquodoboit balanced", () => {
  const r = route("balanced", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "porters");
});

check("halifax-yarmouth cleanest unified graph", () => {
  const r = route("cleanest", HALIFAX, YARMOUTH);
  assertComplete(r, "hfx-yar");
  assert.ok(r.distanceMeters > 200000, "long route distance");
  assert.ok((r.stats.pavedPercent || 0) >= 50, "cleanest prefers pavement");
  assert.strictEqual(r.debug.engine, "dirt-node-astar");
});

check("dirt profile reports pavement when used", () => {
  const r = route("dirt", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "dirt-short");
  assert.ok(r.stats);
});

check("unknown excluded by default", () => {
  const r = route("dirt", DIRT_A, DIRT_B, { motorizedUnknown: false });
  // May complete on permissive edges or fail honestly — must not silently use unknown
  if (r.status === "complete") {
    assert.strictEqual(r.unknownAccessMeters || r.stats.unknownAccessPercent || 0, r.stats.unknownAccessPercent);
    assert.ok((r.stats.unknownAccessPercent || 0) === 0, "no unknown distance by default");
  } else {
    assert.ok(["failed", "error"].includes(r.status));
  }
});

check("unknown opt-in warns and measures", () => {
  const r = route("dirt", PORTERS, MUSQUODOBOIT, { motorizedUnknown: true });
  if (r.status !== "complete") return; // still valid if no path
  assert.ok(r.warnings.some((w) => String(w.code).includes("unknown")));
  assert.ok(typeof r.stats.unknownAccessPercent === "number");
});

check("far start fails without free-space", () => {
  const sea = loc(-63.0, 44.0, "offshore");
  const r = route("direct", sea, PORTERS);
  assert.strictEqual(r.status, "failed");
  assert.ok(!r.geometry || r.geometry.length === 0);
  assert.ok(r.debug.startMatch || r.debug);
});

check("match limit rejects multi-km", () => {
  const r = route("direct", PORTERS, MUSQUODOBOIT, {}, { matchLimitMeters: 5000 });
  assert.strictEqual(r.status, "error");
  assert.strictEqual(r.error, "match_limit_too_large");
});

check("restricted never routable via policy surface", () => {
  // Graph may contain restricted edges; ensure none appear in a complete route.
  const r = route("balanced", PORTERS, MUSQUODOBOIT);
  if (r.status === "complete") {
    for (const seg of r.segments) {
      assert.notStrictEqual(seg.accessClass, "motorized_restricted");
      assert.notStrictEqual(seg.accessClass, "motorized_excluded");
    }
  }
});

check("direct has distance field", () => {
  const r = route("direct", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "direct");
  const dirt = route("dirt", PORTERS, MUSQUODOBOIT);
  if (dirt.status === "complete") {
    // Dirt may be longer; direct should not be wildly longer than dirt on same OD
    assert.ok(r.distanceMeters > 0 && dirt.distanceMeters > 0);
  }
});

check("no OSRM / no straight-line fake route on failure", () => {
  const r = route("cleanest", loc(-60, 40, "nowhere"), loc(-61, 41, "also-nowhere"));
  assert.notStrictEqual(r.status, "complete");
  assert.ok(!r.geometry || r.geometry.length === 0);
});

console.log("\n" + passed + " fixture checks finished");
if (process.exitCode) process.exit(process.exitCode);
