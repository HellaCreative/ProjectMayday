'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {buildGraphFromOsm}=require('../pack-fabric/routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../pack-fabric/routing/lib/pack-v4');
const {createV4Graph}=require('../pack-fabric/routing/lib/adventure/v4-graph');
const {compile}=require('./directed-restrictions');
function fixture() {
 const nodes=Array.from({length:6},(_,i)=>({id:i+1,lon:-63+i*.01,lat:45+(i%2)*.01}));
 const ways=[[1,2],[2,3],[3,4],[3,5],[4,6],[5,6]].map((nodeIds,i)=>({id:i+10,nodeIds,tags:{highway:'unclassified',access:'yes'}}));
 const b=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'ns',sourceEpoch:'fixture'});return decodeGraphV4(b.graphBuffer,b.geomBuffer);
}
function compare(pack) {
 const rules=compile(pack),graph=createV4Graph(pack,{allowUnknown:true});let checked=0;
 function walk(node,state,history,depth) {
  if(!depth)return;
  graph.forEachOutgoing(node,arc=>{
   const key=arc.id*2+(pack.edgeFrom[arc.id]===node?0:1),path=[...history,key];
   const blocked=rules.some(r=>r.keys.length<=path.length&&r.keys.every((k,i)=>k===path[path.length-r.keys.length+i]));
   const actual=graph.transition(state,arc);assert.equal(!blocked,actual.allowed,'directed walk '+path.join(','));checked++;
   if(actual.allowed)walk(arc.to,actual.state,path,depth-1);
  });
 }
 for(let n=0;n<pack.nodeCount;n++)walk(n,0,[],7);assert.ok(checked>100);
}
test('compiled forbidden walks match baseline node-only unions and via-way branches',()=>{
 const p=fixture();p.restrictions=[{fromEdge:0,toEdge:2,viaEdges:[1],viaNode:p.edgeTo[0],only:true},{fromEdge:0,toEdge:3,viaEdges:[1],viaNode:p.edgeTo[0],only:true},{fromEdge:2,toEdge:4,viaNode:p.edgeTo[2],only:false},{fromEdge:1,toEdge:2,viaNode:p.edgeTo[1],only:true},{fromEdge:1,toEdge:3,viaNode:p.edgeTo[1],only:true}];compare(p);
});
test('compiled no via-way and motorcycle exceptions match all bounded walks',()=>{
 const p=fixture();p.restrictions=[{fromEdge:0,toEdge:2,viaEdges:[1],viaNode:p.edgeTo[0],only:false},{fromEdge:1,toEdge:3,viaNode:p.edgeTo[1],only:false,vehicleMask:7,except:['motorcycle']}];compare(p);
});
test('node-only constraints and via-only constraints on the same arrival both apply',()=>{
 const p=fixture();p.restrictions=[{fromEdge:0,toEdge:1,viaNode:p.edgeTo[0],only:true},{fromEdge:0,toEdge:2,viaEdges:[1],viaNode:p.edgeTo[0],only:true}];compare(p);
});
test('completed shorter only rule does not release a longer active rule',()=>{
 const p=fixture();p.restrictions=[{fromEdge:0,toEdge:2,viaEdges:[1],viaNode:p.edgeTo[0],only:true},{fromEdge:0,toEdge:4,viaEdges:[1,2],viaNode:p.edgeTo[0],only:true}];compare(p);
});
