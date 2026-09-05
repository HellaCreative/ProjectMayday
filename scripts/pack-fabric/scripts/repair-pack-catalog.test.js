"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  DEFAULT_REGIONS,
  assertOnlyTargetRowsChanged,
  parseArgs,
  repairCatalogRows
} = require("./repair-pack-catalog");

const idGraph = {
  name: "graph.v2.bin",
  bytes: 10,
  sha256: "a".repeat(64)
};
const idGeometry = {
  name: "geometry.v1.bin",
  bytes: 20,
  sha256: "b".repeat(64)
};

function catalog(idFiles) {
  return {
    schemaVersion: "pack-manifest.v1",
    marker: "preserve",
    generatedAt: "before",
    regions: [
      { id: "ns", keep: true, files: [{ ...idGraph, sha256: "c".repeat(64) }] },
      { id: "id", files: idFiles }
    ]
  };
}

test("defaults to the exact known drift set and remains dry-run", () => {
  const parsed = parseArgs([]);
  assert.equal(parsed.apply, false);
  assert.deepEqual(parsed.regions, DEFAULT_REGIONS);
});

test("repairs only named rows and preserves all unrelated JSON", () => {
  const remote = catalog([{ ...idGraph, bytes: 999 }, idGeometry]);
  const seed = catalog([idGraph, idGeometry]);
  const repaired = repairCatalogRows(remote, seed, ["id"], "after");
  assert.equal(repaired.generatedAt, "after");
  assert.equal(repaired.marker, "preserve");
  assert.equal(repaired.regions[0], remote.regions[0]);
  assert.deepEqual(repaired.regions[1].files, [idGraph, idGeometry]);
  assert.doesNotThrow(() => assertOnlyTargetRowsChanged(remote, repaired, ["id"]));
});

test("rejects missing targets and invalid seed identities", () => {
  assert.throws(
    () => repairCatalogRows(catalog([idGraph, idGeometry]), catalog([idGraph, idGeometry]), ["wa"], "after"),
    /no target regions/
  );
  assert.throws(
    () => repairCatalogRows(catalog([idGraph, idGeometry]), catalog([{ ...idGraph, sha256: "bad" }, idGeometry]), ["id"], "after"),
    /Invalid SHA-256/
  );
});

test("unrelated row changes fail closed", () => {
  const before = catalog([idGraph, idGeometry]);
  const after = JSON.parse(JSON.stringify(before));
  after.regions[0].keep = false;
  assert.throws(() => assertOnlyTargetRowsChanged(before, after, ["id"]), /unrelated region/);
});
