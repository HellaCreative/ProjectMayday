#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { buildGraphFromOsm } = require("../routing/lib/legal-topology/osm-graph");
const { encodeFromOsmGraph } = require("../routing/lib/pack-v4");

const DIRT = path.resolve(__dirname, "../../..");
const dests = [
  path.join(DIRT, "DirtTests/Fixtures"),
  path.join(DIRT, "scripts/pack-fabric/routing/fixtures/legal-topology")
];

function write(name, osm) {
  const graph = buildGraphFromOsm(osm);
  const encoded = encodeFromOsmGraph(graph, { regionId: "fix", sourceEpoch: "fixture" });
  for (const dir of dests) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `${name}.graph.v4.bin`), encoded.graphBuffer);
    fs.writeFileSync(path.join(dir, `${name}.geometry.v1.bin`), encoded.geomBuffer);
  }
  console.log("wrote", name, encoded.graphBuffer.length, encoded.geomBuffer.length);
}

write("yarmouth-harbour", {
  nodes: [
    { id: 1, lon: -65.7749, lat: 43.6486, tags: {} },
    { id: 2, lon: -65.7755, lat: 43.6490, tags: {} },
    { id: 10, lon: -65.7535, lat: 43.6534, tags: {} },
    { id: 11, lon: -65.7528, lat: 43.6539, tags: {} },
    { id: 20, lon: -63.2015, lat: 45.3904, tags: {} },
    { id: 21, lon: -63.2100, lat: 45.3904, tags: {} },
    { id: 22, lon: -64.5, lat: 44.5, tags: {} }
  ],
  ways: [
    { id: 100, nodeIds: [1, 2], tags: { highway: "service", name: "disconnected-pier" } },
    { id: 200, nodeIds: [10, 11], tags: { highway: "secondary", name: "town-road" } },
    { id: 300, nodeIds: [20, 21], tags: { highway: "trunk", name: "start-road" } },
    { id: 400, nodeIds: [21, 22, 10], tags: { highway: "trunk", name: "inland-connector" } }
  ]
});
