#!/usr/bin/env node
"use strict";

/**
 * Build thinned per-province longhaul packs for Vercel canada-chain hops.
 *
 * Province fabrics:
 *   QC / PE — OSM-only (no NRN). PE has no shippable provincial capillary.
 *   NS — OSM + NSTDB (no NRN); provincial capillary stays in the pack so Allow
 *        unknown can use purple TRACK. NRN highway spine is dropped.
 *   NB — OSM + Forest Roads (no NRN); provincial kept like NS so NS↔NB Allow
 *        works. Capillary is weaker than NSTDB on surface/class (see map doc).
 *   Others — OSM + NRN fabric; provincial capillary omitted (size)
 *
 * Hub bulbs keep village/city basemap snaps without shipping every full pack.
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
    { lon: -71.068, lat: 48.428 }, // Chicoutimi / Saguenay downtown (not river)
    { lon: -72.23, lat: 48.52 }, // Roberval / Lac-Saint-Jean
    { lon: -71.65, lat: 48.55 }, // Alma
    { lon: -70.33, lat: 47.38 }, // Rivière-du-Loup
    { lon: -68.65, lat: 47.55 }, // Dégelis / NB approach
    { lon: -70.67, lat: 46.12 } // Saint-Georges / Beauce
  ],
  nb: [
    { lon: -64.778, lat: 46.088 }, // Moncton
    { lon: -66.643, lat: 45.963 }, // Fredericton
    { lon: -66.059, lat: 45.273 }, // Saint John
    { lon: -67.583, lat: 47.376 }, // Edmundston / QC approach
    { lon: -64.21, lat: 45.83 }, // Amherst NS / NB border approach
    { lon: -63.81, lat: 46.16 } // Cape Jourimain / Confederation Bridge approach
  ],
  ns: [
    { lon: -63.575, lat: 44.649 }, // Halifax
    { lon: -63.28, lat: 45.365 }, // Truro
    { lon: -61.39, lat: 46.14 }, // Sydney area
    { lon: -64.52, lat: 44.98 }, // Bridgewater / South Shore
    { lon: -64.21, lat: 45.83 } // Amherst / NB border approach
  ],
  pe: [
    { lon: -63.126, lat: 46.238 }, // Charlottetown
    { lon: -63.79, lat: 46.395 }, // Summerside
    { lon: -63.70, lat: 46.25 }, // Borden-Carleton / bridge
    { lon: -62.98, lat: 46.42 }, // Souris approach / east
    { lon: -64.0, lat: 46.8 } // Tignish / north tip approach
  ],
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

    const corridorFabric = new Set([]); // dense NRN-everywhere — too large for Hobby
    const hubFabric = new Set(["on"]); // spine + hub bulbs (QC is OSM-only below)
    const maritimeFabric = new Set(["nl"]); // PE is osm-only below; NS/NB osm-provincial
    const osmProvince = new Set(["qc", "pe"]); // full OSM fabric; no NRN; one pack per province
    const osmProvincialProvince = new Set(["ns", "nb"]); // OSM + provincial; no NRN

    let extractMode = "spine";
    if (osmProvincialProvince.has(code)) {
      extractMode = "fabric-osm-provincial";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "osm-provincial",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 40000
      });
    } else if (osmProvince.has(code)) {
      extractMode = "fabric-osm-only";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "osm",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 40000
      });
    } else if (hubFabric.has(code)) {
      extractMode = "fabric-hub";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "hub",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 45000
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
    // QC OSM-only + NS/NB OSM+provincial packs are full-province (Hobby-safe after thin).
    // Other packs stay clipped to the national southern corridor.
    if (!osmProvince.has(code) && !osmProvincialProvince.has(code)) {
      g = clipGraphToCorridor(g, corridor, BUFFER_M);
    }
    if (String(extractMode).startsWith("fabric")) {
      // Corridor clip can leave stale component labels — refresh only.
      g = relabelComponents(g);
    }
    for (const e of g.edges) e.g = thinGeometry(e.g, 6);
    g.edgeCount = g.edges.length;
    g.regionId = code;
    g.province = String(code).toUpperCase();
    g.schemaVersion = "longhaul-region-1";
    const keepProvincial = osmProvincialProvince.has(code);
    const qcOsmOnly = osmProvince.has(code);
    const mentalModel = keepProvincial
      ? code === "ns"
        ? "osm-nstdb-fabric"
        : "osm-provincial-fabric"
      : qcOsmOnly
        ? "osm-fabric-province"
        : "osm-nrn-fabric";
    g.lineage = {
      purpose: keepProvincial
        ? code === "ns"
          ? "canada-chain / in-province pack (OSM+NSTDB; no NRN)"
          : "canada-chain / in-province pack (OSM+Forest Roads; no NRN)"
        : qcOsmOnly
          ? "canada-chain / in-province pack (OSM-only; no NRN)"
          : "canada-chain hop pack (OSM+NRN road fabric; hub bulbs; no provincial)",
      mentalModel,
      source: `regions/${code}/graph.v1.json.gz`,
      hasRoadClass,
      hasOsm,
      extractMode,
      dropNrn: keepProvincial || qcOsmOnly || undefined,
      keepProvincial: keepProvincial || undefined,
      hubCount: (HUBS[code] || []).length,
      corridorBufferMeters: keepProvincial || qcOsmOnly ? null : BUFFER_M,
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
