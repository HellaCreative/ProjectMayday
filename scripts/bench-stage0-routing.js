#!/usr/bin/env node
"use strict";

/**
 * Stage 0 benchmarks: short / mid / NS-BC, cold+warm, flags off vs on.
 * Equality surface: status, distanceMeters, geometry, segments (id/surface/length), stats percents.
 */
const { clearGraphCache, resetCacheStats } = require("../routing/lib/graph");
const { routeRequest } = require("../routing/lib/router");

const SHORT = {
  name: "short-ns",
  locations: [
    { lat: 44.6488, lon: -63.575 },
    { lat: 44.67, lon: -63.6 }
  ]
};
const MID = {
  name: "mid-hfx-yarmouth",
  locations: [
    { lat: 44.6488, lon: -63.575 },
    { lat: 43.8361, lon: -66.1209 }
  ]
};
const LONG = {
  name: "ns-bc",
  locations: [
    { lat: 44.6488, lon: -63.575 },
    { lat: 49.2827, lon: -123.1207 }
  ]
};

function equalitySlice(r) {
  return {
    status: r.status,
    distanceMeters: r.distanceMeters,
    geometryLen: (r.geometry || []).length,
    geometryHead: (r.geometry || []).slice(0, 2),
    geometryTail: (r.geometry || []).slice(-2),
    segmentSig: (r.segments || []).map((s) => [
      String(s.edgeId),
      s.surfaceClass,
      s.distanceMeters
    ]),
    stats: r.stats
      ? {
          pavedPercent: r.stats.pavedPercent,
          gravelPercent: r.stats.gravelPercent,
          accessPercent: r.stats.accessPercent,
          trackPercent: r.stats.trackPercent,
          hops: r.stats.hops,
          hopKm: r.stats.hopKm
        }
      : null
  };
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

async function once(label, locs, profile) {
  clearGraphCache();
  resetCacheStats();
  const t0 = Date.now();
  const r = await routeRequest({
    profile: profile || "cleanest",
    locations: locs,
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { matchLimitMeters: 500 }
  });
  const ms = Date.now() - t0;
  return {
    label,
    ms,
    status: r.status,
    error: r.error,
    km: r.distanceMeters != null ? Math.round(r.distanceMeters / 1000) : null,
    searchMs: (r.stats && r.stats.searchMs) || (r.debug && r.debug.searchMs) || null,
    packLoads: (r.stats && r.stats.packLoads) != null ? r.stats.packLoads : (r.debug && r.debug.cache && r.debug.cache.loads),
    packHits: (r.stats && r.stats.packCacheHits) != null ? r.stats.packCacheHits : (r.debug && r.debug.cache && r.debug.cache.hits),
    inflateMs: (r.stats && r.stats.inflateMs) != null ? r.stats.inflateMs : (r.debug && r.debug.cache && r.debug.cache.inflateMs),
    mode: r.debug && r.debug.graphMode,
    slice: equalitySlice(r),
    raw: r
  };
}

async function coldWarm(name, locs, profile) {
  const cold = await once(name + "-cold", locs, profile);
  const warm = await once(name + "-warm", locs, profile);
  return { cold, warm };
}

async function main() {
  const flag = process.env.ROUTING_CHAIN_CACHE === "1" ? "on" : "off";
  console.log(JSON.stringify({ env: "local-node", node: process.version, ROUTING_CHAIN_CACHE: flag }, null, 2));

  const results = {};
  for (const suite of [SHORT, MID, LONG]) {
    results[suite.name] = await coldWarm(suite.name, suite.locations, "cleanest");
    console.log(
      suite.name,
      "cold",
      results[suite.name].cold.ms + "ms",
      "warm",
      results[suite.name].warm.ms + "ms",
      "status",
      results[suite.name].cold.status,
      "km",
      results[suite.name].cold.km,
      "loads/hits",
      results[suite.name].cold.packLoads + "/" + results[suite.name].cold.packHits,
      "searchMs",
      results[suite.name].cold.searchMs,
      "inflateMs",
      results[suite.name].cold.inflateMs
    );
  }

  if (process.env.STAGE0_BASELINE_FILE) {
    const fs = require("fs");
    const base = JSON.parse(fs.readFileSync(process.env.STAGE0_BASELINE_FILE, "utf8"));
    const parity = {};
    for (const key of Object.keys(results)) {
      parity[key] = deepEqual(base[key].cold.slice, results[key].cold.slice);
    }
    console.log("PARITY_VS_BASELINE", JSON.stringify(parity));
  }

  const out = process.env.STAGE0_OUT || null;
  if (out) {
    const fs = require("fs");
    const slim = {};
    for (const [k, v] of Object.entries(results)) {
      slim[k] = {
        cold: { ...v.cold, raw: undefined },
        warm: { ...v.warm, raw: undefined }
      };
      // keep slice for parity
      slim[k].cold.slice = v.cold.slice;
      slim[k].warm.slice = v.warm.slice;
    }
    fs.writeFileSync(out, JSON.stringify(slim, null, 2));
    console.log("wrote", out);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
