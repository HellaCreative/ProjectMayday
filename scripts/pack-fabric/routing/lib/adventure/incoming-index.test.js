'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {encodeFromOsmGraph,decodeGraphV4}=require('../pack-v4');
const {createProjectedGraph}=require('./projected-graph');
const {createIncomingIndexCache}=require('./incoming-index');
const {createReverseCostCache}=require('./reverse-cost-cache');
const {prepareReverseCosts,buildLowerBounds,searchResourcePath}=require('./resource-search');
const {createBudget}=require('./budget');
const budget=(maxExpansions=1000000,signal)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions,signal});
function fixture() {
 const nodes=Array.from({length:12},(_,i)=>({osmNodeId:i+1,lon:i*.01,lat:0}));
 const pairs=[[0,1],[1,2],[2,3],[3,4],[4,5],[5,0],[2,0],[3,1],[0,4],[6,7],[7,8],[8,6],[4,4],[0,1]];
 const edges=pairs.map(([from,to],i)=>({from,to,osmWayId:i+1,meters:100+i*17,accessForward:i===8?3:0,accessReverse:i%3===0?2:i===9?1:0,
  surfaceLeaf:i%2?'gravel':'asphalt',roadClassLeaf:'unclassified',coords:[[nodes[from].lon,0],[nodes[to].lon,0]]}));
 const e=encodeFromOsmGraph({nodes,edges,restrictions:[{fromEdge:0,toEdge:1,viaNode:1,viaEdges:[],viaWayIds:[],osmRelationId:1}]},{regionId:'fixture',sourceEpoch:'fixed'});
 return decodeGraphV4(e.graphBuffer,e.geomBuffer);
}
function projected(pack,allowUnknown,edit=false){return createProjectedGraph(pack,{budget:budget(),allowUnknown,endpointEdges:[8],
 points:[{id:'a',edgeIndex:0,fraction:edit?.5:.2},{id:'b',edgeIndex:1,fraction:.7},{id:'pump',edgeIndex:0,fraction:.8,station:{id:'pump',accessEvidence:'verified'}},
 {id:'end',edgeIndex:8,fraction:1},{id:'loop',edgeIndex:12,fraction:.4},{id:'parallel',edgeIndex:13,fraction:.3}]});}
test('incoming projected adjacency exactly equals reversed forward traversal including loops, access and order',()=>{
 for(const allowUnknown of [false,true])for(const edit of [false,true]) {
  const pack=fixture(),g=projected(pack,allowUnknown,edit),index=createIncomingIndexCache().prepare({pack,revision:'one',budget:budget()});
  const incoming=g.prepareIncoming({index,budget:budget()}),expected=Array.from({length:g.nodeCount},()=>[]);
  for(let n=0;n<g.nodeCount;n++)g.forEachOutgoing(n,a=>expected[a.to].unshift(a));
  for(let n=0;n<g.nodeCount;n++){
   const actual=[];incoming.forEachIncoming(n,a=>actual.push(a));assert.deepEqual(actual,expected[n],`node ${n}`);
   let calls=0;incoming.forEachIncoming(n,()=>{calls++;return false;});assert.equal(calls,Math.min(1,expected[n].length));
  }
 }
});
test('on-demand costs preserve exact and capped bounds and turn/fuel routes across targets and policies',()=>{
 const pack=fixture(),cache=createReverseCostCache({useIncomingBounds:true});
 for(const allowUnknown of [false,true])for(const edit of [false,true])for(const edgeCost of [a=>a.distanceMeters,a=>a.distanceMeters*(a.surfaceLeaf==='gravel'?1:30),()=>0]) {
  const g=projected(pack,allowUnknown,edit),args={graph:g,nodeCount:g.nodeCount,edgeCost};
  const full=prepareReverseCosts({...args,budget:budget()}),onDemand=cache.prepare({graph:g,revision:'one',edgeCost,budget:budget()});
  for(const target of [0,3,6,11,g.pointNodes.get('b')])for(const stopAt of [null,0,g.pointNodes.get('a')]) {
   const options={...args,target,stopAt};
   const a=buildLowerBounds({...options,reverseCosts:full,budget:budget()}),b=buildLowerBounds({...options,reverseCosts:onDemand.reverseCosts,budget:budget()});
   assert.deepEqual(b.distances,a.distances);assert.equal(b.coverage,a.coverage);assert.equal(b.capCost,a.capCost);
  }
  const start=g.pointNodes.get('a'),end=g.pointNodes.get('b'),options={graph:g,start,end,edgeCost,fuel:{usableRangeMeters:2000,initialUsableMeters:500}};
  const a=searchResourcePath({...options,budget:budget(),lowerBounds:buildLowerBounds({...args,target:end,reverseCosts:full,budget:budget()})});
  const b=searchResourcePath({...options,budget:budget(),lowerBounds:buildLowerBounds({...args,target:end,reverseCosts:onDemand.reverseCosts,budget:budget()})});
  assert.equal(b.state,a.state);assert.deepEqual(b.arcs,a.arcs);assert.deepEqual(b.visits,a.visits);
 }
});
test('base adjacency reuse excludes request projection/cost state; revision, cancellation and bounds remain enforced',()=>{
 const pack=fixture(),cache=createIncomingIndexCache(),args={pack,revision:'one'};
 assert.equal(cache.prepare({...args,budget:budget(1)}).state,'incomplete');assert.equal(cache.diagnostics().entries,0);
 assert.equal(cache.prepare({...args,budget:budget()}).cacheHit,false);
 assert.equal(cache.prepare({...args,budget:budget()}).cacheHit,true);
 assert.equal(cache.prepare({...args,revision:'two',budget:budget()}).cacheHit,false);
 assert.equal(cache.prepare({...args,budget:budget(10,{aborted:true})}).reason,'cancelled');
 assert.equal(createIncomingIndexCache({maxBytes:1}).prepare({...args,budget:budget()}).reason,'reverse_storage_limit');
 cache.clear();assert.equal(cache.diagnostics().entries,0);
});
const {createV4Graph}=require('./v4-graph');
test('neutral turn fast path preserves node and via-way restrictions over branching histories',()=>{
 const pack=fixture();pack.restrictions.push({fromEdge:1,viaEdges:[2,3],toEdge:4,only:false,viaNode:2});
 const a=createV4Graph(pack),b=createV4Graph(pack,{fastNeutralTurns:true});
 let frontier=Array.from({length:pack.nodeCount},(_,node)=>({node,a:0,b:0}));
 for(let depth=0;depth<6;depth++) {
  const next=[];
  for(const prior of frontier)for(const arc of a.outgoing(prior.node)) {
   const x=a.transition(prior.a,arc),y=b.transition(prior.b,arc);assert.deepEqual(y,x);
   if(x.allowed)next.push({node:arc.to,a:x.state,b:y.state});
  }
  frontier=next;
 }
 for(const arcs of [[{id:1,from:1,to:2}],[{id:2,from:2,to:3}],[{id:1,from:1,to:2},{id:2,from:2,to:3}]])
  assert.deepEqual(b.seedArrival(arcs),a.seedArrival(arcs));
 assert.ok(b.diagnostics().cachedTransitions<a.diagnostics().cachedTransitions);
});
