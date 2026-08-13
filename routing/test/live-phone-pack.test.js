#!/usr/bin/env node
"use strict";

const assert = require("assert");
const { remoteGraphUrl, graphCdnBaseUrl, resolveGraphRequest } = require("../regional/select");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log("PASS", name);
  } catch (err) {
    console.error("FAIL", name, err.message);
    process.exitCode = 1;
  }
}

check("remoteGraphUrl is the phone pack for every region", () => {
  const base = graphCdnBaseUrl();
  for (const id of ["bc", "ab", "wa", "ns", "on"]) {
    assert.strictEqual(remoteGraphUrl(id), base + "/" + id + "/graph.v2.bin");
  }
});

check("preferLonghaulPacks cannot split live from PACKS", () => {
  const prev = process.env.VERCEL;
  process.env.VERCEL = "1";
  try {
    for (const id of ["bc", "ab", "wa"]) {
      const forced = resolveGraphRequest({ regionId: id, preferLonghaulPacks: true });
      const p = String(forced.graphPath || "");
      assert.ok(p.includes(id + "/graph.v2.bin"), id + " must be phone pack, got " + p);
      assert.ok(!p.includes("longhaul"), id + " must not use longhaul, got " + p);
    }
    const body = resolveGraphRequest({
      locations: [
        { lat: 49.0504, lon: -122.3045 },
        { lat: 50.111, lon: -120.786 }
      ]
    });
    const p = String(body.graphPath || (body.graphPaths && body.graphPaths[0]) || "");
    assert.ok(p.includes("graph.v2.bin"), "Abbotsford→Merritt must be phone pack, got " + body.mode + " " + p);
    assert.ok(!/longhaul/i.test(p), "must not be longhaul extract, got " + p);
  } finally {
    if (prev == null) delete process.env.VERCEL;
    else process.env.VERCEL = prev;
  }
});

if (!process.exitCode) console.log(passed + " passed");
