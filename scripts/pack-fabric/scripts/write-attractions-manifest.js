#!/usr/bin/env node
"use strict";

/** Write a local attractions-manifest.v1 covering every extracted region pack. */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { REGION_BBOX } = require("../routing/regional/select");

const ROOT = path.resolve(__dirname, "../../..");
const LOCAL_ROOT = process.env.ATTRACTIONS_V1_ROOT
  || path.join(ROOT, "scripts/pack-fabric/app/data/attractions/v1");

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function main() {
  if (!fs.existsSync(LOCAL_ROOT)) {
    throw new Error(`No attractions output at ${LOCAL_ROOT}`);
  }
  const regions = [];
  for (const id of fs.readdirSync(LOCAL_ROOT).sort()) {
    const filePath = path.join(LOCAL_ROOT, id, "attractions.v1.json");
    if (!fs.existsSync(filePath)) continue;
    const buffer = fs.readFileSync(filePath);
    const pack = JSON.parse(buffer.toString("utf8"));
    if (pack.schema !== "attractions.v1" || pack.regionId !== id) {
      throw new Error(`Invalid attractions pack '${id}'`);
    }
    const bounds = Array.isArray(pack.bounds) && pack.bounds.length === 4
      ? pack.bounds
      : REGION_BBOX[id];
    if (!bounds) throw new Error(`No bounds for '${id}'`);
    regions.push({
      id,
      bounds,
      counts: pack.counts,
      sourceUpdatedAt: pack.sourceUpdatedAt || null,
      file: {
        name: "attractions.v1.json",
        bytes: buffer.length,
        sha256: sha256(buffer)
      }
    });
  }
  if (!regions.length) throw new Error("No attractions.v1 packs found");
  const manifest = {
    schema: "attractions-manifest.v1",
    generatedAt: new Date().toISOString(),
    basePath: "/attractions/v1",
    regions
  };
  const out = path.join(LOCAL_ROOT, "manifest.json");
  fs.writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`attractions manifest regions=${regions.length} path=${out}`);
}

try {
  main();
} catch (error) {
  console.error(error && error.message ? error.message : String(error));
  process.exit(1);
}
