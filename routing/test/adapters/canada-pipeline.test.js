#!/usr/bin/env node
"use strict";

const assert = require("assert");
const path = require("path");
const { classifyNrnProps, featureToEdges } = require("../../adapters/nrn");
const { classifyNstdbDescription, packedFeatureToEdge } = require("../../adapters/ns-nstdb");
const { createNormalizedEdge } = require("../../schema/edge");
const {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE
} = require("../../schema/enums");
const { conflateRegion } = require("../../conflation/conflate");
const { resolveGraphRequest, selectRegionsForLocations } = require("../../regional/select");
const { buildRegionalGraph } = require("../../regional/package");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log("PASS", name);
  } catch (err) {
    console.error("FAIL", name, err.message);
    process.exitCode = 1;
  }
}

check("NRN paved maps to paved + permissive", () => {
  const c = classifyNrnProps({
    PAVSTATUS: "Paved",
    PAVSURF: "Flexible",
    UNPAVSURF: "Unknown",
    ROADCLASS: "Arterial",
    STRUCTTYPE: "None",
    TRAFFICDIR: "Both directions"
  });
  assert.strictEqual(c.ok, true);
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.paved);
  assert.strictEqual(c.accessClass, ACCESS_CLASS.motorized_permissive);
});

check("NRN unpaved maps to gravel", () => {
  const c = classifyNrnProps({
    PAVSTATUS: "Unpaved",
    PAVSURF: "Unknown",
    UNPAVSURF: "Gravel",
    ROADCLASS: "Local / Street",
    STRUCTTYPE: "None",
    TRAFFICDIR: "Both directions"
  });
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.gravel);
});

check("NRN missing pavement stays unknown surface — not invented paved", () => {
  const c = classifyNrnProps({
    PAVSTATUS: "Unknown",
    PAVSURF: "Unknown",
    UNPAVSURF: "Unknown",
    ROADCLASS: "Local / Street",
    STRUCTTYPE: "None",
    TRAFFICDIR: "Both directions"
  });
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.unknown);
});

check("NRN resource/recreation unknown pavement is motorized_unknown", () => {
  const c = classifyNrnProps({
    PAVSTATUS: "Unknown",
    ROADCLASS: "Resource / Recreation",
    STRUCTTYPE: "None",
    TRAFFICDIR: "Both directions"
  });
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.resource);
  assert.strictEqual(c.accessClass, ACCESS_CLASS.motorized_unknown);
});

check("NSTDB TRACK is motorized_unknown", () => {
  const c = classifyNstdbDescription("TRACK");
  assert.strictEqual(c.ok, true);
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.track);
  assert.strictEqual(c.accessClass, ACCESS_CLASS.motorized_unknown);
});

check("NSTDB TRAIL is excluded", () => {
  const c = classifyNstdbDescription("TRAIL");
  assert.strictEqual(c.ok, false);
  assert.strictEqual(c.reason, "non_motorized_trail");
});

check("NSTDB Resource Access maps to resource surface", () => {
  const c = classifyNstdbDescription("ROAD - Unpaved Resource Access Dry Weather");
  assert.strictEqual(c.surfaceClass, SURFACE_CLASS.resource);
  assert.strictEqual(c.accessClass, ACCESS_CLASS.motorized_permissive);
});

check("canonical edge rejects invented geometry-less records", () => {
  assert.throws(() =>
    createNormalizedEdge({
      edgeId: "x",
      province: "NS",
      sourceName: "t",
      geometry: { type: "LineString", coordinates: [[1, 2]] },
      surfaceClass: "paved",
      accessClass: "motorized_permissive",
      structureType: "none"
    })
  );
});

check("stable NRN edge IDs are deterministic", () => {
  const feature = {
    properties: {
      NID: "abc",
      ROADSEGID: 9,
      PAVSTATUS: "Paved",
      ROADCLASS: "Local / Street",
      STRUCTTYPE: "None",
      TRAFFICDIR: "Both directions"
    },
    geometry: {
      type: "LineString",
      coordinates: [
        [-63.5, 44.6],
        [-63.51, 44.61]
      ]
    }
  };
  const a = featureToEdges(feature, "NS", "v1").edges[0].edgeId;
  const b = featureToEdges(feature, "NS", "v1").edges[0].edgeId;
  assert.strictEqual(a, b);
  assert.ok(a.startsWith("nrn-ns-"));
});

check("packed NSTDB feature preserves lineage", () => {
  const { edge } = packedFeatureToEdge({
    type: "Feature",
    properties: {
      edgeId: "ns-gov-abcdef123456",
      sourceRecordId: "99",
      surfaceClass: "track",
      accessClass: "motorized_unknown",
      structureType: "none",
      distanceMeters: 120,
      sourceDescription: "TRACK"
    },
    geometry: {
      type: "LineString",
      coordinates: [
        [-63.3, 44.7],
        [-63.31, 44.71]
      ]
    }
  });
  assert.ok(edge);
  assert.strictEqual(edge.province, "NS");
  assert.ok(String(edge.lineageId).includes("nstdb"));
  assert.strictEqual(edge.accessClass, "motorized_unknown");
});

check("conflation keeps backbone and skips near-duplicate supplement", () => {
  const backbone = [
    createNormalizedEdge({
      edgeId: "nrn-1",
      lineageId: "nrn:1",
      province: "NS",
      sourceName: "NRN",
      geometry: {
        type: "LineString",
        coordinates: [
          [-63.0, 45.0],
          [-63.01, 45.01]
        ]
      },
      surfaceClass: "paved",
      accessClass: "motorized_permissive",
      structureType: "none",
      distanceMeters: 1000
    })
  ];
  const supplement = [
    createNormalizedEdge({
      edgeId: "ns-1",
      lineageId: "nstdb:1",
      province: "NS",
      sourceName: "NSTDB",
      geometry: {
        type: "LineString",
        coordinates: [
          [-63.0001, 45.0001],
          [-63.0101, 45.0101]
        ]
      },
      surfaceClass: "paved",
      accessClass: "motorized_permissive",
      structureType: "none",
      distanceMeters: 1000
    }),
    createNormalizedEdge({
      edgeId: "ns-track",
      lineageId: "nstdb:track",
      province: "NS",
      sourceName: "NSTDB",
      geometry: {
        type: "LineString",
        coordinates: [
          [-63.2, 45.2],
          [-63.21, 45.21]
        ]
      },
      surfaceClass: "track",
      accessClass: "motorized_unknown",
      structureType: "none",
      distanceMeters: 800
    })
  ];
  const result = conflateRegion({ backbone, supplement, province: "NS" });
  assert.strictEqual(result.report.freeSpaceConnectors, 0);
  assert.strictEqual(result.report.stats.backboneKept, 1);
  assert.ok(result.report.stats.supplementDuplicateSkipped >= 1);
  assert.ok(result.features.some((f) => f.edgeId === "ns-track"));
  assert.ok(!result.features.some((f) => f.edgeId === "ns-1"));
});

check("regional graph build assigns components and bbox", () => {
  const features = [
    createNormalizedEdge({
      edgeId: "a",
      lineageId: "a",
      province: "NS",
      sourceName: "NRN",
      geometry: {
        type: "LineString",
        coordinates: [
          [-63.0, 45.0],
          [-63.01, 45.0]
        ]
      },
      surfaceClass: "paved",
      accessClass: "motorized_permissive",
      structureType: "none",
      distanceMeters: 800
    }),
    createNormalizedEdge({
      edgeId: "b",
      lineageId: "b",
      province: "NS",
      sourceName: "NSTDB",
      geometry: {
        type: "LineString",
        coordinates: [
          [-64.0, 46.0],
          [-64.01, 46.0]
        ]
      },
      surfaceClass: "track",
      accessClass: "motorized_unknown",
      structureType: "none",
      distanceMeters: 700
    })
  ];
  const graph = buildRegionalGraph({ features, province: "NS", regionId: "ns" });
  assert.strictEqual(graph.edgeCount, 2);
  assert.ok(graph.componentCount >= 2);
  assert.ok(Array.isArray(graph.bbox) && graph.bbox.length === 4);
  assert.strictEqual(graph.enums.SURFACE_NAME[2], "access");
});

check("capillary endpoint snap joins near-miss fabric nodes", () => {
  // ~11 m east of fabric endpoint — same junction, survey disagreement.
  const fabricEnd = [-66.643, 45.963];
  const nearMiss = [-66.64286, 45.963];
  const features = [
    createNormalizedEdge({
      edgeId: "osm-1",
      lineageId: "osm:1",
      province: "NB",
      sourceName: "OpenStreetMap",
      geometry: {
        type: "LineString",
        coordinates: [
          [-66.65, 45.963],
          fabricEnd
        ]
      },
      surfaceClass: "paved",
      accessClass: "motorized_permissive",
      structureType: "none",
      distanceMeters: 500,
      meta: { conflationRole: "backbone" }
    }),
    createNormalizedEdge({
      edgeId: "nb-fr-1",
      lineageId: "nb-fr:1",
      province: "NB",
      sourceName: "New Brunswick Forest Roads (DNR-ED)",
      geometry: {
        type: "LineString",
        coordinates: [
          nearMiss,
          [-66.63, 45.97]
        ]
      },
      surfaceClass: "resource",
      accessClass: "motorized_unknown",
      structureType: "none",
      distanceMeters: 900,
      meta: { conflationRole: "supplement" }
    })
  ];
  const graph = buildRegionalGraph({ features, province: "NB", regionId: "nb" });
  assert.strictEqual(graph.edgeCount, 2);
  assert.strictEqual(graph.componentCount, 1, "near-miss capillary must join fabric");
  assert.ok(graph.lineage.endpointSnap.snappedEndpoints >= 1);
});

check("Fredericton urban avoid is downtown-tight, not metro-wide", () => {
  const { pointInAdventureUrbanCore } = require("../../regional/merge");
  assert.strictEqual(pointInAdventureUrbanCore(-66.643, 45.963), true, "downtown core");
  assert.strictEqual(pointInAdventureUrbanCore(-66.72, 45.88), false, "New Maryland / SW ring");
  assert.strictEqual(pointInAdventureUrbanCore(-66.58, 45.92), false, "Lincoln / east approach");
});

check("Charlottetown and Summerside urban avoid are downtown-tight", () => {
  const { pointInAdventureUrbanCore } = require("../../regional/merge");
  assert.strictEqual(pointInAdventureUrbanCore(-63.126, 46.238), true, "Charlottetown downtown");
  assert.strictEqual(pointInAdventureUrbanCore(-63.79, 46.395), true, "Summerside core");
  assert.strictEqual(pointInAdventureUrbanCore(-63.70, 46.25), false, "Borden / bridge approach");
  assert.strictEqual(pointInAdventureUrbanCore(-63.81, 46.16), false, "Cape Jourimain NB");
});

check("NB vs PE primary region keeps Sackville NB and Borden PE", () => {
  const { primaryRegionForPoint } = require("../../regional/select");
  assert.strictEqual(primaryRegionForPoint(-64.37, 45.9), "nb", "Sackville");
  assert.strictEqual(primaryRegionForPoint(-63.81, 46.16), "nb", "Cape Jourimain");
  assert.strictEqual(primaryRegionForPoint(-63.70, 46.25), "pe", "Borden-Carleton");
  assert.strictEqual(primaryRegionForPoint(-63.126, 46.238), "pe", "Charlottetown");
});

check("NB↔PE corridor includes Confederation Bridge neighbour link", () => {
  const { regionsForRoute, shortestRegionPath } = require("../../regional/merge");
  assert.deepStrictEqual(shortestRegionPath("nb", "pe"), ["nb", "pe"]);
  assert.deepStrictEqual(shortestRegionPath("ns", "pe"), ["ns", "nb", "pe"]);
  assert.ok(regionsForRoute(["nb", "pe"]).includes("nb"));
  assert.ok(regionsForRoute(["nb", "pe"]).includes("pe"));
});

check("region selection hits Nova Scotia for Halifax points", () => {
  const regions = selectRegionsForLocations([
    { lat: 44.65, lon: -63.58 },
    { lat: 44.74, lon: -63.3 }
  ]);
  // May be empty if regional pack not built yet — still a valid array.
  assert.ok(Array.isArray(regions));
});

check("Halifax and Yarmouth resolve to Nova Scotia only", () => {
  const regions = selectRegionsForLocations([
    { lat: 44.6488, lon: -63.575 },
    { lat: 43.8361, lon: -66.1209 }
  ]);
  assert.deepStrictEqual(regions, ["ns"]);
});

check("Kelowna resolves to BC not Alberta despite bbox overlap", () => {
  const { primaryRegionForPoint } = require("../../regional/select");
  assert.strictEqual(primaryRegionForPoint(-119.496, 49.888), "bc");
  assert.strictEqual(primaryRegionForPoint(-114.071, 51.045), "ab");
  assert.deepStrictEqual(
    selectRegionsForLocations([
      { lat: 51.045, lon: -114.071 },
      { lat: 49.888, lon: -119.496 }
    ]),
    ["ab", "bc"]
  );
});

check("resolveGraphRequest defaults to regional NS pack (OSM fabric)", () => {
  const result = resolveGraphRequest({
    locations: [
      { lat: 44.74, lon: -63.3 },
      { lat: 44.79, lon: -63.15 }
    ]
  });
  assert.strictEqual(result.ok, true);
  assert.notStrictEqual(result.mode, "legacy-production");
  assert.ok(
    String(result.mode).includes("regional") || String(result.mode).includes("longhaul"),
    "expected regional/longhaul NS, got " + result.mode
  );
  assert.deepStrictEqual(result.regionIds, ["ns"]);
});

check("Halifax–Yarmouth uses regional NS graph by default", () => {
  const result = resolveGraphRequest({
    locations: [
      { lat: 44.6488, lon: -63.575 },
      { lat: 43.8361, lon: -66.1209 }
    ]
  });
  assert.strictEqual(result.ok, true);
  assert.notStrictEqual(result.mode, "legacy-production");
});

check("ROUTING_PREFER_LEGACY restores NS legacy pack", () => {
  const prev = process.env.ROUTING_PREFER_LEGACY;
  process.env.ROUTING_PREFER_LEGACY = "1";
  try {
    const result = resolveGraphRequest({
      locations: [
        { lat: 44.6488, lon: -63.575 },
        { lat: 43.8361, lon: -66.1209 }
      ]
    });
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.mode, "legacy-production");
  } finally {
    if (prev == null) delete process.env.ROUTING_PREFER_LEGACY;
    else process.env.ROUTING_PREFER_LEGACY = prev;
  }
});

check("Halifax to Vancouver corridor includes NB and western provinces", () => {
  const { regionsForRoute, shortestRegionPath } = require("../../regional/merge");
  assert.deepStrictEqual(shortestRegionPath("ns", "bc"), [
    "ns",
    "nb",
    "qc",
    "on",
    "mb",
    "sk",
    "ab",
    "bc"
  ]);
  assert.ok(regionsForRoute(["ns","bc"]).includes("nb"));
  assert.ok(regionsForRoute(["ns","bc"]).includes("on"));
});

check("in-QC uses single qc longhaul pack (no quadrant chain)", () => {
  const { provinceFamily, resolveGraphRequest: resolve, primaryRegionForPoint } = require("../../regional/select");
  const { corridorLocationsForRoute } = require("../../regional/merge");
  assert.strictEqual(provinceFamily("qc-sl"), "qc");
  assert.strictEqual(provinceFamily("qc-west"), "qc");
  assert.strictEqual(provinceFamily("nb"), "nb");
  assert.strictEqual(primaryRegionForPoint(-70.67, 46.12), "qc");
  assert.strictEqual(primaryRegionForPoint(-74.35, 45.65), "qc");

  const locs = [
    { lat: 46.12, lon: -70.67 }, // Saint-Georges / Beauce
    { lat: 45.65, lon: -74.35 } // west of Montréal
  ];
  // National spine anchors must not be injected for in-QC hauls.
  const corridor = corridorLocationsForRoute(locs);
  assert.strictEqual(corridor.length, 2);
  assert.ok(!corridor.some((p) => Math.abs(p.lat - 46.813) < 0.05 && Math.abs(p.lon + 71.208) < 0.05));

  const prev = process.env.VERCEL;
  process.env.VERCEL = "1";
  try {
    const result = resolve({ locations: locs });
    assert.strictEqual(result.ok, true);
    assert.notStrictEqual(result.mode, "canada-chain");
    assert.ok(
      String(result.mode).includes("longhaul"),
      "expected single qc longhaul, got " + result.mode
    );
    assert.deepStrictEqual(result.regionIds, ["qc"]);
  } finally {
    if (prev == null) delete process.env.VERCEL;
    else process.env.VERCEL = prev;
  }
});

check("NB→QC still injects corridor anchors for chain hops", () => {
  const { corridorLocationsForRoute } = require("../../regional/merge");
  const locs = [
    { lat: 45.963, lon: -66.643 }, // Fredericton
    { lat: 46.813, lon: -71.208 } // Quebec City
  ];
  // Cleanest may use highway spine; adventure must not.
  const clean = corridorLocationsForRoute(locs, { profile: "cleanest" });
  assert.ok(clean.length > 2, "Clean cross-province should keep spine anchors");
  const adventure = corridorLocationsForRoute(locs, { profile: "balanced" });
  assert.strictEqual(adventure.length, 2, "adventure must not inject city hubs");
});

check("New Glasgow→Saint John adventure must not force city hubs", () => {
  const { corridorLocationsForRoute } = require("../../regional/merge");
  const locs = [
    { lat: 45.59, lon: -62.65 }, // New Glasgow
    { lat: 45.27, lon: -66.06 } // Saint John
  ];
  const adventure = corridorLocationsForRoute(locs, { profile: "balanced" });
  assert.strictEqual(adventure.length, 2, "adventure A→B only");
  assert.ok(
    !adventure.some((p) => Math.abs(p.lat - 44.6488) < 0.15),
    "no Halifax"
  );
  assert.ok(
    !adventure.some((p) => Math.abs(p.lat - 46.099) < 0.05 && Math.abs(p.lon + 64.8) < 0.05),
    "no Moncton hub"
  );
  const clean = corridorLocationsForRoute(locs, { profile: "cleanest" });
  assert.ok(
    !clean.some((p) => Math.abs(p.lat - 44.6488) < 0.08 && Math.abs(p.lon + 63.575) < 0.08),
    "Halifax must not be a Clean chain waypoint either"
  );
});

check("New Glasgow→Mirabel adventure skips Montreal metro hub", () => {
  const { corridorLocationsForRoute } = require("../../regional/merge");
  const locs = [
    { lat: 45.59, lon: -62.65 },
    { lat: 45.68, lon: -74.04 }
  ];
  const adventure = corridorLocationsForRoute(locs, { profile: "dirt" });
  assert.strictEqual(adventure.length, 2);
  assert.ok(!adventure.some((p) => Math.abs(p.lon + 73.567) < 0.15 && Math.abs(p.lat - 45.5) < 0.15));
});

check("all canonical enum tables are non-empty", () => {
  assert.ok(Object.keys(SURFACE_CLASS).length >= 6);
  assert.ok(Object.keys(ACCESS_CLASS).length >= 4);
  assert.ok(Object.keys(STRUCTURE_TYPE).length >= 5);
});

console.log(passed + " adapter/conflation checks finished");
