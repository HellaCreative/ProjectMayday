#!/usr/bin/env node
"use strict";

/**
 * Build the Nova Scotia regional routing graph:
 *   NRN (national backbone) + NSTDB (provincial supplement) → conflate → package
 *
 * Does not invent free-space connectors.
 * Raw NRN archives stay under data-raw/ (gitignored).
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const nrnAdapter = require("../routing/adapters/nrn");
const nstdbAdapter = require("../routing/adapters/ns-nstdb");
const { conflateRegion } = require("../routing/conflation/conflate");
const { buildRegionalGraph, writeRegionalGraph } = require("../routing/regional/package");

const ROOT = path.join(__dirname, "..");
const NRN_SEQ = path.join(ROOT, "data-raw", "nrn", "ns", "nrn-roadseg.geojsonseq");
const OUT_REGION = path.join(ROOT, "routing", "data", "regions", "ns");
const REPORT_DIR = path.join(ROOT, "routing", "data", "reports");
const LEGACY_GRAPH = path.join(ROOT, "routing", "data", "ns-graph.v1.json.gz");

async function main() {
  if (!fs.existsSync(NRN_SEQ)) {
    throw new Error(
      "Missing NRN GeoJSONSeq at " + NRN_SEQ + ". Run the NRN download/export first."
    );
  }

  console.log("Running NRN adapter…");
  const nrn = await nrnAdapter.run({
    inputPath: NRN_SEQ,
    province: "NS",
    downloadUrl: "https://geo.statcan.gc.ca/nrn_rrn/ns/nrn_rrn_ns_GPKG.zip",
    datasetVersion: "NRN_NS_18_0"
  });
  console.log("NRN features:", nrn.features.length);

  console.log("Running NSTDB adapter from packed chunks…");
  const nstdb = await nstdbAdapter.run({ province: "NS" });
  console.log("NSTDB features:", nstdb.features.length);

  console.log("Conflating (NRN backbone + NSTDB supplement)…");
  const conflated = conflateRegion({
    backbone: nrn.features,
    supplement: nstdb.features,
    province: "NS"
  });
  console.log("Conflated features:", conflated.features.length);
  console.log(JSON.stringify(conflated.report.stats, null, 2));

  const graph = buildRegionalGraph({
    features: conflated.features,
    province: "NS",
    regionId: "ns",
    lineage: {
      nrn: {
        adapter: nrn.report.adapter,
        featureCount: nrn.report.featureCount,
        excludedByReason: nrn.report.excludedByReason,
        classification: nrn.report.classification
      },
      nstdb: {
        adapter: nstdb.report.adapter,
        featureCount: nstdb.report.featureCount,
        excludedByReason: nstdb.report.excludedByReason,
        classification: nstdb.report.classification
      }
    },
    conflationReport: conflated.report
  });

  const written = writeRegionalGraph(graph, OUT_REGION);
  console.log("Wrote", written.graphPath);
  console.log(JSON.stringify(written.meta, null, 2));

  fs.mkdirSync(REPORT_DIR, { recursive: true });
  const report = {
    generatedAt: new Date().toISOString(),
    region: "NS",
    nrn: nrn.report,
    nstdb: nstdb.report,
    conflation: conflated.report,
    graph: written.meta,
    legacyGraphPresent: fs.existsSync(LEGACY_GRAPH),
    freeSpaceConnectors: 0
  };
  // Strip full feature arrays from adapter reports before writing.
  delete report.nrn.features;
  delete report.nstdb.features;
  const reportPath = path.join(REPORT_DIR, "ns-nrn-nstdb-build.json");
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  console.log("Report", reportPath);

  // Comparison stub sizes vs legacy
  if (fs.existsSync(LEGACY_GRAPH)) {
    const legacyStat = fs.statSync(LEGACY_GRAPH);
    const compare = {
      generatedAt: new Date().toISOString(),
      legacy: { path: "routing/data/ns-graph.v1.json.gz", gzBytes: legacyStat.size },
      regional: {
        path: path.relative(ROOT, written.graphPath),
        gzBytes: written.meta.gzBytes,
        edgeCount: written.meta.edgeCount,
        nodeCount: written.meta.nodeCount,
        sourceCounts: written.meta.sourceCounts
      },
      notes: [
        "Regional graph uses NRN backbone + NSTDB supplement.",
        "Fixture suite must pass against the active production graph path.",
        "No free-space connectors were introduced."
      ]
    };
    fs.writeFileSync(
      path.join(REPORT_DIR, "ns-graph-comparison.json"),
      JSON.stringify(compare, null, 2)
    );
    console.log("Comparison written");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
