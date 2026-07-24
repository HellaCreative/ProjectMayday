#!/usr/bin/env node
"use strict";

/**
 * Saskatchewan acceptance smoke ODs (Phase 1 OSM-only — permanent).
 *
 * Usage:
 *   node scripts/smoke-sk-routes.js
 *   ROUTING_SMOKE_BASE=https://dirt-mayday.vercel.app node scripts/smoke-sk-routes.js
 */

const BASE = process.env.ROUTING_SMOKE_BASE || "";

const CASES = [
  {
    name: "Regina → Moose Jaw (balanced, in-SK)",
    body: {
      profile: "balanced",
      locations: [
        { lat: 50.445, lon: -104.618 },
        { lat: 50.4, lon: -105.55 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [50, 120]
  },
  {
    name: "Saskatoon → Regina (cleanest)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 52.133, lon: -106.67 },
        { lat: 50.445, lon: -104.618 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [220, 400]
  },
  {
    name: "Brandon → Regina (cleanest, MB→SK)",
    body: {
      profile: "cleanest",
      locations: [
        { lat: 49.85, lon: -99.95 },
        { lat: 50.445, lon: -104.618 }
      ],
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    },
    expectKm: [300, 550]
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
    console.error(`${failed} required SK smoke(s) failed`);
    process.exit(1);
  }
  console.log("SK smoke complete");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
