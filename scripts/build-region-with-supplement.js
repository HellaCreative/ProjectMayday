#!/usr/bin/env node
"use strict";

/**
 * Rebuild a regional graph:
 *   NRN backbone → OSM gap-fill (optional) → provincial supplement
 * Usage: node scripts/build-region-with-supplement.js <code>
 * Requires existing NRN regional pack OR NRN geojsonseq at data-raw/nrn/<code>/
 * Optional OSM roads geojsonseq at data-raw/osm-roads/<geofabrik-slug>/roads.geojsonseq
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const nrnAdapter = require("../routing/adapters/nrn");
const osmRoads = require("../routing/adapters/osm-roads");
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

/** Geofabrik canada/* slug for OSM gap-fill extracts. */
const OSM_SLUG = {
  nb: "new-brunswick",
  qc: "quebec",
  ns: "nova-scotia",
  on: "ontario",
  ab: "alberta",
  bc: "british-columbia"
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
  const backboneEdges = (graph.edges || []).filter((e) => {
    const src = String(e.src || "");
    if (!src) return true;
    // Keep NRN and prior OSM gap-fill when re-adding provincial (two-phase builds).
    return /national road network|^nrn\b|openstreetmap/i.test(src);
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

async function loadOsmGapFill(code) {
  const slug = OSM_SLUG[code];
  if (!slug) return null;
  const seq = path.join(ROOT, "data-raw", "osm-roads", slug, "roads.geojsonseq");
  if (!fs.existsSync(seq)) {
    console.log(`[${code}] No OSM gap-fill extract at ${seq} — skipping OSM tier`);
    return null;
  }
  return osmRoads.run({
    inputPath: seq,
    province: code.toUpperCase(),
    sourceUrl: `https://download.geofabrik.de/north-america/canada/${slug}-latest.osm.pbf`,
    downloadUrl: `https://download.geofabrik.de/north-america/canada/${slug}-latest.osm.pbf`,
    datasetVersion: `geofabrik:${slug}`
  });
}

async function main() {
  const args = process.argv.slice(2);
  const code = String(args.find((a) => !a.startsWith("--")) || "").toLowerCase();
  const osmOnly = args.includes("--osm-only");
  const skipOsm = args.includes("--skip-osm");
  if (!code || !SUPPLEMENTS[code]) {
    throw new Error(
      "Usage: build-region-with-supplement.js <ns|nb|bc|ab|on|qc> [--osm-only] [--skip-osm]"
    );
  }
  const suppMod = SUPPLEMENTS[code]();
  console.log(`[${code}] Loading NRN backbone…`);
  const nrn = await loadNrnFeatures(code);
  console.log(`[${code}] NRN features:`, nrn.features.length);

  let backbone = nrn.features;
  let osmReport = null;
  let osmConflation = null;
  if (!skipOsm) {
    console.log(`[${code}] Loading OSM gap-fill…`);
    const osm = await loadOsmGapFill(code);
    if (osm && osm.features.length) {
      console.log(`[${code}] OSM gap-fill candidates:`, osm.features.length);
      osmConflation = conflateRegion({
        backbone,
        supplement: osm.features,
        province: code.toUpperCase()
      });
      backbone = osmConflation.features;
      osmReport = osm.report;
      console.log(`[${code}] After OSM gap-fill:`, osmConflation.report.stats);
    }
  } else {
    console.log(`[${code}] Skipping OSM (--skip-osm); keeping NRN+OSM already on pack if present`);
  }

  let supp = { features: [], report: { adapter: null, featureCount: 0, excludedByReason: {}, classification: {} } };
  let conflated = {
    features: backbone,
    report: {
      freeSpaceConnectors: 0,
      stats: {
        backboneKept: backbone.length,
        supplementAdded: 0,
        supplementDuplicateSkipped: 0
      }
    }
  };

  if (!osmOnly) {
    console.log(`[${code}] Running provincial supplement ${suppMod.name}…`);
    const maxByCode = { ab: 250000, bc: 200000, on: 350000, qc: Infinity, ns: 500000, nb: Infinity };
    supp = await suppMod.run({
      maxFeatures: maxByCode[code] != null ? maxByCode[code] : 250000,
      pageSize: code === "bc" ? 500 : 2000
    });
    console.log(`[${code}] Supplement features:`, supp.features.length);

    conflated = conflateRegion({
      backbone,
      supplement: supp.features,
      province: code.toUpperCase()
    });
    console.log(`[${code}] After provincial:`, conflated.features.length, conflated.report.stats);
  } else {
    console.log(`[${code}] --osm-only: writing NRN+OSM pack without provincial`);
  }

  const graph = buildRegionalGraph({
    features: conflated.features,
    province: code.toUpperCase(),
    regionId: code,
    lineage: {
      nrn: { adapter: nrn.report.adapter, featureCount: nrn.report.featureCount },
      osm: osmReport
        ? {
            adapter: osmReport.adapter,
            featureCount: osmReport.featureCount,
            added: osmConflation ? osmConflation.report.stats.supplementAdded : 0,
            duplicateSkipped: osmConflation ? osmConflation.report.stats.supplementDuplicateSkipped : 0,
            classification: osmReport.classification,
            excludedByReason: osmReport.excludedByReason
          }
        : null,
      provincial: {
        adapter: supp.report.adapter,
        featureCount: supp.report.featureCount,
        excludedByReason: supp.report.excludedByReason,
        classification: supp.report.classification
      }
    },
    conflationReport: {
      osm: osmConflation ? osmConflation.report : null,
      provincial: conflated.report
    }
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
        stack: ["nrn", osmReport ? "osm-gap-fill" : null, "provincial"].filter(Boolean),
        nrn: { adapter: nrn.report.adapter, featureCount: nrn.report.featureCount },
        osm: osmReport,
        osmConflation: osmConflation ? osmConflation.report : null,
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
      if (supp.report && supp.report.adapter) {
        row.provincial.adapter = supp.report.adapter;
        row.provincial.status = "ready";
        row.provincial.dateRetrieved = new Date().toISOString().slice(0, 10);
      }
      if (osmReport) {
        row.osm = {
          adapter: "osm-roads",
          role: "gap-fill",
          status: "ready",
          featureCount: osmReport.featureCount,
          added: osmConflation ? osmConflation.report.stats.supplementAdded : 0,
          license: "OpenStreetMap contributors (ODbL)",
          dateRetrieved: new Date().toISOString().slice(0, 10)
        };
      } else if (skipOsm && row.osm) {
        row.osm.status = row.osm.status || "ready";
      }
      const hasOsm = !!(osmReport || (row.osm && row.osm.status === "ready"));
      const hasProvincial = !!(supp.report && supp.report.adapter);
      row.routingMode = hasOsm
        ? hasProvincial
          ? "nrn+osm+provincial"
          : "nrn+osm"
        : hasProvincial
          ? "nrn+provincial"
          : "nrn-backbone";
      row.routingReady = (conflated.report.freeSpaceConnectors || 0) === 0;
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
