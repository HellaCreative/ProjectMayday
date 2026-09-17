"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { buildPack, kind } = require("./build-attractions-pack");

function seq(features) {
  return features.map((feature) => "\x1e" + JSON.stringify(feature) + "\n").join("");
}

test("maps every Attraction switch tag", () => {
  assert.equal(kind({ tourism: "viewpoint" }), "viewpoint");
  assert.equal(kind({ tourism: "attraction" }), "attraction");
  assert.equal(kind({ natural: "cave_entrance" }), "cave");
  assert.equal(kind({ amenity: "cave_entrance" }), "cave");
  assert.equal(kind({ natural: "waterfall" }), "waterfall");
  assert.equal(kind({ waterway: "waterfall" }), "waterfall");
  assert.equal(kind({ man_made: "lighthouse" }), "lighthouse");
  assert.equal(kind({ natural: "beach" }), "beach");
  assert.equal(kind({ leisure: "beach" }), "beach");
  assert.equal(kind({ tourism: "hotel" }), null);
});

test("prefers viewpoint over generic attraction tags", () => {
  assert.equal(kind({ tourism: "viewpoint", natural: "beach" }), "viewpoint");
});

test("builds dots inside the region bbox", () => {
  const pack = buildPack(seq([
    {
      id: "n1",
      properties: { tourism: "viewpoint", name: "Cape Split" },
      geometry: { type: "Point", coordinates: [-64.5, 45.33] }
    },
    {
      id: "w2",
      properties: { natural: "waterfall", name: "Petite Falls" },
      geometry: { type: "LineString", coordinates: [[-61.3, 44.9], [-61.31, 44.91]] }
    },
    {
      id: "n3",
      properties: { man_made: "lighthouse", name: "Boston Light" },
      geometry: { type: "Point", coordinates: [-70.89, 42.32] }
    },
    {
      id: "n4",
      properties: { tourism: "viewpoint", disused: "yes" },
      geometry: { type: "Point", coordinates: [-63.5, 44.7] }
    }
  ]), { regionId: "ns", generatedAt: "2026-09-17T00:00:00.000Z" });
  assert.equal(pack.schema, "attractions.v1");
  assert.equal(pack.regionId, "ns");
  assert.equal(pack.elements.length, 2);
  assert.equal(pack.counts.viewpoint, 1);
  assert.equal(pack.counts.waterfall, 1);
  assert.equal(pack.dropped.closed, 1);
  assert.equal(pack.dropped.outsideBounds, 1);
  assert.equal(pack.elements[0].tags["dirt:kind"], "viewpoint");
  assert.equal(pack.elements[0].tags["dirt:category"], "attraction");
});
