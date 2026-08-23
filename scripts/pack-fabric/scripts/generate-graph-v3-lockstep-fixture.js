#!/usr/bin/env node
"use strict";

/**
 * Phase D: build NS v3 candidate + JS golden lockstep fixture for Swift tests.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/generate-graph-v3-lockstep-fixture.js
 *
 * Writes:
 *   DirtTests/Fixtures/ns-graph.v3.candidate.bin
 *   DirtTests/Fixtures/ns-graph.v3.lockstep.json
 */
const fs = require("fs");
const path = require("path");
const osmRoads = require("../routing/adapters/osm-roads");
const { buildRegionalGraph } = require("../routing/regional/package");
const { encodeFromV1, decodeGraphV2 } = require("../routing/lib/pack-v2");

const ROOT = path.join(__dirname, "../../..");
const SEQ = path.join(
  __dirname,
  "..",
  "data-raw",
  "osm-roads",
  "nova-scotia",
  "roads.geojsonseq"
);
const OUT_DIR = path.join(ROOT, "DirtTests", "Fixtures");
const OUT_BIN = path.join(OUT_DIR, "ns-graph.v3.candidate.bin");
const OUT_JSON = path.join(OUT_DIR, "ns-graph.v3.lockstep.json");

async function main() {
  console.log("building NS intermediate graph…");
  const { features } = await osmRoads.run({
    inputPath: SEQ,
    province: "NS",
    datasetVersion: "phase-d-fixture"
  });
  const graph = buildRegionalGraph({
    features,
    regionId: "ns",
    province: "NS",
    lineage: { phase: "D-lockstep-fixture" }
  });
  console.log("encoding v3… edges=", graph.edges.length);
  const { graphBuffer } = encodeFromV1(graph);
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(OUT_BIN, graphBuffer);

  const decoded = decodeGraphV2(graphBuffer);
  if (!decoded.hasLeaves) throw new Error("fixture pack missing leaves");

  const sampleSet = new Set();
  for (let ei = 0; ei < decoded.undirectedEdgeCount; ei += 500) sampleSet.add(ei);
  // Always include first/last
  sampleSet.add(0);
  sampleSet.add(decoded.undirectedEdgeCount - 1);

  let atvDesignatedMeters = 0;
  let atvDesignatedEdges = 0;
  for (let ei = 0; ei < decoded.undirectedEdgeCount; ei += 1) {
    if (decoded.edgeFlags[ei] & 1) {
      sampleSet.add(ei);
      atvDesignatedMeters += decoded.edgeMeters[ei];
      atvDesignatedEdges += 1;
    }
  }

  const samples = [...sampleSet]
    .sort((a, b) => a - b)
    .map((ei) => {
      const grade = decoded.edgeGrade[ei];
      const surfaceIdx = decoded.edgeSurfaceLeaf[ei];
      const roadIdx = decoded.edgeRoadClassLeaf[ei];
      const structIdx = decoded.edgeStructureLeaf[ei];
      const accessIdx = decoded.edgeAccessLeaf[ei];
      const surfaceNames = decoded.enums.surfaceLeafNames || [""];
      const roadNames = decoded.enums.roadClassLeafNames || ["unknown"];
      const structNames = decoded.enums.structureLeafNames || [""];
      const accessNames = decoded.enums.accessLeafNames || [""];
      const surfaceLeaf = surfaceIdx === 0 ? null : surfaceNames[surfaceIdx] || null;
      const roadClassLeaf = roadNames[roadIdx] || "unknown";
      const structureLeaf = structIdx === 0 ? null : structNames[structIdx] || null;
      const accessLeaf = accessIdx === 0 ? null : accessNames[accessIdx] || null;
      return {
        edgeIndex: ei,
        meters: decoded.edgeMeters[ei],
        surfaceLeaf: surfaceLeaf === "" ? null : surfaceLeaf,
        roadClassLeaf: roadClassLeaf === "" ? "unknown" : roadClassLeaf,
        tracktype: grade & 0x0f,
        smoothness: (grade >> 4) & 0x0f,
        layer: decoded.edgeLayer[ei],
        structureLeaf: structureLeaf === "" ? null : structureLeaf,
        accessLeaf: accessLeaf === "" ? null : accessLeaf,
        atvDesignated: (decoded.edgeFlags[ei] & 1) !== 0
      };
    });

  const fixture = {
    generatedAt: new Date().toISOString(),
    candidateFile: "ns-graph.v3.candidate.bin",
    undirectedEdgeCount: decoded.undirectedEdgeCount,
    atvDesignatedEdges,
    atvDesignatedKm: Number((atvDesignatedMeters / 1000).toFixed(3)),
    sampleCount: samples.length,
    sampleEvery: 500,
    note: "tracktype/smoothness are edgeGrade nibbles (JS/Swift lockstep codes, not strings)",
    samples
  };
  fs.writeFileSync(OUT_JSON, JSON.stringify(fixture, null, 2) + "\n");
  console.log(
    JSON.stringify(
      {
        outBin: OUT_BIN,
        outJson: OUT_JSON,
        bytes: graphBuffer.length,
        edges: decoded.undirectedEdgeCount,
        samples: samples.length,
        atvDesignatedKm: fixture.atvDesignatedKm,
        atvDesignatedEdges
      },
      null,
      2
    )
  );
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
