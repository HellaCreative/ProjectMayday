"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {
  fallbackSettlementsForRegion,
  settlementBoxesForPack
} = require("./urban-settlements");

test("v3 compatibility settlements include Truro and yield to embedded pack metadata", () => {
  const fallback = fallbackSettlementsForRegion("NS");
  assert.ok(fallback.length > 1);
  assert.ok(fallback.some((box) => box.name === "Truro"));
  assert.equal(settlementBoxesForPack({ regionId: "ns", meta: {} }), fallback);
  const embedded = [{ name: "pack-authoritative" }];
  assert.equal(settlementBoxesForPack({ regionId: "ns", meta: { settlements: embedded } }), embedded);
  assert.deepEqual(settlementBoxesForPack({ regionId: "nb", meta: {} }), []);
});

test("live and on-device settlement compatibility data are byte-identical", () => {
  const live = fs.readFileSync(path.join(__dirname, "urban-settlements.v1.json"));
  const swift = fs.readFileSync(
    path.join(__dirname, "../../../../Dirt/Routing/UrbanSettlements.json")
  );
  assert.deepEqual(swift, live);
});
