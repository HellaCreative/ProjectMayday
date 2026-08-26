"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  PRIMARY_COMPONENT_FRACTION,
  corridorPrimary,
  permissiveVertices,
  primaryComponentFloor
} = require("./build-v3-cross-pack-seams");

function packedAccess(access) {
  return (Number(access) & 7) << 3;
}

function chain(startLon, startLat, count, idPrefix, nodeOffset) {
  const coords = [];
  const edges = [];
  for (let i = 0; i < count; i += 1) {
    coords.push([startLon + i * 0.001, startLat]);
  }
  for (let i = 0; i < count - 1; i += 1) {
    edges.push({
      from: nodeOffset + i,
      to: nodeOffset + i + 1,
      access: 1,
      id: `${idPrefix}-${i}`,
      line: [coords[i], coords[i + 1]]
    });
  }
  return { coords, edges };
}

function mockLoaded(parts) {
  const nodes = [];
  const edges = [];
  for (const part of parts) {
    nodes.push(...part.coords);
    edges.push(...part.edges);
  }
  const edgeFrom = new Int32Array(edges.map((e) => e.from));
  const edgeTo = new Int32Array(edges.map((e) => e.to));
  const edgeAttrs = new Uint16Array(edges.map((e) => packedAccess(e.access)));
  const lines = edges.map((e) => e.line);
  const ids = edges.map((e) => e.id);
  return {
    id: "mock",
    pack: {
      nodeCount: nodes.length,
      undirectedEdgeCount: edges.length,
      edgeFrom,
      edgeTo,
      edgeAttrs,
      hasLeaves: true,
      edgeId: (ei) => ids[ei]
    },
    geom: {
      polyline: (ei) => lines[ei]
    }
  };
}

const corridor = { minLon: -70, minLat: 45, maxLon: -55, maxLat: 60 };

test("primary floor is 5% of the largest corridor component", () => {
  assert.equal(PRIMARY_COMPONENT_FRACTION, 0.05);
  assert.equal(primaryComponentFloor(120386), 6019);
  assert.equal(primaryComponentFloor(737146), 36857);
  assert.equal(primaryComponentFloor(0), Infinity);
});

test("disconnected clip fragments are not primary", () => {
  const giant = chain(-67.2, 52.8, 80, "qc-hwy", 0);
  const fragment = chain(-66.8, 54.8, 2, "qc-spur", 80);
  const loaded = mockLoaded([giant, fragment]);
  const primary = corridorPrimary(loaded, corridor);
  assert.equal(primary.largest, 80);
  assert.equal(primary.floor, 4);
  assert.equal(primary.onPrimary(0), true);
  assert.equal(primary.onPrimary(79), true);
  assert.equal(primary.onPrimary(80), false);
  assert.equal(primary.onPrimary(81), false);
});

test("Labrador-scale secondary stays; island giant stays; dead spur drops", () => {
  const island = chain(-58.5, 48.5, 80, "nl-island", 0);
  const labrador = chain(-67.2, 52.8, 10, "nl-labrador", 80);
  const spur = chain(-66.8, 54.8, 2, "nl-spur", 90);
  const loaded = mockLoaded([island, labrador, spur]);
  const primary = corridorPrimary(loaded, corridor);
  assert.equal(primary.largest, 80);
  assert.equal(primary.floor, 4);
  assert.equal(primary.onPrimary(0), true);
  assert.equal(primary.onPrimary(85), true);
  assert.equal(primary.onPrimary(90), false);
});

test("shared vertices require a primary component on both packs", () => {
  const qcGiant = chain(-67.26, 52.79, 80, "qc-389", 0);
  const qcSpur = chain(-66.85, 54.80, 2, "qc-clip", 80);
  const nlIsland = chain(-58.5, 48.5, 80, "nl-island", 0);
  const nlLabrador = chain(-67.26, 52.79, 10, "nl-lab", 80);
  const nlSpur = chain(-66.85, 54.80, 2, "nl-clip", 90);
  const qc = mockLoaded([qcGiant, qcSpur]);
  const nl = mockLoaded([nlIsland, nlLabrador, nlSpur]);
  const qcVerts = permissiveVertices(qc, corridor);
  const nlVerts = permissiveVertices(nl, corridor);
  const shared = [];
  for (const [key, leftRow] of qcVerts.byKey) {
    if (nlVerts.byKey.has(key)) shared.push(key);
  }
  assert.ok(shared.some((key) => key.startsWith("-67.26000,52.79000")));
  assert.equal(shared.some((key) => key.startsWith("-66.85000,54.80000")), false);
});
