"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { shortlist, loadPairFromSidecars, parseArgs } = require("./thin-subregion-seams");

test("shortlist caps and diversifies coordinates", () => {
  const rows = [];
  for (let i = 0; i < 2000; i += 1) {
    rows.push({
      coordinate: [-80 + (i % 50) * 0.2, 44 + Math.floor(i / 50) * 0.2],
      edge: { accessForward: 0, accessReverse: 1 }
    });
  }
  const picked = shortlist(rows, 100);
  assert.ok(picked.length <= 100);
  assert.ok(picked.length >= 50);
});

test("loadPairFromSidecars reads neighbor rows without topology", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "thin-seams-"));
  try {
    for (const [id, neighbor, n] of [
      ["aa", "bb", 3],
      ["bb", "aa", 3]
    ]) {
      const dir = path.join(root, id);
      fs.mkdirSync(dir);
      const neighbors = {
        [neighbor]: Array.from({ length: n }, (_, i) => ({
          coordinate: [-70 - i, 45 + i],
          edge: { accessForward: 0, accessReverse: 1 }
        }))
      };
      fs.writeFileSync(
        path.join(dir, "cross-pack-seams.v2.json"),
        JSON.stringify({
          schemaVersion: "dirt-cross-pack-seams.v2",
          fabricReleaseId: "fabric-test",
          sourceEpoch: "epoch-test",
          regionId: id,
          neighbors
        })
      );
    }
    const loaded = loadPairFromSidecars(root, "aa", "bb");
    assert.equal(loaded.leftRows.length, 3);
    assert.equal(loaded.rightRows.length, 3);
    assert.equal(loaded.meta.fabricReleaseId, "fabric-test");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("parseArgs requires pair", () => {
  assert.throws(() => parseArgs(["--topology", "t.json", "--root", "packs"]));
});
