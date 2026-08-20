"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { remoteGraphUrl } = require("./select");

test("a deployment-scoped live candidate overrides only its named region", () => {
  const previous = process.env.R2_REGION_BASE_OVERRIDES;
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({
    ns: "https://packs.example/candidates/ns-release"
  });
  try {
    assert.equal(
      remoteGraphUrl("ns"),
      "https://packs.example/candidates/ns-release/ns/graph.v2.bin"
    );
    assert.match(remoteGraphUrl("bc"), /\/bc\/graph\.v2\.bin$/);
    assert.doesNotMatch(remoteGraphUrl("bc"), /ns-release/);
  } finally {
    if (previous == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previous;
  }
});

test("malformed candidate override fails closed", () => {
  const previous = process.env.R2_REGION_BASE_OVERRIDES;
  process.env.R2_REGION_BASE_OVERRIDES = "not-json";
  try {
    assert.throws(() => remoteGraphUrl("ns"), /Invalid R2_REGION_BASE_OVERRIDES/);
  } finally {
    if (previous == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previous;
  }
});
