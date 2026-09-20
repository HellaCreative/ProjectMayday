"use strict";

/**
 * Fetch a region's OSM admin polygon and cache it for clip + ownership.
 *
 *   node scripts/pack-fabric/scripts/fetch-admin-polygon.js pe
 */
const fs = require("fs");
const path = require("path");
const https = require("https");
const os = require("os");
const { spawnSync } = require("child_process");
const { osmAdminRelation } = require("../routing/registry/osm-admin");

const FABRIC = path.join(__dirname, "..");
const POLYGON_DIR = path.join(FABRIC, "routing", "data", "region-polygons");
const SCHEMA_PATH = path.join(FABRIC, "routing", "schema", "region-polygons.v1.json");
const IOS_PATH = path.join(FABRIC, "../..", "Dirt", "Routing", "OnDevice", "RegionPolygons.json");
const USER_AGENT = "DirtPackFactory/1.0 (routing pack clip)";

// D.C. is part of the Maryland download, not a gap between two state packs.
// Keep the same ownership geometry in extraction, the registry and the app.
function coverageRelationIds(id) {
  return id === "md" ? [osmAdminRelation(id), 162069] : [osmAdminRelation(id)];
}

function unionCoverage(geometries) {
  if (geometries.length === 1) return geometries[0];
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-admin-coverage-"));
  try {
    const input = path.join(temporary, "coverage.geojson");
    fs.writeFileSync(input, JSON.stringify({ type: "FeatureCollection", features: geometries.map(geometry =>
      ({ type: "Feature", properties: {}, geometry })) }));
    const result = spawnSync("ogr2ogr", ["-f", "GeoJSON", "/vsistdout/", input,
      "-dialect", "sqlite", "-sql", "SELECT ST_Union(geometry) AS geometry FROM coverage"],
      { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    if (result.error || result.status !== 0) throw new Error(`coverage union failed: ${result.error || result.stderr}`);
    const geometry = JSON.parse(result.stdout).features?.[0]?.geometry;
    if (!["Polygon", "MultiPolygon"].includes(geometry?.type)) throw new Error("coverage union has no polygon");
    return geometry;
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function get(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { "User-Agent": USER_AGENT } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return get(res.headers.location).then(resolve, reject);
        }
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          if (res.statusCode !== 200) {
            return reject(new Error(`HTTP ${res.statusCode} ${url}: ${body.slice(0, 200)}`));
          }
          resolve(body);
        });
      })
      .on("error", reject);
  });
}

function loadUnified() {
  if (fs.existsSync(SCHEMA_PATH)) {
    return JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8"));
  }
  return {
    schemaVersion: "dirt-region-polygons.v1",
    source: "OpenStreetMap Nominatim admin boundaries, polygon_threshold=0.005",
    osmRelations: {},
    regions: {}
  };
}

function writeUnified(doc) {
  fs.mkdirSync(POLYGON_DIR, { recursive: true });
  fs.mkdirSync(path.dirname(SCHEMA_PATH), { recursive: true });
  const text = JSON.stringify(doc) + "\n";
  fs.writeFileSync(SCHEMA_PATH, text);
  fs.writeFileSync(path.join(POLYGON_DIR, "atlantic.v1.json"), text);
  fs.writeFileSync(IOS_PATH, text);
}

async function fetchAdminPolygon(regionId, { threshold = "0.005" } = {}) {
  const id = String(regionId || "").toLowerCase();
  const relationId = osmAdminRelation(id);
  const relationIds = coverageRelationIds(id);
  const url =
    "https://nominatim.openstreetmap.org/lookup?osm_ids=" +
    relationIds.map(value => `R${value}`).join(",") +
    "&format=json&polygon_geojson=1&polygon_threshold=" +
    threshold;
  const rows = JSON.parse(await get(url));
  const geometries = relationIds.map(value => {
    const row = Array.isArray(rows) ? rows.find(row => row.osm_type === "relation" && Number(row.osm_id) === value) : null;
    if (!row?.geojson) throw new Error(`Nominatim returned no polygon for ${id} (R${value})`);
    return row.geojson;
  });
  const geometry = unionCoverage(geometries);
  const doc = loadUnified();
  doc.osmRelations = doc.osmRelations || {};
  doc.regions = doc.regions || {};
  doc.osmRelations[id] = relationId;
  doc.coverageRelations = doc.coverageRelations || {};
  doc.coverageRelations[id] = relationIds;
  doc.regions[id] = geometry;
  writeUnified(doc);
  const clipPath = path.join(POLYGON_DIR, `${id}.clip.geojson`);
  fs.writeFileSync(
    clipPath,
    JSON.stringify({
      type: "FeatureCollection",
      features: [{ type: "Feature", properties: { id, osmRelations: relationIds }, geometry }]
    })
  );
  return { id, relationId, coverageRelationIds: relationIds, clipPath, type: geometry.type };
}

function clipGeojsonPath(regionId) {
  const id = String(regionId || "").toLowerCase();
  const cached = path.join(POLYGON_DIR, `${id}.clip.geojson`);
  if (fs.existsSync(cached)) return cached;
  const unified = loadUnified();
  const geom = unified.regions && unified.regions[id];
  if (!geom) return null;
  fs.mkdirSync(POLYGON_DIR, { recursive: true });
  fs.writeFileSync(
    cached,
    JSON.stringify({
      type: "FeatureCollection",
      features: [{ type: "Feature", properties: { id }, geometry: geom }]
    })
  );
  return cached;
}

if (require.main === module) {
  const id = String(process.argv[2] || "").toLowerCase();
  if (!id) {
    console.error("Usage: fetch-admin-polygon.js <region-id>");
    process.exit(1);
  }
  fetchAdminPolygon(id)
    .then((row) => console.log(JSON.stringify(row, null, 2)))
    .catch((err) => {
      console.error(err && err.stack ? err.stack : err);
      process.exit(1);
    });
}

module.exports = {
  SCHEMA_PATH,
  clipGeojsonPath,
  fetchAdminPolygon,
  loadUnified,
  writeUnified,
  coverageRelationIds,
  unionCoverage
};
