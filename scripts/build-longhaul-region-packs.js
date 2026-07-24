#!/usr/bin/env node
"use strict";

/**
 * Build thinned per-province longhaul packs for Vercel canada-chain hops.
 *
 * Province fabrics:
 *   QC / PE / ON / MB / SK / AB / BC — OSM-only (no NRN) when built that way.
 *        PE / SK stay OSM-only permanently; ON/AB/BC gain provincial overlays later.
 *   NS — OSM + NSTDB (no NRN); provincial capillary stays in the pack so Allow
 *        unknown can use purple TRACK. NRN highway spine is dropped.
 *   NB — OSM + Forest Roads (no NRN); provincial kept like NS so NS↔NB Allow
 *        works. Capillary is weaker than NSTDB on surface/class (see map doc).
 *   Others (legacy) — OSM + NRN fabric; provincial capillary omitted (size)
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
  on: [
    { lon: -75.697, lat: 45.421 }, // Ottawa
    { lon: -79.383, lat: 43.653 }, // Toronto
    { lon: -79.25, lat: 43.16 }, // Niagara / St. Catharines
    { lon: -80.25, lat: 43.55 }, // Kitchener / Waterloo
    { lon: -81.25, lat: 42.98 }, // London
    { lon: -82.98, lat: 42.31 }, // Windsor approach
    { lon: -78.32, lat: 44.3 }, // Peterborough
    { lon: -77.14, lat: 44.23 }, // Belleville / 401
    { lon: -76.5, lat: 44.23 }, // Kingston
    { lon: -74.73, lat: 45.02 }, // Cornwall / QC approach
    { lon: -74.58, lat: 45.61 }, // Hawkesbury / QC border
    { lon: -76.5, lat: 45.48 }, // Renfrew / Ottawa Valley
    { lon: -79.69, lat: 44.39 }, // Barrie / cottage approach
    { lon: -79.46, lat: 46.31 }, // North Bay
    { lon: -81.0, lat: 46.49 }, // Sudbury
    { lon: -84.35, lat: 46.52 }, // Sault Ste. Marie
    { lon: -89.247, lat: 48.38 }, // Thunder Bay
    { lon: -94.49, lat: 49.78 }, // Kenora / MB approach
    { lon: -80.4, lat: 45.35 }, // Parry Sound / 400 corridor
    { lon: -77.9, lat: 45.03 } // Bancroft / Madawaska
  ],
  mb: [
    { lon: -97.138, lat: 49.895 }, // Winnipeg
    { lon: -97.94, lat: 49.85 }, // Portage la Prairie
    { lon: -99.95, lat: 49.85 }, // Brandon
    { lon: -98.1, lat: 49.5 }, // Winkler / southern corridor
    { lon: -97.2, lat: 50.2 }, // Selkirk / north of Winnipeg
    { lon: -94.49, lat: 49.78 }, // Kenora ON / MB approach
    { lon: -101.3, lat: 49.7 }, // SK border / Virden approach
    { lon: -98.9, lat: 51.2 }, // Dauphin
    { lon: -97.85, lat: 53.97 } // Thompson approach
  ],
  sk: [
    { lon: -104.618, lat: 50.445 }, // Regina
    { lon: -106.67, lat: 52.133 }, // Saskatoon
    { lon: -105.55, lat: 50.4 }, // Moose Jaw
    { lon: -102.48, lat: 51.22 }, // Yorkton
    { lon: -108.3, lat: 52.77 }, // North Battleford
    { lon: -109.17, lat: 51.45 }, // Kindersley / west
    { lon: -101.4, lat: 49.7 }, // MB border approach
    { lon: -110.0, lat: 49.7 }, // AB border approach
    { lon: -104.0, lat: 49.15 } // Estevan / south
  ],
  ab: [
    { lon: -114.071, lat: 51.045 }, // Calgary
    { lon: -113.491, lat: 53.547 }, // Edmonton
    { lon: -113.0, lat: 53.55 }, // Sherwood Park / east Edmonton
    { lon: -114.0, lat: 51.2 }, // Airdrie / north Calgary
    { lon: -112.83, lat: 49.69 }, // Lethbridge
    { lon: -110.0, lat: 49.7 }, // SK border approach
    { lon: -116.4, lat: 51.2 }, // BC divide / Lake Louise band
    { lon: -115.57, lat: 51.18 }, // Banff / Bow Valley
    { lon: -111.38, lat: 56.73 }, // Fort McMurray approach
    { lon: -118.8, lat: 55.17 }, // Grande Prairie
    { lon: -113.82, lat: 52.27 } // Red Deer
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
    const hubFabric = new Set([]); // legacy NRN hub bulbs — west graduated to osmProvince
    const maritimeFabric = new Set(["nl"]); // PE is osm-only below; NS/NB osm-provincial
    // Full OSM fabric; no NRN; one pack per province (Phase 1 west + east OSM-only).
    const osmProvince = new Set(["qc", "pe", "on", "mb", "sk", "ab", "bc"]);
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
      // ON (and later large west packs): drop remote service mesh so QC|ON
      // canada-chain hops fit Hobby 2048 MB. PE/QC stay full fabric.
      const largeOsm = code === "on" || code === "ab" || code === "bc";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "osm",
        hubLocations: HUBS[code] || [],
        hubBufferMeters: 40000,
        dropService: largeOsm
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
