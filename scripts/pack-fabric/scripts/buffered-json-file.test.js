"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const { BufferedJSONFile } = require("./buffered-json-file");
const { writeTopologyDocument } = require("./build-v4-seams");

test("buffered topology output preserves complete UTF-8 JSON bytes", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-buffered-json-"));
  try {
    const file = path.join(root, "topology.json");
    const row = { coordinate: [-63.3, 44.7], osmNodeId: "123", name: "Québec 🏍", restrictions: [] };
    const doc = { schemaVersion: "dirt-cross-pack-topology.v2", generatedAt: "2026-09-20",
      sourceEpoch: "fixture", fabricReleaseId: "test", regions: {
        aa: { neighbors: { bb: Array.from({ length: 5000 }, () => row) } },
        bb: { neighbors: { aa: [row] } }
      }, pairs: [{ left: "aa", right: "bb", proofs: 5000 }] };
    writeTopologyDocument(file, doc);
    assert.equal(fs.readFileSync(file, "utf8"), JSON.stringify(doc) + "\n");
    const writer = new BufferedJSONFile(file, 7);
    const chunks = ["{", '"city":', '"Québec 🏍"', ",", '"ok":true', "}", "\n"];
    for (const chunk of chunks) writer.write(chunk);
    writer.close(); writer.close();
    assert.equal(fs.readFileSync(file, "utf8"), chunks.join(""));
    assert.throws(() => writer.write("x"), /closed/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("buffered writer rejects invalid sizing before opening a file", () => {
  assert.throws(() => new BufferedJSONFile("unused", 0), /limit/);
});
