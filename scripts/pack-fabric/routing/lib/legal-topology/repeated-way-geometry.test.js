"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const { parseOpl, parseOplFile } = require("./opl");
const { buildGraphFromOsm, haversineMeters } = require("./osm-graph");
const { encodeFromOsmGraph, decodeGraphV4, decodeGeometryV1 } = require("../pack-v4");
const { assertSharedRoadGeometry } = require("../../../scripts/build-v4-seams");
const fixture = path.resolve(__dirname, "../../fixtures/legal-topology/texas-repeated-way-717538889.opl");

// Exact September 18 North America source way. Its center aisle and two loops
// revisit A/B; (way,A,B) alone must not label both the straight and western aisle.
for (const compact of [false, true]) test(`repeated source junctions retain distinct road shapes (compact=${compact})`, async () => {
  const osm = compact ? await parseOplFile(fixture, { packedNodes: true }) : parseOpl(fs.readFileSync(fixture, "utf8"));
  const graph = buildGraphFromOsm(osm);
  const identities = new Map();
  for (const edge of graph.edges) {
    const key = `${edge.osmWayId}:${graph.nodes[edge.from].osmNodeId}:${graph.nodes[edge.to].osmNodeId}`;
    if (identities.has(key)) assert.deepEqual(edge.coords, identities.get(key), `ambiguous identity ${key}`);
    identities.set(key, edge.coords);
    assert.equal(edge.accessForward, 2, "private source must remain prohibited");
    assert.equal(edge.accessReverse, 2, "private source must remain prohibited");
  }
  const original = parseOpl(fs.readFileSync(fixture, "utf8"));
  const nodes = new Map(original.nodes.map(n => [String(n.id),[n.lon,n.lat]]));
  const sequence = original.ways[0].nodeIds.map(id => nodes.get(String(id)));
  const originalMeters = sequence.slice(1).reduce((sum,p,i) => sum + haversineMeters(sequence[i],p),0);
  assert.ok(Math.abs(graph.edges.reduce((sum,e) => sum+e.meters,0)-originalMeters) < 1e-8, "no road may disappear or shortcut a bend");
  function encoded(id) {
    const bytes = encodeFromOsmGraph(graph,{regionId:id,sourceEpoch:"fixture-20260918"});
    return { manifest:{regionId:id}, pack:decodeGraphV4(bytes.graphBuffer,bytes.geomBuffer), geometry:decodeGeometryV1(bytes.geomBuffer) };
  }
  assert.equal(assertSharedRoadGeometry(encoded("tx-ne"),encoded("tx-nw")),graph.edges.length);
});
