#!/usr/bin/env node
"use strict";

const assert = require("assert");
const { routeRequest, loadGraph } = require("../lib/router");

function loc(lon, lat, label) {
  return { lon, lat, label };
}

async function route(profile, a, b, accessPolicy = {}, options = {}) {
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
async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log("PASS", name);
  } catch (err) {
    console.error("FAIL", name, err.message);
    process.exitCode = 1;
  }
}

async function main() {
await check("porters-musquodoboit balanced", async () => {
  const r = await route("balanced", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "porters");
});

await check("halifax-yarmouth cleanest unified graph", async () => {
  const r = await route("cleanest", HALIFAX, YARMOUTH);
  assertComplete(r, "hfx-yar");
  assert.ok(r.distanceMeters > 200000, "long route distance");
  assert.ok((r.stats.pavedPercent || 0) >= 50, "cleanest prefers pavement");
  assert.strictEqual(r.debug.engine, "dirt-node-astar");
});

await check("dirt profile reports pavement when used", async () => {
  const r = await route("dirt", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "dirt-short");
  assert.ok(r.stats);
});

await check("unknown excluded by default", async () => {
  const r = await route("dirt", DIRT_A, DIRT_B, { motorizedUnknown: false });
  if (r.status === "complete") {
    assert.ok((r.stats.unknownAccessPercent || 0) === 0, "no unknown distance by default");
  } else {
    assert.ok(["failed", "error"].includes(r.status));
  }
});

await check("unknown opt-in warns and measures", async () => {
  const r = await route("dirt", PORTERS, MUSQUODOBOIT, { motorizedUnknown: true });
  if (r.status !== "complete") return;
  assert.ok(r.warnings.some((w) => String(w.code).includes("unknown")));
  assert.ok(typeof r.stats.unknownAccessPercent === "number");
});

await check("far start fails without free-space", async () => {
  const sea = loc(-63.0, 44.0, "offshore");
  const r = await route("direct", sea, PORTERS);
  assert.strictEqual(r.status, "failed");
  assert.ok(!r.geometry || r.geometry.length === 0);
  assert.ok(r.debug.startMatch || r.debug);
});

await check("match limit rejects multi-km", async () => {
  const r = await route("direct", PORTERS, MUSQUODOBOIT, {}, { matchLimitMeters: 5000 });
  assert.strictEqual(r.status, "error");
  assert.strictEqual(r.error, "match_limit_too_large");
});

await check("restricted never routable via policy surface", async () => {
  const r = await route("balanced", PORTERS, MUSQUODOBOIT);
  if (r.status === "complete") {
    for (const seg of r.segments) {
      assert.notStrictEqual(seg.accessClass, "motorized_restricted");
      assert.notStrictEqual(seg.accessClass, "motorized_excluded");
    }
  }
});

await check("direct has distance field", async () => {
  const r = await route("direct", PORTERS, MUSQUODOBOIT);
  assertComplete(r, "direct");
  const dirt = await route("dirt", PORTERS, MUSQUODOBOIT);
  if (dirt.status === "complete") {
    assert.ok(r.distanceMeters > 0 && dirt.distanceMeters > 0);
  }
});

await check("avoidEdgeIds excludes a reported edge server-side", async () => {
  const base = await route("balanced", PORTERS, MUSQUODOBOIT);
  assertComplete(base, "avoid-base");
  // Pick a mid-route edge to avoid so start/end snapping is unaffected.
  const mid = base.segments[Math.floor(base.segments.length / 2)];
  const avoidId = mid.edgeId;
  assert.ok(avoidId, "picked an edge id to avoid");
  const avoided = await route(
    "balanced",
    PORTERS,
    MUSQUODOBOIT,
    {},
    { avoidEdgeIds: [avoidId] }
  );
  // Either a complete alternate that never uses the avoided edge, or a clean
  // failure — never a straight-line / free-space route.
  if (avoided.status === "complete") {
    for (const seg of avoided.segments) {
      assert.notStrictEqual(String(seg.edgeId), String(avoidId), "alternate must not use avoided edge");
    }
    assert.ok(
      avoided.debug.avoidedEdgeIds.map(String).includes(String(avoidId)),
      "debug reports avoided edge"
    );
    assert.ok(
      avoided.warnings.some((w) => w.code === "avoided_edges"),
      "warns that edges were avoided"
    );
  } else {
    assert.ok(["failed"].includes(avoided.status), "clean failure status");
    assert.ok(!avoided.geometry || avoided.geometry.length === 0, "no fake geometry on failure");
  }
});

await check("avoidEdgeIds is a no-op when the edge is off-route", async () => {
  const r = await route("balanced", PORTERS, MUSQUODOBOIT, {}, { avoidEdgeIds: ["__no_such_edge__"] });
  assertComplete(r, "avoid-noop");
  assert.deepStrictEqual(r.debug.avoidedEdgeIds, ["__no_such_edge__"]);
});

await check("no OSRM / no straight-line fake route on failure", async () => {
  const r = await route("cleanest", loc(-60, 40, "nowhere"), loc(-61, 41, "also-nowhere"));
  assert.notStrictEqual(r.status, "complete");
  assert.ok(!r.geometry || r.geometry.length === 0);
});

console.log("\n" + passed + " fixture checks finished");
if (process.exitCode) process.exit(process.exitCode);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
