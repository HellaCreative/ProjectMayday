"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  graphFileRecord,
  parseArgs,
  regionRecord,
  verifyRouteIdentity
} = require("./assert-live-pack-lockstep");

const ON_FILES = [
  { name: "graph.v3.bin", bytes: 123, sha256: "graph-on" },
  { name: "geometry.v1.bin", bytes: 456, sha256: "geometry-on" },
  { name: "fuel.v1.json", bytes: 789, sha256: "fuel-on" }
];

test("lockstep verification requires exactly one explicit region", () => {
  assert.deepEqual(parseArgs(["--region", "ON"]), { help: false, regionId: "on" });
  assert.throws(() => parseArgs([]), /exactly one --region/);
  assert.throws(
    () => parseArgs(["--region", "on", "--region", "bc"]),
    /only once/
  );
  assert.throws(() => parseArgs(["on"]), /Unknown argument/);
});

test("region lookup never falls through to a different province or state", () => {
  const manifest = {
    regions: [
      { id: "bc", files: [{ name: "graph.v2.bin" }, { name: "geometry.v1.bin" }] },
      { id: "on", files: ON_FILES }
    ]
  };
  const region = regionRecord(manifest, "on");
  assert.equal(region.id, "on");
  assert.equal(graphFileRecord(region).name, "graph.v3.bin");
  assert.throws(() => regionRecord(manifest, "ns"), /has no region 'ns'/);
});

test("live identity must match the selected region's promoted graph and geometry", () => {
  const region = { id: "on", files: ON_FILES };
  const result = {
    debug: {
      packIdentity: [{
        regionId: "on",
        graphBytes: 123,
        graphSha256: "graph-on",
        geometryBytes: 456,
        geometrySha256: "geometry-on"
      }]
    }
  };
  assert.doesNotThrow(() => verifyRouteIdentity(result, "on", region));
  assert.throws(() => verifyRouteIdentity(result, "bc", region), /did not report region 'bc'/);
});
