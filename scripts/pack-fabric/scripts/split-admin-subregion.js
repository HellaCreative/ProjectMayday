#!/usr/bin/env node
"use strict";
// Split a parent by a verified OSM administrative subregion, retaining the
// remainder. A longitude band cannot represent an island/mainland division.
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const { spawnSync } = require("node:child_process");
const { loadUnified, writeUnified } = require("./fetch-admin-polygon");
const { hashFile } = require("./prepare-common-source-lock");
const { validateGeometry } = require("./prepare-v4-polygons");
function main() {
  const [file, parent, parentRelation, child, childRelation, remainder] = process.argv.slice(2);
  if (!file || ![parent,child,remainder].every(id => /^[a-z]{2}(-[a-z]+)?$/.test(id || "")) ||
      !/^\d+$/.test(parentRelation || "") || !/^\d+$/.test(childRelation || ""))
    throw new Error("usage: split-admin-subregion.js lookup.json parent parentRelation child childRelation remainder");
  const rows = JSON.parse(fs.readFileSync(file));
  const select = id => {
    const row = rows.find(r => r.osm_type === "relation" && String(r.osm_id) === id && r.type === "administrative");
    if (!row || !["Polygon","MultiPolygon"].includes(row.geojson?.type)) throw new Error(`missing administrative polygon ${id}`);
    return row.geojson;
  };
  const parentGeometry = select(parentRelation), childGeometry = select(childRelation);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-admin-split-"));
  const write = (file, geometry, id) => fs.writeFileSync(file, JSON.stringify({ type: "FeatureCollection",
    features: [{ type: "Feature", properties: { id }, geometry }] }) + "\n");
  const run = args => {
    const r = spawnSync("ogr2ogr", args, { encoding: "utf8" });
    if (r.status !== 0) throw new Error(r.stderr);
  };
  try {
    write(path.join(tmp,"parent.geojson"),parentGeometry,parent);
    write(path.join(tmp,"child.geojson"),childGeometry,child);
    const db = path.join(tmp,"split.gpkg");
    run(["-f","GPKG",db,path.join(tmp,"parent.geojson"),"-nln","parent"]);
    run(["-update",db,path.join(tmp,"child.geojson"),"-nln","child"]);
    const results = { [parent]: parentGeometry };
    for (const [id,operation] of [[child,"ST_Intersection"],[remainder,"ST_Difference"]]) {
      const out = path.join(tmp,`${id}.geojson`);
      run(["-f","GeoJSON",out,db,"-dialect","SQLite","-sql",
        `SELECT ${operation}(a.geom,b.geom) AS geometry FROM parent a, child b`]);
      validateGeometry(out,id);
      results[id] = JSON.parse(fs.readFileSync(out)).features[0].geometry;
    }
    const unified = loadUnified(), dir = path.resolve(__dirname,"../routing/data/region-polygons");
    for (const [id,geometry] of Object.entries(results)) {
      write(path.join(dir,`${id}.clip.geojson`),geometry,id);
      unified.regions[id] = geometry;
    }
    unified.osmRelations[parent] = Number(parentRelation);
    unified.osmRelations[child] = Number(childRelation);
    unified.osmRelations[remainder] = Number(parentRelation);
    unified.subregions ||= {};
    unified.subregions[parent] = { recipe: "administrative-subtraction", parentRelation: Number(parentRelation),
      child, childRelation: Number(childRelation), remainder, boundarySHA256: hashFile(file),
      source: "OpenStreetMap Nominatim administrative polygons", updatedAt: new Date().toISOString() };
    writeUnified(unified);
    console.log(JSON.stringify(unified.subregions[parent]));
  } finally { fs.rmSync(tmp,{recursive:true,force:true}); }
}
if (require.main === module) { try { main(); } catch(e) { console.error(e); process.exitCode=1; } }
