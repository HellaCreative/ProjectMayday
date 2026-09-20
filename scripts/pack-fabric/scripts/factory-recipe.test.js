"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { fingerprint } = require("./factory-recipe");

test("factory identity is stable across ordering, but changes with bytes or tools", () => {
  const inputs = { "clip.geojson": "geometry", "builder.js": "source" };
  const tools = { node: "v22", osmium: "1.19" };
  const first = fingerprint(inputs, tools);
  assert.equal(first.sha256, fingerprint({ "builder.js": "source", "clip.geojson": "geometry" },
    { osmium: "1.19", node: "v22" }).sha256);
  assert.notEqual(first.sha256, fingerprint({ ...inputs, "clip.geojson": "new cut" }, tools).sha256);
  assert.notEqual(first.sha256, fingerprint({ ...inputs, "builder.js": "new rules" }, tools).sha256);
  assert.notEqual(first.sha256, fingerprint(inputs, { ...tools, osmium: "1.20" }).sha256);
  assert.notEqual(first.sha256, fingerprint({ ...inputs, "new-builder.js": "extra input" }, tools).sha256);
});
