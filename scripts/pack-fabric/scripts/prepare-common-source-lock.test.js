"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { parseArgs, batchConfig } = require("./prepare-common-source-lock");
test("common source requires a publisher checksum and explicit supported region set", () => {
  const args = ["--source", "source.pbf", "--url", "https://example.invalid/dated.pbf", "--md5", "a".repeat(32), "--output", "lock.json"];
  assert.deepEqual(parseArgs([...args, "qc-n", "ns", "ns"]).regions, ["ns", "qc-n"]);
  assert.throws(() => parseArgs(args));
  assert.throws(() => parseArgs([...args, "made-up"]));
  assert.throws(() => parseArgs([...args, "ns", "--refresh"]));
  assert.throws(() => parseArgs(["--source"]));
  assert.equal(parseArgs([...args, "ns", "--batch-size", "2"]).batchSize, 2);
  assert.throws(() => parseArgs([...args, "ns", "--batch-size", "67"]), /measured/);
});
test("batched extraction retains exact polygons, destinations and timestamp", () => {
  const entries = [{ pbf: "/out/ns.pbf", halo: "/clip/ns.geojson" }, { pbf: "/out/pe.pbf", halo: "/clip/pe.geojson" }];
  assert.deepEqual(batchConfig(entries, "2026-09-18T20:21:10Z"), { extracts: entries.map(e => ({ output: e.pbf,
    polygon: { file_name: e.halo, file_type: "geojson" },
    output_header: { osmosis_replication_timestamp: "2026-09-18T20:21:10Z" } })) });
});
