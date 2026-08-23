"use strict";

const assert = require("node:assert/strict");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const test = require("node:test");
const { materializeVerifiedRelease, verifyReleaseBytes } = require("./release-pack");

function fixtureRelease(bytes) {
  return {
    schemaVersion: "dirt-pack-release.v1",
    releaseId: "ns-test-01",
    publicBase: "https://packs.example/candidates/ns-test-01",
    regions: [{
      id: "ns",
      files: [{
        name: "graph.v2.bin",
        bytes: bytes.length,
        sha256: crypto.createHash("sha256").update(bytes).digest("hex")
      }]
    }]
  };
}

test("materializes only bytes matching the immutable release identity", async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-release-pack-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const expected = Buffer.from("exact promoted graph bytes");
  const calls = [];
  const result = await materializeVerifiedRelease({
    release: fixtureRelease(expected),
    regionId: "ns",
    fileNames: ["graph.v2.bin"],
    cacheRoot: root,
    fetchImpl: async (url) => {
      calls.push(url);
      return { ok: true, status: 200, arrayBuffer: async () => expected };
    }
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0], "https://packs.example/candidates/ns-test-01/ns/graph.v2.bin");
  assert.deepEqual(fs.readFileSync(result.files["graph.v2.bin"].path), expected);
});

test("fails closed when downloaded bytes do not match the release", async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-release-pack-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const expected = Buffer.from("expected");
  await assert.rejects(
    materializeVerifiedRelease({
      release: fixtureRelease(expected),
      regionId: "ns",
      fileNames: ["graph.v2.bin"],
      cacheRoot: root,
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        arrayBuffer: async () => Buffer.from("different")
      })
    }),
    /mismatch/
  );
});

test("rejects an invalid release record before fetching", async () => {
  let fetched = false;
  await assert.rejects(
    materializeVerifiedRelease({
      release: { schemaVersion: "dirt-pack-release.v1", releaseId: "bad", publicBase: "https://packs.example", regions: [] },
      regionId: "ns",
      fileNames: ["graph.v2.bin"],
      fetchImpl: async () => { fetched = true; }
    }),
    /has no ns region/
  );
  assert.equal(fetched, false);
});

test("byte verification checks both size and SHA-256", () => {
  const bytes = Buffer.from("abc");
  const record = {
    bytes: 3,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex")
  };
  assert.equal(verifyReleaseBytes(bytes, record, "fixture"), record.sha256);
  assert.throws(() => verifyReleaseBytes(Buffer.from("abcd"), record, "fixture"), /byte mismatch/);
});
