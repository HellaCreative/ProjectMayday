"use strict";
// Test-only: dump V4 snap candidates for one local pack. HTTP is rejected.
const fs = require("node:fs");
const path = require("node:path");
function denyNetwork() { throw new Error("Reference runner forbids network access"); }
global.fetch = denyNetwork;
for (const protocol of ["node:http", "node:https"]) {
  const module = require(protocol); module.request = denyNetwork; module.get = denyNetwork;
}
const {loadGraphAsync} = require("./pack-fabric/routing/lib/graph");
const {legalSnapDetailed, selectConnectedSnapPair, bearingDeg} = require("./pack-fabric/routing/lib/legal-topology/snap");
const [directory, lonA, latA, lonB, latB, meters = "250"] = process.argv.slice(2);
if (!directory || !lonA || !latA || !lonB || !latB) {
  throw new Error("Usage: node scripts/native-routing-snap-dump.cjs PACK_DIR LON_A LAT_A LON_B LAT_B [METERS]");
}
(async () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, "pack-manifest.v2.json"), "utf8"));
  const runtime = await loadGraphAsync(path.resolve(directory, manifest.graph.name));
  const start = {lon: Number(lonA), lat: Number(latA)};
  const end = {lon: Number(lonB), lat: Number(latB)};
  const radius = Number(meters);
  const intent = bearingDeg([start.lon, start.lat], [end.lon, end.lat]);
  const startCands = legalSnapDetailed(runtime.pack, runtime.geom, start, {
    intentBearingDeg: intent, maxMeters: radius
  }).candidates;
  const endCands = legalSnapDetailed(runtime.pack, runtime.geom, end, {
    intentBearingDeg: (intent + 180) % 360, maxMeters: radius
  }).candidates;
  const pair = selectConnectedSnapPair(runtime.pack, startCands, endCands, {allowUnknown: false});
  const brief = (c) => ({
    way: c.osmWayId, edge: c.edgeIndex, forward: c.forward, score: Math.round(c.score * 10) / 10,
    distanceM: Math.round(c.distanceM * 10) / 10, tangent: Math.round(c.tangent)
  });
  console.log(JSON.stringify({
    intent, radius,
    start: startCands.slice(0, 6).map(brief),
    end: endCands.slice(0, 6).map(brief),
    pair: pair.ok ? {start: brief(pair.start), end: brief(pair.end)} : pair
  }, null, 2));
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
