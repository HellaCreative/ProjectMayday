#!/usr/bin/env node
"use strict";

const assert = require("assert");
const {
  buildCurveEvents,
  classifyCurve,
  mergeNavCues,
  distanceToCueMeters,
  haversineMeters,
  bearingDeg
} = require("../lib/roadbook-curves");

function destination(lon, lat, bearingDegValue, distanceM) {
  const R = 6371000;
  const δ = distanceM / R;
  const θ = (bearingDegValue * Math.PI) / 180;
  const φ1 = (lat * Math.PI) / 180;
  const λ1 = (lon * Math.PI) / 180;
  const φ2 = Math.asin(
    Math.sin(φ1) * Math.cos(δ) + Math.cos(φ1) * Math.sin(δ) * Math.cos(θ)
  );
  const λ2 =
    λ1 +
    Math.atan2(
      Math.sin(θ) * Math.sin(δ) * Math.cos(φ1),
      Math.cos(δ) - Math.sin(φ1) * Math.sin(φ2)
    );
  return [(λ2 * 180) / Math.PI, (φ2 * 180) / Math.PI];
}

/** Build a polyline that goes straight, then arcs by totalDeg over arcLengthM. */
function makeArcRoute(options) {
  const {
    start = [-63.3, 44.7],
    approachM = 120,
    arcLengthM = 160,
    totalDeg = 90,
    side = "left",
    exitM = 120,
    stepM = 12
  } = options || {};
  const sign = side === "right" ? 1 : -1;
  const coords = [start];
  let bearing = 0;
  let cursor = start.slice();

  function step(dist, turnPerM) {
    const n = Math.max(1, Math.round(dist / stepM));
    const d = dist / n;
    for (let i = 0; i < n; i += 1) {
      bearing = (bearing + sign * turnPerM * d + 360) % 360;
      cursor = destination(cursor[0], cursor[1], bearing, d);
      coords.push(cursor);
    }
  }

  step(approachM, 0);
  step(arcLengthM, totalDeg / arcLengthM);
  step(exitM, 0);
  return coords;
}

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

check("straight route produces no turn cues", () => {
  const coords = makeArcRoute({ totalDeg: 0, arcLengthM: 200 });
  // Force true straight
  const straight = [coords[0]];
  let p = coords[0];
  for (let i = 0; i < 30; i += 1) {
    p = destination(p[0], p[1], 10, 15);
    straight.push(p);
  }
  const events = buildCurveEvents(straight);
  assert.strictEqual(events.length, 0, "expected no curves, got " + events.length);
});

check("gentle sweeping left curve produces high-numbered LEFT cue", () => {
  // ~90° over 280 m → large radius → 5 or 6
  const coords = makeArcRoute({
    side: "left",
    totalDeg: 90,
    arcLengthM: 280,
    approachM: 100,
    exitM: 100
  });
  const events = buildCurveEvents(coords);
  assert.ok(events.length >= 1, "expected a curve");
  const c = events[0];
  assert.strictEqual(c.side, "left");
  assert.strictEqual(c.direction, "LEFT");
  assert.ok(c.number >= 5, "expected easy/fast number, got " + c.number);
  assert.strictEqual(c.source, "geometry");
  assert.ok(c.confidence > 0.3);
});

check("tighter left curve produces a lower-numbered LEFT cue", () => {
  const gentle = buildCurveEvents(
    makeArcRoute({ side: "left", totalDeg: 90, arcLengthM: 280 })
  )[0];
  const tight = buildCurveEvents(
    makeArcRoute({ side: "left", totalDeg: 90, arcLengthM: 55, approachM: 80, exitM: 80 })
  )[0];
  assert.ok(gentle && tight, "both curves required");
  assert.ok(
    tight.number < gentle.number,
    "tight " + tight.number + " should be lower than gentle " + gentle.number
  );
});

check("right curve produces RIGHT", () => {
  const events = buildCurveEvents(
    makeArcRoute({ side: "right", totalDeg: 85, arcLengthM: 120 })
  );
  assert.ok(events.length >= 1);
  assert.strictEqual(events[0].side, "right");
  assert.strictEqual(events[0].direction, "RIGHT");
  assert.match(events[0].spoken, /^right \d/);
});

check("hairpin produces number 1 only when geometry supports it", () => {
  const hairpin = buildCurveEvents(
    makeArcRoute({
      side: "left",
      totalDeg: 155,
      arcLengthM: 40,
      approachM: 80,
      exitM: 80
    })
  )[0];
  assert.ok(hairpin, "hairpin event");
  assert.strictEqual(hairpin.number, 1);
  assert.match(hairpin.spoken, /hairpin/);

  const bigAngleLong = classifyCurve(150, 220);
  assert.ok(bigAngleLong);
  assert.notStrictEqual(
    bigAngleLong.number,
    1,
    "long sweeping large angle must not be hairpin"
  );
});

check("curves are ordered by route distance", () => {
  const a = makeArcRoute({
    side: "left",
    totalDeg: 70,
    arcLengthM: 90,
    approachM: 40,
    exitM: 40
  });
  const last = a[a.length - 1];
  // Extend with a second right bend further along.
  let p = last;
  let bearing = bearingDeg(a[a.length - 2], a[a.length - 1]);
  const extra = a.slice();
  for (let i = 0; i < 8; i += 1) {
    p = destination(p[0], p[1], bearing, 15);
    extra.push(p);
  }
  for (let i = 0; i < 12; i += 1) {
    bearing = (bearing + 7 + 360) % 360;
    p = destination(p[0], p[1], bearing, 12);
    extra.push(p);
  }
  const events = buildCurveEvents(extra);
  assert.ok(events.length >= 2, "need two curves, got " + events.length);
  for (let i = 1; i < events.length; i += 1) {
    assert.ok(events[i].alongKm >= events[i - 1].alongKm);
  }
});

check("no duplicate cues within minimum separation", () => {
  const coords = makeArcRoute({
    side: "left",
    totalDeg: 100,
    arcLengthM: 140,
    approachM: 60,
    exitM: 60
  });
  const events = buildCurveEvents(coords, { minSeparationM: 80 });
  for (let i = 1; i < events.length; i += 1) {
    const gapM = (events[i].alongKm - events[i - 1].alongKm) * 1000;
    assert.ok(gapM >= 80 - 1e-6, "gap " + gapM);
  }
});

check("90-degree curve is not classified solely from total angle", () => {
  const sweep = classifyCurve(90, 280);
  const tight = classifyCurve(90, 50);
  assert.ok(sweep && tight);
  assert.ok(sweep.number > tight.number, "same angle, different radius → different number");
  assert.ok(sweep.number >= 5);
  assert.ok(tight.number <= 3);
});

check("cue distance counts down as rider progresses", () => {
  const cueAlong = 0.42;
  assert.strictEqual(distanceToCueMeters(0.1, cueAlong), 320);
  assert.strictEqual(distanceToCueMeters(0.3, cueAlong), 120);
  assert.strictEqual(distanceToCueMeters(0.42, cueAlong), 0);
  assert.strictEqual(distanceToCueMeters(0.5, cueAlong), 0);
});

check("merge prefers junction when overlapping a curve", () => {
  const curves = [
    {
      alongKm: 1.0,
      number: 4,
      side: "left",
      kind: "curve",
      text: "LEFT 4",
      spoken: "left 4",
      source: "geometry"
    }
  ];
  const junctions = [
    {
      alongKm: 1.04,
      number: 3,
      side: "left",
      kind: "junction",
      text: "LEFT 3",
      spoken: "left 3",
      source: "junction"
    }
  ];
  const merged = mergeNavCues(curves, junctions);
  assert.strictEqual(merged.length, 1);
  assert.strictEqual(merged[0].kind, "junction");
});

console.log("roadbook-curves:", passed, "passed");
if (process.exitCode) process.exit(process.exitCode);
