"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { planItineraryFuelChain } = require("./fuel-chain");

test("itinerary look-ahead rejects a dirt-preferred pump that strands the next leg", () => {
  const result = planItineraryFuelChain({
    usableRangeMeters: 237_500,
    legs: [
      {
        meters: 230_000,
        stations: [
          { id: "early-dirt", meters: 44_000, dirtPct: 95 },
          { id: "late-viable", meters: 180_000, dirtPct: 70 }
        ]
      },
      {
        meters: 190_000,
        stations: [{ id: "leg-2", meters: 120_000, dirtPct: 80 }]
      },
      { meters: 150_000, stations: [] }
    ]
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((stop) => stop.id), ["late-viable", "leg-2"]);
  assert.equal(result.stops[0].legIndex, 0);
  assert.equal(result.stops[1].legIndex, 1);
});

test("rider waypoint on a station resets the tank without a generated stop", () => {
  const result = planItineraryFuelChain({
    usableRangeMeters: 237_500,
    legs: [
      { meters: 200_000, stations: [], waypointReset: { id: "irving", name: "Irving Antigonish" } },
      { meters: 200_000, stations: [] }
    ]
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops, []);
  assert.equal(result.waypointResets.length, 1);
  assert.equal(result.waypointResets[0].id, "irving");
});
