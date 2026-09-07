"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { parseArgs, needsMultipart, verifyRemote } = require("./ship-v4-candidate");

test("V4 ship door accepts only a sealed-fabric candidate command", () => {
  const parsed = parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--verify"]);
  assert.equal(parsed.candidate, "fabric-v4-20260907-01");
  assert.equal(parsed.pack, true);
  assert.equal(parsed.verify, true);
  assert.throws(() => parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--live"]), /forbidden/);
  assert.throws(() => parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--promote"]), /forbidden/);
  assert.throws(() => parseArgs(["--candidate", "ns-v4-legal-topology-20260906-02", "--pack"]), /release id/);
});

test("V4 ship door uses multipart transfer above the reliable direct-upload limit", () => {
  assert.equal(needsMultipart({ identity: { bytes: 96 * 1024 * 1024 } }), false);
  assert.equal(needsMultipart({ identity: { bytes: 96 * 1024 * 1024 + 1 } }), true);
});

test("V4 ship verification retries a transient read-back failure", async () => {
  const body = Buffer.from("verified");
  const item = {
    key: "v4/candidates/fabric-v4-20260907-01/ns/graph.v4.bin",
    identity: {
      bytes: body.length,
      sha256: crypto.createHash("sha256").update(body).digest("hex")
    }
  };
  let fetchCount = 0;
  const fetchFn = async () => {
    fetchCount += 1;
    if (fetchCount === 1) throw new TypeError("fetch failed");
    return new Response(body, { headers: { "content-length": String(body.length) } });
  };

  assert.equal(await verifyRemote(item, "https://candidate.invalid", {
    attempts: 2,
    retryBaseMilliseconds: 0,
    fetchFn,
    quiet: true
  }), true);
  assert.equal(fetchCount, 2);
});

test("V4 ship verification treats only a missing candidate object as reusable=false", async () => {
  const item = {
    key: "v4/candidates/fabric-v4-20260907-01/ns/graph.v4.bin",
    identity: { bytes: 1, sha256: "0".repeat(64) }
  };
  const missing = await verifyRemote(item, "https://candidate.invalid", {
    allowMissing: true,
    fetchFn: async () => new Response(null, { status: 404 }),
    quiet: true
  });
  assert.equal(missing, false);
});
