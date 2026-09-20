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
  assert.equal(graph.edges.length, 4, "split only the ambiguous curve, not every stored shape point");
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

test("revisited way shapes remain unambiguous across varied loop and retrace patterns", () => {
  let seed = 1729;
  const next = () => (seed = (Math.imul(seed,1664525)+1013904223) >>> 0);
  for (let trial=0; trial<100; trial++) {
    const nodes = Array.from({length:8},(_,i) => ({id:String(i+1),lon:-97+i*0.0001,lat:32+(i%3)*0.0001,tags:{}}));
    const ids = Array.from({length:20},() => String((next() >>> 16)%8+1));
    const graph = buildGraphFromOsm({nodes,ways:[{id:"10",nodeIds:ids,tags:{highway:"residential",motorcycle:"yes"}}],relations:[]});
    const shapes = new Map();
    for (const edge of graph.edges) {
      const key = `${graph.nodes[edge.from].osmNodeId}:${graph.nodes[edge.to].osmNodeId}`;
      if (shapes.has(key)) assert.deepEqual(edge.coords,shapes.get(key));
      shapes.set(key,edge.coords);
    }
    const expected = ids.slice(1).reduce((sum,id,i) => {
      const a=nodes[Number(ids[i])-1],b=nodes[Number(id)-1];
      return sum+haversineMeters([a.lon,a.lat],[b.lon,b.lat]);
    },0);
    assert.ok(Math.abs(expected-graph.edges.reduce((sum,e)=>sum+e.meters,0))<1e-6);
  }
});
