#!/usr/bin/env node
"use strict";

/**
 * Alberta acceptance smoke ODs (Phase 1 OSM-only).
 *
 * Usage:
 *   node scripts/smoke-ab-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-ab-routes.js
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Calgary north ring → Banff (balanced, in-AB)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 51.15, lon: -114.1 },
        { lat: 51.18, lon: -115.57 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [100, 200]
  },
  {
    name: "Edmonton → Red Deer (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 53.547, lon: -113.491 },
        { lat: 52.27, lon: -113.82 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [120, 220]
  },
  {
    name: "Maple Creek → Medicine Hat (cleanest, SK→AB)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 49.91, lon: -109.48 },
        { lat: 50.04, lon: -110.68 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [60, 180]
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
    console.error(`${failed} required AB smoke(s) failed`);
    process.exit(1);
  }
  console.log("AB smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
