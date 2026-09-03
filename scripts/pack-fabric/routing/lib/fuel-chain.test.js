"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  fuelNeedForProfileRide,
  fuelSearchStartMeters,
  fuelPlanStatus,
  nearestReachableFuelDistance,
  planCrossRegionFuelChain,
  planFuelChainOnRuntime,
  rankForwardFuel,
  stationEligibility
} = require("./fuel-chain");

test("an exhausted graph is a gap but a planning timeout is inconclusive", () => {
  assert.equal(fuelPlanStatus({ ok: false, error: "no_route_connected_fuel_chain" }), "gap");
  assert.equal(fuelPlanStatus({ ok: false, error: "window_time_budget" }), "failed");
  assert.equal(fuelPlanStatus({ ok: true }), "complete");
});

test("watching and the preferred zone never manufacture a stop", () => {
  assert.equal(fuelNeedForProfileRide(null, 153_000, 153_000), null);
  assert.equal(fuelNeedForProfileRide(152_000, 153_000, 153_000), 0);
  assert.equal(fuelNeedForProfileRide(100_000, 153_000, 153_000), 0);
  assert.equal(fuelNeedForProfileRide(70_000, 153_000, 153_000), 0);
  assert.equal(fuelNeedForProfileRide(154_000, 153_000, 153_000), 1);
});

test("a reachable 233 km ride goes direct when destination escape fuel fits", async () => {
  const foundationRoute = {
    status: "complete",
    distanceMeters: 233_400,
    stats: { dirtPercent: 80 },
    segments: []
  };
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 237_500,
    firstLegMaxMeters: 237_500,
    profileMeters: 100_000,
    foundationRoute
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), []);
  assert.equal(result.routes[0], foundationRoute);
  assert.equal(result.diagnostics.selectedReason, "direct_destination");
});

test("destination escape stops at the nearest route-connected pump", () => {
  const result = nearestReachableFuelDistance({
    runtime: lineRuntime(),
    stations: [station("near", 1), station("far", 3)],
    origin: { lat: 45, lon: 0 },
    profile: "cleanest",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    maxMeters: 200_000
  });

  assert.ok(result.meters >= 78_000 && result.meters <= 79_000);
  assert.ok(result.pops < 9, "targeted escape must stop before flooding the fixture graph");
  assert.equal(result.considered, 2);
});

test("a reachable 233 km ride refuels when destination escape fuel does not fit", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 237_500,
    firstLegMaxMeters: 237_500,
    destinationFuelUsedLimitMeters: 210_000,
    profileMeters: 233_400,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.station.id === "__destination__"
        ? candidate.graphMeters > 100_000 ? 233_400 : candidate.graphMeters
        : candidate.graphMeters,
      stats: { dirtPercent: 80 },
      segments: []
    })
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), ["late"]);
  assert.equal(result.diagnostics.destinationEscapeMeters, 27_500);
});

test("a valid post-threshold pump excludes a 32 km full-tank stop", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early-32km", 0.5), station("window", 1), station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    requireFuelStopBeforeEnd: true,
    minimumFuelStops: 1,
    routeCandidate: fixtureRouteCandidate
  });
  assert.equal(result.ok, true);
  assert.ok(result.stops.length >= 1);
  assert.notEqual(result.stops[0].id, "early-32km");
  assert.ok(result.graphMeters[0] >= 65_000);
});

test("a proven one-stop winner skips candidates that cannot beat its forward progress", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early", 1), station("middle", 1.5), station("forward", 2)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 170_000,
    firstLegMaxMeters: 170_000,
    requireFuelStopBeforeEnd: true,
    minimumFuelStops: 1,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "forward");
  const firstDepartureCandidates = result.stationCandidates.filter((row) =>
    row.departureId === "start"
  );
  assert.equal(
    firstDepartureCandidates.length,
    2
  );
  assert.deepEqual(firstDepartureCandidates.map((row) => row.id), ["forward", "middle"]);
});

test("fuel search begins after half the reserve-adjusted usable range", () => {
  assert.equal(fuelSearchStartMeters(140_000, 140_000), 70_000);
  assert.equal(fuelSearchStartMeters(100_000, 140_000), 30_000);
});

test("a meaningful down-and-back fuel stem is rejected", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("stem", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    requireFuelStopBeforeEnd: true,
    minimumFuelStops: 1,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      backtrackMeters: candidate.station.id === "stem" ? 5_000 : 0,
      stats: { dirtPercent: 80 },
      segments: []
    })
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, "no_route_connected_fuel_chain");
});

function lineRuntime() {
  const nodes = [];
  for (let i = 0; i <= 8; i += 1) nodes.push([i * 0.5, 45]);
  const edges = [];
  const adjacency = Array.from({ length: nodes.length }, () => []);
  const edgeGrid = new Map();
  const GRID = 0.01;
  for (let i = 0; i < nodes.length - 1; i += 1) {
    const edge = {
      a: i,
      b: i + 1,
      m: 39_313,
      s: 0,
      ac: 0,
      t: 0,
      rt: "local",
      i: `e${i}`,
      c: 0,
      g: [nodes[i], nodes[i + 1]]
    };
    const edgeIndex = edges.length;
    edges.push(edge);
    adjacency[i].push(edgeIndex);
    adjacency[i + 1].push(edgeIndex);
    const x0 = Math.floor(nodes[i][0] / GRID);
    const x1 = Math.floor(nodes[i + 1][0] / GRID);
    const y = Math.floor(45 / GRID);
    for (let x = x0; x <= x1; x += 1) {
      const key = `${x}:${y}`;
      if (!edgeGrid.has(key)) edgeGrid.set(key, []);
      edgeGrid.get(key).push(edgeIndex);
    }
  }
  return {
    data: { nodeCount: nodes.length, nodes, edges, regionId: "fixture" },
    adjacency,
    edgeGrid,
    GRID,
    enums: {
      SURFACE_NAME: ["paved"],
      ACCESS_NAME: ["motorized_permissive"],
      STRUCTURE_NAME: ["none"]
    }
  };
}

function station(id, lon) {
  return { id, name: id, lat: 45, lon };
}

function fixtureRouteCandidate({ candidate }) {
  return Promise.resolve({
    status: "complete",
    distanceMeters: candidate.graphMeters,
    stats: { dirtPercent: 0 },
    segments: []
  });
}

test("fuel chain is constructed forward from graph-reachable pumps", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: 0 },
      segments: []
    })
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1", "f2", "f3"]);
  assert.equal(result.graphMeters.length, 4);
  assert.equal(result.routes.length, 4);
  assert.ok(result.graphMeters.every((meters) => meters <= 90_000));
});

test("fuel matching ignores pumps outside the rider's current tank reach", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [
      station("f1", 1),
      station("f2", 2),
      station("f3", 3),
      { id: "far-away", name: "far-away", lat: 0, lon: 0 }
    ],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1", "f2", "f3"]);
  assert.equal(result.diagnostics.matchedFuel, 3);
  assert.equal(result.diagnostics.stationsConsidered, 3);
});

test("long fuel chain returns a resumable window capped at three stops", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    minimumFuelStops: 4,
    maxStops: 3,
    allowPartialWindow: true,
    timeBudgetMs: 6_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.windowComplete, false);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1", "f2", "f3"]);
  assert.equal(result.graphMeters.length, 3);
});

test("one-stop window keeps a proven pump when evaluation crosses its deadline", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    minimumFuelStops: 3,
    maxStops: 1,
    allowPartialWindow: true,
    timeBudgetMs: 50,
    routeCandidate: ({ candidate }) => new Promise((resolve) => {
      setTimeout(() => resolve({
        status: "complete",
        distanceMeters: candidate.graphMeters,
        stats: { dirtPercent: 80 },
        segments: []
      }), 75);
    })
  });

  assert.equal(result.ok, true);
  assert.equal(result.windowComplete, false);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1"]);
  assert.deepEqual(result.graphMeters, [78_626]);
  assert.ok(result.diagnostics.profileRouteAttempts > 0);
  assert.ok(result.diagnostics.maxHopMs >= 50);
  assert.ok(result.diagnostics.searchDeadlineOverrunMs > 0);
  assert.equal(result.diagnostics.timeBudgetExceeded, true);
  assert.equal(result.diagnostics.slowestProfileRoutes[0].candidateId, "f1");
  assert.ok(result.diagnostics.slowestProfileRoutes[0].elapsedMs >= 50);
});

test("a proven forward one-stop chain does not route dominated earlier pumps", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [
      station("f1", 0.5), station("f2", 1), station("f3", 1.5),
      station("f4", 2), station("f5", 2.5), station("f6", 3)
    ],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "cleanest",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 250_000,
    firstLegMaxMeters: 250_000,
    maxStops: 1,
    allowPartialWindow: true,
    timeBudgetMs: 15_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  const firstWindow = result.stationCandidates.filter((row) => row.departureId === "start");
  assert.deepEqual(firstWindow.map((row) => row.id), ["f6", "f5"]);
});

test("a rider fuel-stop override forces the first station without changing later search", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 170_000,
    firstLegMaxMeters: 170_000,
    requiredFirstStationId: "f2",
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "f2");
  assert.equal(result.stops.length, 1);
});

test("fuel ranking rejects a geographically backward pump", () => {
  const ranked = rankForwardFuel(
    [
      { station: station("back", -0.5), location: { lat: 45, lon: -0.5 }, graphMeters: 50_000 },
      { station: station("forward", 1), location: { lat: 45, lon: 1 }, graphMeters: 80_000 }
    ],
    { lat: 45, lon: 0 },
    { lat: 45, lon: 4 },
    100_000,
    new Set(),
    "dirt"
  );

  assert.deepEqual(ranked.map((row) => row.station.id), ["forward"]);
});

test("fuel ranking leaves the final five kilometres for the destination", () => {
  const ranked = rankForwardFuel(
    [
      {
        station: station("city-hop", 3.96),
        location: { lat: 45, lon: 3.96 },
        graphMeters: 20_000
      }
    ],
    { lat: 45, lon: 3.88 },
    { lat: 45, lon: 4 },
    100_000,
    new Set(),
    "cleanest"
  );

  assert.deepEqual(ranked, []);
});

test("a depleted waypoint may use one nearby non-forward pump before resuming forward travel", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [
      station("recovery", 1.75),
      station("forward-1", 2.5),
      station("forward-2", 3.5)
    ],
    start: { lat: 45, lon: 2 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 30_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.deepEqual(
    result.stops.map((row) => row.id),
    ["recovery", "forward-1", "forward-2"]
  );
  assert.ok(result.graphMeters.every((meters) => meters <= 90_000));
});

test("look-ahead measures a nearby pump instead of reporting zero fuel distance", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("near-waypoint", 2.005)],
    start: { lat: 45, lon: 2 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    probeFirstReachableStation: true,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: Math.max(400, candidate.graphMeters),
      stats: { dirtPercent: 0 },
      segments: []
    })
  });

  assert.equal(result.ok, true);
  assert.ok(result.firstReachableStationMeters >= 400);
  assert.ok(result.firstReachableStationMeters < 1_000);
});

test("fixed station sample gives probe and selector the same base eligibility", () => {
  let seed = 0x5eed11;
  const random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 0x100000000;
  };
  const current = [0, 45];
  const destination = [4, 45];
  const currentLocation = { lon: current[0], lat: current[1] };
  const destinationLocation = { lon: destination[0], lat: destination[1] };
  const visited = new Set(["visited"]);
  for (let index = 0; index < 64; index += 1) {
    const row = {
      station: { id: index % 11 === 0 ? "visited" : `s${index}` },
      location: { lon: random() * 4.5 - 0.25, lat: 45 + (random() - 0.5) * 0.2 },
      graphMeters: 500 + random() * 95_000,
      dirtAdjacent: index % 2 === 0
    };
    const expected = stationEligibility(row, {
      current,
      destination,
      capMeters: 90_000,
      visited,
      allowNearStartRecovery: false
    }).forward;
    const ranked = rankForwardFuel(
      [row], currentLocation, destinationLocation, 90_000, visited, "balanced", null, null, false
    );
    assert.equal(ranked.length === 1, expected, `station sample ${index}`);
  }
});

test("short route does not manufacture a fuel plan", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 0.25)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 0.5 },
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 100_000,
    firstLegMaxMeters: 100_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops, []);
  assert.equal(result.graphMeters.length, 1);
});

test("forward feeler proves the next anchor without routing a scout leg", async () => {
  let scoutCalls = 0;
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    maxStops: 1,
    allowPartialWindow: true,
    graphOnlyFeeler: true,
    routeCandidate: async () => {
      scoutCalls += 1;
      throw new Error("a forward feeler must not route a disposable scout");
    }
  });

  assert.equal(result.ok, true);
  assert.equal(scoutCalls, 0);
  assert.deepEqual(result.stops.map((row) => row.id), ["mid"]);
});

test("NS to NB forward feeler stays graph-only while targeting the Tantramar door", async () => {
  const start = { lat: 44.76479020946905, lon: -63.34021720179615 };
  const destination = { lat: 46.053670, lon: -67.565147 };
  const tantramar = {
    lat: 45.92,
    lon: -64.35,
    role: "seam",
    between: ["nb", "ns"],
    resolvedRegionId: "ns"
  };
  const calls = [];
  const result = await planCrossRegionFuelChain({
    profile: "cleanest",
    locations: [start, destination],
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: {
      cleanMetroMultiplier: 14,
      avoidMotorways: true
    }
  }, {
    mode: "canada-chain",
    regionIds: ["ns", "nb"]
  }, {
    usableRangeMeters: 207_000,
    firstLegMaxMeters: 207_000,
    windowMaxStops: 1,
    allowPartialWindow: true,
    windowTimeBudgetMs: 5_800,
    forwardFeeler: true
  }, {
    resolveChainSeamWaypoints: async () => ({
      ok: true,
      waypoints: [
        { ...start, resolvedRegionId: "ns" },
        tantramar,
        { ...destination, resolvedRegionId: "nb" }
      ]
    }),
    loadRegionFuel: async (regionId) => ({
      stations: [station("ns-forward-pump", -64.005937)],
      packIdentity: { regionId }
    }),
    loadGraphsForRequest: async () => ({
      packIdentity: [{ regionId: "ns" }]
    }),
    planFuelChainOnRuntime: async (options) => {
      calls.push(options);
      return {
        ok: true,
        stops: [{
          id: "ns-forward-pump",
          lat: 45.230113,
          lon: -64.005937,
          name: "Fuel stop"
        }],
        graphMeters: [136_600],
        stationCandidates: [],
        windowComplete: false,
        diagnostics: {}
      };
    }
  });

  assert.equal(result.status, "complete");
  assert.equal(result.windowComplete, false);
  assert.deepEqual(result.stops.map((row) => row.id), ["ns-forward-pump"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].graphOnlyFeeler, true);
  assert.equal(calls[0].cleanMetroMultiplier, 14);
  assert.equal(calls[0].avoidMotorways, true);
  assert.deepEqual(calls[0].destination, tantramar);
});

test("cross-region one-stop window preserves every seam minimum through the returned pump", async () => {
  const start = { lat: 44.764863437891236, lon: -63.340304626331005 };
  const pump = {
    id: "osm:w330696506",
    lat: 45.908655,
    lon: -64.374146,
    name: "Esso"
  };
  const destination = { lat: 46.192496, lon: -64.242925 };
  const seam = {
    lat: 45.92,
    lon: -64.35,
    role: "seam",
    between: ["nb", "ns"],
    resolvedRegionId: "ns"
  };
  const plannedSegments = [
    {
      ok: true,
      stops: [],
      graphMeters: [218_050.6],
      stationCandidates: [],
      windowComplete: true,
      diagnostics: {}
    },
    {
      ok: true,
      stops: [pump],
      graphMeters: [8_730.8],
      stationCandidates: [],
      windowComplete: false,
      diagnostics: {}
    }
  ];

  const result = await planCrossRegionFuelChain({
    profile: "cleanest",
    locations: [start, destination],
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { cleanMetroMultiplier: 2, avoidMotorways: true }
  }, {
    mode: "canada-chain",
    regionIds: ["ns", "nb"]
  }, {
    usableRangeMeters: 248_000,
    firstLegMaxMeters: 248_000,
    windowMaxStops: 1,
    allowPartialWindow: true,
    windowTimeBudgetMs: 5_800,
    forwardFeeler: true
  }, {
    resolveChainSeamWaypoints: async () => ({
      ok: true,
      waypoints: [
        { ...start, resolvedRegionId: "ns" },
        seam,
        { ...destination, resolvedRegionId: "nb" }
      ]
    }),
    loadRegionFuel: async (regionId) => ({
      stations: [pump],
      packIdentity: { regionId }
    }),
    loadGraphsForRequest: async () => ({ packIdentity: [] }),
    planFuelChainOnRuntime: async () => plannedSegments.shift()
  });

  assert.equal(result.status, "complete");
  assert.equal(result.windowComplete, false);
  assert.deepEqual(result.stops.map((row) => row.id), ["osm:w330696506"]);
  assert.deepEqual(result.graphMeters, [218_050.6, 8_730.8]);
  assert.equal(plannedSegments.length, 0);
});

test("profile ride length requires Dirt fuel even when shortest reachability fits", async () => {
  const usable = 237_500;
  const stopsNeeded = fuelNeedForProfileRide(300_000, usable, usable);
  assert.equal(stopsNeeded, 1);

  const dirt = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: usable,
    firstLegMaxMeters: usable,
    requireFuelStopBeforeEnd: stopsNeeded > 0,
    minimumFuelStops: stopsNeeded,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: 80 },
      segments: []
    })
  });
  assert.equal(dirt.ok, true);
  assert.deepEqual(dirt.stops.map((row) => row.id), ["mid"]);
  assert.ok(Math.abs(dirt.stops[0].dirtPercent - 80) <= 10);

  const clean = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "cleanest",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: usable,
    firstLegMaxMeters: usable,
    requireFuelStopBeforeEnd: fuelNeedForProfileRide(200_000, usable, usable) > 0,
    routeCandidate: fixtureRouteCandidate
  });
  assert.equal(clean.ok, true);
  assert.deepEqual(clean.stops.map((row) => row.id), []);
});

for (const profile of ["dirt", "balanced"]) {
  test(`${profile} keeps a completed viable pump when evaluation crosses the window deadline`, async () => {
    const result = await planFuelChainOnRuntime({
      runtime: lineRuntime(),
      stations: [station("mid", 1)],
      start: { lat: 45, lon: 0 },
      destination: { lat: 45, lon: 2 },
      profile,
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
      usableRangeMeters: 90_000,
      firstLegMaxMeters: 90_000,
      requireFuelStopBeforeEnd: true,
      minimumFuelStops: 1,
      timeBudgetMs: 50,
      routeCandidate: ({ candidate }) => new Promise((resolve) => {
        setTimeout(() => resolve({
          status: "complete",
          distanceMeters: candidate.graphMeters,
          stats: { dirtPercent: profile === "dirt" ? 80 : 50 },
          segments: []
        }), 75);
      })
    });

    assert.equal(result.ok, true);
    assert.deepEqual(result.stops.map((row) => row.id), ["mid"]);
    assert.equal(result.graphMeters.length, 2);
    assert.ok(result.graphMeters.every((meters) => meters <= 90_000));
  });
}

test("a pump is not committed until the active profile routes its continuation", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early", 1), station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 170_000,
    firstLegMaxMeters: 170_000,
    requireFuelStopBeforeEnd: true,
    minimumFuelStops: 1,
    routeCandidate: ({ candidate }) => {
      const isDestination = candidate.station.id === "__destination__";
      if (isDestination && Number(candidate.graphMeters) < 60_000) {
        return Promise.resolve({ status: "no_route", distanceMeters: null, segments: [] });
      }
      return Promise.resolve({
        status: "complete",
        distanceMeters: candidate.graphMeters,
        stats: { dirtPercent: 80 },
        segments: []
      });
    }
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), ["early"]);
  assert.equal(result.graphMeters.length, 2);
});

test("refuel-before-waypoint leaves enough fuel for the known next rider leg", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early", 1), station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 237_500,
    firstLegMaxMeters: 237_500,
    requireFuelStopBeforeEnd: true,
    destinationFuelUsedLimitMeters: 40_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.stops.at(-1).id, "late");
  assert.ok(result.graphMeters.at(-1) <= 40_000);
});
