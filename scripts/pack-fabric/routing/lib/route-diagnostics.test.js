"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  classifyRouteFailureReason,
  effectiveProfileInfo,
  buildRouteDiagnostics,
  classifyFuelFailureReason
} = require("./route-diagnostics");

test("classifies pop_cap and time_cap ahead of noPath", () => {
  assert.equal(classifyRouteFailureReason({ searchOutcome: "popCap" }), "pop_cap");
  assert.equal(classifyRouteFailureReason({ searchOutcome: "timeCap" }), "time_cap");
  assert.equal(
    classifyRouteFailureReason({
      searchOutcome: "noPath",
      attempts: [{ corridorMeters: 25000, outcome: "popCap", pops: 9 }]
    }),
    "pop_cap"
  );
});

test("classifies snap and load corridor clip", () => {
  assert.equal(classifyRouteFailureReason({ snapFailure: true }), "snap_failure");
  assert.equal(classifyRouteFailureReason({ corridorClipLoad: true }), "corridor_clip");
});

test("finite corridor noPath without unbounded attempt is corridor_clip", () => {
  assert.equal(
    classifyRouteFailureReason({
      searchOutcome: "noPath",
      attempts: [
        { corridorMeters: 25000, outcome: "noPath" },
        { corridorMeters: 50000, outcome: "noPath" }
      ]
    }),
    "corridor_clip"
  );
});

test("unbounded noPath after corridor failures is disconnected", () => {
  assert.equal(
    classifyRouteFailureReason({
      searchOutcome: "noPath",
      attempts: [
        { corridorMeters: 25000, outcome: "noPath" },
        { corridorMeters: null, outcome: "noPath" }
      ]
    }),
    "disconnected"
  );
});

test("urban core last resort remains explicit without relabelling Dirt as Clean", () => {
  const info = effectiveProfileInfo("dirt", { urbanCoreFallbackUsed: true });
  assert.equal(info.requestedProfile, "dirt");
  assert.equal(info.effectiveProfile, "dirt");
  assert.deepEqual(info.profileFallbacks, ["urban_core_last_resort"]);
});

test("bounded Balanced road fallback stays explicit in diagnostics", () => {
  const info = effectiveProfileInfo("balanced", {
    balancedSearchFallbackUsed: true
  });
  assert.equal(info.effectiveProfile, "balanced");
  assert.deepEqual(info.profileFallbacks, ["balanced_distance_fallback"]);
});

test("buildRouteDiagnostics keeps attempt timings", () => {
  const diag = buildRouteDiagnostics({
    requestedProfile: "dirt",
    buildMs: 1200,
    searchMs: 900,
    attempts: [
      { corridorMeters: 100000, outcome: "noPath", pops: 10, searchMs: 200 },
      { corridorMeters: 150000, outcome: "completed", pops: 40, searchMs: 700 }
    ],
    searchMeta: {
      pops: 40,
      corridorMeters: 150000,
      corridorWidened: true,
      maxCrossTrackMeters: 12000,
      routeShape: { backwardPercent: 3.5 }
    },
    backtrackPct: 1.2
  });
  assert.equal(diag.buildMs, 1200);
  assert.equal(diag.searchAttempts.length, 2);
  assert.equal(diag.searchAttempts[0].searchMs, 200);
  assert.equal(diag.corridorWidened, true);
  assert.equal(diag.maxCrossTrackMeters, 12000);
  assert.equal(diag.backtrackPct, 1.2);
  assert.equal(diag.requestedProfile, "dirt");
});

test("fuel gap vs timeout reasons", () => {
  assert.equal(classifyFuelFailureReason({ error: "window_time_budget" }), "timeout");
  assert.equal(
    classifyFuelFailureReason({ error: "no_route_connected_fuel_chain" }),
    "gap_no_forward_station"
  );
});
