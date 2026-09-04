#!/usr/bin/env node
"use strict";

/**
 * Bake motorcycle-usable OSM fuel into a phone pack sidecar.
 *
 *   node scripts/pack-fabric/scripts/pack-region-fuel.js bc
 *
 * Reads data-raw/osm-fuel/<geofabrik-slug>/fuel.geojsonseq
 * (from extract-osm-fuel.sh) and writes app/data/packs/v1/{id}/fuel.v1.json.
 * Upload with:
 *   node scripts/pack-fabric/scripts/ship-routing.js \
 *     --candidate <release-id> --pack bc
 * Bare --pack is forbidden. Follow docs/PACK-FACTORY.md through candidate
 * acceptance, exact-byte promotion, stable LIVE deployment, and assertion.
 */
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const { geofabrikSource } = require("../routing/registry/geofabrik");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");

const id = String(process.argv[2] || "").toLowerCase();
let source;
try {
  source = geofabrikSource(id);
} catch (_) {
  source = null;
}
if (!id || !source) {
  console.error("Usage: pack-region-fuel.js <region-id>   (e.g. bc)");
  process.exit(1);
}

const seq = path.join(DIRT, "data-raw/osm-fuel", source.slug, "fuel.geojsonseq");
if (!fs.existsSync(seq)) {
  console.error("missing " + seq);
  console.error(
    "Run: bash scripts/pack-fabric/scripts/extract-osm-fuel.sh " +
      source.slug +
      " " +
      source.country
  );
  process.exit(1);
}

const out = path.join(FABRIC, "app/data/packs/v1", id, "fuel.v1.json");
const r = spawnSync(
  process.execPath,
  [path.join(__dirname, "build-fuel-pack.js"), seq],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      FUEL_V1_OUT: out,
      FUEL_REGION_ID: id
    }
  }
);
if (r.status !== 0) process.exit(r.status || 1);
console.log("packed fuel for", id, "→", out);
