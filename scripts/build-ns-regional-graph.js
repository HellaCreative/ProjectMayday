#!/usr/bin/env node
"use strict";

/**
 * Nova Scotia regional graph — thin wrapper.
 *
 * Live mental model (do not skip OSM):
 *   NRN backbone → OSM road fabric (motorized_permissive) → NSTDB capillary
 *
 * Historically this script built NRN+NSTDB only and silently dropped the OSM
 * basemap fabric. That made Shortbread white roads visible but not routable.
 * Always delegate to the 3-tier builder.
 */
const { spawnSync } = require("child_process");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const builder = path.join(__dirname, "build-region-with-supplement.js");

console.log(
  "build-ns-regional-graph.js → build-region-with-supplement.js ns (NRN+OSM+NSTDB)"
);
const result = spawnSync(process.execPath, [builder, "ns"], {
  cwd: ROOT,
  stdio: "inherit",
  env: process.env
});
process.exit(result.status == null ? 1 : result.status);
