#!/usr/bin/env node
"use strict";

/**
 * Build an NRN-only regional routing graph for one province/territory.
 * Usage: node scripts/build-regional-nrn-graph.js <code> <geojsonseq> [downloadUrl] [datasetVersion]
 */
const fs = require("fs");
const path = require("path");

const nrnAdapter = require("../routing/adapters/nrn");
const { buildRegionalGraph, writeRegionalGraph } = require("../routing/regional/package");

const ROOT = path.join(__dirname, "..");
const REGISTRY = path.join(ROOT, "routing", "registry", "sources.json");

async function main() {
  const code = String(process.argv[2] || "").toLowerCase();
  const inputPath = process.argv[3];
  const downloadUrl =
    process.argv[4] || `https://geo.statcan.gc.ca/nrn_rrn/${code}/nrn_rrn_${code}_GPKG.zip`;
  const datasetVersion = process.argv[5] || `NRN_${code.toUpperCase()}`;

  if (!code || !inputPath) {
    throw new Error("Usage: build-regional-nrn-graph.js <code> <geojsonseq> [url] [version]");
  }
  if (!fs.existsSync(inputPath)) {
    throw new Error("Missing input " + inputPath);
  }

  const province = code.toUpperCase();
  console.log(`[${code}] NRN adapter…`);
  const nrn = await nrnAdapter.run({
    inputPath,
    province,
    downloadUrl,
    datasetVersion
  });
  console.log(`[${code}] NRN features:`, nrn.features.length);

  const graph = buildRegionalGraph({
    features: nrn.features,
    province,
    regionId: code,
    lineage: {
      nrn: {
        adapter: nrn.report.adapter,
        featureCount: nrn.report.featureCount,
        excludedByReason: nrn.report.excludedByReason,
        classification: nrn.report.classification
      },
      provincial: null
    },
    conflationReport: {
      province,
      precedence: {
        backbone: "NRN owns national road identity",
        supplement: "Provincial supplement not ingested for this region yet"
      },
      stats: {
        backboneKept: nrn.features.length,
        supplementAdded: 0,
        supplementDuplicateSkipped: 0
      },
      freeSpaceConnectors: 0
    }
  });

  const outDir = path.join(ROOT, "routing", "data", "regions", code);
  const written = writeRegionalGraph(graph, outDir);
  console.log(`[${code}] Wrote`, written.graphPath);
  console.log(JSON.stringify(written.meta, null, 2));

  const reportDir = path.join(ROOT, "routing", "data", "reports");
  fs.mkdirSync(reportDir, { recursive: true });
  const report = {
    generatedAt: new Date().toISOString(),
    region: province,
    nrn: { ...nrn.report },
    graph: written.meta,
    freeSpaceConnectors: 0
  };
  delete report.nrn.features;
  fs.writeFileSync(
    path.join(reportDir, `${code}-nrn-build.json`),
    JSON.stringify(report, null, 2)
  );

  // Update registry entry for this region.
  if (fs.existsSync(REGISTRY)) {
    const registry = JSON.parse(fs.readFileSync(REGISTRY, "utf8"));
    const row = (registry.regions || []).find((r) => String(r.code).toLowerCase() === code);
    if (row) {
      // NRN backbone pack exists after ingest, but routingReady stays false until
      // the province meets the audit bar (validated graph + documented limitations).
      // Do not mark reference-only / backbone-only packs as routing-ready.
      row.nrn = row.nrn || {};
      row.nrn.status = "ready";
      row.nrn.dateRetrieved = new Date().toISOString().slice(0, 10);
      row.nrn.adapter = "nrn";
      row.nrn.downloadUrl = downloadUrl;
      row.nrn.notes =
        "NRN ROADSEG ingested as national backbone artifact. Not routing-ready until regional validation and provincial-supplement policy from CANADA_DATA_SOURCE_AUDIT.md are applied.";
      row.routingReady = row.code === "NS" ? !!row.routingReady : false;
      row.routingMode = "nrn-backbone-artifact";
      row.backboneArtifact = {
        path: `routing/data/regions/${code}/graph.v1.json.gz`,
        edgeCount: written.meta.edgeCount,
        nodeCount: written.meta.nodeCount,
        gzBytes: written.meta.gzBytes
      };
      registry.updatedAt = new Date().toISOString().slice(0, 10);
      fs.writeFileSync(REGISTRY, JSON.stringify(registry, null, 2) + "\n");
      console.log(
        `[${code}] Registry updated (nrn=${row.nrn.status}, routingReady=${row.routingReady})`
      );
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
