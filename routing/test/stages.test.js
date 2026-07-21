#!/usr/bin/env node
"use strict";

/**
 * Focused tests for the multi-stage trip model (routing/lib/stages.js):
 *   - stage aggregation (summed meters, not averaged percents)
 *   - weighted percentages
 *   - saved-route serialize / deserialize round trip
 *   - stage status transitions
 *   - stale request protection
 */

const assert = require("assert");
const S = require("../lib/stages");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log("PASS", name);
  } catch (err) {
    console.error("FAIL", name, err && err.message ? err.message : err);
    process.exitCode = 1;
  }
}

function pt(lng, lat) {
  return { lng, lat };
}

// A synthetic complete stage route with explicit segment meters.
function fakeRoute(segments) {
  const distanceMeters = segments.reduce((sum, s) => sum + s.distanceMeters, 0);
  return {
    status: "complete",
    geometry: [[0, 0], [1, 1]],
    segments: segments.map((s) => ({
      surfaceClass: s.surface,
      accessClass: s.access || "motorized_permissive",
      distanceMeters: s.distanceMeters,
      geometry: [[0, 0], [1, 1]]
    })),
    distanceMeters,
    estimatedMovingSeconds: segments.reduce((sum, s) => sum + (s.seconds || 0), 0),
    warnings: []
  };
}

// ---- Stage status transitions ------------------------------------------

check("new stage with no points is draft", () => {
  const stage = S.createStage();
  assert.strictEqual(stage.status, S.STAGE_STATUS.DRAFT);
});

check("stage becomes ready once both points set", () => {
  let stage = S.createStage();
  stage = S.transitionStage(stage, "set-start", { point: pt(-63.3, 44.7) });
  assert.strictEqual(stage.status, S.STAGE_STATUS.DRAFT, "still draft with only A");
  stage = S.transitionStage(stage, "set-end", { point: pt(-63.1, 44.8) });
  assert.strictEqual(stage.status, S.STAGE_STATUS.READY);
});

check("route lifecycle: ready -> loading -> complete", () => {
  let stage = S.createStage({ start: pt(-63.3, 44.7), end: pt(-63.1, 44.8) });
  assert.strictEqual(stage.status, S.STAGE_STATUS.READY);
  stage = S.transitionStage(stage, "route-start", { requestToken: 1 });
  assert.strictEqual(stage.status, S.STAGE_STATUS.LOADING);
  stage = S.transitionStage(stage, "route-success", { route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) });
  assert.strictEqual(stage.status, S.STAGE_STATUS.COMPLETE);
});

check("route failure moves stage to failed with no geometry", () => {
  let stage = S.createStage({ start: pt(-63.3, 44.7), end: pt(-63.1, 44.8) });
  stage = S.transitionStage(stage, "route-start", { requestToken: 1 });
  stage = S.transitionStage(stage, "route-failed", { error: "no_route" });
  assert.strictEqual(stage.status, S.STAGE_STATUS.FAILED);
  assert.strictEqual(stage.route, null);
});

check("editing a point invalidates the existing route", () => {
  let stage = S.createStage({ start: pt(-63.3, 44.7), end: pt(-63.1, 44.8) });
  stage = S.transitionStage(stage, "route-success", { route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) });
  assert.strictEqual(stage.status, S.STAGE_STATUS.COMPLETE);
  stage = S.transitionStage(stage, "set-end", { point: pt(-63.0, 44.9) });
  assert.strictEqual(stage.route, null, "route dropped on edit");
  assert.strictEqual(stage.status, S.STAGE_STATUS.READY);
});

// ---- Aggregation + weighted percentages --------------------------------

check("aggregate sums distances and times across stages", () => {
  const trip = S.createTrip({ profile: "dirt" });
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 2000, seconds: 120 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0), route: fakeRoute([{ surface: "paved", distanceMeters: 3000, seconds: 180 }]) })
  ];
  const agg = S.aggregateTrip(trip);
  assert.strictEqual(agg.totalDistanceMeters, 5000);
  assert.strictEqual(agg.totalMovingSeconds, 300);
  assert.strictEqual(agg.completedStageCount, 2);
  assert.strictEqual(agg.complete, true);
});

check("weighted percent uses summed meters, NOT mean of percents", () => {
  // Stage 1: 1000 m all gravel (100% dirt). Stage 2: 9000 m all paved (0% dirt).
  // Mean of percents would be 50%. Weighted by distance = 10% dirt.
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0), route: fakeRoute([{ surface: "paved", distanceMeters: 9000 }]) })
  ];
  const agg = S.aggregateTrip(trip);
  assert.strictEqual(agg.percentages.dirtPercent, 10, "dirt weighted = 10%");
  assert.strictEqual(agg.percentages.pavedPercent, 90, "paved weighted = 90%");
});

check("weightedPercent helper handles zero total", () => {
  assert.strictEqual(S.weightedPercent(5, 0), 0);
  assert.strictEqual(S.weightedPercent(25, 100), 25);
});

check("trip incomplete while any stage not complete", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0) }) // ready, not routed
  ];
  const agg = S.aggregateTrip(trip);
  assert.strictEqual(agg.complete, false);
  assert.strictEqual(agg.completedStageCount, 1);
});

check("gap between stages produces a transfer warning and no connector", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    // Stage 2 starts somewhere else entirely -> gap
    S.createStage({ start: pt(5, 5), end: pt(6, 6), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) })
  ];
  const agg = S.aggregateTrip(trip);
  assert.strictEqual(agg.hasGaps, true);
  assert.ok(agg.warnings.some((w) => w.code === "stage_gap"), "gap warning present");
});

check("linked continuity: appended stage start defaults to previous end", () => {
  const trip = S.createTrip();
  trip.stages[0] = S.createStage({ start: pt(0, 0), end: pt(1, 1) });
  const stage2 = S.addStage(trip);
  assert.ok(S.samePoint(stage2.start, pt(1, 1)), "new stage A = previous B");
});

check("stage access policy is independent per stage", () => {
  const trip = S.createTrip({ accessPolicy: { motorizedUnknown: false } });
  const stage1 = trip.stages[0];
  const stage2 = S.addStage(trip);
  stage1.accessPolicy.motorizedUnknown = true;
  assert.strictEqual(stage1.accessPolicy.motorizedUnknown, true);
  assert.strictEqual(stage2.accessPolicy.motorizedUnknown, false);
});

check("dedupeWarnings collapses by code", () => {
  const deduped = S.dedupeWarnings([
    { code: "unknown_access_enabled", message: "a" },
    { code: "unknown_access_enabled", message: "b" },
    { code: "stage_gap", message: "c" }
  ]);
  assert.strictEqual(deduped.length, 2);
});

// ---- Stage management --------------------------------------------------

check("cannot delete the last remaining stage", () => {
  const trip = S.createTrip();
  assert.strictEqual(trip.stages.length, 1);
  assert.strictEqual(S.removeStage(trip, trip.stages[0].id), false);
  assert.strictEqual(trip.stages.length, 1);
});

check("deleting the final routed stage removes its destination and resets the draft", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(2, 0) })
  ];
  const removedId = trip.stages[1].id;
  const result = S.removeStageWaypoint(trip, removedId);
  assert.ok(result);
  assert.strictEqual(trip.stages.length, 2);
  assert.ok(S.samePoint(trip.stages[0].end, pt(1, 0)), "waypoint 2 remains");
  assert.ok(S.samePoint(trip.stages[1].start, pt(1, 0)), "draft returns to waypoint 2");
  assert.strictEqual(trip.stages[1].end, null, "deleted destination is gone");
});

check("deleting a middle stage reconnects the next destination into one chain", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(2, 0), end: pt(3, 0), route: fakeRoute([{ surface: "paved", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(3, 0) })
  ];
  const removedId = trip.stages[1].id;
  const nextId = trip.stages[2].id;
  const result = S.removeStageWaypoint(trip, removedId);
  assert.ok(result.affectedStageIds.includes(nextId));
  assert.strictEqual(trip.stages.length, 3);
  assert.ok(S.samePoint(trip.stages[1].start, pt(1, 0)), "next leg starts at the previous waypoint");
  assert.ok(S.samePoint(trip.stages[1].end, pt(3, 0)), "next destination remains");
  assert.strictEqual(trip.stages[1].route, null, "reconnected leg must be rerouted");
  assert.ok(S.samePoint(trip.stages[2].start, pt(3, 0)), "trailing draft remains linked");
});

check("reorder preserves stage data and results", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0), end: pt(2, 0), route: fakeRoute([{ surface: "paved", distanceMeters: 2000 }]) })
  ];
  const firstId = trip.stages[0].id;
  const firstRoute = trip.stages[0].route;
  assert.strictEqual(S.moveStage(trip, 0, 1), true);
  assert.strictEqual(trip.stages[1].id, firstId);
  assert.strictEqual(trip.stages[1].route, firstRoute, "route object preserved after reorder");
});

// ---- Stale request protection ------------------------------------------

check("stale response is rejected after a newer edit", () => {
  const tracker = S.createRequestTracker();
  const stageId = "stage-A";
  const tokenA = tracker.issue(stageId); // first request
  const tokenB = tracker.issue(stageId); // user edited, second request issued
  assert.strictEqual(tracker.isCurrent(stageId, tokenA), false, "old token stale");
  assert.strictEqual(tracker.isCurrent(stageId, tokenB), true, "newest token current");
});

check("cancel bumps token so in-flight response is stale", () => {
  const tracker = S.createRequestTracker();
  const stageId = "stage-A";
  const token = tracker.issue(stageId);
  tracker.cancel(stageId);
  assert.strictEqual(tracker.isCurrent(stageId, token), false);
});

check("tokens are independent per stage", () => {
  const tracker = S.createRequestTracker();
  const a = tracker.issue("A");
  tracker.issue("B");
  tracker.issue("B");
  assert.strictEqual(tracker.isCurrent("A", a), true, "stage A unaffected by stage B requests");
});

// ---- Serialize / deserialize -------------------------------------------

check("saved route serialize -> deserialize round trip", () => {
  const trip = S.createTrip({ profile: "dirt", name: "Test Loop" });
  trip.stages = [
    S.createStage({ accessPolicy: { motorizedUnknown: true }, start: pt(-63.3, 44.7), end: pt(-63.1, 44.8), route: fakeRoute([{ surface: "gravel", distanceMeters: 2000, seconds: 120 }]) }),
    S.createStage({ accessPolicy: { motorizedUnknown: false }, start: pt(-63.1, 44.8), end: pt(-63.0, 44.9), route: fakeRoute([{ surface: "track", distanceMeters: 1500, seconds: 90 }]) })
  ];
  trip.accessPolicy = { motorizedPermissive: true, motorizedUnknown: true };

  const record = S.serializeSavedRoute(trip, { name: "Saved Loop" });
  assert.strictEqual(record.schemaVersion, S.SAVED_ROUTE_SCHEMA_VERSION);
  assert.strictEqual(record.name, "Saved Loop");
  assert.strictEqual(record.stages.length, 2);
  assert.strictEqual(record.aggregate.totalDistanceMeters, 3500);
  assert.strictEqual(record.aggregate.complete, true);
  // No debug / loading / token noise persisted.
  assert.ok(!("_loading" in record.stages[0]));
  assert.ok(!("requestToken" in record.stages[0]));

  const rehydrated = S.deserializeSavedRoute(record);
  assert.strictEqual(rehydrated.stages.length, 2);
  assert.strictEqual(rehydrated.profile, "dirt");
  assert.strictEqual(rehydrated.accessPolicy.motorizedUnknown, true);
  assert.strictEqual(rehydrated.stages[0].accessPolicy.motorizedUnknown, true);
  assert.strictEqual(rehydrated.stages[1].accessPolicy.motorizedUnknown, false);
  assert.ok(S.samePoint(rehydrated.stages[0].start, pt(-63.3, 44.7)));
  assert.strictEqual(S.computeStageStatus(rehydrated.stages[0]), S.STAGE_STATUS.COMPLETE);
});

check("legacy saved trip policy rehydrates onto stages", () => {
  const record = {
    schemaVersion: S.SAVED_ROUTE_SCHEMA_VERSION,
    id: "legacy-route",
    name: "Legacy",
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: true },
    stages: [{
      id: "legacy-stage",
      start: pt(0, 0),
      end: pt(1, 0),
      route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }])
    }]
  };
  const trip = S.deserializeSavedRoute(record);
  assert.strictEqual(trip.stages[0].accessPolicy.motorizedUnknown, true);
});

check("incomplete trip serializes as a draft", () => {
  const trip = S.createTrip();
  trip.stages = [
    S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) }),
    S.createStage({ start: pt(1, 0) }) // missing B
  ];
  const record = S.serializeSavedRoute(trip, { name: "Half plan" });
  assert.strictEqual(record.isDraft, true);
  assert.strictEqual(record.aggregate.complete, false);
});

check("deserialize rejects unknown schema version", () => {
  assert.throws(() => S.deserializeSavedRoute({ schemaVersion: 999 }));
});

check("duplicate gets a new id and Copy name", () => {
  const trip = S.createTrip({ name: "Original" });
  trip.stages = [S.createStage({ start: pt(0, 0), end: pt(1, 0), route: fakeRoute([{ surface: "gravel", distanceMeters: 1000 }]) })];
  const record = S.serializeSavedRoute(trip);
  const copy = S.duplicateSavedRoute(record);
  assert.notStrictEqual(copy.id, record.id);
  assert.ok(/Copy/.test(copy.name));
});

console.log("\n" + passed + " stage checks finished");
if (process.exitCode) process.exit(process.exitCode);
