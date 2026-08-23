"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { graphPathForRegion, remoteGraphUrl } = require("./select");

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

test("a verified graph path overrides a stale local regional graph", (t) => {
  const previous = process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-verified-graph-"));
  const verified = path.join(root, "verified-ns-graph.v2.bin");
  fs.writeFileSync(verified, "verified");
  t.after(() => {
    if (previous == null) delete process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
    else process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = previous;
    fs.rmSync(root, { recursive: true, force: true });
  });
  process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({ ns: verified });
  assert.equal(graphPathForRegion("ns"), verified);
});

test("a missing verified graph override fails closed", () => {
  const previous = process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
  process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({ ns: "/tmp/dirt-does-not-exist/graph.v2.bin" });
  try {
    assert.throws(() => graphPathForRegion("ns"), /Verified graph override is unavailable/);
  } finally {
    if (previous == null) delete process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
    else process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = previous;
  }
});
