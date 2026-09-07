"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { decodeOplString, parseTags, parseOpl, parseOplFile } = require("./opl");
const { buildGraphFromOsm } = require("./osm-graph");

test("OPL percent escapes decode without URL-decoder corruption", () => {
  assert.equal(decodeOplString("MacDonald%20%Road"), "MacDonald Road");
  assert.equal(
    decodeOplString("no_left_turn%20%%40%%20%(Mo-Fr%20%07:00-09:00)"),
    "no_left_turn @ (Mo-Fr 07:00-09:00)"
  );
  assert.deepEqual(
    parseTags("Tdestination=Digby%2C%%20%NS,source=A%3D%B"),
    { destination: "Digby, NS", source: "A=B" }
  );
});

test("OPL relation parser preserves decoded conditional restriction tags", () => {
  const parsed = parseOpl(
    "r4116373 Trestriction:conditional=no_left_turn%20%%40%%20%(Mo-Fr%20%07:00-09:00),type=restriction Mn1@via,w2@to,w3@from\n"
  );
  assert.equal(parsed.relations[0].tags["restriction:conditional"], "no_left_turn @ (Mo-Fr 07:00-09:00)");
  assert.deepEqual(parsed.relations[0].members, [
    { type: "node", ref: "1", role: "via" },
    { type: "way", ref: "2", role: "to" },
    { type: "way", ref: "3", role: "from" }
  ]);
});

test("streaming OPL parser preserves the in-memory legal identity", async (t) => {
  const text = [
    "n1 v1 dV c0 t i0 u T x-64.2 y45.8",
    "n2 v1 dV c0 t i0 u Tbarrier=gate x-64.1 y45.9",
    "w10 v1 dV c0 t i0 u Thighway=track Nn1,n2",
    "r20 v1 dV c0 t i0 u Ttype=restriction,restriction=no_left_turn Mw10@from,n2@via,w10@to"
  ].join("\n");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-opl-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "fixture.opl");
  fs.writeFileSync(file, text);
  const streamed = await parseOplFile(file);
  const memory = parseOpl(text);
  assert.deepEqual(streamed.ways, memory.ways);
  assert.deepEqual(streamed.relations, memory.relations);
  assert.deepEqual(streamed.nodes.map((row) => ({ ...row, tags: row.tags || {} })), memory.nodes);

  const packed = await parseOplFile(file, { packedNodes: true });
  assert.equal(packed.nodeStore.count, memory.nodes.length);
  assert.deepEqual(
    memory.nodes.map((row) => packed.nodeStore.get(row.id)),
    memory.nodes.map((row) => ({ ...row, id: String(row.id), tags: row.tags && Object.keys(row.tags).length ? row.tags : null }))
  );
  assert.deepEqual(packed.ways, memory.ways);
  assert.deepEqual(packed.relations, memory.relations);
});

test("packed-node parsing produces the same legal graph as object-node parsing", async (t) => {
  const text = [
    "n1 v1 dV c0 t i0 u T x-64.3 y45.7",
    "n2 v1 dV c0 t i0 u Tbarrier=gate,access=yes x-64.2 y45.8",
    "n3 v1 dV c0 t i0 u T x-64.1 y45.9",
    "n4 v1 dV c0 t i0 u T x-64.0 y46.0",
    "w10 v1 dV c0 t i0 u Thighway=track,surface=gravel Nn1,n2,n3",
    "w11 v1 dV c0 t i0 u Thighway=residential Nn2,n4",
    "r20 v1 dV c0 t i0 u Ttype=restriction,restriction=no_right_turn Mw10@from,n2@via,w11@to"
  ].join("\n");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-opl-packed-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "fixture.opl");
  fs.writeFileSync(file, text);
  const regular = buildGraphFromOsm(await parseOplFile(file));
  const packed = buildGraphFromOsm(await parseOplFile(file, { packedNodes: true }));
  function canonical(graph) {
    const nodeId = (index) => graph.nodes[index].osmNodeId;
    const edge = (index) => {
      const row = graph.edges[index];
      return `${row.osmWayId}:${nodeId(row.from)}:${nodeId(row.to)}`;
    };
    return {
      nodes: graph.nodes.map((row) => ({ id: row.osmNodeId, lon: row.lon, lat: row.lat, tags: row.tags }))
        .sort((a, b) => Number(a.id) - Number(b.id)),
      edges: graph.edges.map((row) => ({
        way: row.osmWayId,
        from: nodeId(row.from),
        to: nodeId(row.to),
        meters: row.meters,
        coords: row.coords,
        accessForward: row.accessForward,
        accessReverse: row.accessReverse,
        surfaceLeaf: row.surfaceLeaf,
        roadClassLeaf: row.roadClassLeaf
      })).sort((a, b) => `${a.way}:${a.from}:${a.to}`.localeCompare(`${b.way}:${b.from}:${b.to}`)),
      barriers: graph.barriers.map((row) => ({
        osmNodeId: row.osmNodeId,
        decision: row.decision,
        reason: row.reason
      })).sort((a, b) => Number(a.osmNodeId) - Number(b.osmNodeId)),
      restrictions: graph.restrictions.map((row) => ({
        relation: row.osmRelationId,
        from: edge(row.fromEdge),
        to: edge(row.toEdge),
        via: nodeId(row.viaNode),
        only: row.only
      })).sort((a, b) => `${a.from}:${a.to}`.localeCompare(`${b.from}:${b.to}`)),
      rejected: graph.rejected,
      unprovenStitches: graph.unprovenStitches
    };
  }
  assert.deepEqual(canonical(packed), canonical(regular));
});
