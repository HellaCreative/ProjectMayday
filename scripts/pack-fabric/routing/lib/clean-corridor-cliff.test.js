"use strict";

/**
 * NS Digby-side Clean corridor cliff (2026-08-23).
 * Point 1 fixed; Point 2 walks north on the orange arterial.
 * With progressRegressionMeters=8000, every finite Clean corridor was noPath
 * past ~44.876; unbounded found a ~177 km east loop. Raising Clean to 20 km
 * lets the arterial (~13–15 km along-track dip) complete inside 25 km corridor.
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const fs = require("fs");
const { maxProgressRegressionMeters } = require("./hop-search");
const { findPathV2 } = require("./find-path-v2");
const { loadGraphSync } = require("./graph");
const { matchPoint, normalizePolicy } = require("./router");

process.env.ROUTING_PACKS_V2 = process.env.ROUTING_PACKS_V2 || "1";

const FROM = { lat: 44.764837, lon: -63.340267 };
const GOOD_TO = { lat: 44.866934, lon: -63.216915 };
const CLIFF_TO = { lat: 44.876224, lon: -63.230298 };

const NS_GRAPH = path.resolve(
  __dirname,
  "../../app/data/packs/v1/ns/graph.v2.bin"
);

function loadNsRuntime() {
  assert.ok(fs.existsSync(NS_GRAPH), `missing local NS pack: ${NS_GRAPH}`);
  return loadGraphSync(NS_GRAPH);
}

function snap(runtime, loc, role) {
  const policy = normalizePolicy({}, "cleanest");
  return matchPoint(runtime, loc, policy, 250, null, null, "cleanest", role);
}

function tryClean(runtime, to, regressionMeters) {
  const policy = normalizePolicy({}, "cleanest");
  const startMatch = snap(runtime, FROM, "start");
  const endMatch = snap(runtime, to, "end");
  assert.ok(startMatch && startMatch.coord, "start snap failed");
  assert.ok(endMatch && endMatch.coord, "end snap failed");
  const diagnostics = {};
  const found = findPathV2(
    runtime,
    startMatch,
    endMatch,
    "cleanest",
    policy,
    null,
    undefined,
    {
      pavedOnly: true,
      costMode: "profile",
      variety: false,
      boundedSearch: true,
      corridorMeters: 25000,
      hardCorridor: true,
      progressRegressionMeters: regressionMeters,
      timeCapMs: 45000,
      deadlineAtMs: Date.now() + 45000,
      diagnostics
    }
  );
  return {
    found: !!found,
    meters: found ? found.distanceMeters : null,
    maxXt: found && found.searchMeta ? found.searchMeta.maxCrossTrackMeters : null,
    corridor: found && found.searchMeta ? found.searchMeta.corridorMeters : null,
    outcome: found ? "completed" : (diagnostics.outcome || "noPath")
  };
}

test("Clean regression ceiling clears the NS arterial cliff threshold", () => {
  assert.equal(maxProgressRegressionMeters("cleanest"), 20000);
});

test(
  "NS Clean cliff: 8km regression noPath; 20km keeps arterial inside 25km corridor",
  { timeout: 120_000 },
  () => {
    const runtime = loadNsRuntime();

    const oldCliff = tryClean(runtime, CLIFF_TO, 8000);
    assert.equal(
      oldCliff.outcome,
      "noPath",
      "pre-fix 8km regression must still fail the cliff pin"
    );

    const fixedCliff = tryClean(runtime, CLIFF_TO, 20000);
    assert.equal(fixedCliff.outcome, "completed");
    assert.ok(fixedCliff.meters < 120000, `cliff path too long: ${fixedCliff.meters}`);
    assert.ok(
      (fixedCliff.maxXt || 0) <= 25000,
      `cliff XT outside 25km corridor: ${fixedCliff.maxXt}`
    );
    assert.equal(fixedCliff.corridor, 25000);

    const good = tryClean(runtime, GOOD_TO, 20000);
    assert.equal(good.outcome, "completed");
    assert.ok(good.meters < 50000, `good pin regressed: ${good.meters}`);
    assert.ok(Math.abs(good.meters - 32137) < 500, `good pin drifted: ${good.meters}`);
  }
);
