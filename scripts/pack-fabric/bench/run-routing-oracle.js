#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const API_ROOT = process.env.DIRT_API_ROOT || "https://dirt-mayday.vercel.app/api";
const CASES_PATH = path.join(__dirname, "routing-oracle-cases.json");
const BASELINE_PATH = path.join(__dirname, "routing-oracle-baseline.json");
const cases = JSON.parse(fs.readFileSync(CASES_PATH, "utf8"));
const usableRangeMeters = cases.tankRangeKm * 1000 * (1 - cases.reservePercent / 100);
const tankRangeMeters = cases.tankRangeKm * 1000;

function parseArgs(argv) {
  const args = { compare: false, expectedBuild: null, scenario: null, profile: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--compare") args.compare = true;
    else if (argv[index] === "--expected-build") args.expectedBuild = argv[++index];
    else if (argv[index] === "--scenario") args.scenario = argv[++index];
    else if (argv[index] === "--profile") args.profile = argv[++index];
    else if (argv[index] === "--help" || argv[index] === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${argv[index]}`);
  }
  if (args.expectedBuild === undefined) throw new Error("--expected-build requires a value");
  return args;
}

function usage() {
  console.log("Usage: npm run bench:routing-oracle [-- --expected-build <sha>] [--compare] [--scenario <id>] [--profile <profile>]");
}

async function post(endpoint, body) {
  const response = await fetch(`${API_ROOT}/${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(65_000)
  });
  const payload = await response.json();
  if (!response.ok || payload.status !== "complete") {
    throw new Error(`${endpoint} ${response.status}: ${payload.error || payload.message || payload.status}`);
  }
  return payload;
}

function options(profile, history, maxPathMeters, regionalHopMinimumMeters = []) {
  const value = {
    sessionSeed: cases.sessionSeed,
    priorEdgeIds: [...history.edgeIds],
    arrivalEdgeId: history.arrivalEdgeId,
    backtrackFactor: 4,
    avoidMotorways: profile === "cleanest"
  };
  if (Number.isFinite(maxPathMeters)) value.maxPathMeters = maxPathMeters;
  if (regionalHopMinimumMeters.length) value.regionalHopMinimumMeters = regionalHopMinimumMeters;
  return value;
}

function routeBody(profile, from, to, history, maxPathMeters, regionalHopMinimumMeters = []) {
  return {
    profile,
    locations: [from, to],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: options(profile, history, maxPathMeters, regionalHopMinimumMeters)
  };
}

function appendHistory(history, response) {
  for (const segment of response.segments || []) {
    if (segment.edgeId == null || segment.edgeId === "") continue;
    const edgeId = String(segment.edgeId);
    history.edgeIds.add(edgeId);
    history.arrivalEdgeId = edgeId;
  }
}

function stopPoint(stop) {
  return {
    lat: Number(stop.lat ?? stop.latitude),
    lon: Number(stop.lon ?? stop.longitude)
  };
}

function identityKey(identity) {
  return [
    identity.regionId,
    identity.graphSha256,
    identity.geometrySha256,
    identity.fuelSha256
  ].filter(Boolean).join(":");
}

function collectIdentity(target, response) {
  for (const identity of response.packIdentity || []) {
    target.set(identityKey(identity), {
      regionId: identity.regionId,
      graphSha256: identity.graphSha256 || null,
      geometrySha256: identity.geometrySha256 || null,
      fuelSha256: identity.fuelSha256 || null
    });
  }
}

function round(value, digits = 1) {
  const scale = 10 ** digits;
  return Math.round(Number(value || 0) * scale) / scale;
}

function weightedPercent(responses, field) {
  const total = responses.reduce((sum, row) => sum + Number(row.distanceMeters || 0), 0);
  if (!(total > 0)) return 0;
  return responses.reduce((sum, row) =>
    sum + Number(row.distanceMeters || 0) * Number(row.stats && row.stats[field] || 0), 0
  ) / total;
}

async function runCase(profile, scenario, buildState, identities) {
  const history = { edgeIds: new Set(), arrivalEdgeId: null };
  const routedHops = [];
  const fuelStops = [];
  const excludedStationIds = new Set();
  let current = scenario.from;
  let remaining = usableRangeMeters;
  let forceFuelStop = false;
  for (let attempt = 1; attempt <= 16; attempt += 1) {
    const chain = await post("fuel-chain", {
      profile,
      locations: [current, scenario.to],
      vehicle: "dual-sport-motorcycle",
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
      fuel: {
        usableRangeMeters,
        firstLegMaxMeters: remaining,
        requireFuelStopBeforeEnd: forceFuelStop,
        minimumFuelStops: forceFuelStop ? 1 : 0,
        profileMeters: 0,
        riderLegId: `${scenario.id}:${profile}`,
        excludedStationIds: [...excludedStationIds],
        windowMaxStops: 1,
        allowPartialWindow: true,
        windowTimeBudgetMs: 5_800,
        // Match the app: fuel allocation must prove the active profile route
        // to each committed stop or destination. Graph-only feelers can claim
        // Clean reached B while the actual Clean hop still exceeds the tank.
        forwardFeeler: false
      },
      options: options(profile, history)
    });
    buildState.add(chain.serviceBuild);
    collectIdentity(identities, chain);
    const selectedStop = (chain.stops || [])[0] || null;
    if (!selectedStop && chain.windowComplete === false) {
      throw new Error("Fuel feeler ended without a forward stop or the destination");
    }
    const target = selectedStop ? stopPoint(selectedStop) : scenario.to;
    let response;
    try {
      response = await post("route", routeBody(
        profile,
        current,
        target,
        history,
        remaining,
        chain.graphMeters || []
      ));
    } catch (error) {
      if (selectedStop) {
        excludedStationIds.add(String(selectedStop.id));
      } else if (!forceFuelStop) {
        forceFuelStop = true;
      } else {
        throw error;
      }
      continue;
    }
    buildState.add(response.serviceBuild);
    collectIdentity(identities, response);
    appendHistory(history, response);
    routedHops.push(response);
    if (!selectedStop) break;
    fuelStops.push({
      id: String(selectedStop.id),
      name: selectedStop.name || null,
      tankPercent: round(Number(response.distanceMeters) / tankRangeMeters * 100),
      usablePercent: round(Number(response.distanceMeters) / usableRangeMeters * 100)
    });
    current = target;
    remaining = usableRangeMeters;
    // Match the app: committed pumps stay excluded for the rider leg so a
    // later one-stop window cannot bounce back to an earlier city station.
    excludedStationIds.add(String(selectedStop.id));
    forceFuelStop = false;
    if (attempt === 16) throw new Error("Fuel feeler exceeded 16 forward attempts");
  }

  const distanceMeters = routedHops.reduce((sum, row) => sum + Number(row.distanceMeters || 0), 0);
  if (!routedHops.length) throw new Error("Fuel feeler returned no routed hops");
  return {
    status: "complete",
    distanceKm: round(distanceMeters / 1000),
    dirtPercent: round(weightedPercent(routedHops, "dirtPercent")),
    gravelPercent: round(weightedPercent(routedHops, "gravelPercent")),
    pavedPercent: round(weightedPercent(routedHops, "pavedPercent")),
    fuelStops,
    finalLegTankPercent: round(Number(routedHops[routedHops.length - 1].distanceMeters) / tankRangeMeters * 100)
  };
}

function compare(current, baseline) {
  const diffs = [];
  const keyed = new Map(baseline.results.map((row) => [`${row.profile}/${row.scenario}`, row]));
  for (const row of current.results) {
    const prior = keyed.get(`${row.profile}/${row.scenario}`);
    if (!prior) {
      diffs.push(`${row.profile}/${row.scenario}: missing baseline`);
      continue;
    }
    for (const field of ["distanceKm", "dirtPercent", "gravelPercent", "pavedPercent"]) {
      const tolerance = field === "distanceKm" ? Math.max(2, prior[field] * 0.02) : 2;
      if (Math.abs(row[field] - prior[field]) > tolerance) {
        diffs.push(`${row.profile}/${row.scenario}: ${field} ${prior[field]} -> ${row[field]}`);
      }
    }
    const priorStops = prior.fuelStops.map((stop) => stop.id).join(",");
    const currentStops = row.fuelStops.map((stop) => stop.id).join(",");
    if (priorStops !== currentStops) {
      diffs.push(`${row.profile}/${row.scenario}: fuel stops ${priorStops || "none"} -> ${currentStops || "none"}`);
    }
    const stopCount = Math.min(prior.fuelStops.length, row.fuelStops.length);
    for (let index = 0; index < stopCount; index += 1) {
      if (Math.abs(prior.fuelStops[index].tankPercent - row.fuelStops[index].tankPercent) > 2) {
        diffs.push(`${row.profile}/${row.scenario}: stop ${index + 1} tank% ${prior.fuelStops[index].tankPercent} -> ${row.fuelStops[index].tankPercent}`);
      }
    }
  }
  return diffs;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return usage();
  const builds = new Set();
  const identities = new Map();
  const results = [];
  const scenarios = args.scenario
    ? cases.scenarios.filter((scenario) => scenario.id === args.scenario)
    : cases.scenarios;
  const profiles = args.profile ? cases.profiles.filter((profile) => profile === args.profile) : cases.profiles;
  if (!scenarios.length) throw new Error(`Unknown scenario: ${args.scenario}`);
  if (!profiles.length) throw new Error(`Unknown profile: ${args.profile}`);
  for (const scenario of scenarios) {
    for (const profile of profiles) {
      process.stderr.write(`oracle ${profile}/${scenario.id}\n`);
      const result = await runCase(profile, scenario, builds, identities);
      results.push({ profile, scenario: scenario.id, ...result });
    }
  }
  if (builds.size !== 1) throw new Error(`Mixed live service builds: ${[...builds].join(", ")}`);
  const serviceBuild = [...builds][0];
  if (args.expectedBuild && serviceBuild !== args.expectedBuild) {
    throw new Error(`Live serviceBuild ${serviceBuild} does not match expected ${args.expectedBuild}`);
  }
  const output = {
    schemaVersion: 1,
    capturedAt: new Date().toISOString(),
    serviceBuild,
    sessionSeed: cases.sessionSeed,
    tankRangeKm: cases.tankRangeKm,
    reservePercent: cases.reservePercent,
    usableRangeKm: round(usableRangeMeters / 1000),
    packIdentity: [...identities.values()].sort((a, b) => a.regionId.localeCompare(b.regionId)),
    results
  };
  console.log(JSON.stringify(output, null, 2));
  if (args.compare) {
    if (!fs.existsSync(BASELINE_PATH)) throw new Error(`Baseline not found: ${BASELINE_PATH}`);
    const diffs = compare(output, JSON.parse(fs.readFileSync(BASELINE_PATH, "utf8")));
    if (diffs.length) {
      process.stderr.write(`Regression oracle failed:\n- ${diffs.join("\n- ")}\n`);
      process.exitCode = 1;
    } else {
      process.stderr.write("Regression oracle passed.\n");
    }
  }
}

main().catch((error) => {
  console.error(error && error.stack || error);
  process.exitCode = 1;
});
