#!/usr/bin/env node
"use strict";

/**
 * Myra A→B profile matrix harness (+ optional long NS OD).
 * Fixed OD × Clean/Direct/Balanced/Dirt × Allow off/on.
 * Asserts Clean stays paved even with Allow on; adventure profiles diverge;
 * Direct has no large lat overshoot past B; Clean/adventure no end U-turn.
 * Long OD (New Glasgow → Yarmouth) checks Balanced+Allow lands ~40–60 dirt%
 * and does not clone Direct’s crow-flies purple cut.
 *
 * Run: node --max-old-space-size=4096 scripts/smoke-myra-profiles.js
 * Skip long: SKIP_LONG_OD=1 node --max-old-space-size=4096 scripts/smoke-myra-profiles.js
 */

const { routeRequest } = require("../routing/lib/router");

// Myra Rd (Porters Lake) → Fall River / Hwy 2 corridor (snap-safe paved hub).
const MYRA = { lat: 44.746, lon: -63.321, label: "Myra" };
const FALL_RIVER = { lat: 44.8175, lon: -63.6125, label: "Fall River Hwy2" };

// User Allow-on gold: New Glasgow → SW NS (Yarmouth).
const NEW_GLASGOW = { lat: 45.5936, lon: -62.6486, label: "New Glasgow" };
const YARMOUTH = { lat: 43.8375, lon: -66.1174, label: "Yarmouth" };

const PROFILES = ["cleanest", "direct", "balanced", "dirt"];
const ALLOWS = [false, true];
const RUN_LONG = process.env.SKIP_LONG_OD !== "1";

function pct(n) {
  return n == null || !Number.isFinite(n) ? "—" : String(Math.round(n));
}

function km(meters) {
  if (!Number.isFinite(meters)) return "—";
  return (meters / 1000).toFixed(1);
}

function haversineMeters(a, b) {
  const R = 6371000;
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function geometryMetrics(geometry, dest) {
  if (!geometry || !geometry.length) {
    return { latOvershootM: null, metersAfterClosest: null, reverseNearEnd: null };
  }
  const destLL = [dest.lon, dest.lat];
  let maxLat = -Infinity;
  let bestI = 0;
  let bestD = Infinity;
  for (let i = 0; i < geometry.length; i += 1) {
    const c = geometry[i];
    if (c[1] > maxLat) maxLat = c[1];
    const d = haversineMeters(c, destLL);
    if (d < bestD) {
      bestD = d;
      bestI = i;
    }
  }
  let metersAfterClosest = 0;
  for (let i = bestI + 1; i < geometry.length; i += 1) {
    metersAfterClosest += haversineMeters(geometry[i - 1], geometry[i]);
  }
  // U-turn: distance-to-B rises then falls again in the last ~1.5 km of path.
  let along = 0;
  const tail = [];
  for (let i = geometry.length - 1; i > 0 && along < 1500; i -= 1) {
    along += haversineMeters(geometry[i - 1], geometry[i]);
    tail.push(haversineMeters(geometry[i], destLL));
  }
  tail.reverse();
  let sawIncrease = false;
  let reverseNearEnd = false;
  for (let i = 1; i < tail.length; i += 1) {
    if (tail[i] > tail[i - 1] + 40) sawIncrease = true;
    if (sawIncrease && tail[i] < tail[i - 1] - 40) {
      reverseNearEnd = true;
      break;
    }
  }
  return {
    latOvershootM: Math.max(0, (maxLat - dest.lat) * 111320),
    metersAfterClosest,
    reverseNearEnd,
    closestM: bestD
  };
}

async function runOne(profile, allow, origin, dest) {
  const t0 = Date.now();
  const r = await routeRequest({
    profile,
    locations: [origin, dest],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: allow
    },
    options: { matchLimitMeters: 500 }
  });
  const stats = r.stats || {};
  const geom = geometryMetrics(r.geometry, dest);
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
    accessPolicy: r.accessPolicy || null,
    latOvershootM: geom.latOvershootM,
    metersAfterClosest: geom.metersAfterClosest,
    reverseNearEnd: geom.reverseNearEnd
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
    assert(
      row.status === "complete",
      `${row.profile} allow=${row.allow} incomplete: ${row.status} ${row.message || ""}`,
      failures
    );
  }

  if (cleanOn && cleanOn.status === "complete") {
    assert(
      (cleanOn.dirt == null || cleanOn.dirt < 15) ||
        (cleanOn.paved != null && cleanOn.paved > 85),
      `Clean+Allow should stay highway-ish (dirt%<15 or paved%>85); got dirt=${cleanOn.dirt} paved=${cleanOn.paved}`,
      failures
    );
    assert(
      cleanOn.unk == null || cleanOn.unk === 0,
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
      cleanOff.unk == null || cleanOff.unk === 0,
      `Clean+Allow-off must have 0 unk-access%; got ${cleanOff.unk}`,
      failures
    );
  }

  // No destination U-turn / overshoot for any profile.
  for (const row of rows) {
    if (row.status !== "complete") continue;
    assert(
      row.metersAfterClosest == null || row.metersAfterClosest < 200,
      `${row.profile} allow=${row.allow} end overshoot: ${Math.round(row.metersAfterClosest)} m after closest approach to B`,
      failures
    );
    assert(
      !row.reverseNearEnd,
      `${row.profile} allow=${row.allow} reverse/U-turn near destination`,
      failures
    );
  }

  if (directOn && directOn.status === "complete") {
    assert(
      directOn.latOvershootM == null || directOn.latOvershootM < 2500,
      `Direct+Allow should not jog far north of B (lat overshoot ${Math.round(directOn.latOvershootM)} m)`,
      failures
    );
  }

  if (balOn && balOn.status === "complete" && balOn.allow) {
    assert(
      balOn.latOvershootM == null || balOn.latOvershootM < 2500,
      `Balanced+Allow should not clone Dirt’s north tourism spur (lat overshoot ${Math.round(balOn.latOvershootM)} m)`,
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
    assert(
      balOn.km != null &&
        directOn.km != null &&
        directOn.km <= balOn.km * 1.08,
      `Direct+Allow length should be ≤ Balanced+Allow; got Direct ${directOn.km} vs Balanced ${balOn.km}`,
      failures
    );
    // Soft ~40–60% dirt band when Allow on and fabric can deliver mix.
    if (balOn.dirt != null && balOn.unk != null && balOn.unk > 5) {
      assert(
        balOn.dirt >= 25 && balOn.dirt <= 70,
        `Balanced+Allow dirt% should sit ~40–60 (band 25–70); got ${balOn.dirt}`,
        failures
      );
    }
    // Must not clone Direct when Dirt actually separates AND fabric can deliver
    // a mid mix (Direct already dirt-rich or Balanced opened meaningful unk).
    // Short paved-leaning ODs may share Direct’s line at low dirt% — that is OK.
    if (
      balOn.dirt != null &&
      directOn.dirt != null &&
      dirtOn.dirt != null &&
      dirtOn.dirt > directOn.dirt + 8 &&
      ((directOn.dirt || 0) >= 25 || (balOn.unk || 0) > 8)
    ) {
      const sameSpine =
        Math.abs(balOn.km - directOn.km) < 0.4 &&
        Math.abs(balOn.dirt - directOn.dirt) < 4;
      assert(
        !sameSpine,
        `Balanced+Allow must not clone Direct+Allow (km ${balOn.km}/${directOn.km}, dirt ${balOn.dirt}/${directOn.dirt})`,
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
      (on.unk || 0) > (off.unk || 0) + 2 || (on.dirt || 0) > (off.dirt || 0) + 5;
    assert(
      opened,
      `${profile}: Allow on should raise dirt% or unk% vs off (off dirt=${off.dirt} unk=${off.unk}; on dirt=${on.dirt} unk=${on.unk})`,
      failures
    );
  }

  return failures;
}

function runLongOdAsserts(rows) {
  const failures = [];
  const byKey = new Map();
  for (const row of rows) byKey.set(row.profile + ":" + row.allow, row);

  const balOn = byKey.get("balanced:true");
  const directOn = byKey.get("direct:true");
  const dirtOn = byKey.get("dirt:true");
  const cleanOn = byKey.get("cleanest:true");

  for (const row of rows) {
    assert(
      row.status === "complete",
      `long ${row.profile} allow=${row.allow} incomplete: ${row.status} ${row.message || ""}`,
      failures
    );
  }

  if (cleanOn && cleanOn.status === "complete") {
    assert(
      (cleanOn.dirt == null || cleanOn.dirt < 15) ||
        (cleanOn.paved != null && cleanOn.paved > 85),
      `long Clean+Allow should stay paved; got dirt=${cleanOn.dirt} paved=${cleanOn.paved}`,
      failures
    );
    assert(
      cleanOn.unk == null || cleanOn.unk === 0,
      `long Clean+Allow must have 0 unk%; got ${cleanOn.unk}`,
      failures
    );
  }

  if (balOn && balOn.status === "complete" && balOn.dirt != null) {
    assert(
      balOn.dirt >= 25 && balOn.dirt <= 70,
      `long Balanced+Allow dirt% should sit ~40–60 (band 25–70); got ${balOn.dirt}`,
      failures
    );
  }

  if (balOn && directOn && balOn.status === "complete" && directOn.status === "complete") {
    const sameSpine =
      Math.abs((balOn.km || 0) - (directOn.km || 0)) < 8 &&
      Math.abs((balOn.dirt || 0) - (directOn.dirt || 0)) < 8;
    assert(
      !sameSpine,
      `long Balanced+Allow must not clone Direct (km ${balOn.km}/${directOn.km}, dirt ${balOn.dirt}/${directOn.dirt})`,
      failures
    );
    // On paved-leaning corridors Direct may sit below ~50% dirt; Balanced must
    // not be Direct’s paved cousin (dirt% below Direct when Direct already low).
    if (
      balOn.dirt != null &&
      directOn.dirt != null &&
      directOn.dirt < 30 &&
      balOn.dirt + 3 < directOn.dirt
    ) {
      assert(
        false,
        `long Balanced+Allow dirt% (${balOn.dirt}) should not sit below Direct (${directOn.dirt}) on paved-leaning fabric`,
        failures
      );
    }
  }

  if (dirtOn && balOn && dirtOn.status === "complete" && balOn.status === "complete") {
    assert(
      dirtOn.dirt == null || balOn.dirt == null || dirtOn.dirt > balOn.dirt + 5,
      `long Dirt should stay dirt-max vs Balanced (dirt ${dirtOn.dirt} vs ${balOn.dirt})`,
      failures
    );
  }

  return failures;
}

async function main() {
  console.log("Myra profile matrix");
  console.log(
    `OD: ${MYRA.label} (${MYRA.lat},${MYRA.lon}) → ${FALL_RIVER.label} (${FALL_RIVER.lat},${FALL_RIVER.lon})`
  );
  console.log("");

  const rows = [];
  for (const profile of PROFILES) {
    for (const allow of ALLOWS) {
      process.stdout.write(`  ${profile} allow=${allow ? "on " : "off"}… `);
      const row = await runOne(profile, allow, MYRA, FALL_RIVER);
      rows.push(row);
      console.log(
        row.status === "complete"
          ? `${km(row.km * 1000)} km  dirt ${pct(row.dirt)}%  paved ${pct(row.paved)}%  unk ${pct(row.unk)}%  lat+${row.latOvershootM != null ? Math.round(row.latOvershootM) : "—"}m  afterClosest ${row.metersAfterClosest != null ? Math.round(row.metersAfterClosest) : "—"}m  (${row.ms}ms)`
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
      "lat+".padStart(7),
      "after".padStart(7),
      "stitch".padStart(7),
      "ms".padStart(7)
    ].join(" ")
  );
  console.log("-".repeat(80));
  for (const row of rows) {
    console.log(
      [
        row.profile.padEnd(10),
        (row.allow ? "on" : "off").padEnd(6),
        km(row.km != null ? row.km * 1000 : null).padStart(7),
        pct(row.dirt).padStart(7),
        pct(row.paved).padStart(8),
        pct(row.unk).padStart(6),
        (row.latOvershootM != null ? String(Math.round(row.latOvershootM)) : "—").padStart(7),
        (row.metersAfterClosest != null ? String(Math.round(row.metersAfterClosest)) : "—").padStart(7),
        String(row.softStitch).padStart(7),
        String(row.ms).padStart(7)
      ].join(" ")
    );
  }

  const failures = runAsserts(rows);

  if (RUN_LONG) {
    console.log("");
    console.log("Long NS OD (New Glasgow → Yarmouth) Allow on");
    const longRows = [];
    for (const profile of PROFILES) {
      process.stdout.write(`  ${profile} allow=on … `);
      const row = await runOne(profile, true, NEW_GLASGOW, YARMOUTH);
      longRows.push(row);
      console.log(
        row.status === "complete"
          ? `${km(row.km * 1000)} km  dirt ${pct(row.dirt)}%  paved ${pct(row.paved)}%  unk ${pct(row.unk)}%  (${row.ms}ms)`
          : `FAIL ${row.status} ${row.message || row.error || ""}`
      );
    }
    failures.push(...runLongOdAsserts(longRows));
  } else {
    console.log("");
    console.log("Long NS OD skipped (SKIP_LONG_OD=1)");
  }

  console.log("");
  if (failures.length) {
    console.error("ASSERT FAIL:");
    for (const f of failures) console.error(" -", f);
    process.exitCode = 1;
  } else {
    console.log(
      "ASSERT PASS: Clean immune; no end U-turn; Direct no north spur; adventure diverge" +
        (RUN_LONG ? "; long Balanced ~50/50 mix." : ".")
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
