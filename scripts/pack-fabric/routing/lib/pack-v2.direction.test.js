"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeFromV1, decodeGraphV2 } = require("./pack-v2");
const { packHasDirectedArc } = require("./travel-direction");
const { assertEncodedDirection } = require("./validate-pack-direction");

function tinyData(direction) {
  return {
    nodeCount: 2,
    nodes: [
      [-64.1884, 45.8071],
      [-64.1886, 45.8072]
    ],
    regionId: "fixture",
    enums: {
      ACCESS_NAME: [
        "motorized_verified",
        "motorized_permissive",
        "motorized_unknown",
        "motorized_restricted",
        "motorized_excluded"
      ],
      SURFACE_NAME: ["paved", "gravel", "access", "track", "unknown"]
    },
    edges: [
      {
        i: "hwy-104-eastbound",
        a: 0,
        b: 1,
        m: 120,
        s: 0,
        ac: 0,
        t: 0,
        rt: "freeway",
        conf: "high",
        d: direction,
        g: [
          [-64.1884, 45.8071],
          [-64.1886, 45.8072]
        ]
      }
    ]
  };
}

test("one-way forward encodes only A to B", () => {
  const { graphBuffer, meta } = encodeFromV1(tinyData("forward"));
  const pack = decodeGraphV2(graphBuffer);
  assert.equal(meta.directedArcCount, 1);
  assert.equal(pack.directedArcCount, 1);
  assert.equal(packHasDirectedArc(pack, 0, 1, 0), true);
  assert.equal(packHasDirectedArc(pack, 1, 0, 0), false);
  assert.doesNotThrow(() => assertEncodedDirection(pack, tinyData("forward").edges));
});

test("one-way reverse encodes only B to A", () => {
  const { graphBuffer } = encodeFromV1(tinyData("reverse"));
  const pack = decodeGraphV2(graphBuffer);
  assert.equal(pack.directedArcCount, 1);
  assert.equal(packHasDirectedArc(pack, 0, 1, 0), false);
  assert.equal(packHasDirectedArc(pack, 1, 0, 0), true);
});

test("bidirectional and omitted direction still encode both arcs", () => {
  for (const direction of ["both", undefined]) {
    const data = tinyData(direction);
    if (direction == null) delete data.edges[0].d;
    const { graphBuffer } = encodeFromV1(data);
    const pack = decodeGraphV2(graphBuffer);
    assert.equal(pack.directedArcCount, 2);
    assert.equal(packHasDirectedArc(pack, 0, 1, 0), true);
    assert.equal(packHasDirectedArc(pack, 1, 0, 0), true);
  }
});

test("validation gate rejects a two-way CSR for a one-way source edge", () => {
  const { graphBuffer } = encodeFromV1(tinyData("both"));
  const pack = decodeGraphV2(graphBuffer);
  assert.throws(
    () => assertEncodedDirection(pack, tinyData("forward").edges),
    /one-way mismatch/
  );
});
