#!/usr/bin/env node
"use strict";

/**
 * Phase B2 gate: OSM leaves survive adapter → intermediate JSON graph.
 * Coarse columns must be byte-identical with/without leaf fields on features.
 *
 * Usage:
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/verify-phase-b-leaf-roundtrip.js \
 *     [--geojsonseq scripts/pack-fabric/data-raw/osm-roads/nova-scotia/roads.geojsonseq]
 */
const path = require("path");
const osmRoads = require("../routing/adapters/osm-roads");
const { buildRegionalGraph } = require("../routing/regional/package");
const { auditLeafLengths } = require("./audit-osm-surface-normalization");

const DEFAULT_SEQ = path.join(
  __dirname,
  "..",
  "data-raw",
  "osm-roads",
  "nova-scotia",
  "roads.geojsonseq"
);

const LEAF_KEYS = [
  "surfaceLeaf",
  "roadClassLeaf",
  "tracktype",
  "smoothness",
  "layer",
  "structureLeaf",
  "accessLeaf",
  "atv",
  "atvDesignated"
];

const COARSE_KEYS = [
  "i",
  "a",
  "b",
  "m",
  "s",
  "t",
  "ac",
  "rt",
  "c",
  "conf",
  "seasonal",
  "src",
  "desc",
  "rid",
  "lin",
  "role"
];

const ABS_KM_TOL = 60;
const REL_TOL = 0.003;

function arg(name) {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : null;
}

function bump(map, key, meters) {
  map[key] = (map[key] || 0) + meters;
}

function surfaceLeafKey(value) {
  if (value == null || value === "") return "(missing)";
  return String(value).toLowerCase();
}

function roadClassLeafKey(value) {
  return String(value || "unknown").toLowerCase();
}

function optionalLeafKey(value) {
  if (value == null || value === "") return "(missing)";
  return String(value).toLowerCase();
}

function mapFromPhaseA(tagSummary) {
  const out = {};
  for (const row of tagSummary.rows) out[row.leaf] = row.km;
  return out;
}

function mapFromGraphEdges(edges, field, keyFn) {
  const meters = {};
  for (const e of edges) bump(meters, keyFn(e[field]), Number(e.m) || 0);
  const km = {};
  for (const [k, m] of Object.entries(meters)) km[k] = m / 1000;
  return km;
}

function compareMaps(label, phaseA, graph, options = {}) {
  const absTol = options.absTol != null ? options.absTol : ABS_KM_TOL;
  const relTol = options.relTol != null ? options.relTol : REL_TOL;
  const keys = new Set([...Object.keys(phaseA), ...Object.keys(graph)]);
  const rows = [];
  let worstAbs = 0;
  let failCount = 0;
  for (const key of [...keys].sort(
    (a, b) => (graph[b] || phaseA[b] || 0) - (graph[a] || phaseA[a] || 0) || a.localeCompare(b)
  )) {
    const a = phaseA[key] || 0;
    const g = graph[key] || 0;
    const abs = Math.abs(g - a);
    const rel = a > 1 ? abs / a : abs > absTol ? 1 : 0;
    const ok = abs <= absTol || rel <= relTol;
    if (!ok) failCount += 1;
    if (abs > worstAbs) worstAbs = abs;
    if (a >= 0.05 || g >= 0.05 || !ok) {
      rows.push({
        key,
        phaseAKm: Number(a.toFixed(3)),
        graphKm: Number(g.toFixed(3)),
        absDelta: Number(abs.toFixed(3)),
        ok
      });
    }
  }
  return { label, failCount, worstAbsKm: Number(worstAbs.toFixed(3)), rows };
}

function stripLeaves(features) {
  return features.map((f) => {
    const copy = { ...f };
    for (const k of LEAF_KEYS) delete copy[k];
    return copy;
  });
}

function coarseFingerprint(edges) {
  return edges.map((e) => {
    const row = {};
    for (const k of COARSE_KEYS) row[k] = e[k];
    row.g0 = e.g && e.g[0];
    row.gN = e.g && e.g[e.g.length - 1];
    return row;
  });
}

function assertCoarseIdentical(withLeaves, withoutLeaves) {
  if (withLeaves.length !== withoutLeaves.length) {
    return {
      ok: false,
      reason: `edge count mismatch ${withLeaves.length} vs ${withoutLeaves.length}`
    };
  }
  const a = coarseFingerprint(withLeaves);
  const b = coarseFingerprint(withoutLeaves);
  for (let i = 0; i < a.length; i += 1) {
    if (JSON.stringify(a[i]) !== JSON.stringify(b[i])) {
      return { ok: false, reason: `edge[${i}] coarse mismatch`, left: a[i], right: b[i] };
    }
  }
  return { ok: true, edgeCount: a.length };
}

function pad(s, n) {
  const t = String(s);
  return t.length >= n ? t.slice(0, n) : t + " ".repeat(n - t.length);
}

async function main() {
  const seq = arg("--geojsonseq") || DEFAULT_SEQ;
  console.log("=== Phase B2 leaf round-trip verify ===");
  console.log("geojsonseq:", seq);

  console.log("\n[1/4] Leaf audit on included routable (post-B1 classify)…");
  const phaseA = await auditLeafLengths(seq);
  console.log(`  included ${phaseA.includedKm.toFixed(1)} km / ${phaseA.includedWays} ways`);

  console.log("\n[2/4] OSM adapter → regional intermediate graph (NS, OSM-only)…");
  const { features, report } = await osmRoads.run({
    inputPath: seq,
    province: "NS",
    datasetVersion: "phase-b2-verify"
  });
  console.log(`  adapter features: ${features.length} (report=${report.featureCount})`);

  let atvDesignatedMeters = 0;
  let unpavedMeters = 0;
  for (const f of features) {
    if (!f.roadClassLeaf) throw new Error("missing roadClassLeaf on " + f.edgeId);
    if (typeof f.layer !== "number") throw new Error("layer not number on " + f.edgeId);
    if (typeof f.atvDesignated !== "boolean") throw new Error("atvDesignated not bool on " + f.edgeId);
    if (f.atvDesignated) atvDesignatedMeters += Number(f.distanceMeters) || 0;
    if (f.surfaceLeaf === "unpaved") unpavedMeters += Number(f.distanceMeters) || 0;
  }
  console.log(
    `  pre-package: surfaceLeaf=unpaved ${(unpavedMeters / 1000).toFixed(1)} km; atvDesignated ${(atvDesignatedMeters / 1000).toFixed(1)} km`
  );

  const graphWith = buildRegionalGraph({
    features,
    regionId: "ns",
    province: "NS",
    lineage: { phase: "B2-verify-with-leaves" }
  });
  const graphWithout = buildRegionalGraph({
    features: stripLeaves(features),
    regionId: "ns",
    province: "NS",
    lineage: { phase: "B2-verify-coarse-only" }
  });
  console.log(`  intermediate edges: ${graphWith.edges.length}`);

  console.log("\n[3/4] Coarse columns with-leaves vs without-leaves…");
  const coarse = assertCoarseIdentical(graphWith.edges, graphWithout.edges);
  if (!coarse.ok) {
    console.error("COARSE MISMATCH:", coarse);
    process.exit(1);
  }
  console.log(`  PASS — ${coarse.edgeCount} edges identical on coarse columns`);

  console.log("\n[4/4] Leaf km: included extract vs intermediate JSON graph…");
  const surfaceA = mapFromPhaseA(phaseA.tags.find((t) => t.tag === "surface"));
  const highwayA = mapFromPhaseA(phaseA.tags.find((t) => t.tag === "highway"));
  const tracktypeA = mapFromPhaseA(phaseA.tags.find((t) => t.tag === "tracktype"));
  const smoothnessA = mapFromPhaseA(phaseA.tags.find((t) => t.tag === "smoothness"));

  const surfaceG = mapFromGraphEdges(graphWith.edges, "surfaceLeaf", surfaceLeafKey);
  const highwayG = mapFromGraphEdges(graphWith.edges, "roadClassLeaf", roadClassLeafKey);
  const tracktypeG = mapFromGraphEdges(graphWith.edges, "tracktype", optionalLeafKey);
  const smoothnessG = mapFromGraphEdges(graphWith.edges, "smoothness", optionalLeafKey);

  let atvDesignatedGraphM = 0;
  for (const e of graphWith.edges) {
    if (e.atvDesignated) atvDesignatedGraphM += Number(e.m) || 0;
  }

  const comparisons = [
    compareMaps("surfaceLeaf vs surface=", surfaceA, surfaceG),
    compareMaps("roadClassLeaf vs highway=", highwayA, highwayG),
    compareMaps("tracktype", tracktypeA, tracktypeG),
    compareMaps("smoothness", smoothnessA, smoothnessG)
  ];

  for (const cmp of comparisons) {
    console.log(`\n## ${cmp.label}  (worst |Δ|=${cmp.worstAbsKm} km, fails=${cmp.failCount})`);
    console.log(`${pad("leaf", 28)} ${pad("extract_km", 12)} ${pad("graph_km", 12)} ${pad("|Δ|", 10)} ok`);
    console.log("-".repeat(72));
    for (const row of cmp.rows.slice(0, 25)) {
      console.log(
        `${pad(row.key, 28)} ${pad(row.phaseAKm.toFixed(1), 12)} ${pad(row.graphKm.toFixed(1), 12)} ${pad(row.absDelta.toFixed(1), 10)} ${row.ok ? "Y" : "N"}`
      );
    }
  }

  const unpavedA = surfaceA.unpaved || 0;
  const unpavedG = surfaceG.unpaved || 0;
  const fineA = surfaceA.fine_gravel || 0;
  const fineG = surfaceG.fine_gravel || 0;
  const gravelA = surfaceA.gravel || 0;
  const gravelG = surfaceG.gravel || 0;
  const atvG = atvDesignatedGraphM / 1000;

  console.log("\n=== Gate highlights ===");
  console.log(
    `surface=unpaved: extract ${unpavedA.toFixed(1)} | graph ${unpavedG.toFixed(1)} | Δ ${Math.abs(unpavedG - unpavedA).toFixed(1)} (Phase A era ≈30004)`
  );
  console.log(`surface=gravel: ${gravelA.toFixed(1)} → ${gravelG.toFixed(1)} (distinct)`);
  console.log(`surface=fine_gravel: ${fineA.toFixed(1)} → ${fineG.toFixed(1)} (distinct)`);
  console.log(`atvDesignated graph km: ${atvG.toFixed(1)} (expect ≈ recovered ATV set ~350)`);

  const sample =
    graphWith.edges.find((e) => e.atvDesignated) ||
    graphWith.edges.find((e) => e.surfaceLeaf === "unpaved") ||
    graphWith.edges[0];
  console.log("\nSample edge leaf fields:", {
    i: sample.i,
    rid: sample.rid,
    m: sample.m,
    s: sample.s,
    rt: sample.rt,
    surfaceLeaf: sample.surfaceLeaf,
    roadClassLeaf: sample.roadClassLeaf,
    tracktype: sample.tracktype,
    smoothness: sample.smoothness,
    layer: sample.layer,
    structureLeaf: sample.structureLeaf,
    accessLeaf: sample.accessLeaf,
    atv: sample.atv,
    atvDesignated: sample.atvDesignated
  });

  const totalFails = comparisons.reduce((n, c) => n + c.failCount, 0);
  if (totalFails > 0) {
    console.error(`\nFAIL: ${totalFails} leaf bucket(s) outside tolerance`);
    process.exit(1);
  }
  if (Math.abs(unpavedG - unpavedA) > ABS_KM_TOL && Math.abs(unpavedG - unpavedA) / Math.max(unpavedA, 1) > REL_TOL) {
    console.error("FAIL: unpaved km mismatch");
    process.exit(1);
  }
  if (!(fineG > 0) || (Math.abs(fineG - fineA) > ABS_KM_TOL && Math.abs(fineG - fineA) / Math.max(fineA, 1) > REL_TOL)) {
    console.error("FAIL: fine_gravel not preserved distinctly");
    process.exit(1);
  }
  if (atvG < 300) {
    console.error("FAIL: atvDesignated km too low (expected ~350 recovered set)");
    process.exit(1);
  }

  console.log("\nPASS — Phase B2 gate: leaves present, round-trip OK, coarse unchanged, atvDesignated marked.");
  console.log("=== STOP (Phase B2 only — no .bin / Swift / router / Phase C) ===");
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
