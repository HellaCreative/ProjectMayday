#!/usr/bin/env node
"use strict";

/**
 * Ontario acceptance smoke ODs (Phase 1 OSM-only).
 *
 * Usage:
 *   node scripts/smoke-on-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-on-routes.js
 *
 * Local default hits routeRequest in-process (uses longhaul packs under VERCEL=1).
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Ottawa → Kingston (balanced, in-ON)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 45.421, lon: -75.697 },
        { lat: 44.23, lon: -76.5 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [120, 320]
  },
  {
    name: "Toronto north ring → Barrie (direct)",
    body: {
      profile: "direct",
      locations: [
        { lat: 43.85, lon: -79.4 },
        { lat: 44.39, lon: -79.69 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [40, 150]
  },
  {
    name: "Sudbury → Sault Ste. Marie (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 46.49, lon: -81.0 },
        { lat: 46.52, lon: -84.35 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [250, 450]
  },
  {
    name: "Gatineau → Ottawa west (cleanest, QC→ON)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 45.48, lon: -75.7 },
        { lat: 45.35, lon: -75.9 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [15, 80]
  },
  {
    name: "Sherbrooke → Kingston (cleanest, QC→ON)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 45.4, lon: -71.93 },
        { lat: 44.23, lon: -76.5 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [350, 700]
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
    console.error(`${failed} required ON smoke(s) failed`);
    process.exit(1);
  }
  console.log("ON smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
