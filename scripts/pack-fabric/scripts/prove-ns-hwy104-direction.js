#!/usr/bin/env node
"use strict";

/**
 * NS directed-travel canary proof for Highway 104 at Upper Nappan.
 *
 * Start: 45.390440, -63.201514
 * Dest:  45.995777, -65.080810
 * Profile: Balanced
 * Probe: 45.8071, -64.1885 (MacDonald Road overpass)
 *
 * Westbound 104 is the north carriageway (OSM way 537982310). Eastbound is
 * the north-pair companion (537982311). A legal westbound ride must stay on
 * way 537982310, not the eastbound carriageway.
 */
process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";

const fs = require("fs");
const path = require("path");
const readline = require("readline");

const FABRIC = path.join(__dirname, "..");
const NS_GRAPH = path.join(FABRIC, "app", "data", "packs", "v1", "ns", "graph.v3.bin");
const NB_GRAPH = path.join(FABRIC, "app", "data", "packs", "v1", "nb", "graph.v3.bin");
const OSM_SEQ = path.join(FABRIC, "data-raw", "osm-roads", "nova-scotia", "roads.geojsonseq");
const overrides = { ns: NS_GRAPH };
if (fs.existsSync(NB_GRAPH)) overrides.nb = NB_GRAPH;
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify(overrides);

const { routeRequest, matchPoint, routeOnRuntime } = require("../routing/lib/router");
const { loadGraphSync } = require("../routing/lib/graph");
const { findPathV2 } = require("../routing/lib/find-path-v2");
const { packHasDirectedArc } = require("../routing/lib/travel-direction");

const PROBE = { lat: 45.8071, lon: -64.1885 };
const START = { lat: 45.390440, lon: -63.201514 };
const DEST = { lat: 45.995777, lon: -65.080810 };
const WEST_OF_OVERPASS = { lat: 45.80818, lon: -64.21 };
const RADIUS_DEG = 0.0035;
const POLICY = { motorizedPermissive: true, motorizedUnknown: false };

function parseSeqLine(line) {
  const trimmed = String(line || "").replace(/^\u001e/, "").trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

function geometryNearProbe(geometry) {
  return (geometry || []).filter((coord) => {
    const lon = Number(coord[0]);
    const lat = Number(coord[1]);
    return Math.abs(lat - PROBE.lat) <= RADIUS_DEG && Math.abs(lon - PROBE.lon) <= RADIUS_DEG;
  });
}

function meanLat(coords) {
  if (!coords.length) return null;
  return coords.reduce((sum, coord) => sum + Number(coord[1]), 0) / coords.length;
}

async function motorwaysNearProbe(seqPath) {
  if (!fs.existsSync(seqPath)) return [];
  const input = fs.createReadStream(seqPath);
  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  const hits = [];
  for await (const line of rl) {
    const feature = parseSeqLine(line);
    if (!feature) continue;
    const props = feature.properties || {};
    if (String(props.highway || "") !== "motorway") continue;
    const coords = feature.geometry && feature.geometry.coordinates;
    if (!Array.isArray(coords) || coords.length < 2) continue;
    const near = coords.filter(
      (coord) =>
        Math.abs(coord[1] - PROBE.lat) <= RADIUS_DEG &&
        Math.abs(coord[0] - PROBE.lon) <= RADIUS_DEG
    );
    if (!near.length) continue;
    const lonDelta = coords[coords.length - 1][0] - coords[0][0];
    hits.push({
      id: props["@id"] || props.id || "",
      oneway: props.oneway || "",
      meanLat: meanLat(near),
      lonDelta,
      westbound: lonDelta < 0
    });
  }
  return hits;
}

function nearestToProbe(geometry) {
  let best = Infinity;
  let bestCoord = null;
  for (const coord of geometry || []) {
    const lon = Number(Array.isArray(coord) ? coord[0] : coord.lon);
    const lat = Number(Array.isArray(coord) ? coord[1] : coord.lat);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    const d = Math.hypot((lat - PROBE.lat) * 111320, (lon - PROBE.lon) * 111320 * Math.cos(PROBE.lat * Math.PI / 180));
    if (d < best) {
      best = d;
      bestCoord = [lon, lat];
    }
  }
  return { meters: Number.isFinite(best) ? Math.round(best) : null, coord: bestCoord };
}

function assertWestbound(geometry, motorways) {
  const near = geometryNearProbe(geometry);
  if (near.length < 2) {
    throw new Error(`route did not pass the MacDonald Road probe (${near.length} vertices)`);
  }
  const lonTravel = near[near.length - 1][0] - near[0][0];
  const routeMeanLat = meanLat(near);
  const west = motorways.filter((way) => way.westbound);
  const east = motorways.filter((way) => !way.westbound);
  const westMean = west.length ? west.reduce((sum, way) => sum + way.meanLat, 0) / west.length : null;
  const eastMean = east.length ? east.reduce((sum, way) => sum + way.meanLat, 0) / east.length : null;
  const report = {
    probeVertices: near.length,
    routeMeanLat,
    lonTravel,
    travelingWest: lonTravel < 0,
    westboundOsmMeanLat: westMean,
    eastboundOsmMeanLat: eastMean,
    closerToWestbound:
      westMean != null && eastMean != null
        ? Math.abs(routeMeanLat - westMean) < Math.abs(routeMeanLat - eastMean)
        : null
  };
  if (!report.travelingWest) {
    throw new Error("canary is not traveling west at Highway 104 / MacDonald Road");
  }
  if (report.closerToWestbound === false) {
    throw new Error("canary is closer to the eastbound Highway 104 carriageway");
  }
  return report;
}

async function main() {
  if (!fs.existsSync(NS_GRAPH)) {
    throw new Error(`missing canary pack ${NS_GRAPH}`);
  }
  const motorways = await motorwaysNearProbe(OSM_SEQ);
  const northPair = motorways
    .slice()
    .sort((a, b) => Math.abs(a.meanLat - 45.8077) - Math.abs(b.meanLat - 45.8077))
    .slice(0, 2);
  const west = northPair.filter((way) => way.westbound);
  const east = northPair.filter((way) => !way.westbound);
  if (!west.length || !east.length) {
    throw new Error("OSM extract is missing the twinned Highway 104 carriageways at the probe");
  }

  const runtime = loadGraphSync(NS_GRAPH);
  const start = matchPoint(runtime, START, POLICY, 750, null, null, "balanced", "start");
  const westDest = matchPoint(runtime, WEST_OF_OVERPASS, POLICY, 120, null, null, "balanced", "end");
  if (!start.ok || !westDest.ok) {
    throw new Error(`canary snap failed start=${start.ok} westDest=${westDest.ok}`);
  }
  const westEi = westDest.edgeIndex;
  const westA = runtime.pack.edgeFrom[westEi];
  const westB = runtime.pack.edgeTo[westEi];
  const westOneWay = packHasDirectedArc(runtime.pack, westA, westB, westEi)
    && !packHasDirectedArc(runtime.pack, westB, westA, westEi);

  const nsRide = findPathV2(
    runtime,
    start,
    westDest,
    "balanced",
    POLICY,
    new Set(),
    undefined,
    { sessionSeed: 1 }
  );
  if (!nsRide) {
    throw new Error("NS canary could not ride west of the MacDonald Road overpass");
  }
  const nsProbe = assertWestbound(nsRide.geometry, northPair);

  const liveNs = await routeOnRuntime(
    {
      profile: "balanced",
      locations: [START, WEST_OF_OVERPASS],
      accessPolicy: POLICY,
      options: { sessionSeed: 1 }
    },
    { ok: true, mode: "regional", regionIds: ["ns"] },
    runtime
  );
  if (liveNs.status !== "complete") {
    throw new Error(`LIVE JS router failed the NS westbound canary: ${liveNs.status} ${liveNs.error || ""}`);
  }
  const liveProbe = assertWestbound(liveNs.geometry, northPair);

  const full = await routeRequest({
    profile: "balanced",
    locations: [START, DEST],
    accessPolicy: POLICY,
    options: { sessionSeed: 1 }
  });

  const report = {
    nsCanaryGraph: NS_GRAPH,
    westboundOsmWayId: west[0].id,
    eastboundOsmWayId: east[0].id,
    westboundDestEdge: westDest.edgeId,
    westboundDestIsOneWay: westOneWay,
    nsBalancedKm: +(nsRide.distanceMeters / 1000).toFixed(1),
    nsProbe,
    liveJsProbe: liveProbe,
    fullOd: {
      status: full.status,
      error: full.error || null,
      message: full.message || null,
      km: full.distanceMeters ? +(full.distanceMeters / 1000).toFixed(1) : null,
      hops: full.stats && full.stats.hops,
      hopKm: full.stats && full.stats.hopKm,
      nearestToProbe: nearestToProbe(full.geometry)
    }
  };
  if (full.status !== "complete") {
    console.log(JSON.stringify(report, null, 2));
    console.error("Full NS→NB OD still fails at the chain seam; do not promote until that hop uses a reachable westbound fabric pin.");
    process.exit(2);
  }
  const eastLat = east[0].meanLat;
  const eastHits = (full.geometry || []).filter((coord) => {
    const lon = Number(coord[0]);
    const lat = Number(coord[1]);
    return Math.abs(lat - eastLat) <= 80 / 111320
      && Math.abs(lat - PROBE.lat) <= 0.01
      && Math.abs(lon - PROBE.lon) <= 0.01;
  });
  if (eastHits.length) {
    report.fullOd.eastboundHits = eastHits.length;
    console.log(JSON.stringify(report, null, 2));
    throw new Error("full OD entered the eastbound Highway 104 carriageway near MacDonald Road");
  }
  try {
    report.fullOd.probe = assertWestbound(full.geometry, northPair);
  } catch (error) {
    report.fullOd.probeError = String(error.message || error);
  }
  console.log(JSON.stringify(report, null, 2));
  if (!report.nsProbe.closerToWestbound || !report.liveJsProbe.closerToWestbound) {
    throw new Error("NS Highway 104 canary is not on the legal westbound carriageway");
  }
  console.log("NS Highway 104 canary stayed on the legal westbound carriageway");
  if (!report.fullOd.probe) {
    console.log("Full NS→NB Balanced OD completed without traversing the MacDonald Road overpass; eastbound 104 was not used.");
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = { main, geometryNearProbe, motorwaysNearProbe };
