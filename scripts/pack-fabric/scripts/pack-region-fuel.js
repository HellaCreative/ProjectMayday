#!/usr/bin/env node
"use strict";

/**
 * Bake motorcycle-usable OSM fuel into a phone pack sidecar.
 *
 *   node scripts/pack-fabric/scripts/pack-region-fuel.js bc
 *
 * Reads data-raw/osm-fuel/<geofabrik-slug>/fuel.geojsonseq
 * (from extract-osm-fuel.sh) and writes app/data/packs/v1/{id}/fuel.v1.json.
 * Ship with: node scripts/pack-fabric/scripts/ship-routing.js --pack bc
 */
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const OSM_SLUG = {
  nb: "new-brunswick",
  qc: "quebec",
  ns: "nova-scotia",
  pe: "prince-edward-island",
  on: "ontario",
  mb: "manitoba",
  sk: "saskatchewan",
  ab: "alberta",
  bc: "british-columbia",
  nl: "newfoundland-and-labrador",
  yt: "yukon",
  nt: "northwest-territories",
  nu: "nunavut",
  wa: "washington",
  ak: "alaska",
  al: "alabama",
  ar: "arkansas",
  az: "arizona",
  ca: "california",
  co: "colorado",
  ct: "connecticut",
  dc: "district-of-columbia",
  de: "delaware",
  fl: "florida",
  ga: "georgia",
  hi: "hawaii",
  ia: "iowa",
  id: "idaho",
  il: "illinois",
  in: "indiana",
  ks: "kansas",
  ky: "kentucky",
  la: "louisiana",
  ma: "massachusetts",
  md: "maryland",
  me: "maine",
  mi: "michigan",
  mn: "minnesota",
  mo: "missouri",
  ms: "mississippi",
  mt: "montana",
  nc: "north-carolina",
  nd: "north-dakota",
  ne: "nebraska",
  nh: "new-hampshire",
  nj: "new-jersey",
  nm: "new-mexico",
  nv: "nevada",
  ny: "new-york",
  oh: "ohio",
  ok: "oklahoma",
  or: "oregon",
  pa: "pennsylvania",
  ri: "rhode-island",
  sc: "south-carolina",
  sd: "south-dakota",
  tn: "tennessee",
  tx: "texas",
  ut: "utah",
  va: "virginia",
  vt: "vermont",
  wi: "wisconsin",
  wv: "west-virginia",
  wy: "wyoming"
};

const id = String(process.argv[2] || "").toLowerCase();
if (!id || !OSM_SLUG[id]) {
  console.error("Usage: pack-region-fuel.js <region-id>   (e.g. bc)");
  process.exit(1);
}

const seq = path.join(DIRT, "data-raw/osm-fuel", OSM_SLUG[id], "fuel.geojsonseq");
if (!fs.existsSync(seq)) {
  console.error("missing " + seq);
  console.error(
    "Run: bash scripts/pack-fabric/scripts/extract-osm-fuel.sh " +
      OSM_SLUG[id] +
      (["wa","al","ak","az","ar","ca","co","ct","de","fl","ga","hi","id","il","in","ia","ks","ky","la","me","md","ma","mi","mn","ms","mo","mt","ne","nv","nh","nj","nm","ny","nc","nd","oh","ok","or","pa","ri","sc","sd","tn","tx","ut","vt","va","wv","wi","wy","dc"].includes(id) ? " us" : " canada")
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
