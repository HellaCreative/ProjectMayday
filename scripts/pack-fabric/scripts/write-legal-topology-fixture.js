#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { buildGraphFromOsm } = require("../routing/lib/legal-topology/osm-graph");
const { encodeFromOsmGraph } = require("../routing/lib/pack-v4");

const DIRT = path.resolve(__dirname, "../../..");
const highwayCanary = {
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

write("legal-topology-canary", highwayCanary);

// Real, directional forecourt geometry: separate entrance and exit, with a
// public detour that must never be replaced by a customer-only through road.
const forecourt = {
  nodes: [[1,-64.005,45],[2,-64.001,45],[3,-64,45],
    [4,-63.9998,45.0001],[5,-63.9996,45.00015],[6,-63.9994,45],
    [7,-63.995,45],[8,-64,45.002],[9,-63.9994,45.002]]
    .map(([id,lon,lat])=>({id,lon,lat,tags:{}})),
  ways: [[10,[1,2,3],false],[20,[3,4],true],[21,[4,5],true],
    [22,[5,6],true],[11,[6,7],false],[12,[3,8,9,6],false]]
    .map(([id,nodeIds,customer])=>({id,nodeIds,tags: customer
      ? {highway:"service",access:"customers",oneway:"yes",surface:"asphalt"}
      : {highway:"unclassified",surface:"asphalt"}})),
  relations: []
};
write("legal-topology-forecourt", forecourt);
write("legal-topology-forecourt-blocked", {...forecourt, relations:[{
  id:200, members:[{type:"way",ref:20,role:"from"},
    {type:"node",ref:4,role:"via"},{type:"way",ref:21,role:"to"}],
  tags:{type:"restriction",restriction:"no_straight_on"}
}]});

write("legal-topology-restrictions", {
  nodes: [
    { id: 1, lon: 0, lat: 0, tags: {} },
    { id: 2, lon: 0.001, lat: 0, tags: {} },
    { id: 3, lon: 0.002, lat: 0, tags: {} },
    { id: 4, lon: 0.003, lat: 0, tags: {} },
    { id: 5, lon: 0.004, lat: 0, tags: {} },
    { id: 6, lon: 0.001, lat: 0.001, tags: {} },
    { id: 7, lon: 0.003, lat: 0.001, tags: {} },
    { id: 8, lon: 0.002, lat: 0.001, tags: {} },
    { id: 20, lon: 0.01, lat: 0, tags: {} },
    { id: 21, lon: 0.011, lat: 0, tags: {} },
    { id: 22, lon: 0.012, lat: 0, tags: {} },
    { id: 23, lon: 0.013, lat: 0, tags: {} },
    { id: 24, lon: 0.014, lat: 0, tags: {} }
  ],
  ways: [
    { id: 10, nodeIds: [1, 2], tags: { highway: "residential" } },
    { id: 11, nodeIds: [2, 3, 4], tags: { highway: "residential" } },
    { id: 12, nodeIds: [4, 5], tags: { highway: "residential" } },
    { id: 13, nodeIds: [6, 2], tags: { highway: "residential" } },
    { id: 14, nodeIds: [4, 7], tags: { highway: "residential" } },
    { id: 15, nodeIds: [3, 8], tags: { highway: "residential" } },
    { id: 20, nodeIds: [20, 21], tags: { highway: "service", access: "destination" } },
    { id: 21, nodeIds: [22, 23], tags: { highway: "service", access: "customers" } },
    { id: 22, nodeIds: [23, 24], tags: { highway: "track", access: "unknown" } }
  ],
  relations: [
    {
      id: 100,
      members: [
        { type: "way", ref: 10, role: "from" },
        { type: "way", ref: 11, role: "via" },
        { type: "way", ref: 12, role: "to" }
      ],
      tags: { type: "restriction", restriction: "no_straight_on" }
    }
  ]
});
