#!/usr/bin/env node
"use strict";

/**
 * Nova Scotia regional graph — thin wrapper.
 *
 * Locked product fabric (no NRN):
 *   OSM road fabric (motorized_permissive) → NSTDB / STDB capillary (unknown-gated)
 *
 * NRN is not part of the NS routing fabric. Quebec made the same call for NRN;
 * NS keeps provincial NSTDB purple as the dirt capillary between OSM roads.
 */
const { spawnSync } = require("child_process");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const builder = path.join(__dirname, "build-region-with-supplement.js");

console.log(
  "build-ns-regional-graph.js → build-region-with-supplement.js ns --osm-plus-provincial (OSM+NSTDB, no NRN)"
);
const result = spawnSync(
  process.execPath,
  [builder, "ns", "--osm-plus-provincial"],
  {
    cwd: ROOT,
    stdio: "inherit",
    env: process.env
  }
);
process.exit(result.status == null ? 1 : result.status);
