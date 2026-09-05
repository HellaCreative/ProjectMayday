#!/usr/bin/env node
"use strict";

/**
 * Resume-safe builder for all regional service data. Existing canonical fuel
 * sidecars are never rebuilt. Missing fuel is derived from the same one-time
 * regional OSM extract used for campground/lodging/liquor.
 */

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { OSM_REGION } = require("../routing/registry/geofabrik");

const DIRT = path.resolve(__dirname, "../../..");
const EXTRACTOR = path.join(__dirname, "extract-region-service-data.sh");
const RIDER_ROOT = path.join(DIRT, "scripts/pack-fabric/app/data/rider-services/v1");
const FUEL_ROOT = path.join(DIRT, "scripts/pack-fabric/app/data/packs/v1");

function parseArgs(argv) {
  let force = false;
  let regions = Object.keys(OSM_REGION).sort();
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--force") force = true;
    else if (argv[index] === "--regions") {
      regions = String(argv[++index] || "").split(",").map((id) => id.trim().toLowerCase()).filter(Boolean);
    } else if (argv[index] === "--help" || argv[index] === "-h") {
      return { help: true, force, regions };
    } else throw new Error(`Unknown argument: ${argv[index]}`);
  }
  if (!regions.length || regions.some((id) => !OSM_REGION[id]) || new Set(regions).size !== regions.length) {
    throw new Error("--regions must contain unique registered two-letter region ids");
  }
  return { help: false, force, regions };
}

function validRiderPack(file, regionId) {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    return value.schema === "rider-services.v1" && value.regionId === regionId &&
      Array.isArray(value.elements) && value.elements.length > 0;
  } catch (_) {
    return false;
  }
}

function validFuelPack(file, regionId) {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    return value.schema === "fuel.v1" && value.regionId === regionId &&
      Array.isArray(value.stations) && value.stations.length > 0;
  } catch (_) {
    return false;
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log("Usage: build-service-data.js [--regions ns,nb,...] [--force]");
    return;
  }
  let built = 0;
  let skipped = 0;
  for (const id of options.regions) {
    const riderFile = path.join(RIDER_ROOT, id, "rider-services.v1.json");
    const fuelFile = path.join(FUEL_ROOT, id, "fuel.v1.json");
    const fuelExists = validFuelPack(fuelFile, id);
    if (!options.force && validRiderPack(riderFile, id) && fuelExists) {
      console.log(`skip ${id}: Rider Services and canonical fuel already valid`);
      skipped += 1;
      continue;
    }
    const mode = fuelExists ? "rider-only" : "with-fuel";
    console.log(`build ${id}: ${mode}`);
    const result = spawnSync("bash", [EXTRACTOR, id, mode], {
      cwd: DIRT,
      env: process.env,
      stdio: "inherit"
    });
    if (result.error || result.status !== 0) {
      throw new Error(`Service-data build failed for '${id}'`);
    }
    if (!validRiderPack(riderFile, id) || !validFuelPack(fuelFile, id)) {
      throw new Error(`Service-data build did not produce valid Rider Services and fuel for '${id}'`);
    }
    built += 1;
  }
  console.log(`service-data build complete regions=${options.regions.length} built=${built} skipped=${skipped}`);
}

if (require.main === module) {
  try { main(); } catch (error) {
    console.error("SERVICE DATA BUILD FAIL:", error && error.message || String(error));
    process.exit(1);
  }
}

module.exports = { parseArgs, validFuelPack, validRiderPack };
