"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { buildPack, category, representativePoint } = require("./build-rider-services-pack");

function seq(features) {
  return features.map((feature) => "\x1e" + JSON.stringify(feature) + "\n").join("");
}

test("maps the launch Rider Services taxonomy", () => {
  assert.equal(category({ tourism: "camp_site" }), "campground");
  assert.equal(category({ tourism: "bed_and_breakfast" }), "lodging");
  assert.equal(category({ shop: "wine" }), "liquor");
  assert.equal(category({ amenity: "fuel" }), null);
});

test("builds deterministic normalized nodes and area centers", () => {
  const pack = buildPack(seq([
    {
      id: "n10",
      properties: { tourism: "camp_site", name: "Porters Lake Provincial Park" },
      geometry: { type: "Point", coordinates: [-63.382, 44.72] }
    },
    {
      id: "w20",
      properties: { shop: "alcohol", name: "NSLC" },
      geometry: { type: "Polygon", coordinates: [[[-63.3, 44.7], [-63.2, 44.7], [-63.2, 44.8], [-63.3, 44.7]]] }
    },
    {
      id: "n30",
      properties: { tourism: "hotel", disused: "yes" },
      geometry: { type: "Point", coordinates: [-63, 44] }
    }
  ]), { regionId: "ns", generatedAt: "2026-09-05T00:00:00.000Z" });
  assert.equal(pack.schema, "rider-services.v1");
  assert.equal(pack.regionId, "ns");
  assert.deepEqual(pack.counts, { campground: 1, lodging: 0, liquor: 1 });
  assert.equal(pack.dropped.closed, 1);
  assert.equal(pack.elements.length, 2);
  assert.equal(pack.elements[0].tags["dirt:category"], "campground");
  assert.equal(pack.elements[1].type, "way");
  assert.deepEqual(representativePoint({ type: "Point", coordinates: [1, 2] }), [1, 2]);
});
