#!/usr/bin/env node
"use strict";

/**
 * Manitoba acceptance smoke ODs (Phase 1 OSM-only).
 *
 * Usage:
 *   node scripts/smoke-mb-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-mb-routes.js
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Winnipeg west ring → Brandon (balanced, in-MB)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 49.9, lon: -97.3 },
        { lat: 49.85, lon: -99.95 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [150, 320]
  },
  {
    name: "Portage → Winnipeg (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 49.97, lon: -98.29 },
        { lat: 49.9, lon: -97.2 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [60, 140]
  },
  {
    name: "Kenora TCH → Winnipeg (cleanest, ON→MB)",
    body: {
      profile: "cleanest",
      locations: [
        // Hwy 17 west of Kenora downtown — avoid sparse service-dropped snaps
        { lat: 49.77, lon: -94.55 },
        { lat: 49.9, lon: -97.2 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [150, 350]
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
    console.error(`${failed} required MB smoke(s) failed`);
    process.exit(1);
  }
  console.log("MB smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
