"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { chooseDirtRideCandidate } = require("./find-path-v2");

function candidate({ dirt, paved, backward = 0, lateral = 0, route = 300_000, width }) {
  return {
    ride: { id: width },
    width,
    dirtPercent: dirt,
    pavedMeters: paved,
    routeMeters: route,
    backwardMeters: backward,
    lateralMeters: lateral
  };
}

test("Dirt candidate selection works back from 100 percent, not shortest distance", () => {
  const directish = candidate({ dirt: 58, paved: 260_000, backward: 10_000, lateral: 30_000, width: 50_000 });
  const adventure = candidate({ dirt: 72, paved: 210_000, backward: 35_000, lateral: 80_000, width: 150_000 });
  assert.equal(chooseDirtRideCandidate([directish, adventure]).width, 150_000);
});

test("Dirt rejects purposeless meander when dirt yield is effectively tied", () => {
  const coherent = candidate({ dirt: 71, paved: 190_000, backward: 8_000, lateral: 25_000, width: 100_000 });
  const meander = candidate({ dirt: 72, paved: 191_000, backward: 70_000, lateral: 160_000, width: 150_000 });
  assert.equal(chooseDirtRideCandidate([meander, coherent]).width, 100_000);
});

test("Dirt uses less pavement before meander when dirt percentages are close", () => {
  const morePavement = candidate({ dirt: 70, paved: 220_000, backward: 0, lateral: 0, width: 50_000 });
  const lessPavement = candidate({ dirt: 71, paved: 180_000, backward: 20_000, lateral: 20_000, width: 100_000 });
  assert.equal(chooseDirtRideCandidate([morePavement, lessPavement]).width, 100_000);
});

test("Dirt does not consume a wider corridor when ride quality is identical", () => {
  const wide = candidate({ dirt: 70, paved: 180_000, backward: 10_000, lateral: 20_000, width: 200_000 });
  const narrow = candidate({ dirt: 70, paved: 180_000, backward: 10_000, lateral: 20_000, width: 50_000 });
  assert.equal(chooseDirtRideCandidate([wide, narrow]).width, 50_000);
});

test("Dirt rejects a large loop for a single-digit dirt gain", () => {
  const coherent = candidate({ dirt: 70, paved: 120_000, backward: 4_000, route: 250_000, width: 50_000 });
  const loop = candidate({ dirt: 77, paved: 110_000, backward: 80_000, route: 340_000, width: 200_000 });
  assert.equal(chooseDirtRideCandidate([loop, coherent]).width, 50_000);
});
