"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  qualifiesAsUrbanCore,
  settlementRadiusKm
} = require("./pack-region-urban");
const { boxIntersectsPackBbox } = require("../routing/lib/pack-v2");

test("fresh split-region urban extraction carries its source identity and rural towns", async t => {
  const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "urban-source-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const input = path.join(dir, "places.geojsonseq"), output = path.join(dir, "urban.json");
  fs.writeFileSync(input, JSON.stringify({ type: "Feature", geometry: { type: "Point", coordinates: [-63, 48] },
    properties: { place: "town", name: "Rural test", population: "1000", "@id": "node/42" } }) + "\n");
  const sourceIdentity = { sha256: "a".repeat(64), osmTimestamp: "2026-09-18T00:00:00Z" };
  await require("./pack-region-urban").build("qc-n", "quebec-north", { input, output, sourceIdentity });
  const result = JSON.parse(fs.readFileSync(output));
  assert.deepEqual(result.sourceIdentity, sourceIdentity);
  assert.equal(result.cores.length, 0);
  assert.equal(result.settlements[0].name, "Rural test");
});

test("small OSM towns are settlement avoidance, not hard urban walls", () => {
  assert.equal(qualifiesAsUrbanCore("town", 12_421), false);
  assert.ok(settlementRadiusKm("town", 12_421) >= 1.2);
});

test("adjacent urban boxes are embedded only when they overlap pack fabric", () => {
  const waBbox = [-124.74, 45.53, -116.86, 49.08];
  const abbotsford = { minLat: 48.99, maxLat: 49.12, minLon: -122.43, maxLon: -122.23 };
  const calgary = { minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85 };
  assert.equal(boxIntersectsPackBbox(abbotsford, waBbox), true);
  assert.equal(boxIntersectsPackBbox(calgary, waBbox), false);
});

test("major towns and cities remain hard urban-core walls", () => {
  assert.equal(qualifiesAsUrbanCore("town", 50_000), true);
  assert.equal(qualifiesAsUrbanCore("city", 40_000), true);
  assert.equal(qualifiesAsUrbanCore("city", 4_450), false);
  assert.equal(qualifiesAsUrbanCore("city", 0), true);
});
