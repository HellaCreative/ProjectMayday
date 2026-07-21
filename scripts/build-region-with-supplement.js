#!/usr/bin/env node
"use strict";

/**
 * Rebuild a regional graph as NRN backbone + optional provincial supplement.
 * Usage: node scripts/build-region-with-supplement.js <code>
 * Requires existing NRN regional pack OR NRN geojsonseq at data-raw/nrn/<code>/
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const nrnAdapter = require("../routing/adapters/nrn");
const { conflateRegion } = require("../routing/conflation/conflate");
const { buildRegionalGraph, writeRegionalGraph } = require("../routing/regional/package");

const ROOT = path.join(__dirname, "..");
const REGISTRY = path.join(ROOT, "routing", "registry", "sources.json");

const SUPPLEMENTS = {
  ns: () => require("../routing/adapters/ns-nstdb"),
  nb: () => require("../routing/adapters/nb-forest-roads"),
  bc: () => require("../routing/adapters/bc-ften"),
  ab: () => require("../routing/adapters/ab-access"),
  on: () => require("../routing/adapters/on-mnrf"),
  qc: () => require("../routing/adapters/qc-multiusage")
};

async function loadNrnFeatures(code) {
  const seq = path.join(ROOT, "data-raw", "nrn", code, "nrn-roadseg.geojsonseq");
  if (fs.existsSync(seq)) {
    return nrnAdapter.run({
      inputPath: seq,
      province: code.toUpperCase(),
      downloadUrl: `https://geo.statcan.gc.ca/nrn_rrn/${code}/nrn_rrn_${code}_GPKG.zip`,
      datasetVersion: `NRN_${code.toUpperCase()}`
    });
  }
  // Fall back to unpacking edges already in the regional graph as backbone features.
  const gzPath = path.join(ROOT, "routing", "data", "regions", code, "graph.v1.json.gz");
  if (!fs.existsSync(gzPath)) {
    throw new Error("No NRN seq or regional graph for " + code);
  }
  const graph = JSON.parse(zlib.gunzipSync(fs.readFileSync(gzPath)).toString("utf8"));
  const { createNormalizedEdge } = require("../routing/schema/edge");
  const {
    SURFACE_CLASS,
    ACCESS_CLASS,
    STRUCTURE_TYPE,
    ROAD_TRACK_CLASS,
    SOURCE_CONFIDENCE
  } = require("../routing/schema/enums");
  const surfaceName = graph.enums.SURFACE_NAME;
  const accessName = graph.enums.ACCESS_NAME;
  const structureName = graph.enums.STRUCTURE_NAME;
  // If this pack already includes a provincial supplement, only keep NRN edges
  // as backbone so re-runs do not double-ingest resource roads.
  const backboneEdges = (graph.edges || []).filter((e) => {
    const src = String(e.src || "");
    if (!src) return true;
    return /national road network|^nrn\b/i.test(src);
  });
  const features = backboneEdges.map((e) =>
    createNormalizedEdge({
      edgeId: e.i,
      lineageId: e.lin || e.i,
      province: code.toUpperCase(),
      sourceName: e.src || "National Road Network",
      sourceDatasetVersion: "from-regional-pack",
      sourceFeatureId: e.rid || null,
      sourceGeometryLineage: "regional-pack",
      geometry: { type: "LineString", coordinates: e.g },
      surfaceClass: surfaceName[e.s] || SURFACE_CLASS.unknown,
      roadTrackClass: e.rt || ROAD_TRACK_CLASS.unknown,
      accessClass: accessName[e.ac] || ACCESS_CLASS.motorized_unknown,
      structureType: structureName[e.t] || STRUCTURE_TYPE.none,
      sourceConfidence: e.conf || SOURCE_CONFIDENCE.medium,
      roadName: e.desc || null,
      direction: "both",
      seasonal: !!e.seasonal,
      distanceMeters: e.m,
      meta: { fromPack: true }
    })
  );
  return {
    features,
    report: {
      adapter: "nrn-from-pack",
      featureCount: features.length,
      excludedByReason: {},
      classification: {},
      notes:
        backboneEdges.length !== (graph.edges || []).length
          ? [
              `Filtered ${(graph.edges || []).length - backboneEdges.length} non-NRN edges from existing regional pack before re-supplement.`
            ]
          : []
    }
  };
}

async function main() {
  const code = String(process.argv[2] || "").toLowerCase();
  if (!code || !SUPPLEMENTS[code]) {
    throw new Error("Usage: build-region-with-supplement.js <ns|nb|bc|ab|on|qc>");
  }
  const suppMod = SUPPLEMENTS[code]();
  console.log(`[${code}] Loading NRN backbone…`);
  const nrn = await loadNrnFeatures(code);
  console.log(`[${code}] NRN features:`, nrn.features.length);

  console.log(`[${code}] Running provincial supplement ${suppMod.name}…`);
  // Soft caps only for exploratory builds. QC live layer ~945k — do not truncate.
  const maxByCode = { ab: 250000, bc: 200000, on: 350000, qc: Infinity, ns: 500000, nb: Infinity };
  const supp = await suppMod.run({
    maxFeatures: maxByCode[code] != null ? maxByCode[code] : 250000,
    pageSize: code === "bc" ? 500 : 2000
  });
  console.log(`[${code}] Supplement features:`, supp.features.length);

  const conflated = conflateRegion({
    backbone: nrn.features,
    supplement: supp.features,
    province: code.toUpperCase()
  });
  console.log(`[${code}] Conflated:`, conflated.features.length, conflated.report.stats);

  const graph = buildRegionalGraph({
    features: conflated.features,
    province: code.toUpperCase(),
    regionId: code,
    lineage: {
      nrn: { adapter: nrn.report.adapter, featureCount: nrn.report.featureCount },
      provincial: {
        adapter: supp.report.adapter,
        featureCount: supp.report.featureCount,
        excludedByReason: supp.report.excludedByReason,
        classification: supp.report.classification
      }
    },
    conflationReport: conflated.report
  });

  const outDir = path.join(ROOT, "routing", "data", "regions", code);
  const written = writeRegionalGraph(graph, outDir);
  console.log(`[${code}] Wrote`, written.graphPath, written.meta.gzBytes, "bytes");

  const reportDir = path.join(ROOT, "routing", "data", "reports");
  fs.mkdirSync(reportDir, { recursive: true });
  fs.writeFileSync(
    path.join(reportDir, `${code}-nrn-supplement-build.json`),
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        region: code.toUpperCase(),
        nrn: { adapter: nrn.report.adapter, featureCount: nrn.report.featureCount },
        provincial: supp.report,
        conflation: conflated.report,
        graph: written.meta,
        freeSpaceConnectors: 0
      },
      null,
      2
    )
  );

  if (fs.existsSync(REGISTRY)) {
    const registry = JSON.parse(fs.readFileSync(REGISTRY, "utf8"));
    const row = (registry.regions || []).find((r) => String(r.code).toLowerCase() === code);
    if (row) {
      row.provincial = row.provincial || {};
      row.provincial.adapter = supp.report.adapter;
      row.provincial.status = "ready";
      row.provincial.dateRetrieved = new Date().toISOString().slice(0, 10);
      row.provincial.notes = (row.provincial.notes || "") + " Supplemental adapter ingested.";
      row.routingMode = "nrn+provincial";
      // Product routing-ready only after pack exists and free-space is zero.
      row.routingReady = conflated.report.freeSpaceConnectors === 0;
      row.backboneArtifact = {
        path: `routing/data/regions/${code}/graph.v1.json.gz`,
        edgeCount: written.meta.edgeCount,
        nodeCount: written.meta.nodeCount,
        gzBytes: written.meta.gzBytes
      };
      registry.updatedAt = new Date().toISOString().slice(0, 10);
      fs.writeFileSync(REGISTRY, JSON.stringify(registry, null, 2) + "\n");
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
