#!/usr/bin/env node
"use strict";

/**
 * Build thinned per-province longhaul packs for Vercel canada-chain hops.
 *
 * Live mental model:
 *   OSM + NRN = road fabric (driveable basemap roads). Provincial capillary
 *   stays out of these packs — enable via unknown-access on full regional graphs.
 *
 * Hub bulbs keep village/city basemap snaps (Saint-Raymond, Moncton, etc.)
 * without shipping full provincial graphs.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { corridorLocationsForRoute } = require("../routing/regional/merge");
const {
  clipGraphToCorridor,
  extractHighwayGraph,
  extractLonghaulSpineGraph,
  extractRoadFabricLonghaulGraph,
  relabelComponents
} = require("../routing/regional/corridor");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const CODES_DEFAULT = ["ns", "nb", "qc", "on", "mb", "sk", "ab", "bc"];
const CODES = process.argv.slice(2).filter((a) => !a.startsWith("--")).length
  ? process.argv.slice(2).filter((a) => !a.startsWith("--")).map((c) => c.toLowerCase())
  : CODES_DEFAULT;
const BUFFER_M = 200000;

function thinGeometry(coords, maxPts = 6) {
  if (!coords || coords.length <= maxPts) return coords;
  const out = [coords[0]];
  const step = (coords.length - 1) / (maxPts - 1);
  for (let i = 1; i < maxPts - 1; i += 1) {
    out.push(coords[Math.round(i * step)]);
  }
  out.push(coords[coords.length - 1]);
  return out;
}

function load(code) {
  const buf = fs.readFileSync(path.join(REGIONS, code, "graph.v1.json.gz"));
  const g = JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  g.regionId = code;
  return g;
}

const HUBS = {
  qc: [
    { lon: -71.208, lat: 46.813 }, // Quebec City
    { lon: -71.30, lat: 46.95 }, // Lac-Beauport
    { lon: -71.833, lat: 46.899 }, // Saint-Raymond
    { lon: -73.567, lat: 45.502 }, // Montreal
    { lon: -73.75, lat: 45.58 }, // Laval
    { lon: -74.28, lat: 46.05 }, // Sainte-Agathe
    { lon: -74.60, lat: 46.12 }, // Mont-Tremblant
    { lon: -72.543, lat: 46.343 }, // Trois-Rivières
    { lon: -71.93, lat: 45.40 }, // Sherbrooke
    { lon: -72.15, lat: 45.65 }, // Drummondville
    { lon: -75.71, lat: 45.43 }, // Gatineau
    { lon: -71.15, lat: 48.42 }, // Saguenay
    { lon: -70.33, lat: 47.38 }, // Rivière-du-Loup
    { lon: -68.65, lat: 47.55 } // Dégelis / NB approach
  ],
  nb: [
    { lon: -64.778, lat: 46.088 }, // Moncton
    { lon: -66.643, lat: 45.963 }, // Fredericton
    { lon: -66.059, lat: 45.273 }, // Saint John
    { lon: -67.583, lat: 47.376 } // Edmundston / QC approach
  ],
  ns: [
    { lon: -63.575, lat: 44.649 }, // Halifax
    { lon: -63.28, lat: 45.365 }, // Truro
    { lon: -61.39, lat: 46.14 }, // Sydney area
    { lon: -64.52, lat: 44.98 } // Bridgewater / South Shore
  ],
  pe: [{ lon: -63.126, lat: 46.238 }],
  nl: [{ lon: -52.712, lat: 47.561 }]
};

function main() {
  const corridor = corridorLocationsForRoute([
    { lat: 44.6488, lon: -63.575 },
    { lat: 49.2827, lon: -123.1207 }
  ]);
  console.log("corridor waypoints", corridor.length);

  for (const code of CODES) {
    let g = load(code);
    const before = g.edgeCount || (g.edges || []).length;
    const hasRoadClass = (g.edges || []).some((e) => e.rt);
    const hasOsm = (g.edges || []).some((e) => /openstreetmap/i.test(String(e.src || "")));

    const corridorFabric = new Set([]); // dense NRN-everywhere — too large for QC on Hobby
    const hubFabric = new Set(["qc", "on"]); // spine + hub bulbs
    const maritimeFabric = new Set(["ns", "nb", "pe", "nl"]);

    let extractMode = "spine";
    if (hubFabric.has(code)) {
      extractMode = "fabric-hub";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "hub",
        hubLocations: HUBS[code] || [],
        // Wider bulbs so Saint-Raymond / Laurentians / border towns still snap.
        hubBufferMeters: code === "qc" ? 28000 : 45000
      });
    } else if (corridorFabric.has(code)) {
      extractMode = "fabric-corridor";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "corridor",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 50000
      });
    } else if (maritimeFabric.has(code) || hasOsm) {
      extractMode = "fabric-maritime";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "maritime",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 35000
      });
    } else if (!hasRoadClass) {
      extractMode = "highway-no-track";
      g = extractHighwayGraph(g);
    } else {
      extractMode = "longhaul-spine";
      g = extractLonghaulSpineGraph(g);
    }

    const afterSpine = g.edgeCount;
    g = clipGraphToCorridor(g, corridor, BUFFER_M);
    if (String(extractMode).startsWith("fabric")) {
      // Corridor clip can leave stale component labels — refresh only.
      g = relabelComponents(g);
    }
    for (const e of g.edges) e.g = thinGeometry(e.g, 6);
    g.edgeCount = g.edges.length;
    g.regionId = code;
    g.province = String(code).toUpperCase();
    g.schemaVersion = "longhaul-region-1";
    g.lineage = {
      purpose: "canada-chain hop pack (OSM+NRN road fabric; hub bulbs; no provincial)",
      mentalModel: "osm-nrn-fabric",
      source: `regions/${code}/graph.v1.json.gz`,
      hasRoadClass,
      hasOsm,
      extractMode,
      hubCount: (HUBS[code] || []).length,
      corridorBufferMeters: BUFFER_M,
      thinnedGeometry: true,
      inputEdgeCount: before,
      spineEdgeCount: afterSpine,
      outputEdgeCount: g.edgeCount
    };

    const outDir = path.join(REGIONS, code);
    const json = JSON.stringify(g);
    const gz = zlib.gzipSync(Buffer.from(json, "utf8"), { level: 9 });
    fs.writeFileSync(path.join(outDir, "longhaul.v1.json.gz"), gz);
    const meta = {
      regionId: code,
      schemaVersion: g.schemaVersion,
      edgeCount: g.edgeCount,
      nodeCount: g.nodeCount,
      gzBytes: gz.length,
      inflatedBytes: Buffer.byteLength(json),
      path: `routing/data/regions/${code}/longhaul.v1.json.gz`,
      lineage: g.lineage
    };
    fs.writeFileSync(path.join(outDir, "longhaul.v1.meta.json"), JSON.stringify(meta, null, 2));
    console.log(
      code,
      "edges",
      before,
      "→extract",
      afterSpine,
      "→pack",
      g.edgeCount,
      "mode",
      extractMode,
      "gzMB",
      (gz.length / 1e6).toFixed(2),
      "inflMB",
      (meta.inflatedBytes / 1e6).toFixed(1)
    );
  }
}

main();
