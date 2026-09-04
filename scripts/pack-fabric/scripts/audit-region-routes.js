#!/usr/bin/env node
"use strict";

/**
 * Repeatable local/live acceptance gate for a province or state pack.
 *
 *   node scripts/audit-region-routes.js ns
 *   node scripts/audit-region-routes.js ns --live https://dirt-mayday.vercel.app/api/route
 *   node scripts/audit-region-routes.js ns --out routing/data/reports/ns-route-acceptance.json
 */
const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");
const { segmentIntersectsBox } = require("../routing/lib/hop-search");

const FABRIC = path.resolve(__dirname, "..");
const FIXTURES = path.join(FABRIC, "routing/registry/acceptance-routes.json");
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const REGIONS = path.join(FABRIC, "routing/data/regions");
const RUNS = [
  { key: "dirt", profile: "dirt", allowUnknown: false },
  { key: "dirt-allow-unknown", profile: "dirt", allowUnknown: true },
  { key: "balanced", profile: "balanced", allowUnknown: false },
  { key: "cleanest", profile: "cleanest", allowUnknown: false }
];

function arg(name) {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : null;
}

function regionArg() {
  return String(process.argv.slice(2).find((value) => !value.startsWith("--") && !/^https?:/i.test(value)) || "").toLowerCase();
}

function postJson(url, payload) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const body = JSON.stringify(payload);
    const lib = target.protocol === "https:" ? https : http;
    const request = lib.request({
      hostname: target.hostname,
      port: target.port || undefined,
      path: target.pathname + target.search,
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body)
      }
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        let result;
        try {
          result = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch (error) {
          return reject(new Error(`HTTP ${response.statusCode}: invalid JSON`));
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return reject(new Error(`HTTP ${response.statusCode}: ${result.message || result.error || "route failed"}`));
        }
        resolve(result);
      });
    });
    request.setTimeout(120000, () => request.destroy(new Error("route timeout")));
    request.on("error", reject);
    request.write(body);
    request.end();
  });
}

function pointInBox(point, box) {
  return point && point[0] >= box.minLon && point[0] <= box.maxLon
    && point[1] >= box.minLat && point[1] <= box.maxLat;
}

function intersectedCoreNames(geometry, from, to, boxes) {
  if (!Array.isArray(geometry) || geometry.length < 2) return [];
  const start = [from.lon, from.lat];
  const end = [to.lon, to.lat];
  const names = new Set();
  for (const box of boxes || []) {
    if (pointInBox(start, box) || pointInBox(end, box)) continue;
    for (let i = 1; i < geometry.length; i += 1) {
      if (segmentIntersectsBox(geometry[i - 1], geometry[i], box)) {
        names.add(box.name || box.id || "unnamed-core");
        break;
      }
    }
  }
  return [...names];
}

function loadUrbanCores(region) {
  const file = path.join(REGIONS, region, "urban-cores.v1.json");
  if (!fs.existsSync(file)) return [];
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  return json.cores || json.urbanCores || [];
}

function fuelCount(region) {
  const file = path.join(PACKS, region, "fuel.v1.json");
  if (!fs.existsSync(file)) return 0;
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  if (Array.isArray(json.features)) return json.features.length;
  if (Array.isArray(json.stations)) return json.stations.length;
  if (Array.isArray(json.items)) return json.items.length;
  return Number(json.count) || 0;
}

function searchMeta(result) {
  return result && result.debug && result.debug.searchMeta || {};
}

function fail(failures, routeId, profile, message) {
  failures.push({ route: routeId, profile, message });
}

async function main() {
  const region = regionArg();
  if (!region) throw new Error("Usage: audit-region-routes.js <region> [--live <url>] [--out <file>]");
  const fixtureFile = JSON.parse(fs.readFileSync(FIXTURES, "utf8"));
  const fixture = fixtureFile.regions && fixtureFile.regions[region];
  if (!fixture || !Array.isArray(fixture.routes) || !fixture.routes.length) {
    throw new Error(`No deliberate acceptance routes registered for ${region}`);
  }
  const liveURL = arg("--live");
  let localRouteRequest = null;
  if (!liveURL) {
    process.env.VERCEL = "1";
    process.env.ROUTING_CHAIN_CACHE = "0";
    localRouteRequest = require("../routing/lib/router").routeRequest;
  }
  const route = (payload) => liveURL ? postJson(liveURL, payload) : localRouteRequest(payload);
  const cores = loadUrbanCores(region);
  const failures = [];
  const rows = [];
  const packedFuelCount = fuelCount(region);
  if (packedFuelCount < Number(fixture.fuelMinimum || 0)) {
    fail(failures, "pack", "fuel", `packed fuel ${packedFuelCount} is below ${fixture.fuelMinimum}`);
  }

  for (const test of fixture.routes) {
    const byProfile = {};
    for (const run of RUNS) {
      const profile = run.profile;
      const profileKey = run.key;
      const started = Date.now();
      const payload = {
        locations: [test.from, test.to],
        profile,
        accessPolicy: { motorizedPermissive: true, motorizedUnknown: run.allowUnknown },
        options: { sessionSeed: 42 }
      };
      if (!test.chain) payload.regionId = region;
      const result = await route(payload);
      if (!result || result.status !== "complete") {
        fail(failures, test.id, profileKey, result && (result.message || result.error) || "route incomplete");
        continue;
      }
      const meta = searchMeta(result);
      const coreHits = intersectedCoreNames(result.geometry, test.from, test.to, cores);
      const row = {
        route: test.id,
        profile: profileKey,
        allowUnknown: run.allowUnknown,
        distanceKm: Number(((result.distanceMeters || 0) / 1000).toFixed(1)),
        dirtPercent: result.stats && result.stats.dirtPercent,
        elapsedMs: Date.now() - started,
        pass2Outcome: meta.pass2Outcome || "completed",
        pops: meta.pops || 0,
        backwardPercent: meta.routeShape && meta.routeShape.backwardPercent,
        corridorCandidates: Array.isArray(meta.corridorCandidates) ? meta.corridorCandidates.length : 0,
        urbanCoreHits: coreHits
      };
      rows.push(row);
      byProfile[profileKey] = row;
      if (coreHits.length && !(meta.urbanCoreFallbackUsed || result.debug && result.debug.fallback === "urban_core_last_resort")) {
        fail(failures, test.id, profileKey, `crossed urban cores: ${coreHits.join(", ")}`);
      }
      if (meta.timedOut || meta.pass2Outcome === "timeCap" || meta.pass2Outcome === "popCap") {
        fail(failures, test.id, profileKey, `search ended ${meta.pass2Outcome || "at a cap"}`);
      }
      if (profile === "dirt") {
        const minimum = run.allowUnknown
          ? Number(test.minimumDirtAllowUnknownPercent || test.minimumDirtPercent || 0)
          : Number(test.minimumDirtPercent || 0);
        if (row.dirtPercent < minimum) {
          fail(failures, test.id, profileKey, `${row.dirtPercent}% dirt is below ${minimum}%`);
        }
        const minimumCorridors = Number.isFinite(Number(test.minimumCorridorCandidates))
          ? Number(test.minimumCorridorCandidates)
          : 3;
        if (row.corridorCandidates < minimumCorridors) {
          fail(
            failures,
            test.id,
            profileKey,
            `fewer than ${minimumCorridors} corridor candidates were evaluated`
          );
        }
        if (Number.isFinite(row.backwardPercent)
            && row.backwardPercent > Number(test.maximumDirtBackwardPercent || Infinity)) {
          fail(failures, test.id, profileKey, `${row.backwardPercent}% backward exceeds ${test.maximumDirtBackwardPercent}%`);
        }
      }
      if (profile === "balanced"
          && Math.abs(row.dirtPercent - 50) > Number(test.balancedTolerance || 5)) {
        fail(failures, test.id, profileKey, `${row.dirtPercent}% is outside the 50/50 tolerance`);
      }
      if (profile === "cleanest" && row.dirtPercent > Number(test.maximumCleanDirtPercent || 2)) {
        fail(failures, test.id, profileKey, `${row.dirtPercent}% dirt exceeds Clean maximum`);
      }
    }
    if (byProfile.dirt && byProfile.balanced
        && byProfile.dirt.dirtPercent < byProfile.balanced.dirtPercent) {
      fail(failures, test.id, "dirt", "Dirt returned less dirt than Balanced");
    }
  }

  const report = {
    schemaVersion: "dirt-region-route-acceptance.v1",
    generatedAt: new Date().toISOString(),
    region,
    target: liveURL || "local",
    osmOnlyExpected: true,
    fuelStations: packedFuelCount,
    urbanCoreCount: cores.length,
    passed: failures.length === 0,
    failures,
    routes: rows
  };
  const out = arg("--out");
  if (out) {
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, JSON.stringify(report, null, 2) + "\n");
  }
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  if (failures.length) process.exit(1);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
