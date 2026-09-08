"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
} = require("./service-contract");

test("route and fuel APIs share one explicit service contract", () => {
  const result = withServiceIdentity({ status: "complete" }, { VERCEL_GIT_COMMIT_SHA: "abc123" });
  assert.equal(result.serviceContract, ROUTING_SERVICE_CONTRACT);
  assert.equal(result.serviceBuild, "abc123");
  assert.equal(result.status, "complete");
});

test("service build is honest when no deployment identity exists", () => {
  assert.equal(serviceBuild({}), "local-uncommitted");
});

test("responses identify the selected connection revision independently of road release", () => {
  assert.equal(withServiceIdentity({}, {}).connectionRevision, null);
  assert.equal(withServiceIdentity({}, {DIRT_V4_CONNECTION_REVISION:"connections-v4-20260908-02"}).connectionRevision,
    "connections-v4-20260908-02");
});
