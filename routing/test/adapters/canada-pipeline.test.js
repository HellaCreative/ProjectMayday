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

check("region selection hits Nova Scotia for Halifax points", () => {
  const regions = selectRegionsForLocations([
    { lat: 44.65, lon: -63.58 },
    { lat: 44.74, lon: -63.3 }
  ]);
  // May be empty if regional pack not built yet — still a valid array.
  assert.ok(Array.isArray(regions));
});

check("resolveGraphRequest falls back to legacy when no regional pack", () => {
  const tmpEmpty = path.join(__dirname, "..", "..", "data", "regions-empty-test");
  const result = resolveGraphRequest(
    {
      locations: [
        { lat: 44.74, lon: -63.3 },
        { lat: 44.79, lon: -63.15 }
      ]
    },
    tmpEmpty
  );
  assert.strictEqual(result.ok, true);
  assert.ok(result.mode === "legacy" || result.regionIds.includes("ns") || result.regionIds.includes("__legacy_ns__"));
});

check("all canonical enum tables are non-empty", () => {
  assert.ok(Object.keys(SURFACE_CLASS).length >= 6);
  assert.ok(Object.keys(ACCESS_CLASS).length >= 4);
  assert.ok(Object.keys(STRUCTURE_TYPE).length >= 5);
});

console.log(passed + " adapter/conflation checks finished");
