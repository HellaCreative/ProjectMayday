"use strict";
// Test-only JS orchestration over one local V4 pack. HTTP is rejected before
// loading any reference module. Never used by the app. Multi-pack JS merge
// still expects JSON graphs, so NS+NB V4 comparison uses the Swift regional
// graph and this runner for single-pack identity checks.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
let networkAttempts = 0;
function denyNetwork() { networkAttempts++; throw new Error("Reference runner forbids network access"); }
global.fetch = denyNetwork;
for (const protocol of ["node:http", "node:https"]) {
  const module = require(protocol); module.request = denyNetwork; module.get = denyNetwork;
}
const [root, regionsText, requestFile, secondsText = "90"] = process.argv.slice(2);
if (!root || !regionsText || !requestFile || !Number.isFinite(Number(secondsText)) || Number(secondsText) <= 0) {
  throw new Error("Usage: node scripts/native-routing-pack-reference.cjs PACK_ROOT ns REQUEST_JSON [SECONDS]");
}
const {loadGraphAsync} = require("./pack-fabric/routing/lib/graph");
const {routeOnRuntime} = require("./pack-fabric/routing/lib/router");
const {planFuelChainOnRuntime} = require("./pack-fabric/routing/lib/fuel-chain");
(async () => {
  const started = performance.now();
  const request = JSON.parse(fs.readFileSync(requestFile, "utf8"));
  const regions = regionsText.split(",").map((id) => id.trim()).filter(Boolean);
  if (regions.length !== 1) {
    throw new Error("JS V4 decoder is single-pack in this runner; use Swift RegionalGraph for NS+NB.");
  }
  const directory = path.join(root, regions[0]);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, "pack-manifest.v2.json"), "utf8"));
  const identities = [{region: manifest.regionId}];
  const stations = [];
  for (const field of ["graph", "geometry", "fuel"]) {
    const artifact = manifest[field];
    if (!artifact) continue;
    const data = fs.readFileSync(path.join(directory, artifact.name));
    const sha = crypto.createHash("sha256").update(data).digest("hex");
    if (sha !== artifact.sha256) throw new Error(field + " hash mismatch");
    identities[0][field] = sha;
    if (field === "fuel") {
      const payload = JSON.parse(data.toString("utf8"));
      for (const station of payload.stations || []) stations.push(station);
    }
  }
  const deadlineAtMs = Date.now() + Number(secondsText) * 1000 - (performance.now() - started);
  const runtime = await loadGraphAsync(path.resolve(directory, manifest.graph.name));
  const prepareSeconds = (performance.now() - started) / 1000;
  const resolution = {regionIds: regions, graphPaths: [path.resolve(directory, manifest.graph.name)], mode: "local-reference"};
  const body = {...request, options: {...request.options, deadlineAtMs}};
  let result;
  if (request.fuel) {
    const start = request.locations[0];
    const destination = request.locations[request.locations.length - 1];
    result = await planFuelChainOnRuntime({
      runtime,
      stations,
      start,
      destination,
      profile: request.profile,
      accessPolicy: request.accessPolicy,
      usableRangeMeters: request.fuel.usableRangeMeters,
      firstLegMaxMeters: request.fuel.firstLegMaxMeters,
      requireFuelStopBeforeEnd: request.fuel.requireFuelStopBeforeEnd === true,
      minimumFuelStops: request.fuel.minimumFuelStops || 0,
      destinationFuelUsedLimitMeters: request.fuel.destinationFuelUsedLimitMeters,
      mapZoom: request.options && request.options.mapZoom,
      matchLimitMeters: request.options && request.options.matchLimitMeters,
      timeBudgetMs: Number(secondsText) * 1000,
      deadlineAtMs,
      graphResolution: resolution,
      ensureDestinationFuelEscape: request.fuel.ensureDestinationFuelEscape === true
    });
  } else {
    result = await routeOnRuntime(body, resolution, runtime);
  }
  console.log(JSON.stringify({request, packIdentities: identities,
    seconds: (performance.now() - started) / 1000, prepareSeconds, networkAttempts,
    maxRSS: process.resourceUsage().maxRSS, result}));
  if (networkAttempts) process.exitCode = 1;
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
