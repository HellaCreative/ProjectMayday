#!/usr/bin/env node
"use strict";

// Four bounded pieces of one unchanged administrative outline. The overlap is
// working coverage; ownership remains the exact latitude/longitude cut.
const fs = require("node:fs");
const path = require("node:path");
const { clipGeometry } = require("./split-subregion-polygons");
const { clipGeojsonPath, loadUnified, writeUnified } = require("./fetch-admin-polygon");
const { validateGeometry } = require("./prepare-v4-polygons");

function gridPieces(geometry, parent, latitude, longitude, overlap) {
  if (![latitude, longitude, overlap].every(Number.isFinite) || overlap < 0)
    throw new Error("finite cuts and nonnegative overlap required");
  const pieces = {};
  for (const ns of ["n", "s"]) for (const ew of ["e", "w"]) {
    const band = clipGeometry(geometry, ns === "n" ? "north-of" : "south-of",
      latitude + (ns === "n" ? -overlap : overlap));
    const piece = band && clipGeometry(band, ew === "e" ? "east-of" : "west-of",
      longitude + (ew === "e" ? -overlap : overlap));
    if (!piece) throw new Error(`${parent}-${ns}${ew}: empty grid piece`);
    pieces[`${parent}-${ns}${ew}`] = piece;
  }
  return pieces;
}

function main(args = process.argv.slice(2)) {
  if (args.length < 3 || args.length > 4) throw new Error("parent cut-lat cut-lon [overlap-degrees]");
  const [parent, lat, lon, overlap = "0.25"] = args;
  const parentPath = clipGeojsonPath(parent);
  if (!parentPath) throw new Error(`missing ${parent} outline`);
  const doc = JSON.parse(fs.readFileSync(parentPath));
  const geometry = doc.features?.[0]?.geometry || doc.geometry || doc;
  const pieces = gridPieces(geometry, parent, Number(lat), Number(lon), Number(overlap));
  const unified = loadUnified();
  for (const [id, shape] of Object.entries(pieces)) {
    const file = path.join(path.dirname(parentPath), `${id}.clip.geojson`);
    fs.writeFileSync(file, JSON.stringify({ type: "FeatureCollection", features: [
      { type: "Feature", properties: { id }, geometry: shape }
    ] }));
    validateGeometry(file, id);
    unified.regions[id] = shape;
    unified.osmRelations[id] = unified.osmRelations[parent];
  }
  unified.subregions ||= {};
  unified.subregions[parent] = { recipe: "latitude-longitude-grid", children: Object.keys(pieces),
    ownershipCutLat: Number(lat), ownershipCutLon: Number(lon), overlapDeg: Number(overlap) };
  writeUnified(unified);
  console.log(JSON.stringify(unified.subregions[parent]));
}
if (require.main === module) main();
module.exports = { gridPieces };
