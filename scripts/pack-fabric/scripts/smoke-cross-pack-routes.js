#!/usr/bin/env node
"use strict";

const https = require("https");
const http = require("http");
const liveURL = process.env.LIVE_ROUTE_URL || "";

if (!liveURL) {
  process.env.VERCEL = "1";
  process.env.ROUTING_CHAIN_CACHE = "0";
}

const { routeRequest } = require("../routing/lib/router");

const CASES = [
  {
    id: "bc-ab",
    from: { lon: -116.963, lat: 51.301 }, // Golden, BC
    to: { lon: -115.35, lat: 51.09 } // Canmore, AB
  },
  {
    id: "bc-wa",
    from: { lon: -119.468, lat: 49.032 }, // Osoyoos, BC
    to: { lon: -119.435, lat: 48.939 } // Oroville, WA
  }
];
const PROFILES = ["dirt", "balanced", "cleanest"];

function haversineMeters(a, b) {
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}

function maxGeometryGap(geometry) {
  let max = 0;
  for (let i = 1; i < (geometry || []).length; i += 1) {
    max = Math.max(max, haversineMeters(geometry[i - 1], geometry[i]));
  }
  return max;
}

function postJson(url, payload) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const body = JSON.stringify(payload);
    const req = lib.request(
      {
        hostname: target.hostname,
        port: target.port || undefined,
        path: target.pathname + target.search,
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body)
        }
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          let json;
          try {
            json = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          } catch (error) {
            return reject(new Error(`HTTP ${res.statusCode}: invalid JSON`));
          }
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`HTTP ${res.statusCode}: ${json.message || json.error || "route failed"}`));
          }
          resolve(json);
        });
      }
    );
    req.setTimeout(120000, () => req.destroy(new Error("route timeout")));
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function runRoute(payload) {
  return liveURL ? postJson(liveURL, payload) : routeRequest(payload);
}

async function main() {
  const results = [];
  for (const test of CASES) {
    for (const profile of PROFILES) {
      const result = await runRoute({
        locations: [test.from, test.to],
        profile,
        accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
        options: { sessionSeed: 42 }
      });
      if (result.status !== "complete") {
        throw new Error(`${test.id}/${profile}: ${result.error || result.status} ${result.message || ""}`);
      }
      const seams = (result.debug && result.debug.seamSnaps) || [];
      if (!seams.length || seams.some((row) => row.seamMethod !== "same-osm-way-and-vertex" || row.dualCount !== 2)) {
        throw new Error(`${test.id}/${profile}: route did not use a topology-proven seam`);
      }
      const row = {
        case: test.id,
        profile,
        km: Math.round(result.distanceMeters / 1000),
        dirtPercent: result.stats && result.stats.dirtPercent,
        seamWay: seams[0].osmWayId,
        seamSeedDistanceM: seams[0].seedDistanceM,
        maxGeometryGapM: Math.round(maxGeometryGap(result.geometry))
      };
      results.push(row);
      console.log(JSON.stringify(row));
    }
  }
  console.log(JSON.stringify({ ok: true, target: liveURL || "local", routes: results.length }, null, 2));
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
