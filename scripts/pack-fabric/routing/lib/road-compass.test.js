"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const {buildRoadCompass} = require("./road-compass");
const {decodeGraphV4} = require("./pack-v4");
const {buildTurnAwareState, v4TransitionState} = require("./find-path-v2");

test("remaining road distance follows the road around a dead-end, not proximity", () => {
  const arcs = [[[1,0,10],[2,1,10]],[[0,0,10]],[[3,2,50]],[]];
  const result = buildRoadCompass({stateCount:4,destination:3,
    outgoing:(state,visit)=>arcs[state].forEach(a=>visit(...a))});
  assert.equal(result.status,"complete");
  assert.deepEqual([...result.remaining],[60,70,50,0]);
  assert.deepEqual([...result.nextState],[2,0,3,-1]);
});

test("legal remaining distance retains the incoming via-way restriction state", () => {
  const pack=decodeGraphV4(fs.readFileSync(path.join(__dirname,"../fixtures/legal-topology/legal-topology-restrictions.graph.v4.bin")));
  const node=id=>pack.osmNodeIds.findIndex(n=>Number(n)===id);
  const edge=way=>pack.osmWayIds.findIndex(w=>Number(w)===way);
  const turns=buildTurnAwareState(pack,pack.nodeCount,pack.nodeCount,pack.nodeCount+1);
  const result=buildRoadCompass({stateCount:turns.stateCount,destination:node(5),outgoing:(state,visit)=>{
    const from=turns.graphNodeOf(state); if(from>=pack.nodeCount)return;
    for(let a=pack.nodeOffsets[from];a<pack.nodeOffsets[from+1];a++) {
      const ei=pack.edgeUndirectedIndex[a],to=pack.edgeTargets[a];
      const next=v4TransitionState(pack,turns,state,ei,from,to,-1,-1);
      if(next>=0)visit(next,ei,pack.edgeMeters[ei]);
    }
  }});
  let restricted=turns.stateForArrival(node(2),edge(10));
  const via=[...pack.osmWayIds].map((w,i)=>Number(w)===11?i:-1).filter(i=>i>=0);
  const first=via.find(e=>pack.edgeFrom[e]===node(2)||pack.edgeTo[e]===node(2));
  restricted=turns.transition(restricted,first,node(3));
  restricted=turns.transition(restricted,via.find(e=>e!==first),node(4));
  assert.equal(result.status,"complete");
  assert.ok(result.remaining[restricted]>result.remaining[node(4)],"turn-forbidden arrival must take a real legal detour");
  assert.notEqual(result.nextEdge[restricted],edge(12));
  assert.equal(result.remaining[restricted],333);
  assert.equal(result.remaining[node(4)],111);
});

test("interrupted compass exposes no incomplete table as a distance proof",()=>{
  const result=buildRoadCompass({stateCount:4,destination:3,outgoing:()=>{},cancelled:()=>true});
  assert.equal(result.status,"cancelled"); assert.equal(result.remaining,undefined);
});
