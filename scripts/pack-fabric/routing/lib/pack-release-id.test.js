"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { packReleaseId } = require("./pack-release-id");
test("promotion preserves graph and fuel release identity", () => {
 for (const namespace of ["candidates", "releases"])
  for (const file of ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json"])
   assert.equal(packReleaseId(`https://cdn.example/v4/${namespace}/fabric-v4-20260909-01/ns/${file}?cache=1`), "fabric-v4-20260909-01");
});
test("legacy, unrelated and malformed paths do not gain V4 admission", () => {
 for (const source of [null, "", "/ns/graph.v2.bin", "/v4/releases/x/ns/graph.v4.bin", "/v4/releases/a%2Fb/ns/graph.v4.bin", "/v4/releases/okay/", "/v4/releases/../ns/graph.v4.bin"])
  assert.equal(packReleaseId(source), null);
});

test("legacy candidate naming retains provenance without granting qualification", () => { assert.equal(packReleaseId("https://cdn.example/candidates/ns-osm-test-01/ns/fuel.v1.json"), "ns-osm-test-01"); });
