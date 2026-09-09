#!/usr/bin/env node
"use strict";
const fs = require("fs"), path = require("path");
const { hashFile } = require("./extract-locked-place-records");
const { radiusKm, settlementRadiusKm, qualifiesAsUrbanCore, box } = require("./pack-region-urban");
const { polygonOwner } = require("../routing/lib/region-polygons");

function population(value) {
  if (value == null || !/^\d[\d, ]*$/.test(value)) return null;
  const n = Number(value.replace(/[, ]/g, ""));
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function build(recordPath) {
  const input = JSON.parse(fs.readFileSync(recordPath)), id = input.regionId;
  if (input.schema !== "dirt-locked-place-records.v1") throw new Error("Source records required");
  const cores = [], settlements = [], missingPopulation = [], excludedByOwnership = [], areaRecords = [];
  for (const row of input.records) {
    if (row.type !== "node") { areaRecords.push(row); continue; }
    const owner = polygonOwner(...row.coordinate);
    if (owner !== id) { excludedByOwnership.push({ ...row, owner }); continue; }
    const tags = row.tags, pop = population(tags.population), place = tags.place;
    if (pop == null) missingPopulation.push(row);
    // Keep the existing national factory threshold. NB's accepted reviewed
    // supplement is supplied separately, not made into a new national rule.
    const core = qualifiesAsUrbanCore(place, pop ?? 0);
    const radius = core ? radiusKm(place, pop ?? 0) : settlementRadiusKm(place, pop ?? 0);
    const result = { ...box(row.coordinate, radius, tags.name || tags["name:en"] || row.sourceId, place, pop, row.sourceId), coordinate: row.coordinate,
      populationRaw: tags.population ?? null, populationYear: tags["population:date"] ?? null, populationSource: tags["source:population"] ?? null };
    (core ? cores : settlements).push(result);
  }
  const sort = (a,b) => (b.population ?? -1) - (a.population ?? -1) || a.sourceId.localeCompare(b.sourceId);
  cores.sort(sort); settlements.sort(sort);
  return { schemaVersion: "urban-cores.v1", regionId: id, revision: "locked-place-nodes-20260909-01", source: "OpenStreetMap place=city|town nodes", method: "population-scaled-core-radius",
    policy: { id: "existing-national-factory-city20k-town50k", cityMinimumPopulation: 20000, townMinimumPopulation: 50000, missingPopulation: "Preserve unknown population; existing factory treats place=city as a core, town as settlement", bounds: "DIRT population-scaled estimates; not measured OSM urban boundaries", areaFeatures: "Retained for audit, outside the node classification policy; no invented centroid or duplicate area wall" },
    provenance: { sourceUrl: input.source.sourceUrl, sourceSha256: input.source.sourceSha256, osmTimestamp: input.source.osmTimestamp, sourceEpoch: input.sourceEpoch, recordsSha256: hashFile(recordPath) },
    completeness: { sourceNodePassComplete: true, nodeCount: input.records.filter(r=>r.type==="node").length, ownedNodeCount: cores.length + settlements.length, missingPopulationCount: missingPopulation.length, areaRecordCount: areaRecords.length, measuredUrbanBoundaries: false },
    cores, settlements, missingPopulation, excludedByOwnership, areaRecords };
}
if (require.main === module) {
  const root = path.resolve(process.argv[2]);
  for (const id of Object.keys(require("../routing/registry/geofabrik").OSM_REGION).sort()) {
    const recordPath = path.join(root, id, "place-records.json"), data = build(recordPath);
    const output = path.join(root, id, "urban-cores.v1.json");
    if (fs.existsSync(output)) throw new Error(`Refusing to overwrite ${output}`);
    fs.writeFileSync(output, JSON.stringify(data, null, 2) + "\n");
    console.log(JSON.stringify({ id, cores: data.cores.length, settlements: data.settlements.length, ...data.completeness }));
  }
}
module.exports = { build, population };
