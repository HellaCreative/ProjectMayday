#!/usr/bin/env node
"use strict";

/**
 * Dead-end spur / U-turn diagnostic.
 *
 * Product law: a route must never enter a dead-end and come back out mid-route.
 * The only legal reversals are at A, B, or a user waypoint.
 *
 * Detects, on the returned route:
 *   - repeated edgeId (the same physical edge ridden twice = out-and-back)
 *   - immediate reversal (segment i and i+1 share an edgeId)
 *   - repeated geometry vertices with the excursion length between repeats
 *
 * Run: node --max-old-space-size=4096 scripts/diag-uturn-spurs.js
 *      OD=44.746,-63.321,45.5936,-62.6486 PROFILES=dirt ALLOWS=on node ... 
 */

const { routeRequest } = require("../routing/lib/router");

const OD_PRESETS = [
  {
    label: "Halifax → Sheet Harbour hinterland",
    a: { lat: 44.6488, lon: -63.5752 },
    b: { lat: 45.1266, lon: -61.9736 }
  },
  {
    label: "Porters Lake → Trafalgar (screenshot corridor)",
    a: { lat: 44.746, lon: -63.321 },
    b: { lat: 45.3272, lon: -62.2317 }
  },
  {
    label: "New Glasgow → Yarmouth (long NS gold)",
    a: { lat: 45.5936, lon: -62.6486 },
    b: { lat: 43.8375, lon: -66.1174 }
  }
];

function parseOd() {
  const raw = process.env.OD;
  if (!raw) return OD_PRESETS;
  const n = raw.split(",").map(Number);
  if (n.length !== 4 || n.some((v) => !Number.isFinite(v))) {
    throw new Error("OD must be lat,lon,lat,lon");
  }
  return [{ label: "custom", a: { lat: n[0], lon: n[1] }, b: { lat: n[2], lon: n[3] } }];
}

const PROFILES = (process.env.PROFILES || "dirt,balanced,direct,cleanest").split(",");
const ALLOWS = (process.env.ALLOWS || "on,off").split(",").map((s) => s.trim() === "on");

function haversineMeters(a, b) {
  const R = 6371000;
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/**
 * Analyse the segment list for repeated edges and out-and-back excursions.
 * Returns counts + the meters wasted riding the same ground twice.
 */
function analyseSegments(segments) {
  const segs = segments || [];
  const byId = new Map();
  segs.forEach((seg, i) => {
    const id = String(seg.edgeId == null ? "?" + i : seg.edgeId);
    if (!byId.has(id)) byId.set(id, []);
    byId.get(id).push(i);
  });

  let repeatedEdges = 0;
  let repeatedMeters = 0;
  const excursions = [];
  const sameCoord = (a, b) =>
    a && b && a[0].toFixed(6) === b[0].toFixed(6) && a[1].toFixed(6) === b[1].toFixed(6);
  const reverses = (a, b) => {
    const ag = a.geometry || [];
    const bg = b.geometry || [];
    return (
      ag.length > 1 &&
      bg.length > 1 &&
      sameCoord(ag[0], bg[bg.length - 1]) &&
      sameCoord(ag[ag.length - 1], bg[0])
    );
  };
  for (const [id, idxs] of byId) {
    if (idxs.length < 2) continue;
    if (String(id).startsWith("?")) continue;
    for (let k = 1; k < idxs.length; k += 1) {
      if (!reverses(segs[idxs[k - 1]], segs[idxs[k]])) continue;
      repeatedEdges += 1;
      repeatedMeters += Number(segs[idxs[k]].distanceMeters) || 0;
      const from = idxs[k - 1];
      const to = idxs[k];
      let spanM = 0;
      for (let i = from; i <= to; i += 1) spanM += Number(segs[i].distanceMeters) || 0;
      excursions.push({
        edgeId: id,
        firstIndex: from,
        secondIndex: to,
        segmentsBetween: to - from - 1,
        spanMeters: Math.round(spanM),
        at: segs[from].geometry && segs[from].geometry[0]
      });
    }
  }

  let immediateReversals = 0;
  for (let i = 1; i < segs.length; i += 1) {
    if (
      segs[i].edgeId != null &&
      segs[i].edgeId === segs[i - 1].edgeId &&
      reverses(segs[i - 1], segs[i])
    ) {
      immediateReversals += 1;
    }
  }

  excursions.sort((x, y) => x.spanMeters - y.spanMeters);
  return { repeatedEdges, repeatedMeters, immediateReversals, excursions };
}

/** Repeated geometry vertices → the line physically doubles back on itself. */
function analyseGeometry(geometry) {
  const g = geometry || [];
  const seen = new Map();
  let doubleBacks = 0;
  let doubleBackMeters = 0;
  const spots = [];
  const cum = [0];
  for (let i = 1; i < g.length; i += 1) cum.push(cum[i - 1] + haversineMeters(g[i - 1], g[i]));
  for (let i = 0; i < g.length; i += 1) {
    const key = g[i][0].toFixed(6) + "," + g[i][1].toFixed(6);
    if (seen.has(key)) {
      const prev = seen.get(key);
      const span = cum[i] - cum[prev];
      if (span > 50) {
        doubleBacks += 1;
        doubleBackMeters += span;
        spots.push({ at: g[i], spanMeters: Math.round(span) });
      }
    }
    seen.set(key, i);
  }
  spots.sort((x, y) => y.spanMeters - x.spanMeters);
  const stack = [];
  const stackIndex = new Map();
  const loops = [];
  for (let i = 0; i < g.length; i += 1) {
    const key = g[i][0].toFixed(6) + "," + g[i][1].toFixed(6);
    if (stackIndex.has(key)) {
      const at = stackIndex.get(key);
      const startI = stack[at].sourceIndex;
      const span = cum[i] - cum[startI];
      if (span > 50) loops.push({ at: g[i], spanMeters: Math.round(span), from: startI, to: i });
      for (let j = stack.length - 1; j > at; j -= 1) stackIndex.delete(stack[j].key);
      stack.length = at + 1;
      continue;
    }
    stackIndex.set(key, stack.length);
    stack.push({ key, sourceIndex: i });
  }
  return {
    doubleBacks,
    doubleBackMeters: Math.round(doubleBackMeters),
    spots: spots.slice(0, 8),
    loopCount: loops.length,
    loops
  };
}

async function runOne(profile, allow, od) {
  const t0 = Date.now();
  const r = await routeRequest({
    profile,
    locations: [od.a, od.b],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: allow },
    options: { matchLimitMeters: 500 }
  });
  const seg = analyseSegments(r.segments);
  const geo = analyseGeometry(r.geometry);
  const loopSegmentHits = [];
  for (const spot of geo.spots.slice(0, 4)) {
    const key = spot.at[0].toFixed(6) + "," + spot.at[1].toFixed(6);
    const hits = [];
    for (let i = 0; i < (r.segments || []).length; i += 1) {
      const coords = r.segments[i].geometry || [];
      if (coords.some((c) => c[0].toFixed(6) + "," + c[1].toFixed(6) === key)) {
        hits.push({
          index: i,
          edgeId: r.segments[i].edgeId,
          meters: r.segments[i].distanceMeters,
          first: coords[0],
          last: coords[coords.length - 1]
        });
      }
    }
    loopSegmentHits.push({ spot, hits });
  }
  const softContext = [];
  for (let i = 0; i < (r.segments || []).length; i += 1) {
    if (!String(r.segments[i].edgeId || "").startsWith("soft-stitch-")) continue;
    softContext.push(
      (r.segments || []).slice(Math.max(0, i - 2), i + 3).map((s, j) => ({
        index: Math.max(0, i - 2) + j,
        edgeId: s.edgeId,
        meters: s.distanceMeters,
        first: s.geometry && s.geometry[0],
        last: s.geometry && s.geometry[s.geometry.length - 1]
      }))
    );
  }
  return {
    profile,
    allow,
    status: r.status,
    message: r.message || null,
    ms: Date.now() - t0,
    km: Number.isFinite(r.distanceMeters) ? r.distanceMeters / 1000 : null,
    dirt: r.stats ? r.stats.dirtPercent : null,
    paved: r.stats ? r.stats.pavedPercent : null,
    unk: r.stats ? r.stats.unknownAccessPercent : null,
    engine: r.debug ? r.debug.engine : null,
    softStitches:
      (r.debug && r.debug.searchMeta && r.debug.searchMeta.softStitchCount) || 0,
    usedSoftStitches: (r.segments || []).filter((s) => String(s.edgeId || "").startsWith("soft-stitch-")).length,
    softContext,
    loopSegmentHits,
    ...seg,
    ...geo
  };
}

function fmt(n, w) {
  return String(n == null ? "—" : n).padStart(w);
}

async function main() {
  const ods = parseOd();
  let bad = 0;
  for (const od of ods) {
    console.log("");
    console.log("OD:", od.label, `(${od.a.lat},${od.a.lon}) → (${od.b.lat},${od.b.lon})`);
    console.log(
      ["profile".padEnd(10), "allow".padEnd(6), "km".padStart(7), "dirt%".padStart(6),
        "repEdge".padStart(8), "repKm".padStart(7), "uturn".padStart(6),
        "dblBack".padStart(8), "dblKm".padStart(7), "ms".padStart(7)].join(" ")
    );
    console.log("-".repeat(84));
    for (const profile of PROFILES) {
      for (const allow of ALLOWS) {
        const row = await runOne(profile.trim(), allow, od);
        if (row.status !== "complete") {
          console.log(`${profile.padEnd(10)} ${(allow ? "on" : "off").padEnd(6)} FAIL ${row.status} ${row.message || ""}`);
          continue;
        }
        if (row.repeatedEdges > 0 || row.doubleBacks > 0) bad += 1;
        console.log(
          [
            row.profile.padEnd(10),
            (row.allow ? "on" : "off").padEnd(6),
            fmt(row.km != null ? row.km.toFixed(1) : null, 7),
            fmt(row.dirt, 6),
            fmt(row.repeatedEdges, 8),
            fmt((row.repeatedMeters / 1000).toFixed(2), 7),
            fmt(row.immediateReversals, 6),
            fmt(row.loopCount, 8),
            fmt((row.doubleBackMeters / 1000).toFixed(2), 7),
            fmt(row.ms, 7)
          ].join(" ")
        );
        if (process.env.VERBOSE === "1") {
          for (const ex of row.excursions.slice(-6)) {
            console.log(
              `      spur: edge ${ex.edgeId} idx ${ex.firstIndex}→${ex.secondIndex}` +
                ` between=${ex.segmentsBetween} span=${ex.spanMeters}m at ${ex.at ? ex.at.map((v) => v.toFixed(5)).join(",") : "?"}`
            );
          }
          for (const s of row.spots) {
            console.log(`      dblBack ${s.spanMeters}m at ${s.at.map((v) => v.toFixed(5)).join(",")}`);
          }
          for (const item of row.loopSegmentHits) {
            console.log(`      repeated coordinate ${JSON.stringify(item.spot.at)} occurs in:`);
            for (const hit of item.hits) {
              console.log(
                `        [${hit.index}] ${hit.edgeId} ${hit.meters}m ${JSON.stringify(hit.first)} → ${JSON.stringify(hit.last)}`
              );
            }
          }
          console.log(`      soft stitches built=${row.softStitches}, used=${row.usedSoftStitches}`);
          for (const context of row.softContext) {
            console.log("      soft-stitch path context:");
            for (const seg of context) {
              console.log(
                `        [${seg.index}] ${seg.edgeId} ${seg.meters}m ${JSON.stringify(seg.first)} → ${JSON.stringify(seg.last)}`
              );
            }
          }
          for (const loop of row.loops.slice(0, 8)) {
            console.log(
              `      loop ${loop.spanMeters}m geometry ${loop.from}→${loop.to} at ${loop.at.map((v) => v.toFixed(5)).join(",")}`
            );
          }
        }
      }
    }
  }
  console.log("");
  console.log(bad ? `FOUND spur/U-turn artifacts in ${bad} run(s)` : "CLEAN: no repeated edges, no double-backs");
  process.exitCode = bad ? 1 : 0;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
