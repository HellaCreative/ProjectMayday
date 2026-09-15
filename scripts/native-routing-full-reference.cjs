"use strict";
// Test-only, full single-pack JavaScript orchestration over local immutable files.
// HTTP is rejected before loading any reference module. Never used by the app.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
let networkAttempts = 0;
function denyNetwork() { networkAttempts++; throw new Error("Reference runner forbids network access"); }
global.fetch = denyNetwork;
for (const protocol of ["node:http", "node:https"]) {
  const module = require(protocol); module.request = denyNetwork; module.get = denyNetwork;
}
const [directory, requestFile, secondsText = "60"] = process.argv.slice(2);
if (!directory || !requestFile || !Number.isFinite(Number(secondsText)) || Number(secondsText) <= 0) {
  throw new Error("Usage: node scripts/native-routing-full-reference.cjs PACK_DIRECTORY REQUEST_JSON [SECONDS]");
}
const {loadGraphAsync} = require("./pack-fabric/routing/lib/graph");
const {routeOnRuntime} = require("./pack-fabric/routing/lib/router");
(async () => {
  const started = performance.now();
  const request = JSON.parse(fs.readFileSync(requestFile, "utf8"));
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, "pack-manifest.v2.json"), "utf8"));
  const hashes = {};
  for (const field of ["graph", "geometry"]) {
    const artifact = manifest[field];
    const data = fs.readFileSync(path.join(directory, artifact.name));
    const sha = crypto.createHash("sha256").update(data).digest("hex");
    if (sha !== artifact.sha256) throw new Error(field + " hash mismatch");
    hashes[field] = sha;
  }
  const deadlineAtMs = Date.now() + Number(secondsText) * 1000 - (performance.now() - started);
  const runtime = await loadGraphAsync(path.resolve(directory, "graph.v4.bin"));
  const prepareSeconds = (performance.now() - started) / 1000;
  const result = await routeOnRuntime({...request, options: {...request.options, deadlineAtMs}},
    {regionIds: [manifest.regionId], mode: "local-reference"}, runtime);
  console.log(JSON.stringify({request, packIdentities: {region: manifest.regionId, ...hashes},
    seconds: (performance.now() - started) / 1000, prepareSeconds, networkAttempts,
    maxRSS: process.resourceUsage().maxRSS, result}));
  if (networkAttempts || result.status !== "complete") process.exitCode = 1;
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
