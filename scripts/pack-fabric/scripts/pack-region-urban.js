#!/usr/bin/env node
"use strict";

/** Build generic, OSM-derived urban walls for a regional routing pack. */
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const FABRIC = path.join(__dirname, "..");
const SLUGS = {
  bc: "british-columbia",
  ab: "alberta",
  wa: "washington"
};

function number(value) {
  const parsed = Number(String(value == null ? "" : value).replace(/[^0-9.]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function flattenCoordinates(value, out) {
  if (!Array.isArray(value)) return;
  if (value.length >= 2 && Number.isFinite(Number(value[0])) && Number.isFinite(Number(value[1]))) {
    out.push([Number(value[0]), Number(value[1])]);
    return;
  }
  for (const child of value) flattenCoordinates(child, out);
}

function centerOf(feature) {
  const coords = [];
  flattenCoordinates(feature.geometry && feature.geometry.coordinates, coords);
  if (!coords.length) return null;
  let lon = 0;
  let lat = 0;
  for (const c of coords) {
    lon += c[0];
    lat += c[1];
  }
  return [lon / coords.length, lat / coords.length];
}

function radiusKm(place, population) {
  if (population >= 1_000_000) return 18;
  if (population >= 500_000) return 14;
  if (population >= 200_000) return 10;
  if (population >= 100_000) return 5.5;
  if (population >= 50_000) return 4.5;
  return place === "city" ? 3.5 : 1.8;
}

function qualifiesAsUrbanCore(place, population) {
  if (place === "town") return population >= 50_000;
  // OSM uses place=city for some small, single-corridor communities. Treating
  // every label as a 3.5 km wall can sever the only mountain-valley road. A
  // population threshold gives every region the same product definition of an
  // urban core; a missing population remains conservative until audited.
  if (place === "city") return population === 0 || population >= 20_000;
  return false;
}

function settlementRadiusKm(place, population) {
  return place === "city"
    ? Math.min(3.5, Math.max(2.2, radiusKm(place, population) * 0.5))
    : Math.min(2.2, Math.max(1.2, radiusKm(place, population)));
}

function box(center, radius, name, place, population, sourceId) {
  const [lon, lat] = center;
  const latDelta = radius / 111.1;
  const lonDelta = radius / (111.1 * Math.max(0.2, Math.cos((lat * Math.PI) / 180)));
  return {
    minLat: +(lat - latDelta).toFixed(5),
    maxLat: +(lat + latDelta).toFixed(5),
    minLon: +(lon - lonDelta).toFixed(5),
    maxLon: +(lon + lonDelta).toFixed(5),
    name,
    place,
    population,
    radiusKm: radius,
    sourceId
  };
}

async function build(id, requestedSlug) {
  const slug = String(requestedSlug || SLUGS[id] || "").toLowerCase();
  if (!slug) {
    throw new Error("Usage: pack-region-urban.js <region-code> [geofabrik-slug]");
  }
  const input = path.join(FABRIC, "data-raw", "osm-urban", slug, "places.geojsonseq");
  if (!fs.existsSync(input)) throw new Error(`Missing ${input}`);
  const byName = new Map();
  const settlementsByName = new Map();
  const stream = readline.createInterface({ input: fs.createReadStream(input), crlfDelay: Infinity });
  for await (const line of stream) {
    const record = line.replace(/^\x1e/, "").trim();
    if (!record) continue;
    const feature = JSON.parse(record);
    const props = feature.properties || {};
    const place = String(props.place || "").toLowerCase();
    if (place !== "city" && place !== "town") continue;
    const center = centerOf(feature);
    if (!center) continue;
    const name = String(props.name || props["name:en"] || props.id || "urban-core");
    const population = number(props.population);
    const row = box(center, radiusKm(place, population), name, place, population, String(props["@id"] || props.id || ""));
    const key = name.toLowerCase();
    const settlementRadius = settlementRadiusKm(place, population);
    const settlement = box(center, settlementRadius, name, place, population, String(props["@id"] || props.id || ""));
    const priorSettlement = settlementsByName.get(key);
    if (
      !priorSettlement || settlement.population > priorSettlement.population ||
      settlement.radiusKm > priorSettlement.radiusKm
    ) {
      settlementsByName.set(key, settlement);
    }
    // Cities and major towns are hard walls. Smaller towns stay in the separate
    // settlement layer so a scored preference can avoid them without severing
    // the only rural through-road.
    if (!qualifiesAsUrbanCore(place, population)) continue;
    const prior = byName.get(key);
    if (!prior || row.population > prior.population || row.radiusKm > prior.radiusKm) byName.set(key, row);
  }
  const cores = [...byName.values()].sort((a, b) => b.population - a.population || a.name.localeCompare(b.name));
  const settlements = [...settlementsByName.values()]
    .filter((row) => !byName.has(row.name.toLowerCase()))
    .sort((a, b) => b.population - a.population || a.name.localeCompare(b.name));
  if (!cores.length) throw new Error(`${id}: OSM place extract produced no urban cores`);
  const output = path.join(FABRIC, "routing", "data", "regions", id, "urban-cores.v1.json");
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(
    output,
    JSON.stringify({
      schemaVersion: "urban-cores.v1",
      regionId: id,
      generatedAt: new Date().toISOString(),
      source: "OpenStreetMap place=city|town",
      method: "population-scaled-core-radius",
      cores,
      settlements
    }, null, 2) + "\n"
  );
  return { id, coreCount: cores.length, settlementCount: settlements.length, output };
}

if (require.main === module) {
  build(String(process.argv[2] || "").toLowerCase(), process.argv[3])
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => { console.error(error); process.exit(1); });
}

module.exports = {
  build,
  radiusKm,
  settlementRadiusKm,
  qualifiesAsUrbanCore,
  box
};
