#!/usr/bin/env node
"use strict";

const fs = require("fs");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const { osmAdminRelation } = require("../routing/registry/osm-admin");
const { clipGeojsonPath, fetchAdminPolygon } = require("./fetch-admin-polygon");

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function validateGeometry(file, id) {
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  const geometry = doc.geometry || (doc.features && doc.features[0] && doc.features[0].geometry);
  if (!geometry || !["Polygon", "MultiPolygon"].includes(geometry.type)) {
    throw new Error(`${id} has no polygon geometry`);
  }
  if (!Array.isArray(geometry.coordinates) || !geometry.coordinates.length) {
    throw new Error(`${id} polygon is empty`);
  }
  return geometry.type;
}

async function main() {
  const ids = process.argv.slice(2).length
    ? process.argv.slice(2).map((id) => String(id).toLowerCase())
    : Object.keys(OSM_REGION).sort();
  for (let index = 0; index < ids.length; index += 1) {
    const id = ids[index];
    if (!OSM_REGION[id]) throw new Error(`unknown region ${id}`);
    let file = clipGeojsonPath(id);
    if (!file) {
      console.log(`[${index + 1}/${ids.length}] fetching ${id} R${osmAdminRelation(id)}`);
      file = (await fetchAdminPolygon(id)).clipPath;
      await wait(1_100);
    } else {
      console.log(`[${index + 1}/${ids.length}] cached ${id}`);
    }
    console.log(`${id}: ${validateGeometry(file, id)}`);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = { main, validateGeometry };
