"use strict";

process.env.ROUTING_PACKS_V2 = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { encodeFromV1 } = require("./pack-v2");
const { loadGraphSync, clearGraphCache } = require("./graph");
const { routeOnRuntime } = require("./router");

const ENUMS = {
  ACCESS_NAME: [
    "motorized_verified",
    "motorized_permissive",
    "motorized_unknown",
    "motorized_restricted",
    "motorized_excluded"
  ],
  SURFACE_NAME: ["paved", "gravel", "access", "track", "unknown"],
  STRUCTURE_NAME: ["none", "bridge", "tunnel", "ford", "ferry"]
};

function writeOnewayPack() {
  const data = {
    nodeCount: 2,
    nodes: [
      [-64.1880, 45.8071],
      [-64.1890, 45.8071]
    ],
    regionId: "fixture",
    enums: ENUMS,
    edges: [
      {
        i: "eastbound-104",
        a: 0,
        b: 1,
        m: 100,
        s: 0,
        ac: 0,
        t: 0,
        rt: "freeway",
        conf: "high",
        d: "forward",
        g: [
          [-64.1880, 45.8071],
          [-64.1890, 45.8071]
        ]
      }
    ]
  };
  const { graphBuffer, geomBuffer } = encodeFromV1(data);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-oneway-runtime-"));
  const graphPath = path.join(dir, "graph.v3.bin");
  fs.writeFileSync(graphPath, graphBuffer);
  fs.writeFileSync(path.join(dir, "geometry.v1.bin"), geomBuffer);
  return { dir, graphPath };
}

test("LIVE router follows a one-way edge and refuses the reverse snap", async () => {
  const { dir, graphPath } = writeOnewayPack();
  try {
    const runtime = loadGraphSync(graphPath);
    const graphResolution = { ok: true, mode: "regional", regionIds: ["fixture"] };
    const policy = { motorizedPermissive: true, motorizedUnknown: false };
    const legal = await routeOnRuntime(
      {
        profile: "balanced",
        locations: [
          { lat: 45.8071, lon: -64.1882 },
          { lat: 45.8071, lon: -64.1888 }
        ],
        accessPolicy: policy
      },
      graphResolution,
      runtime
    );
    assert.equal(legal.status, "complete");
    assert.ok(legal.distanceMeters > 0);

    const illegal = await routeOnRuntime(
      {
        profile: "balanced",
        locations: [
          { lat: 45.8071, lon: -64.1888 },
          { lat: 45.8071, lon: -64.1882 }
        ],
        accessPolicy: policy
      },
      graphResolution,
      runtime
    );
    assert.equal(illegal.status, "failed");
    assert.equal(illegal.error, "no_route");
  } finally {
    clearGraphCache();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("V4 live arrival stays on the requested one-way carriageway in both directions", async () => {
  const { buildGraphFromOsm } = require("./legal-topology/osm-graph");
  const { encodeFromOsmGraph } = require("./pack-v4");
  const graph = buildGraphFromOsm({
    nodes: [[1, 0, 45], [2, 0.01, 45], [3, 0.01, 45.0002], [4, 0, 45.0002]].map(([id, lon, lat]) => ({ id, lon, lat, tags: {} })),
    ways: [[10, [1, 2], "motorway"], [20, [3, 4], "motorway"], [30, [2, 3], "motorway_link"], [40, [4, 1], "motorway_link"]].map(([id, nodeIds, highway]) => ({ id, nodeIds, tags: { highway, oneway: "yes", motor_vehicle: "yes", surface: "asphalt" } }))
  });
  const encoded = encodeFromOsmGraph(graph, { regionId: "fixture", sourceEpoch: "test" });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-v4-arrival-"));
  try {
    const file = path.join(dir, "graph.v4.bin");
    fs.writeFileSync(file, encoded.graphBuffer);fs.writeFileSync(path.join(dir, "geometry.v1.bin"), encoded.geomBuffer);
    const runtime = loadGraphSync(file);
    for (const [lat, a, b, way] of [[45, 0.002, 0.008, "10"], [45.0002, 0.008, 0.002, "20"]]) {
      const result = await routeOnRuntime({ profile: "cleanest", locations: [{ lat, lon: a }, { lat, lon: b }], accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }, options: { mapZoom: 14 } }, { ok: true, mode: "regional", regionIds: ["fixture"] }, runtime);
      assert.equal(result.status, "complete");
      assert.ok(result.distanceMeters < 600, "must not drive around the interchange to the opposite carriageway");
      assert.ok(result.segments.filter(s => s.distanceMeters > 0).every(s => s.edgeId.startsWith(`w${way}:`)));
    }
  } finally { clearGraphCache(); fs.rmSync(dir, { recursive: true, force: true }); }
});
