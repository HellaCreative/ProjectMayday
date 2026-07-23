#!/usr/bin/env node
"use strict";

/**
 * Quebec acceptance smoke ODs (Provincial Build Guide / DIRT-MAP-A-PROVINCE).
 *
 * Usage:
 *   node scripts/smoke-qc-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-qc-routes.js
 *
 * Local default hits routeRequest in-process (uses longhaul packs under VERCEL=1).
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Beauce → west Montréal (balanced, in-QC)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 46.12, lon: -70.67 },
        { lat: 45.65, lon: -74.35 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [250, 700]
  },
  {
    name: "Gatineau → Mont-Tremblant (direct)",
    body: {
      profile: "direct",
      locations: [
        { lat: 45.48, lon: -75.7 },
        { lat: 46.12, lon: -74.6 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [80, 280]
  },
  {
    name: "Roberval → Chicoutimi (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 48.52, lon: -72.23 },
        { lat: 48.428, lon: -71.068 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [50, 200]
  },
  {
    name: "Fredericton → Québec City (cleanest, NB→QC)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 45.963, lon: -66.643 },
        { lat: 46.813, lon: -71.208 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [400, 900]
  },
  {
    name: "New Glasgow → Québec City (cleanest, NS→QC)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 45.59, lon: -62.65 },
        { lat: 46.813, lon: -71.208 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [800, 1800],
    optional: true
  }
];

async function runOne(c) {
  const started = Date.now();
  let result;
  if (BASE) {
    const res = await fetch(BASE.replace(/\/$/, "") + "/api/route", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(c.body)
    });
    result = await res.json();
  } else {
    process.env.VERCEL = process.env.VERCEL || "1";
    const { routeRequest } = require("../routing/lib/router");
    result = await routeRequest(c.body);
  }
  const ms = Date.now() - started;
  const km = (result.distanceMeters || 0) / 1000;
  const ok =
    result.status === "complete" &&
    km >= c.expectKm[0] &&
    km <= c.expectKm[1];
  return {
    name: c.name,
    ok,
    optional: !!c.optional,
    status: result.status,
    error: result.error,
    message: result.message,
    km: km ? Math.round(km * 10) / 10 : null,
    ms,
    regionIds: result.debug && result.debug.regionIds
  };
}

async function main() {
  let failed = 0;
  for (const c of CASES) {
    const r = await runOne(c);
    const mark = r.ok ? "PASS" : r.optional ? "LIMIT" : "FAIL";
    if (!r.ok && !r.optional) failed += 1;
    console.log(
      `${mark}  ${r.name}  status=${r.status} km=${r.km} ${r.ms}ms` +
        (r.regionIds ? ` regions=${JSON.stringify(r.regionIds)}` : "") +
        (r.error ? ` error=${r.error}` : "") +
        (r.message ? ` msg=${String(r.message).slice(0, 120)}` : "")
    );
  }
  if (failed) {
    console.error(`${failed} required QC smoke(s) failed`);
    process.exit(1);
  }
  console.log("QC smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
