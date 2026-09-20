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

test("publisher and source-lock hashes cover identical complete bytes in one read pass", t => {
  const fs = require("node:fs"), os = require("node:os"), path = require("node:path"), crypto = require("node:crypto");
  const { hashFile, hashFileSet } = require("./prepare-common-source-lock");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-hash-set-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "source.pbf");
  const bytes = Buffer.alloc(8 * 1024 * 1024 + 513, 0x73); bytes[bytes.length - 1] = 0x2f;
  fs.writeFileSync(file, bytes);
  const both = hashFileSet(file, ["md5", "sha256"]);
  for (const algorithm of ["md5", "sha256"]) {
    assert.equal(both[algorithm], crypto.createHash(algorithm).update(bytes).digest("hex"));
    assert.equal(both[algorithm], hashFile(file, algorithm));
  }
  fs.writeFileSync(file, Buffer.alloc(0));
  assert.equal(hashFileSet(file, ["sha256"]).sha256, crypto.createHash("sha256").digest("hex"));
});
