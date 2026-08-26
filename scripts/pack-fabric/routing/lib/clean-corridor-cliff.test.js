"use strict";

/**
 * Clean law (2026-08-23): pavement through-edges, soft forward fan, no corridor,
 * no hard regression. Snapped A/B always traversable. Coincident pack nodes bridge.
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const fs = require("fs");
const {
  maxProgressRegressionMeters,
  corridorMetersForProfile,
  isBlockedForCleanPavement,
  coincidentSiblingLists
} = require("./hop-search");
const { approachAwayExtraCost, corridorCrossTrackExtra } = require("./profile-costs");
const { findPathV2 } = require("./find-path-v2");
const { loadGraphSync } = require("./graph");
const { matchPoint, normalizePolicy } = require("./router");

process.env.ROUTING_PACKS_V2 = process.env.ROUTING_PACKS_V2 || "1";

const FROM = { lat: 44.764816, lon: -63.340274 };
const GOOD_TO = { lat: 44.866934, lon: -63.216915 };
const FAIL_TO = { lat: 44.872924, lon: -63.220318 };

const NS_GRAPH = path.resolve(
  __dirname,
  "../../app/data/packs/v1/ns/graph.v3.bin"
);

function loadNsRuntime() {
  assert.ok(fs.existsSync(NS_GRAPH), `missing local NS pack: ${NS_GRAPH}`);
  return loadGraphSync(NS_GRAPH);
}

function snap(runtime, loc, role) {
  const policy = normalizePolicy({}, "cleanest");
  return matchPoint(runtime, loc, policy, 250, null, null, "cleanest", role);
}

function tryClean(runtime, to) {
  const policy = normalizePolicy({}, "cleanest");
  const diagnostics = {};
  const found = findPathV2(
    runtime,
    snap(runtime, FROM, "start"),
    snap(runtime, to, "end"),
    "cleanest",
    policy,
    null,
    undefined,
    {
      pavedOnly: true,
      costMode: "profile",
      variety: false,
      boundedSearch: true,
      corridorMeters: 0,
      hardCorridor: false,
      progressRegressionMeters: Number.MAX_SAFE_INTEGER,
      settlementWall: false,
      settlementFallback: false,
      cityWall: true,
      timeCapMs: 20000,
      deadlineAtMs: Date.now() + 20000,
      diagnostics
    }
  );
  let west = Infinity;
  const coords = found && found.geometry;
  if (Array.isArray(coords)) {
    for (const c of coords) {
      const lon = Array.isArray(c) ? Number(c[0]) : Number(c.lon);
      if (lon < west) west = lon;
    }
  }
  return {
    found: !!found,
    meters: found ? found.distanceMeters : null,
    dirtPct: found && found.stats ? found.stats.dirtPercent : null,
    corridor: found && found.searchMeta ? found.searchMeta.corridorMeters : null,
    west: west !== Infinity ? west : null,
    outcome: found ? "completed" : diagnostics.outcome || "noPath"
  };
}

test("Clean has no corridor and no hard regression cap", () => {
  assert.equal(corridorMetersForProfile("cleanest"), null);
  assert.equal(maxProgressRegressionMeters("cleanest"), Infinity);
});

test("Clean has no chord cross-track cone", () => {
  const a = { lat: 44.76, lon: -63.34 };
  const b = { lat: 44.87, lon: -63.22 };
  const far = { lat: 45.2, lon: -63.5 };
  const xt = corridorCrossTrackExtra("cleanest", far, a, b, 1000);
  assert.equal(xt, 0);
});

test("Clean away gravity stays below extra pavement of a long loop", () => {
  const away15 = approachAwayExtraCost("cleanest", 20000, 35000, 15000, 50);
  assert.ok(away15 > 0);
  assert.ok(away15 <= 15 * 2.5);
  // 60 km extra paved collector still costs ~70 in profile units.
  const pavedExtra = 60 * 1.0 * 1.18;
  assert.ok(away15 < pavedExtra);
});

test("short around beats long monotonic loop when both flow toward B", () => {
  const collectorPerKm = 1.0 * 1.18;
  const shortAround = 32 * collectorPerKm;
  const dipAway = approachAwayExtraCost("cleanest", 20000, 35000, 15000, 50);
  const longLoop = 92 * collectorPerKm;
  assert.ok(shortAround + dipAway < longLoop);
});

test("untagged local/service blocked; major unknown allowed", () => {
  assert.equal(isBlockedForCleanPavement("paved", "local"), false);
  assert.equal(isBlockedForCleanPavement("unknown", "arterial"), false);
  assert.equal(isBlockedForCleanPavement("unknown", "local"), true);
  assert.equal(isBlockedForCleanPavement("unknown", "service"), true);
  assert.equal(isBlockedForCleanPavement("gravel", "collector"), true);
});

test("coincident sibling lists merge duplicate nodes", () => {
  // Two nodes at same coord → siblings
  const coords = new Float64Array([
    -63.22038, 44.87164,
    -63.22038, 44.87164,
    -63.21, 44.86
  ]);
  const lists = coincidentSiblingLists(coords, 3, 2);
  assert.ok(lists[0] && lists[0].includes(1));
  assert.ok(lists[1] && lists[1].includes(0));
  assert.equal(lists[2], null);
});

test(
  "NS Clean: GOOD and FAIL stay on short paved spine (not Dartmouth loop)",
  { timeout: 120_000 },
  () => {
    const runtime = loadNsRuntime();

    const good = tryClean(runtime, GOOD_TO);
    assert.equal(good.outcome, "completed");
    assert.ok(Math.abs(good.meters - 32137) < 1000, `GOOD drifted: ${good.meters}`);
    assert.equal(good.dirtPct, 0);
    assert.equal(good.corridor, null);
    assert.ok(good.west > -63.45, `GOOD went west: ${good.west}`);

    const fail = tryClean(runtime, FAIL_TO);
    assert.equal(fail.outcome, "completed");
    assert.ok(fail.meters < 45000, `FAIL too long: ${fail.meters}`);
    assert.equal(fail.dirtPct, 0);
    assert.equal(fail.corridor, null);
    assert.ok(fail.west > -63.45, `FAIL Dartmouth loop: west=${fail.west}`);
  }
);

test("Clean snap is nearest — does not prefer pavement over closer dirt", () => {
  const runtime = loadNsRuntime();
  const policy = normalizePolicy({}, "cleanest");
  // Tap nearer a likely dirt/service than a highway when one exists around Halifax.
  const tap = { lat: 44.764816, lon: -63.340274 };
  const clean = matchPoint(runtime, tap, policy, 250, null, null, "cleanest", "start");
  const asEnd = matchPoint(runtime, tap, policy, 250, null, null, "balanced", "end");
  assert.ok(clean && clean.coord);
  // Clean must not apply paved preference; score is distance-first.
  assert.ok(Math.abs(clean.distanceM - asEnd.distanceM) < 80 || clean.edgeIndex === asEnd.edgeIndex);
});
