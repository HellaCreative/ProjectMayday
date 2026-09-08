"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");

const {
  buildFixture,
  OUT,
  RELEASE_ID
} = require("../../scripts/generate-v4-seeded-adventure-lockstep-fixture");

test("sealed V4 nonzero seed reproduces the committed JS/Swift edge fixture", {
  timeout: 20_000
}, () => {
  const expected = JSON.parse(fs.readFileSync(OUT, "utf8"));
  const actual = buildFixture();
  delete expected.generatedAt;
  delete actual.generatedAt;

  assert.equal(actual.releaseId, RELEASE_ID);
  assert.equal(actual.graphVersion, 4);
  assert.equal(actual.seamContract, "dirt-cross-pack-seams.v2");
  assert.notEqual(actual.route.routeSeed, 0);
  assert.ok(actual.route.forwardCandidateCount >= 2);
  assert.deepEqual(actual, expected);
});
