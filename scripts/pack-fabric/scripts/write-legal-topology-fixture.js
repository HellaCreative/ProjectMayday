#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { buildGraphFromOsm } = require("../routing/lib/legal-topology/osm-graph");
const { encodeFromOsmGraph } = require("../routing/lib/pack-v4");

const DIRT = path.resolve(__dirname, "../../..");
const osm = {
  nodes: [
    { id: 1, lon: -64.19, lat: 45.80779, tags: {} },
    { id: 2, lon: -64.21, lat: 45.80779, tags: {} },
    { id: 3, lon: -64.21, lat: 45.80731, tags: {} },
    { id: 4, lon: -64.19, lat: 45.80731, tags: {} }
  ],
  ways: [
    { id: 537982310, nodeIds: [1, 2], tags: { highway: "motorway", oneway: "yes" } },
    { id: 537982311, nodeIds: [3, 4], tags: { highway: "motorway", oneway: "yes" } }
  ],
  relations: []
};
const graph = buildGraphFromOsm(osm);
const encoded = encodeFromOsmGraph(graph, { regionId: "fix", sourceEpoch: "fixture" });
const dests = [
  path.join(DIRT, "DirtTests/Fixtures"),
  path.join(DIRT, "scripts/pack-fabric/routing/fixtures/legal-topology")
];
for (const dir of dests) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "legal-topology-canary.graph.v4.bin"), encoded.graphBuffer);
  fs.writeFileSync(path.join(dir, "legal-topology-canary.geometry.v1.bin"), encoded.geomBuffer);
}
console.log("wrote legal-topology-canary", encoded.graphBuffer.length, encoded.geomBuffer.length);
