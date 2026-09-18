"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  readTopologySealMetaSync,
  parsePairsFromTail,
  scalarFromHead
} = require("./topology-meta");

test("scalarFromHead reads quoted fields", () => {
  const head = '{"schemaVersion":"dirt-cross-pack-topology.v2","fabricReleaseId":"fabric-v4-20260917-02"}';
  assert.equal(scalarFromHead(head, "fabricReleaseId"), "fabric-v4-20260917-02");
});

test("parsePairsFromTail reads trailing pairs array", () => {
  const tail = '],"pairs":[{"left":"on-s","right":"on-n","proofs":12},{"left":"qc-s","right":"qc-n","proofs":9}]}\n';
  const pairs = parsePairsFromTail(tail);
  assert.equal(pairs.length, 2);
  assert.equal(pairs[0].left, "on-s");
});

test("readTopologySealMetaSync avoids full-document parse", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "topo-meta-"));
  const file = path.join(root, "cross-pack-topology.v2.json");
  try {
    const rows = Array.from({ length: 200 }, (_, i) => ({
      coordinate: [-70, 45 + i * 0.001],
      edge: { accessForward: 1, accessReverse: 1 }
    }));
    const doc = {
      schemaVersion: "dirt-cross-pack-topology.v2",
      generatedAt: "2026-09-18T00:00:00.000Z",
      sourceEpoch: "epoch-test",
      fabricReleaseId: "fabric-v4-20260917-02",
      regions: {
        "on-s": { neighbors: { "on-n": rows } },
        "on-n": { neighbors: { "on-s": rows } }
      },
      pairs: [{ left: "on-n", right: "on-s", proofs: rows.length }]
    };
    fs.writeFileSync(file, `${JSON.stringify(doc)}\n`);
    const meta = readTopologySealMetaSync(file);
    assert.equal(meta.fabricReleaseId, "fabric-v4-20260917-02");
    assert.equal(meta.sourceEpoch, "epoch-test");
    assert.equal(meta.pairCount, 1);
    assert.deepEqual(meta.regionIds, ["on-n", "on-s"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
