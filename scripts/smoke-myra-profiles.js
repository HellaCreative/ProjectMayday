#!/usr/bin/env node
"use strict";

/**
 * Myra A→B profile matrix harness.
 * Fixed OD × Clean/Direct/Balanced/Dirt × Allow off/on.
 * Asserts Clean stays paved even with Allow on; adventure profiles diverge.
 *
 * Run: node --max-old-space-size=4096 scripts/smoke-myra-profiles.js
 */

const { routeRequest } = require("../routing/lib/router");

// Myra Rd (Porters Lake) → Fall River / Hwy 2 corridor (snap-safe paved hub).
const MYRA = { lat: 44.746, lon: -63.321, label: "Myra" };
const FALL_RIVER = { lat: 44.8175, lon: -63.6125, label: "Fall River Hwy2" };

const PROFILES = ["cleanest", "direct", "balanced", "dirt"];
const ALLOWS = [false, true];

function pct(n) {
  return n == null || !Number.isFinite(n) ? "—" : String(Math.round(n));
}

function km(meters) {
  if (!Number.isFinite(meters)) return "—";
  return (meters / 1000).toFixed(1);
}

async function runOne(profile, allow) {
  const t0 = Date.now();
  const r = await routeRequest({
    profile,
    locations: [MYRA, FALL_RIVER],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: allow
    },
    options: { matchLimitMeters: 500 }
  });
  const stats = r.stats || {};
  return {
    profile,
    allow,
    status: r.status,
    error: r.error || null,
    message: r.message || null,
    ms: Date.now() - t0,
    km: Number.isFinite(r.distanceMeters) ? r.distanceMeters / 1000 : null,
    dirt: stats.dirtPercent,
    paved: stats.pavedPercent,
    unk: stats.unknownAccessPercent,
    softStitch: (r.debug && r.debug.softStitchCount) || 0,
    accessPolicy: r.accessPolicy || null
  };
}

function assert(cond, msg, failures) {
  if (!cond) failures.push(msg);
}

function runAsserts(rows) {
  const failures = [];
  const byKey = new Map();
  for (const row of rows) byKey.set(row.profile + ":" + row.allow, row);

  const cleanOn = byKey.get("cleanest:true");
  const cleanOff = byKey.get("cleanest:false");
  const directOn = byKey.get("direct:true");
  const dirtOn = byKey.get("dirt:true");
  const balOn = byKey.get("balanced:true");

  for (const row of rows) {
    assert(row.status === "complete", `${row.profile} allow=${row.allow} incomplete: ${row.status} ${row.message || ""}`, failures);
  }

  if (cleanOn && cleanOn.status === "complete") {
    assert(
      (cleanOn.dirt == null || cleanOn.dirt < 15) || (cleanOn.paved != null && cleanOn.paved > 85),
      `Clean+Allow should stay highway-ish (dirt%<15 or paved%>85); got dirt=${cleanOn.dirt} paved=${cleanOn.paved}`,
      failures
    );
    assert(
      (cleanOn.unk == null || cleanOn.unk === 0),
      `Clean+Allow must have 0 unk-access% (law); got ${cleanOn.unk}`,
      failures
    );
    assert(
      cleanOn.softStitch === 0,
      `Clean+Allow must not soft-stitch; got ${cleanOn.softStitch}`,
      failures
    );
    if (cleanOn.accessPolicy) {
      assert(
        cleanOn.accessPolicy.motorizedUnknown === false,
        `Clean+Allow response policy must force motorizedUnknown=false; got ${JSON.stringify(cleanOn.accessPolicy)}`,
        failures
      );
    }
  }

  if (cleanOff && cleanOff.status === "complete") {
    assert(
      (cleanOff.unk == null || cleanOff.unk === 0),
      `Clean+Allow-off must have 0 unk-access%; got ${cleanOff.unk}`,
      failures
    );
  }

  if (dirtOn && directOn && dirtOn.status === "complete" && directOn.status === "complete") {
    const dirtDirtier =
      (dirtOn.dirt != null && directOn.dirt != null && dirtOn.dirt > directOn.dirt) ||
      (dirtOn.unk != null && directOn.unk != null && dirtOn.unk > directOn.unk) ||
      (dirtOn.km != null && directOn.km != null && dirtOn.km > directOn.km * 1.02);
    assert(
      dirtDirtier,
      `Dirt+Allow should be dirtier/longer/more-unk than Direct+Allow (dirt ${dirtOn.dirt} vs ${directOn.dirt}, unk ${dirtOn.unk} vs ${directOn.unk}, km ${dirtOn.km} vs ${directOn.km})`,
      failures
    );
    assert(
      dirtOn.km != null && directOn.km != null && directOn.km <= dirtOn.km * 1.05,
      `Direct+Allow should be shorter than (or ~equal) Dirt+Allow; got Direct ${directOn.km} vs Dirt ${dirtOn.km}`,
      failures
    );
  }

  if (balOn && directOn && dirtOn && balOn.status === "complete") {
    // Soft band when Dirt and Direct actually separate on dirt%.
    if (
      balOn.dirt != null &&
      directOn.dirt != null &&
      dirtOn.dirt != null &&
      dirtOn.dirt > directOn.dirt + 5
    ) {
      assert(
        balOn.dirt >= directOn.dirt - 5 && balOn.dirt <= dirtOn.dirt + 5,
        `Balanced+Allow dirt% should sit between Direct and Dirt (±5); got B=${balOn.dirt} D=${directOn.dirt} Dirt=${dirtOn.dirt}`,
        failures
      );
    }
  }

  // Allow on must open capillary for adventure (vs Allow off on same profile).
  for (const profile of ["direct", "balanced", "dirt"]) {
    const off = byKey.get(profile + ":false");
    const on = byKey.get(profile + ":true");
    if (!off || !on || off.status !== "complete" || on.status !== "complete") continue;
    const opened =
      (on.unk || 0) > (off.unk || 0) + 2 ||
      (on.dirt || 0) > (off.dirt || 0) + 5;
    assert(
      opened,
      `${profile}: Allow on should raise dirt% or unk% vs off (off dirt=${off.dirt} unk=${off.unk}; on dirt=${on.dirt} unk=${on.unk})`,
      failures
    );
  }

  return failures;
}

async function main() {
  console.log("Myra profile matrix");
  console.log(`OD: ${MYRA.label} (${MYRA.lat},${MYRA.lon}) → ${FALL_RIVER.label} (${FALL_RIVER.lat},${FALL_RIVER.lon})`);
  console.log("");

  const rows = [];
  for (const profile of PROFILES) {
    for (const allow of ALLOWS) {
      process.stdout.write(`  ${profile} allow=${allow ? "on " : "off"}… `);
      const row = await runOne(profile, allow);
      rows.push(row);
      console.log(
        row.status === "complete"
          ? `${km(row.km * 1000)} km  dirt ${pct(row.dirt)}%  paved ${pct(row.paved)}%  unk ${pct(row.unk)}%  (${row.ms}ms)`
          : `FAIL ${row.status} ${row.message || row.error || ""}`
      );
    }
  }

  console.log("");
  console.log(
    [
      "profile".padEnd(10),
      "allow".padEnd(6),
      "km".padStart(7),
      "dirt%".padStart(7),
      "paved%".padStart(8),
      "unk%".padStart(6),
      "stitch".padStart(7),
      "ms".padStart(7)
    ].join(" ")
  );
  console.log("-".repeat(64));
  for (const row of rows) {
    console.log(
      [
        row.profile.padEnd(10),
        (row.allow ? "on" : "off").padEnd(6),
        km(row.km != null ? row.km * 1000 : null).padStart(7),
        pct(row.dirt).padStart(7),
        pct(row.paved).padStart(8),
        pct(row.unk).padStart(6),
        String(row.softStitch).padStart(7),
        String(row.ms).padStart(7)
      ].join(" ")
    );
  }

  const failures = runAsserts(rows);
  console.log("");
  if (failures.length) {
    console.error("ASSERT FAIL:");
    for (const f of failures) console.error(" -", f);
    process.exitCode = 1;
  } else {
    console.log("ASSERT PASS: Clean immune to Allow; adventure profiles diverge.");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
