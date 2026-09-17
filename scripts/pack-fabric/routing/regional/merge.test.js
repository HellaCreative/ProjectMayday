"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  corridorLocationsForRoute,
  shortestRegionPath,
  REGION_NEIGHBOURS
} = require("./merge");
const { resolveGraphRequest } = require("./select");
const { OSM_REGION } = require("../registry/geofabrik");

test("Nova Scotia and Newfoundland use their topology-proven direct ferry", () => {
  assert.deepEqual(shortestRegionPath("ns", "nl"), ["ns", "nl"]);

  const points = corridorLocationsForRoute([
    { lon: -60.251, lat: 46.207 },
    { lon: -59.1367, lat: 47.5721 }
  ], { profile: "cleanest", forChain: true });

  assert.equal(points.length, 3);
  assert.deepEqual(points[1].between, ["nl", "ns"]);
});

test("Nova Scotia and Prince Edward Island use their topology-proven direct ferry", () => {
  assert.deepEqual(shortestRegionPath("ns", "pe"), ["ns", "pe"]);

  const points = corridorLocationsForRoute([
    { lon: -63.288, lat: 45.665 },
    { lon: -62.65, lat: 46.2 }
  ], { profile: "cleanest", forChain: true });

  assert.equal(points.length, 3);
  assert.deepEqual(points[1].between, ["ns", "pe"]);
});

test("Maine chains to New Brunswick across the Calais–St. Stephen land border", () => {
  assert.deepEqual(shortestRegionPath("me", "nb"), ["me", "nb"]);
});

test("the road-border registry covers every catalog region and stays symmetric", () => {
  const { catalogRegionIds } = require("../registry/geofabrik");
  const catalog = new Set(catalogRegionIds());
  // Legacy parent `on` remains in OSM_REGION + neighbours for upgrade/fallback.
  for (const id of catalog) {
    assert.ok(REGION_NEIGHBOURS[id], `missing neighbours for catalog region ${id}`);
  }
  assert.ok(REGION_NEIGHBOURS.on, "legacy on neighbours retained");
  assert.ok(REGION_NEIGHBOURS["on-s"] && REGION_NEIGHBOURS["on-n"]);
  for (const [id, neighbors] of Object.entries(REGION_NEIGHBOURS)) {
    if (id.startsWith("qc-")) continue; // legacy emergency shards
    for (const neighbor of neighbors) {
      if (neighbor.startsWith("qc-")) continue;
      assert.ok(REGION_NEIGHBOURS[neighbor], `${id} references unknown ${neighbor}`);
      assert.ok(REGION_NEIGHBOURS[neighbor].includes(id), `${id}<->${neighbor} is not symmetric`);
    }
  }
  assert.deepEqual(shortestRegionPath("bc", "wa"), ["bc", "wa"]);
  assert.deepEqual(shortestRegionPath("ns", "ny"), ["ns", "nb", "qc", "ny"]);
  assert.deepEqual(shortestRegionPath("on-s", "on-n"), ["on-s", "on-n"]);
  assert.equal(shortestRegionPath("az", "co").length, 3, "Four Corners is not a road seam");
  assert.equal(shortestRegionPath("ut", "nm").length, 3, "Four Corners is not a road seam");
});

test("Swift and backend keep two-letter adjacency lockstep (subregions are extra)", () => {
  const swift = fs.readFileSync(
    path.resolve(__dirname, "../../../../Dirt/Routing/OnDevice/GraphPackStore.swift"),
    "utf8"
  );
  const block = swift.match(/private static let roadReachableNeighbours:[\s\S]*?\n    \]/);
  assert.ok(block, "Swift adjacency registry missing");
  const parsed = {};
  for (const line of block[0].split("\n")) {
    const row = line.match(/^\s*"([a-z]{2})": \[(.*)\],?$/);
    if (!row) continue;
    parsed[row[1]] = [...row[2].matchAll(/"([a-z]{2})"/g)].map((match) => match[1]).sort();
  }
  const backend = Object.fromEntries(
    Object.entries(REGION_NEIGHBOURS)
      .filter(([id]) => id.length === 2)
      .map(([id, neighbors]) => [id, neighbors.filter((neighbor) => neighbor.length === 2).sort()])
  );
  assert.deepEqual(parsed, backend);
});

test("state/state and Canada/US requests always select the explicit chain", () => {
  const route = (from, to) => resolveGraphRequest({
    disableLonghaul: true,
    locations: [
      { lon: 0, lat: 0, resolvedRegionId: from },
      { lon: 1, lat: 1, resolvedRegionId: to }
    ]
  });

  const state = route("id", "mt");
  assert.equal(state.mode, "canada-chain");
  assert.deepEqual(state.regionIds, ["id", "mt"]);

  const international = route("bc", "wa");
  assert.equal(international.mode, "canada-chain");
  assert.deepEqual(international.regionIds, ["bc", "wa"]);

  const longInternational = route("ns", "ny");
  assert.equal(longInternational.mode, "canada-chain");
  assert.deepEqual(longInternational.regionIds, ["nb", "ns", "ny", "qc"]);
});
const { metroBlocks } = require("../lib/hop-search");

test("Clean long-haul chaining never manufactures city-core waypoints", () => {
  const start = { lon: -63.57, lat: 44.65 };
  const end = { lon: -123.15, lat: 49.70 };
  const points = corridorLocationsForRoute([start, end], {
    profile: "cleanest",
    forChain: true
  });
  assert.ok(points.length > 2);
  for (const point of points.slice(1, -1)) {
    assert.notEqual(point.role, "spine");
    assert.equal(
      metroBlocks(point.lon, point.lat, [start.lon, start.lat], [end.lon, end.lat]),
      false
    );
  }
});
