"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const test = require("node:test");
const assert = require("node:assert/strict");
const { compactGraphFile } = require("./compact-v4-candidate");

const LEGACY_FIXTURE = path.resolve(
  __dirname,
  "../routing/fixtures/legal-topology/legal-topology-canary-legacy.graph.v4.bin"
);

test("candidate compaction resumes exactly after graph replacement", (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-v4-compact-"));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const graph = path.join(temp, "graph.v4.bin");
  fs.copyFileSync(LEGACY_FIXTURE, graph);

  const first = compactGraphFile(graph, true);
  assert.equal(first.alreadyCompact, false);
  assert.ok(first.savedBytes > 0);
  assert.ok(first.journalPath && fs.existsSync(first.journalPath));

  // Simulate an interruption after the atomic graph rename but before the
  // manifest/report rewrite. The journal must retain the exact size record.
  const resumed = compactGraphFile(graph, true);
  assert.equal(resumed.alreadyCompact, true);
  assert.equal(resumed.beforeBytes, first.beforeBytes);
  assert.equal(resumed.afterBytes, first.afterBytes);
  assert.equal(resumed.savedBytes, first.savedBytes);
});
