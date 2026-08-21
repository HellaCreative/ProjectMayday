#!/usr/bin/env node
"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const BENCH_DIR = __dirname;
const REPO_ROOT = path.resolve(BENCH_DIR, "../../..");
const FIXTURE_PATH = path.join(BENCH_DIR, "ns-routes.json");
const RESULTS_DIR = path.join(BENCH_DIR, "results");
const LATEST_PATH = path.join(RESULTS_DIR, "latest.md");
const NS_RELEASE_PATH = path.join(
  REPO_ROOT,
  "scripts/pack-fabric/routing/data/releases/ns-osm-20260821-02.json"
);
const NS_FUEL_PATH = path.join(
  REPO_ROOT,
  "scripts/pack-fabric/app/data/packs/v1/ns/fuel.v1.json"
);
const NS_FUEL = JSON.parse(fs.readFileSync(NS_FUEL_PATH, "utf8"));

async function loadBenchFuel() {
  return {
    ok: true,
    regionIds: ["ns"],
    stations: Array.isArray(NS_FUEL.stations) ? NS_FUEL.stations : []
  };
}

// Benchmark the immutable release that supplied the current promoted stable
// Nova Scotia pack. The candidate URL retains the exact approved bytes even
// after promotion, keeping repeated runs deterministic.
function configureLiveNovaScotiaSource() {
  if (process.env.R2_REGION_BASE_OVERRIDES) return;
  const release = JSON.parse(fs.readFileSync(NS_RELEASE_PATH, "utf8"));
  if (!release.publicBase || !(release.regions || []).some((region) => region.id === "ns")) {
    throw new Error("Nova Scotia live release record is incomplete");
  }
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({ ns: release.publicBase });
}

configureLiveNovaScotiaSource();

const { routeRequest, matchPoint, normalizePolicy } = require("../routing/lib/router");
const { fuelChainRequest } = require("../routing/lib/fuel-chain");
const { loadGraphsForRequest } = require("../routing/lib/graph");
const { findPathV2 } = require("../routing/lib/find-path-v2");
const { resolveGraphRequest, graphCdnBaseUrlForRegion } = require("../routing/regional/select");
const SESSION_SEED = 0xD1_47_0008;
const USABLE_METERS = 237_500;
const PROFILES = ["dirt", "balanced", "direct", "clean"];
const PROFILE_API = { dirt: "dirt", balanced: "balanced", direct: "direct", clean: "cleanest" };

function usage() {
  console.log("Usage: npm run bench:ns [-- --compare <sha>]");
}

function parseArgs(argv) {
  let compare = null;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--help" || argv[index] === "-h") return { help: true, compare: null };
    if (argv[index] === "--compare") {
      compare = argv[index + 1];
      if (!compare) throw new Error("--compare requires a git revision");
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${argv[index]}`);
  }
  return { help: false, compare };
}

function git(...args) {
  return execFileSync("git", args, { cwd: REPO_ROOT, encoding: "utf8" }).trim();
}

function locationsFor(route) {
  const points = route.waypoints || [route.from, route.to];
  return points.map(([lat, lon]) => ({ lat, lon }));
}

function validateFixtures(routes) {
  if (!Array.isArray(routes) || routes.length !== 8) throw new Error("Expected exactly eight NS benchmark routes");
  const ids = new Set();
  for (const route of routes) {
    if (!route.id || ids.has(route.id)) throw new Error(`Invalid or duplicate route id: ${route.id}`);
    ids.add(route.id);
    const points = locationsFor(route);
    if (points.length < 2 || points.some((point) => !Number.isFinite(point.lat) || !Number.isFinite(point.lon))) {
      throw new Error(`Invalid coordinates for ${route.id}`);
    }
  }
}

function benchmarkCases(routes) {
  const cases = [];
  for (const route of routes) {
    for (const profile of PROFILES) {
      const unknownModes = profile === "dirt" ? [false, true] : [false];
      for (const allowUnknown of unknownModes) {
        // Fuel is always planned. The baseline route above remains an internal
        // route-only diagnostic, but it is no longer a rider-visible mode or a
        // second benchmark axis.
        cases.push({ route, profile, allowUnknown, fuelOn: true });
      }
    }
  }
  return cases;
}

function caseID(item) {
  return [
    item.route.id,
    item.profile,
    item.allowUnknown ? "unknown-on" : "unknown-off",
    "fuel-planned"
  ].join("/");
}

function requestBody(
  profile, allowUnknown, from, to, history, maxPathMeters, directExtraBudgetMeters,
  logSnap = false
) {
  const options = {
    sessionSeed: SESSION_SEED,
    priorEdgeIds: [...history.edgeIDs],
    arrivalEdgeId: history.arrivalEdgeID,
    backtrackFactor: 4
  };
  if (Number.isFinite(maxPathMeters)) options.maxPathMeters = maxPathMeters;
  if (Number.isFinite(directExtraBudgetMeters)) options.directExtraBudgetMeters = directExtraBudgetMeters;
  if (logSnap) options.logSnap = true;
  return {
    profile: PROFILE_API[profile],
    locations: [from, to],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: allowUnknown
    },
    options
  };
}

function fuelBody(profile, allowUnknown, from, to, history, firstCap, requireStop, profileMeters, riderLegId, destinationFuelUsedLimitMeters, probe = false, excludedStationIds = [], windowTimeBudgetMs = 5_800) {
  return {
    profile: PROFILE_API[profile],
    locations: [from, to],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: allowUnknown
    },
    fuel: {
      usableRangeMeters: USABLE_METERS,
      firstLegMaxMeters: firstCap,
      requireFuelStopBeforeEnd: requireStop,
      profileMeters,
      riderLegId,
      destinationFuelUsedLimitMeters,
      probeFirstReachableStation: probe,
      excludedStationIds,
      windowTimeBudgetMs
    },
    options: {
      sessionSeed: SESSION_SEED,
      priorEdgeIds: [...history.edgeIDs],
      arrivalEdgeId: history.arrivalEdgeID,
      backtrackFactor: 4
    }
  };
}

function emptyHistory() {
  return { edgeIDs: new Set(), arrivalEdgeID: null };
}

function cloneHistory(history) {
  return { edgeIDs: new Set(history.edgeIDs), arrivalEdgeID: history.arrivalEdgeID };
}

function appendHistory(history, response) {
  for (const segment of response.segments || []) {
    if (segment.edgeId == null || segment.edgeId === "") continue;
    const edgeID = String(segment.edgeId);
    history.edgeIDs.add(edgeID);
    history.arrivalEdgeID = edgeID;
  }
}

async function timed(operation, timings) {
  const started = process.hrtime.bigint();
  const value = await operation();
  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  timings.push(ms);
  return value;
}

function requireComplete(response, label) {
  if (!response || response.status !== "complete" || !Number.isFinite(Number(response.distanceMeters))) {
    const reason = response && (response.error || response.message) || "invalid_response";
    throw new Error(`${label}: ${reason}`);
  }
  return response;
}

function routeFallback(response) {
  if (!response) return null;
  return response.debug && (response.debug.fallbackReason || response.debug.fallback)
    || response.backtrackReason
    || null;
}

function stopLocation(stop) {
  return { lat: Number(stop.lat ?? stop.latitude), lon: Number(stop.lon ?? stop.longitude) };
}

function summarizeResponses(responses, metadata) {
  const meters = responses.reduce((sum, response) => sum + Number(response.distanceMeters || 0), 0);
  const weighted = (field) => meters > 0
    ? responses.reduce((sum, response) => sum + Number(response.stats && response.stats[field] || 0) * Number(response.distanceMeters || 0), 0) / meters
    : 0;
  const backtrackMeters = responses.reduce((sum, response) => sum + Number(response.backtrackMeters || 0), 0);
  const fallbackReasons = [...new Set([
    ...responses.map(routeFallback).filter(Boolean),
    metadata.fallbackReason
  ].filter(Boolean))];
  return {
    status: "complete",
    meters: Math.round(meters),
    dirtPct: Math.round(weighted("dirtPercent") * 10) / 10,
    pavedPct: Math.round(weighted("pavedPercent") * 10) / 10,
    unknownPct: Math.round(weighted("unknownSurfacePercent") * 10) / 10,
    fuelStops: metadata.fuelStops,
    maxHopMeters: Math.round(Math.max(0, ...responses.map((response) => Number(response.distanceMeters || 0)))),
    backtrackPct: meters > 0 ? Math.round(backtrackMeters / meters * 1000) / 10 : 0,
    restrictedMeters: Math.round(responses.reduce((sum, response) => sum + Number(response.restrictedMeters || 0), 0)),
    lowDirt: responses.some((response) => response.lowDirt === true),
    fallbackReason: fallbackReasons.length ? fallbackReasons.join(",") : null,
    stationCandidates: {
      count: metadata.stationCandidateCount,
      chosenDirtPct: metadata.chosenDirtPct
    },
    ms: Math.round(metadata.totalMs),
    maxHopMs: Math.round(Math.max(0, ...metadata.timings)),
    shortestMeters: metadata.shortestMeters,
    urbanWall: metadata.urbanWall,
    fuelGap: metadata.fuelGap === true,
    gapReason: metadata.gapReason || null
  };
}

async function routeCase(item, shortestMeters) {
  const startedAt = Number(item._startedAt || Date.now());
  const timings = Array.isArray(item._timings) ? [...item._timings] : [];
  const points = locationsFor(item.route);
  const baseline = Array.isArray(item._baseline) ? item._baseline : [];
  const directLegBudget = item.profile === "direct" ? 15_000 / (points.length - 1) : undefined;

  if (!baseline.length) {
    const discoveryHistory = emptyHistory();
    for (let index = 0; index < points.length - 1; index += 1) {
      const response = requireComplete(await timed(
        () => routeRequest(requestBody(
          item.profile, item.allowUnknown, points[index], points[index + 1],
          discoveryHistory, undefined, directLegBudget,
          item.route.id === "through-halifax"
        )),
        timings
      ), `baseline leg ${index + 1}`);
      baseline[index] = response;
      appendHistory(discoveryHistory, response);
    }
  }

  // Route responses are reusable. Fuel decisions are not. Retry the forward
  // chain against the same cached routes under one itinerary-wide deadline.
  const fuelDeadline = Number(item._fuelDeadline || (Date.now() + 20_000));
  const retryContext = {
    _baseline: baseline,
    _timings: timings,
    _startedAt: startedAt,
    _fuelDeadline: fuelDeadline
  };

  if (!item.fuelOn) {
    return summarizeResponses(baseline, {
      fuelStops: 0,
      stationCandidateCount: 0,
      chosenDirtPct: [],
      timings,
      totalMs: Date.now() - startedAt,
      shortestMeters,
      urbanWall: urbanWallStatus(item, baseline)
    });
  }

  const responses = [];
  const finalHistory = emptyHistory();
  let fuelUsed = 0;
  let fuelStops = 0;
  let stationCandidateCount = 0;
  const chosenDirtPct = [];
  const selectedStopsByLeg = [];
  const firstReachable = [];

  // This bounded profile-route probe is the itinerary look-ahead pass. It
  // measures the first pump on each cached RiderLeg before any is selected.
  for (let index = 0; !item._disableLookahead && baseline.length > 1 && index < baseline.length; index += 1) {
    const remainingMs = Math.max(100, fuelDeadline - Date.now());
    const probe = await fuelChainRequest(fuelBody(
      item.profile, item.allowUnknown, points[index], points[index + 1],
      emptyHistory(), USABLE_METERS, false, Number(baseline[index].distanceMeters),
      `${item.route.id}:${index + 1}:probe`, null, true, [], Math.min(5_800, remainingMs)
    ), { loadFuelForLocations: loadBenchFuel });
    firstReachable[index] = Number(probe && probe.firstReachableStationMeters);
  }
  const onward = [];
  let tail = 0;
  for (let index = baseline.length - 1; index >= 0; index -= 1) {
    const through = Number(baseline[index].distanceMeters) + tail;
    onward[index] = Number.isFinite(firstReachable[index])
      ? Math.min(firstReachable[index], through)
      : through;
    tail = onward[index];
  }

  for (let index = 0; index < baseline.length; index += 1) {
    const from = points[index];
    const to = points[index + 1];
    const baselineMeters = Number(baseline[index].distanceMeters);
    const firstCap = Math.max(0, USABLE_METERS - fuelUsed);
    const destinationLimit = !item._disableLookahead && index + 1 < baseline.length
      ? Math.max(0, USABLE_METERS - onward[index + 1])
      : null;
    const requireStop = index === item._forceFuelLeg || baselineMeters > firstCap + 1
      || (Number.isFinite(destinationLimit) && fuelUsed + baselineMeters > destinationLimit + 1);

    if (baselineMeters <= firstCap + 1 && !requireStop) {
      responses.push(baseline[index]);
      fuelUsed += baselineMeters;
      appendHistory(finalHistory, baseline[index]);
      continue;
    }

    if (Date.now() >= fuelDeadline) {
      return summarizeFuelGap(item, baseline, responses, index, {
        fuelStops, stationCandidateCount, chosenDirtPct, timings, startedAt,
        shortestMeters, reason: "itinerary_fuel_time_budget"
      });
    }
    const chainStarted = process.hrtime.bigint();
    const chain = await fuelChainRequest(fuelBody(
        item.profile, item.allowUnknown, from, to, finalHistory, firstCap, requireStop,
        baselineMeters, `${item.route.id}:${index + 1}`,
        destinationLimit, false, (item._excludedStationsByLeg || {})[index] || [],
        Math.min(5_800, Math.max(100, fuelDeadline - Date.now()))
      ), { loadFuelForLocations: loadBenchFuel });
    const chainMs = Number(process.hrtime.bigint() - chainStarted) / 1e6;
    timings.push(Number(chain && chain.diagnostics && chain.diagnostics.maxHopMs) || chainMs);
    if (!chain || chain.status !== "complete") {
      if (index === 0 && !item._disableLookahead) {
        return routeCase({
          ...item, ...retryContext,
          _disableLookahead: true,
          _fuelBacktrackAttempt: 1
        }, shortestMeters);
      }
      if (index > 0 && Number(item._fuelBacktrackAttempt || 0) < 2) {
        const priorIndex = index - 1;
        const priorStops = selectedStopsByLeg[priorIndex] || [];
        const signature = priorStops.map((stop) => String(stop.id)).join(",");
        const priorSignatures = new Set(item._fuelStationSignatures || []);
        if (priorSignatures.has(signature)) {
          return summarizeFuelGap(item, baseline, responses, index, {
            fuelStops, stationCandidateCount, chosenDirtPct, timings, startedAt,
            shortestMeters,
            reason: `repeated_station_set:${signature || "empty"}`
          });
        }
        priorSignatures.add(signature);
        const priorLatest = priorStops[priorStops.length - 1];
        const excluded = { ...(item._excludedStationsByLeg || {}) };
        excluded[priorIndex] = [...(excluded[priorIndex] || [])];
        if (priorLatest && priorLatest.id != null) excluded[priorIndex].push(String(priorLatest.id));
        return routeCase({
          ...item, ...retryContext,
          _fuelBacktrackAttempt: Number(item._fuelBacktrackAttempt || 0) + 1,
          _fuelStationSignatures: [...priorSignatures],
          _excludedStationsByLeg: excluded,
          _forceFuelLeg: priorLatest ? item._forceFuelLeg : priorIndex
        }, shortestMeters);
      }
      const reason = chain && (chain.error || chain.message) || "no_fuel_chain";
      const directCandidates = chain && chain.stationCandidates;
      const attempted = Array.isArray(directCandidates) && directCandidates.length
        ? directCandidates
        : chain && chain.diagnostics && chain.diagnostics.stationCandidates;
      return summarizeFuelGap(item, baseline, responses, index, {
        fuelStops,
        stationCandidateCount: stationCandidateCount + (Array.isArray(attempted) ? attempted.length : 0),
        chosenDirtPct,
        timings,
        startedAt,
        shortestMeters,
        reason: `leg_${index + 1}:${reason}`
      });
    }
    stationCandidateCount += (chain.stationCandidates || []).length;
    const stops = chain.stops || [];
    selectedStopsByLeg[index] = stops;
    chosenDirtPct.push(...stops.map((stop) => Number(stop.dirtPercent)).filter(Number.isFinite));
    const hopPoints = [from, ...stops.map(stopLocation), to];
    for (let hop = 0; hop < hopPoints.length - 1; hop += 1) {
      const cap = hop === 0 ? firstCap : USABLE_METERS;
      const response = requireComplete(await timed(
        () => routeRequest(requestBody(
          item.profile, item.allowUnknown, hopPoints[hop], hopPoints[hop + 1], finalHistory, cap,
          item.profile === "direct" ? 0 : undefined
        )),
        timings
      ), `fuel leg ${index + 1} hop ${hop + 1}`);
      if (Number(response.distanceMeters) > cap + 1) throw new Error(`fuel hop exceeds cap: ${response.distanceMeters}`);
      responses.push(response);
      appendHistory(finalHistory, response);
      if (hop < stops.length) {
        fuelStops += 1;
        fuelUsed = 0;
      } else {
        fuelUsed += Number(response.distanceMeters);
      }
    }
  }

  return summarizeResponses(responses, {
    fuelStops,
    stationCandidateCount,
    chosenDirtPct,
    timings,
    totalMs: Date.now() - startedAt,
    shortestMeters,
    urbanWall: urbanWallStatus(item, responses)
  });
}

function summarizeFuelGap(item, baseline, completedResponses, failedLegIndex, metadata) {
  const drawable = [...completedResponses, ...baseline.slice(failedLegIndex)];
  return summarizeResponses(drawable, {
    fuelStops: metadata.fuelStops,
    stationCandidateCount: metadata.stationCandidateCount,
    chosenDirtPct: metadata.chosenDirtPct,
    timings: metadata.timings,
    totalMs: Date.now() - metadata.startedAt,
    shortestMeters: metadata.shortestMeters,
    urbanWall: urbanWallStatus(item, drawable),
    fallbackReason: `fuel_gap:${metadata.reason}`,
    fuelGap: true,
    gapReason: metadata.reason
  });
}

function urbanWallStatus(item, responses) {
  if (item.route.id !== "through-halifax" || item.profile !== "clean") return null;
  const labelled = responses.some((response) => response.debug && response.debug.fallback);
  return labelled ? "labelled_fallback" : "held";
}

const shortestCache = new Map();

async function shortestPathMeters(route, allowUnknown) {
  const key = `${route.id}:${allowUnknown ? 1 : 0}`;
  if (shortestCache.has(key)) return shortestCache.get(key);
  const points = locationsFor(route);
  let total = 0;
  for (let index = 0; index < points.length - 1; index += 1) {
    const body = {
      profile: "direct",
      locations: [points[index], points[index + 1]],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: allowUnknown }
    };
    const selection = resolveGraphRequest(body);
    const runtime = await loadGraphsForRequest(selection, { locations: body.locations, profile: "direct" });
    if (runtime.format !== "v2") throw new Error("NS shortest reference requires the live graph.v2 pack");
    const policy = normalizePolicy(body.accessPolicy, "direct");
    const start = matchPoint(runtime, points[index], policy, 250, new Set(), null, "direct", "start");
    const end = matchPoint(runtime, points[index + 1], policy, 250, new Set(), start.componentId, "direct", "end");
    if (!start.ok || !end.ok) throw new Error(`Shortest reference match failed for ${route.id} leg ${index + 1}`);
    const shortest = findPathV2(runtime, start, end, "direct", policy, new Set(), undefined, {
      costMode: "distance",
      corridorMeters: 0,
      hardCorridor: false,
      boundedSearch: false,
      cityWall: true,
      settlementWall: false,
      settlementFallback: false,
      progressRegressionMeters: Number.MAX_SAFE_INTEGER,
      sessionSeed: SESSION_SEED,
      variety: false
    });
    if (!shortest) throw new Error(`Shortest reference route failed for ${route.id} leg ${index + 1}`);
    total += Number(shortest.distanceMeters || 0);
  }
  const rounded = Math.round(total);
  shortestCache.set(key, rounded);
  return rounded;
}

function assertionsFor(item, result) {
  const checks = [];
  const add = (name, pass, detail) => checks.push({ name, pass: !!pass, detail });
  if (result.status !== "complete") {
    add("route complete", false, result.error || "failed");
    const limit = item.fuelOn ? 6000 : 4000;
    add(`≤${limit}ms per hop`, result.maxHopMs <= limit, `${result.maxHopMs}ms`);
    return checks;
  }
  if (item.profile === "dirt" && !item.allowUnknown && item.fuelOn) {
    if (!["through-halifax", "short-no-fuel"].includes(item.route.id)) {
      add("dirt ≥70", result.dirtPct >= 70, `${result.dirtPct}%`);
    }
    if (result.fuelGap) {
      add("fuel gap labelled", !!result.gapReason, result.gapReason || "missing reason");
    } else {
      add("fuel hops ≤237500", result.maxHopMeters <= USABLE_METERS, `${result.maxHopMeters}m`);
    }
  }
  if (item.fuelOn && result.fuelGap && !(item.profile === "dirt" && !item.allowUnknown)) {
    add("fuel gap labelled", !!result.gapReason, result.gapReason || "missing reason");
  }
  if (item.profile === "balanced") {
    add("balanced 45–55", result.dirtPct >= 45 && result.dirtPct <= 55, `${result.dirtPct}%`);
  }
  if (item.profile === "clean") {
    add("clean ≤15", result.dirtPct <= 15, `${result.dirtPct}%`);
    if (item.route.id === "through-halifax") {
      add("urban wall", ["held", "labelled_fallback"].includes(result.urbanWall), result.urbanWall || "unlabelled");
    }
  }
  if (item.profile === "direct") {
    add(
      "direct ≤shortest+15km",
      Number.isFinite(result.shortestMeters) && result.meters <= result.shortestMeters + 15_000,
      Number.isFinite(result.shortestMeters)
        ? `${result.meters}m vs ${result.shortestMeters}m`
        : (result.shortestError || "shortest reference unavailable")
    );
  }
  add(
    "no unexplained backtrack",
    result.backtrackPct === 0 || !!result.fallbackReason,
    result.backtrackPct === 0 ? "0%" : `${result.backtrackPct}% ${result.fallbackReason || "unexplained"}`
  );
  const limit = item.fuelOn ? 6000 : 4000;
  add(`≤${limit}ms per hop`, result.maxHopMs <= limit, `${result.maxHopMs}ms`);
  return checks;
}

function failureResult(error, elapsedMs) {
  const benchmark = error && error.benchmark || {};
  return {
    status: "failed",
    error: error && error.message ? error.message : String(error),
    meters: null,
    dirtPct: null,
    pavedPct: null,
    unknownPct: null,
    fuelStops: null,
    maxHopMeters: null,
    backtrackPct: null,
    restrictedMeters: null,
    lowDirt: null,
    fallbackReason: null,
    stationCandidates: {
      count: Number(benchmark.stationCandidateCount || 0),
      chosenDirtPct: []
    },
    ms: Math.round(elapsedMs),
    maxHopMs: Math.round(elapsedMs),
    shortestMeters: null,
    urbanWall: null
  };
}

function fmt(value, suffix = "") {
  return value == null ? "—" : `${value}${suffix}`;
}

function markdownReport(run) {
  const lines = [
    `# Nova Scotia routing benchmark`,
    ``,
    `Git \`${run.gitSha}\` · ${run.generatedAt} · seed \`${run.sessionSeed}\` · ${run.summary.passed}/${run.summary.total} cases green`,
    `Live source: \`${run.source.graphBase}/ns\``,
    ``,
    `| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |`,
    `| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |`
  ];
  for (const row of run.cases) {
    const failed = row.assertions.some((assertion) => !assertion.pass);
    const resultMark = failed ? "🔴" : "🟢";
    const assertionText = row.assertions.map((assertion) =>
      `${assertion.pass ? "✓" : "✗"} ${assertion.name}${assertion.pass ? "" : ` (${assertion.detail})`}`
    ).join("<br>");
    const chosen = row.stationCandidates.chosenDirtPct.length
      ? row.stationCandidates.chosenDirtPct.map((value) => `${value}%`).join(",")
      : "—";
    lines.push(
      `| ${resultMark} | \`${row.id}\` | ${row.meters == null ? "—" : (row.meters / 1000).toFixed(1)} | ` +
      `${fmt(row.dirtPct, "%")} | ${fmt(row.pavedPct, "%")} | ${fmt(row.unknownPct, "%")} | ` +
      `${fmt(row.fuelStops)} | ${row.maxHopMeters == null ? "—" : (row.maxHopMeters / 1000).toFixed(1)} km | ` +
      `${fmt(row.backtrackPct, "%")} | ${fmt(row.restrictedMeters, " m")} | ` +
      `${row.stationCandidates.count} / ${chosen} | ${fmt(row.ms)} | ${assertionText} |`
    );
  }
  lines.push("", failedSummary(run));
  return `${lines.join("\n")}\n`;
}

function failedSummary(run) {
  const failed = run.cases.filter((row) => row.assertions.some((assertion) => !assertion.pass));
  if (!failed.length) return "All reported assertions are green.";
  return `Red rows: ${failed.map((row) => `\`${row.id}\``).join(", ")}. These are measurements, not blocked tests.`;
}

function resolveComparisonPath(revision, currentPath) {
  const sha = git("rev-parse", "--short", revision);
  const matches = fs.readdirSync(RESULTS_DIR)
    .filter((name) => name.endsWith(".json") && name !== path.basename(currentPath) && name.startsWith(`${sha}-`))
    .sort()
    .reverse();
  if (!matches.length) throw new Error(`No benchmark result found for ${revision} (${sha})`);
  return path.join(RESULTS_DIR, matches[0]);
}

function delta(current, prior) {
  if (!Number.isFinite(current) || !Number.isFinite(prior)) return "—";
  const value = Math.round((current - prior) * 10) / 10;
  return value > 0 ? `+${value}` : `${value}`;
}

function comparisonTable(current, prior) {
  const priorByID = new Map(prior.cases.map((row) => [row.id, row]));
  const lines = [
    `Comparison ${current.gitSha} vs ${prior.gitSha}`,
    `| Case | Δm | Δdirt | Δpaved | Δunknown | Δstops | ΔmaxHop | Δbacktrack | Δrestricted | Δcandidates | Δchosen dirt | Δms | Assertions |`,
    `| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |`
  ];
  for (const row of current.cases) {
    const legacyFuelOnID = row.id.replace(/\/fuel-planned$/, "/fuel-on");
    const before = priorByID.get(row.id) || priorByID.get(legacyFuelOnID);
    if (!before) continue;
    const chosenNow = row.stationCandidates.chosenDirtPct[0];
    const chosenBefore = before.stationCandidates.chosenDirtPct[0];
    const checks = row.assertions.map((assertion) => `${assertion.pass ? "✓" : "✗"} ${assertion.name}`).join("<br>");
    lines.push(
      `| \`${row.id}\` | ${delta(row.meters, before.meters)} | ${delta(row.dirtPct, before.dirtPct)} | ` +
      `${delta(row.pavedPct, before.pavedPct)} | ${delta(row.unknownPct, before.unknownPct)} | ` +
      `${delta(row.fuelStops, before.fuelStops)} | ${delta(row.maxHopMeters, before.maxHopMeters)} | ` +
      `${delta(row.backtrackPct, before.backtrackPct)} | ${delta(row.restrictedMeters, before.restrictedMeters)} | ` +
      `${delta(row.stationCandidates.count, before.stationCandidates.count)} | ${delta(chosenNow, chosenBefore)} | ` +
      `${delta(row.ms, before.ms)} | ${checks} |`
    );
  }
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return usage();
  const routes = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf8"));
  validateFixtures(routes);
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const gitSha = git("rev-parse", "--short", "HEAD");
  const generatedAt = new Date().toISOString();
  const rows = [];
  const cases = benchmarkCases(routes);

  for (let index = 0; index < cases.length; index += 1) {
    const item = cases[index];
    const id = caseID(item);
    process.stderr.write(`[${index + 1}/${cases.length}] ${id}\n`);
    const started = process.hrtime.bigint();
    let result;
    try {
      let shortest = null;
      let shortestError = null;
      if (item.profile === "direct") {
        try {
          shortest = await shortestPathMeters(item.route, item.allowUnknown);
        } catch (error) {
          shortestError = error && error.message ? error.message : String(error);
        }
      }
      result = await routeCase(item, shortest);
      if (shortestError) result.shortestError = shortestError;
      if (item.profile === "dirt" && Number.isFinite(result.dirtPct) && result.dirtPct < 70) {
        result.lowDirt = true;
      }
    } catch (error) {
      result = failureResult(error, Number(process.hrtime.bigint() - started) / 1e6);
    }
    rows.push({
      id,
      routeID: item.route.id,
      profile: item.profile,
      allowUnknown: item.allowUnknown,
      fuelOn: item.fuelOn,
      ...result,
      assertions: assertionsFor(item, result)
    });
  }

  const passed = rows.filter((row) => row.assertions.every((assertion) => assertion.pass)).length;
  const run = {
    schemaVersion: 1,
    gitSha,
    generatedAt,
    sessionSeed: SESSION_SEED,
    source: {
      region: "ns",
      graphBase: graphCdnBaseUrlForRegion("ns"),
      releaseRecord: path.relative(REPO_ROOT, NS_RELEASE_PATH)
    },
    fuel: { tankMeters: 250_000, reservePercent: 5, usableMeters: USABLE_METERS },
    summary: { total: rows.length, passed, failed: rows.length - passed },
    cases: rows
  };
  const timestamp = generatedAt.replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  const resultPath = path.join(RESULTS_DIR, `${gitSha}-${timestamp}.json`);
  fs.writeFileSync(resultPath, `${JSON.stringify(run, null, 2)}\n`);
  fs.writeFileSync(LATEST_PATH, markdownReport(run));
  console.log(`Wrote ${path.relative(REPO_ROOT, resultPath)}`);
  console.log(`Wrote ${path.relative(REPO_ROOT, LATEST_PATH)}`);
  console.log(`${passed}/${rows.length} cases green; failures are reported, not thrown.`);

  if (args.compare) {
    const priorPath = resolveComparisonPath(args.compare, resultPath);
    const prior = JSON.parse(fs.readFileSync(priorPath, "utf8"));
    console.log("");
    console.log(comparisonTable(run, prior));
  }
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
