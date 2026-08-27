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

test("equal-stop itinerary chains preserve forward progress before dirt quality", () => {
  const result = planItineraryFuelChain({
    usableRangeMeters: 200_000,
    legs: [{
      meters: 300_000,
      stations: [
        { id: "early-dirt", meters: 120_000, dirtPct: 95 },
        { id: "forward-paved", meters: 180_000, dirtPct: 5 }
      ]
    }]
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((stop) => stop.id), ["forward-paved"]);
});

test("rider waypoint on a station resets the tank without a generated stop", () => {
  const result = planItineraryFuelChain({
    usableRangeMeters: 237_500,
    legs: [
      {
        meters: 200_000,
        stations: [],
        waypoint: { lat: 45.616, lon: -61.998 },
        fuelPois: [{ id: "irving", name: "Irving Antigonish", lat: 45.616, lon: -61.998 }]
      },
      { meters: 200_000, stations: [] }
    ]
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops, []);
  assert.equal(result.waypointResets.length, 1);
  assert.equal(result.waypointResets[0].id, "irving");
});

test("dragging a waypoint off a station removes the reset so an auto stop can return", () => {
  const station = { id: "irving", name: "Irving Antigonish", lat: 45.616, lon: -61.998 };
  const along = [
    { id: "auto-1", meters: 150_000, dirtPct: 40 },
  ];
  const along2 = [{ id: "auto-2", meters: 150_000, dirtPct: 40 }];
  const on = planItineraryFuelChain({
    usableRangeMeters: 237_500,
    legs: [
      { meters: 200_000, stations: along, waypoint: station, fuelPois: [station] },
      { meters: 200_000, stations: along2 }
    ]
  });
  assert.equal(on.ok, true);
  assert.deepEqual(on.stops, []);
  assert.equal(on.waypointResets[0].id, "irving");

  const off = planItineraryFuelChain({
    usableRangeMeters: 237_500,
    legs: [
      {
        meters: 200_000,
        stations: along,
        waypoint: { lat: 45.630, lon: -61.980 },
        fuelPois: [station]
      },
      { meters: 200_000, stations: along2 }
    ]
  });
  assert.equal(off.ok, true);
  assert.equal(off.waypointResets.length, 0);
  assert.ok(off.stops.length >= 1, "auto stop should return after the reset is gone");
  assert.ok(off.stops.every((stop) => stop.id.startsWith("auto")));
});

test("an ordinary numbered waypoint never resets fuel", () => {
  const { deriveWaypointFuelStation, deriveWaypointRefuels, WAYPOINT_FUEL_SNAP_METERS } = require("./fuel-chain");
  const station = { id: "irving", lat: 45.616, lon: -61.998, name: "Irving" };
  assert.equal(WAYPOINT_FUEL_SNAP_METERS, 150);
  assert.equal(deriveWaypointFuelStation({ lat: 45.630, lon: -61.980 }, [station]), null);
  assert.equal(deriveWaypointFuelStation(station, [station]).id, "irving");
  const resets = deriveWaypointRefuels(
    [
      { lat: 44.65, lon: -63.58 },
      { lat: 45.0, lon: -62.5 },
      { lat: 46.14, lon: -60.19 }
    ],
    [station]
  );
  assert.deepEqual(resets, []);
});
