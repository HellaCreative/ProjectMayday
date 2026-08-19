#!/usr/bin/env node
"use strict";

/**
 * Compare Dirt vs Balanced vs Direct vs Clean on a local graph.v2.bin.
 * Mirrors OnDeviceProfileCosts.swift + a node-to-node Dijkstra (no virtual
 * endpoints / runtime stitches). Good enough to see whether profiles diverge.
 *
 * Usage:
 *   node scripts/pack-fabric/scripts/analyze-profile-routes.js
 *   node scripts/pack-fabric/scripts/analyze-profile-routes.js --pair chilliwack-enderby
 */

const fs = require("fs");
const path = require("path");
const { decodeGraphV2, unpackSurface, unpackAccess, unpackRoadClass, unpackConfidence, ROAD_CLASS_NAME } =
  require("../routing/lib/pack-v2");

const ROOT = path.resolve(__dirname, "../../..");
const PACKS = path.join(ROOT, "scripts/pack-fabric/app/data/packs/v1");

const SURFACE_NAME = ["paved", "gravel", "access", "track", "unknown"];
const ACCESS_FALLBACK = [
  "motorized_verified",
  "motorized_permissive",
  "motorized_unknown",
  "motorized_restricted",
  "motorized_excluded"
];

const PAIRS = {
  "chilliwack-enderby": {
    pack: "bc",
    from: { lat: 49.162, lon: -121.951, label: "Chilliwack" },
    to: { lat: 50.551, lon: -119.139, label: "Enderby" }
  },
  "abbotsford-merritt": {
    pack: "bc",
    from: { lat: 49.0504, lon: -122.3045, label: "Abbotsford" },
    to: { lat: 50.111, lon: -120.786, label: "Merritt" }
  },
  "hope-princeton": {
    pack: "bc",
    from: { lat: 49.385, lon: -121.442, label: "Hope" },
    to: { lat: 49.459, lon: -120.506, label: "Princeton" }
  },
  "merritt-kamloops": {
    pack: "bc",
    from: { lat: 50.111, lon: -120.786, label: "Merritt" },
    to: { lat: 50.674, lon: -120.328, label: "Kamloops" }
  },
  "golden-revelstoke": {
    pack: "bc",
    from: { lat: 51.299, lon: -116.964, label: "Golden" },
    to: { lat: 50.998, lon: -118.195, label: "Revelstoke" }
  },
  "chilliwack-crowsnest": {
    pack: "bc",
    from: { lat: 49.162, lon: -121.951, label: "Chilliwack" },
    to: { lat: 49.633, lon: -114.694, label: "Crowsnest (BC side)" }
  },
  "calgary-lethbridge": {
    pack: "ab",
    from: { lat: 51.0447, lon: -114.0719, label: "Calgary" },
    to: { lat: 49.694, lon: -112.833, label: "Lethbridge" }
  },
  "calgary-drumheller": {
    pack: "ab",
    from: { lat: 51.0447, lon: -114.0719, label: "Calgary" },
    to: { lat: 51.463, lon: -112.71, label: "Drumheller" }
  },
  "crowsnest-calgary": {
    pack: "ab",
    from: { lat: 49.633, lon: -114.508, label: "Crowsnest (AB side)" },
    to: { lat: 51.0447, lon: -114.0719, label: "Calgary" }
  }
};

function haversine(aLat, aLon, bLat, bLon) {
  const R = 6371000;
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLon = ((bLon - aLon) * Math.PI) / 180;
  const s1 = Math.sin(dLat / 2);
  const s2 = Math.sin(dLon / 2);
  const h =
    s1 * s1 +
    Math.cos((aLat * Math.PI) / 180) * Math.cos((bLat * Math.PI) / 180) * s2 * s2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function surfaceWeight(profile, surfaceCode, roadClassCode) {
  const tables = {
    direct: [1.42, 0.98, 0.92, 0.88, 0.96],
    balanced: [1.38, 1.12, 1.05, 1.0, 1.18],
    dirt: [16.0, 0.28, 0.12, 0.06, 0.28],
    cleanest: [1.0, 8.0, 10.0, 14.0, 6.0]
  };
  const dirtUnpaved = [1.0, 0.58, 0.38, 0.28, 0.55];
  const idx = Math.min(Math.max(surfaceCode, 0), 4);
  const road = ROAD_CLASS_NAME[roadClassCode] || "unknown";
  // Untagged highway is pavement, not adventure fuel — match rider paint.
  if (
    (profile === "dirt" || profile === "balanced" || profile === "direct") &&
    idx === 4 &&
    (road === "freeway" ||
      road === "arterial" ||
      road === "ramp" ||
      road === "collector" ||
      road === "local" ||
      road === "service")
  ) {
    return tables[profile][0];
  }
  let w = tables[profile][idx];
  if (profile === "dirt" && idx > 0) w *= dirtUnpaved[idx];
  return w;
}

function roadClassWeight(profile, roadClassCode) {
  const key = ROAD_CLASS_NAME[roadClassCode] || "unknown";
  const tables = {
    cleanest: {
      freeway: 0.94, arterial: 0.98, collector: 1.18, ramp: 0.96,
      local: 2.6, service: 3.2, resource: 1.0, recreation: 1.0,
      track: 1.0, double_track: 1.0, unknown: 1.0
    },
    direct: {
      freeway: 1.7, arterial: 1.45, collector: 1.06, ramp: 1.6,
      local: 0.98, service: 1.12, resource: 0.9, recreation: 0.88,
      track: 0.9, double_track: 0.9, unknown: 1.0
    },
    balanced: {
      freeway: 3.2, arterial: 2.4, collector: 1.08, ramp: 2.8,
      local: 1.0, service: 1.15, resource: 0.92, recreation: 0.9,
      track: 0.92, double_track: 0.92, unknown: 1.0
    },
    dirt: {
      freeway: 14.0,
      arterial: 9.5,
      collector: 2.4,
      ramp: 12.0,
      local: 0.78,
      service: 1.4,
      resource: 0.4,
      recreation: 0.38,
      track: 0.3,
      double_track: 0.3,
      unknown: 0.95
    }
  };
  const table = tables[profile];
  return table[key] != null ? table[key] : table.unknown;
}

function passableQualityMult(profile, surfaceCode, roadClassCode, accessCode, confidenceCode) {
  if (profile !== "dirt" && profile !== "balanced") return 1;
  let m = 1;
  if (confidenceCode === 0) m *= 0.9;
  else if (confidenceCode === 2) m *= profile === "dirt" ? 1.25 : 1.22;
  if (accessCode === 2) m *= profile === "dirt" ? 1.35 : 1.15;
  const surface = SURFACE_NAME[surfaceCode] || "unknown";
  const road = ROAD_CLASS_NAME[roadClassCode] || "unknown";
  if (
    surface === "gravel" &&
    (road === "track" || road === "double_track" || road === "resource" || road === "local")
  ) {
    m *= profile === "dirt" ? 0.72 : 0.9;
  }
  return m;
}

function pavementLateJoinMult(profile, surfaceCode, dTo, abMeters) {
  if (surfaceCode !== 0) return 1;
  if (profile !== "dirt" && profile !== "balanced") return 1;
  const nearBand = 1200;
  if (dTo <= nearBand) return 1;
  const farBand = Math.max(abMeters * 0.45, profile === "dirt" ? 14000 : 7000);
  const t = Math.min(1, (dTo - nearBand) / Math.max(1, farBand - nearBand));
  const baseExtra = profile === "dirt" ? 0.75 : 0.95;
  return 1 + baseExtra * t;
}

const DIRT_AWAY_MID = Number(process.env.DIRT_AWAY_MID || 1.45);
const DIRT_NEAR_HORIZON = Number(process.env.DIRT_NEAR_HORIZON || 2500);
const BAN_PAVED = process.env.BAN_PAVED === "1";
const VARIANT = process.env.VARIANT || "current";

function approachAwayExtra(profile, dFrom, dTo, abMeters) {
  const away = dTo - dFrom;
  if (away <= 50) return 0;
  const kmAway = away / 1000;
  if (profile === "dirt") {
    const mid = kmAway * DIRT_AWAY_MID;
    const horizon = DIRT_NEAR_HORIZON > 0 ? DIRT_NEAR_HORIZON : 2500;
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (0.12 + t * t * 0.9);
    }
    const raw = mid + near;
    const cap = kmAway * 16.0 * 0.12;
    return Math.min(raw, cap);
  }
  if (profile === "direct") {
    const nearBand = Math.max(3200, abMeters * 0.3);
    return kmAway * (dFrom < nearBand ? 10 : 4.2);
  }
  if (profile === "balanced") {
    const mid = kmAway * 1.1;
    const horizon = Math.max(4000, abMeters * 0.2);
    let near = 0;
    if (dFrom < horizon) {
      const t = 1 - dFrom / horizon;
      near = kmAway * (0.4 + t * t * 2.4);
    }
    return mid + near;
  }
  const nearBand = Math.max(2800, abMeters * 0.28);
  return kmAway * (dFrom < nearBand ? 6.5 : 3.2);
}

function isAdventureSurface(name) {
  return (
    name === "gravel" ||
    name === "access" ||
    name === "resource" ||
    name === "track" ||
    name === "double_track" ||
    name === "unknown" ||
    name === "single" ||
    name === "unpaved" ||
    name === "dirt"
  );
}

class MinHeap {
  constructor() {
    this.items = [];
  }
  push(node, cost) {
    const items = this.items;
    items.push({ node, cost });
    let i = items.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (items[p].cost <= items[i].cost) break;
      const tmp = items[p];
      items[p] = items[i];
      items[i] = tmp;
      i = p;
    }
  }
  pop() {
    const items = this.items;
    if (!items.length) return null;
    const top = items[0];
    const end = items.pop();
    if (!items.length) return top;
    items[0] = end;
    let i = 0;
    while (true) {
      let s = i;
      const l = i * 2 + 1;
      const r = l + 1;
      if (l < items.length && items[l].cost < items[s].cost) s = l;
      if (r < items.length && items[r].cost < items[s].cost) s = r;
      if (s === i) break;
      const tmp = items[s];
      items[s] = items[i];
      items[i] = tmp;
      i = s;
    }
    return top;
  }
}

function loadPack(regionId) {
  const file = process.env.DIRT_GRAPH_V2
    ? process.env.DIRT_GRAPH_V2
    : path.join(PACKS, regionId, "graph.v2.bin");
  if (!fs.existsSync(file)) throw new Error("missing pack " + file);
  const buf = fs.readFileSync(file);
  const g = decodeGraphV2(buf);
  const accessNames = Array.isArray(g.enums.ACCESS_NAME) ? g.enums.ACCESS_NAME : ACCESS_FALLBACK;
  return { ...g, accessNames, regionId };
}

function accessName(pack, code) {
  return pack.accessNames[code] || ACCESS_FALLBACK[code] || "motorized_unknown";
}

function accessAllowed(pack, code, allowUnknown, profile) {
  const name = accessName(pack, code);
  if (name === "motorized_restricted" || name === "motorized_excluded") return false;
  if (name === "motorized_unknown") return allowUnknown && profile !== "cleanest";
  return true;
}

function nodeLL(pack, node) {
  return {
    lon: pack.nodeCoords[node * 2],
    lat: pack.nodeCoords[node * 2 + 1]
  };
}

function nodeEligibleDegree(pack, node, allowUnknown, profile) {
  const arcStart = pack.nodeOffsets[node];
  const arcEnd = pack.nodeOffsets[node + 1];
  let degree = 0;
  let unpaved = false;
  let highway = false;
  for (let a = arcStart; a < arcEnd; a++) {
    const ei = pack.edgeUndirectedIndex[a];
    const attr = pack.edgeAttrs[ei];
    if (!accessAllowed(pack, unpackAccess(attr), allowUnknown, profile)) continue;
    degree += 1;
    if (unpackSurface(attr) !== 0) unpaved = true;
    const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
    if (road === "freeway" || road === "arterial" || road === "ramp") highway = true;
  }
  return { degree, unpaved, highway };
}

function snapNode(pack, lat, lon, profile, allowUnknown) {
  const n = pack.nodeCount;
  const candidates = [];
  for (let i = 0; i < n; i++) {
    const d = haversine(lat, lon, pack.nodeCoords[i * 2 + 1], pack.nodeCoords[i * 2]);
    if (d > 2500) continue;
    const info = nodeEligibleDegree(pack, i, allowUnknown, profile);
    if (info.degree < 1) continue;
    candidates.push({ i, d, ...info });
  }
  if (!candidates.length) return -1;
  const near = candidates.filter((c) => c.d <= 800 && c.degree >= 3);
  const pool = near.length ? near : candidates.filter((c) => c.degree >= 2);
  const use = pool.length ? pool : candidates;
  use.sort((a, b) => {
    if (b.degree !== a.degree) return b.degree - a.degree;
    return a.d - b.d;
  });
  return use[0].i;
}

function route(pack, fromNode, toNode, profile, allowUnknown) {
  const n = pack.nodeCount;
  const dist = new Float64Array(n);
  dist.fill(Infinity);
  const prev = new Int32Array(n);
  prev.fill(-1);
  const prevEdge = new Int32Array(n);
  prevEdge.fill(-1);
  const heap = new MinHeap();
  dist[fromNode] = 0;
  heap.push(fromNode, 0);

  const endLL = nodeLL(pack, toNode);
  const startLL = nodeLL(pack, fromNode);
  const abMeters = haversine(startLL.lat, startLL.lon, endLL.lat, endLL.lon);
  let popped = 0;

  while (true) {
    const cur = heap.pop();
    if (!cur) break;
    if (cur.cost !== dist[cur.node]) continue;
    popped += 1;
    if (cur.node === toNode) break;
    const arcStart = pack.nodeOffsets[cur.node];
    const arcEnd = pack.nodeOffsets[cur.node + 1];
    const fromLL = nodeLL(pack, cur.node);
    for (let i = arcStart; i < arcEnd; i++) {
      const to = pack.edgeTargets[i];
      const ei = pack.edgeUndirectedIndex[i];
      const attr = pack.edgeAttrs[ei];
      const access = unpackAccess(attr);
      if (!accessAllowed(pack, access, allowUnknown, profile)) continue;
      const surface = unpackSurface(attr);
      if (BAN_PAVED && surface === 0) continue;
      const roadClass = unpackRoadClass(attr);
      const confidence = unpackConfidence(attr) === "high" ? 0 : unpackConfidence(attr) === "low" ? 2 : 1;
      const toLL = nodeLL(pack, to);
      let step =
        (pack.edgeMeters[ei] / 1000) *
        surfaceWeight(profile, surface, roadClass) *
        roadClassWeight(profile, roadClass) *
        passableQualityMult(profile, surface, roadClass, access, confidence);
      step *= pavementLateJoinMult(
        profile,
        surface,
        haversine(toLL.lat, toLL.lon, endLL.lat, endLL.lon),
        abMeters
      );
      step += approachAwayExtra(
        profile,
        haversine(fromLL.lat, fromLL.lon, endLL.lat, endLL.lon),
        haversine(toLL.lat, toLL.lon, endLL.lat, endLL.lon),
        abMeters
      );
      const cost = cur.cost + step;
      if (cost < dist[to]) {
        dist[to] = cost;
        prev[to] = cur.node;
        prevEdge[to] = ei;
        heap.push(to, cost);
      }
    }
  }

  if (!Number.isFinite(dist[toNode])) {
    return { ok: false, popped };
  }

  const edges = [];
  let node = toNode;
  while (node !== fromNode) {
    const ei = prevEdge[node];
    if (ei < 0) return { ok: false, popped };
    edges.push(ei);
    node = prev[node];
  }
  edges.reverse();

  let meters = 0;
  let dirtMeters = 0;
  let pavedMeters = 0;
  let osmMeters = 0;
  let draMeters = 0;
  const surfaceMix = {};
  const roadMix = {};
  for (const ei of edges) {
    const m = pack.edgeMeters[ei];
    meters += m;
    const surface = SURFACE_NAME[unpackSurface(pack.edgeAttrs[ei])] || "unknown";
    const road = ROAD_CLASS_NAME[unpackRoadClass(pack.edgeAttrs[ei])] || "unknown";
    surfaceMix[surface] = (surfaceMix[surface] || 0) + m;
    roadMix[road] = (roadMix[road] || 0) + m;
    if (surface === "paved") pavedMeters += m;
    else if (isAdventureSurface(surface)) dirtMeters += m;
    const id = pack.edgeId ? pack.edgeId(ei) : "";
    if (id.startsWith("bc-dra") || id.startsWith("dra-") || id.includes("Digital Road")) draMeters += m;
    else osmMeters += m;
  }

  return {
    ok: true,
    popped,
    km: meters / 1000,
    dirtPercent: meters ? Math.round((dirtMeters / meters) * 100) : 0,
    pavedPercent: meters ? Math.round((pavedMeters / meters) * 100) : 0,
    osmKm: osmMeters / 1000,
    draKm: draMeters / 1000,
    edges,
    surfaceMix,
    roadMix
  };
}

function overlap(a, b) {
  const set = new Set(a);
  let shared = 0;
  for (const ei of b) if (set.has(ei)) shared += 1;
  const denom = Math.max(a.length, b.length, 1);
  return Math.round((shared / denom) * 100);
}

function mixPct(mix, totalKm) {
  const total = totalKm * 1000;
  return Object.entries(mix)
    .sort((a, b) => b[1] - a[1])
    .map(([k, m]) => `${k} ${Math.round((m / total) * 100)}%`)
    .join(", ");
}

function fabricCensus(pack, allowUnknown) {
  const counts = { edges: 0, paved: 0, unpaved: 0, unknownAccess: 0, track: 0, local: 0, freeway: 0 };
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei++) {
    const attr = pack.edgeAttrs[ei];
    const access = unpackAccess(attr);
    if (!accessAllowed(pack, access, allowUnknown, "dirt")) continue;
    counts.edges += 1;
    const surface = unpackSurface(attr);
    const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
    if (surface === 0) counts.paved += 1;
    else counts.unpaved += 1;
    if (accessName(pack, access) === "motorized_unknown") counts.unknownAccess += 1;
    if (road === "track" || road === "double_track" || road === "resource") counts.track += 1;
    if (road === "local") counts.local += 1;
    if (road === "freeway" || road === "arterial") counts.freeway += 1;
  }
  return counts;
}

function runPair(packs, name, spec, profiles, allowUnknown) {
  const pack = packs[spec.pack];
  const fromNode = snapNode(pack, spec.from.lat, spec.from.lon, "direct", allowUnknown);
  const toNode = snapNode(pack, spec.to.lat, spec.to.lon, "direct", allowUnknown);
  if (fromNode < 0 || toNode < 0) {
    return { name, error: `snap failed from=${fromNode} to=${toNode}` };
  }
  const fromLL = nodeLL(pack, fromNode);
  const toLL = nodeLL(pack, toNode);
  const fromM = Math.round(haversine(spec.from.lat, spec.from.lon, fromLL.lat, fromLL.lon));
  const toM = Math.round(haversine(spec.to.lat, spec.to.lon, toLL.lat, toLL.lon));
  const results = {};
  for (const profile of profiles) {
    const t0 = Date.now();
    results[profile] = route(pack, fromNode, toNode, profile, allowUnknown);
    results[profile].ms = Date.now() - t0;
  }
  return { name, pack: spec.pack, allowUnknown, fromNode, toNode, fromM, toM, results };
}

function printResult(row) {
  console.log(`\n=== ${row.name} (${row.pack}, allow=${row.allowUnknown}) snap ${row.fromM}m / ${row.toM}m ===`);
  if (row.error) {
    console.log("  ERROR", row.error);
    return;
  }
  const dirt = row.results.dirt;
  const balanced = row.results.balanced;
  for (const [profile, r] of Object.entries(row.results)) {
    if (!r.ok) {
      console.log(`  ${profile.padEnd(9)} NO PATH  popped=${r.popped} ${r.ms}ms`);
      continue;
    }
    console.log(
      `  ${profile.padEnd(9)} ${r.km.toFixed(1)} km  dirt=${String(r.dirtPercent).padStart(2)}%  paved=${String(r.pavedPercent).padStart(2)}%  edges=${r.edges.length}  ${r.ms}ms`
    );
    if (r.draKm > 0.05) {
      console.log(`            source:  OSM ${r.osmKm.toFixed(1)} km · DRA ${r.draKm.toFixed(1)} km`);
    }
    console.log(`            surface: ${mixPct(r.surfaceMix, r.km)}`);
    console.log(`            class:   ${mixPct(r.roadMix, r.km)}`);
  }
  if (dirt?.ok && balanced?.ok) {
    const ov = overlap(dirt.edges, balanced.edges);
    console.log(
      `  Dirt vs Balanced overlap=${ov}%  Δdirt=${dirt.dirtPercent - balanced.dirtPercent}pt  Δkm=${(dirt.km - balanced.km).toFixed(1)}`
    );
  }
}

async function main() {
  const argPair = process.argv.includes("--pair")
    ? process.argv[process.argv.indexOf("--pair") + 1]
    : null;
  const allowOn = process.env.ALLOW === "1";
  const names = process.env.PAIRS
    ? process.env.PAIRS.split(",")
    : argPair
    ? [argPair]
    : ["hope-princeton", "merritt-kamloops", "calgary-drumheller", "chilliwack-enderby", "calgary-lethbridge", "golden-revelstoke"];
  const profiles = process.env.PROFILES
    ? process.env.PROFILES.split(",")
    : ["dirt", "balanced", "direct", "cleanest"];
  if (BAN_PAVED) console.log("BAN_PAVED=1 (unpaved-only graph)");
  if (VARIANT !== "current") console.log("VARIANT=" + VARIANT);
  if (DIRT_AWAY_MID !== 0.18) console.log("DIRT_AWAY_MID=" + DIRT_AWAY_MID);
  if (DIRT_NEAR_HORIZON) console.log("DIRT_NEAR_HORIZON=" + DIRT_NEAR_HORIZON);
  const needed = [...new Set(names.map((n) => PAIRS[n].pack))];
  const packs = {};
  for (const id of needed) {
    console.log(`loading ${id}…`);
    packs[id] = loadPack(id);
    const off = fabricCensus(packs[id], false);
    const on = fabricCensus(packs[id], true);
    console.log(
      `  ${id}: nodes=${packs[id].nodeCount} edges=${packs[id].undirectedEdgeCount} allowOff=${off.edges} (paved ${off.paved} unpaved ${off.unpaved} track/resource ${off.track} local ${off.local} hwy ${off.freeway}) allowOn extra unknown=${on.unknownAccess}`
    );
  }

  for (const name of names) {
    const spec = PAIRS[name];
    if (!spec) throw new Error("unknown pair " + name);
    printResult(runPair(packs, name, spec, profiles, allowOn));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
