#!/usr/bin/env node
"use strict";

/**
 * British Columbia acceptance smoke ODs (Phase 1 OSM-only).
 *
 * Usage:
 *   node scripts/smoke-bc-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-bc-routes.js
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Vancouver north ring → Chilliwack (balanced, in-BC)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 49.32, lon: -123.05 },
        { lat: 49.17, lon: -121.95 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [80, 200]
  },
  {
    name: "Kamloops → Kelowna (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 50.67, lon: -120.33 },
        { lat: 49.888, lon: -119.496 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [100, 220]
  },
  {
    name: "Banff → Golden (cleanest, AB→BC)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 51.18, lon: -115.57 },
        { lat: 51.3, lon: -116.96 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [80, 220]
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
    console.error(`${failed} required BC smoke(s) failed`);
    process.exit(1);
  }
  console.log("BC smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
