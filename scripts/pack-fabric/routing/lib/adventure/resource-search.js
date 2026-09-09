"use strict";
const {surfaceKind}=require("./surface");
const {fuelCovers,validateFuel}=require("./fuel-math");

// Experimental fuel-aware label-setting search. This finds a minimum additive
// exploration cost, NOT the globally highest dirt percentage or a 50/50 ride.
// A label owns turn-history state and remaining fuel; a cheaper arrival with
// less fuel cannot discard a more expensive arrival that can finish the ride.
class Heap {
  constructor(compare=(a,b)=>a.priority-b.priority) { this.items=[];this.compare=compare; }
  push(value) {
    const a=this.items;let i=a.length;a.push(value);
    while(i>0) {const p=(i-1)>>1;if(this.compare(a[p],value)<=0) break;a[i]=a[p];i=p;}a[i]=value;
  }
  pop() {
    const a=this.items;if(!a.length)return null;
    const first=a[0],last=a.pop();if(!a.length)return first;
    let i=0;while(i*2+1<a.length){let c=i*2+1;if(c+1<a.length&&this.compare(a[c+1],a[c])<0)c++;
      if(this.compare(last,a[c])<=0)break;a[i]=a[c];i=c;}a[i]=last;return first;
  }
}

function searchResourcePath({graph,start,end,edgeCost,budget,fuel=null,
  initialTurnState=null,destinationEscapeMeters=0,lowerBounds=null,acceptGoal=null,avoidanceCost=null,maxLabels=Infinity,heuristicWeight=1,preferOnwardFuel=false,retainFuelApproach=false,dirtEntryCost=0}) {
  if(!Number.isFinite(dirtEntryCost)||dirtEntryCost<0)throw new TypeError("Dirt entry cost must be finite and nonnegative");
  if(!Number.isFinite(heuristicWeight)||heuristicWeight<1)throw new TypeError("Heuristic weight must be finite and at least one");
  if(!Number.isFinite(destinationEscapeMeters)||destinationEscapeMeters<0) throw new TypeError("A proved destination escape distance is required");
  if(maxLabels!==Infinity&&(!Number.isSafeInteger(maxLabels)||maxLabels<1))throw new TypeError("Positive label limit required");
  if(fuel!=null)validateFuel(fuel,{requireInitial:true});
  // With onward preference enabled, approach retracing is a second priority,
  // before surface cost. Reversal follows the immutable parent chain in O(1)
  // per arc, including driving past a pump then turning back. Necessary access
  // is expensive, never illegal. Preserve the last station entry in the frontier
  // so different pump approaches can compete after a legal exit rejoins a road.
  // Histories sharing that entry can still be pruned: this is bounded candidate
  // generation, not a global loopless-path proof. Full history keys multiply
  // labels too far on regional graphs; fuel and turn feasibility remain exact.
  // Urban exposure precedes the experimental ride cost lexicographically. No
  // finite penalty lets a cheap urban shortcut beat a feasible rural ride.
  // Fewer refills break otherwise equal route costs; free fuel actions must
  // not turn every passing pump into a planned stop.
  const compare=(a,b)=>a.avoidance-b.avoidance || (a.retraceMeters||0)-(b.retraceMeters||0) || a.cost-b.cost || a.refills-b.refills;
  const heap=new Heap((a,b)=>a.avoidance-b.avoidance || (a.retraceMeters||0)-(b.retraceMeters||0) || a.priority-b.priority || a.refills-b.refills),frontiers=new Map();
  if(lowerBounds && (lowerBounds.state!=="complete" || lowerBounds.target!==end || lowerBounds.graph!==graph || lowerBounds.edgeCost!==edgeCost)) throw new TypeError("Lower bounds must be complete and belong to this graph, target and cost model");
  const fuelApproachIndexes=new WeakMap();
  // A legal station exit can rejoin the approach a few junctions away. Retain
  // the approach history so that this does not hide a repeated road.
  // Index lazily, charge the work to the request budget, and never infer roads.
  function approachIndex(approach) {
    if(!approach)return null;
    let index=fuelApproachIndexes.get(approach);
    if(!index){
      index=new Map();
      for(let cursor=approach;cursor;cursor=cursor.parent){
        if(!budget.consume())return null;
        if(cursor.arc){const key=`${cursor.node}:${cursor.arc.id}:${cursor.arc.from}`;if(!index.has(key))index.set(key,cursor);}
      }
      fuelApproachIndexes.set(approach,index);
    }
    return index;
  }
  let labels=0,dominated=0,expanded=0,labelLimitReached=false;
  const labelLimitResult=()=>({state:"incomplete",reason:"label_limit",diagnostics:{labels,dominated,expanded,maxLabels,...budget.snapshot()}});
  function add(label) {
    const estimate=lowerBounds?lowerBounds.distances[label.node]:0;
    if(estimate===Infinity)return;
    // Weight > 1 is explicit candidate-generation guidance: feasible results
    // retain hard constraints but no minimum-cost optimality is claimed.
    label.priority=label.cost+estimate*heuristicWeight;
    if(!budget.check())return;
    const key=graph.stateKey(label.node,label.turnState)+(preferOnwardFuel?`|retreat:${label.retreatCursor?.labelId??0}`:"")+(retainFuelApproach?`|approach:${label.fuelApproach?.arc?`${label.fuelApproach.arc.from}:${label.fuelApproach.arc.id}:${label.fuelApproach.node}`:"none"}`:"")+(dirtEntryCost?`|dirt:${label.onDirt?1:0}`:"");
    const frontier=frontiers.get(key) || [];
    if(frontier.some(old=>old.active&&compare(old,label)<=0&&old.remaining>=label.remaining)) {dominated++;return;}
    if(labels>=maxLabels){labelLimitReached=true;return;}
    const kept=[];
    for(const old of frontier){if(compare(label,old)<=0&&label.remaining>=old.remaining){old.active=false;dominated++;}else kept.push(old);}
    label.labelId=labels+1;label.active=true;kept.push(label);frontiers.set(key,kept);labels++;heap.push(label);
  }
  function materialize(label,goalEvidence=null) {
    const arcs=[],visits=[];let cursor=label;
    while(cursor.parent){if(cursor.arc)arcs.push(cursor.arc);if(cursor.refill)visits.push({stationId:cursor.refill.id,atMeters:cursor.distance,...(cursor.refill.accessEvidence?{accessEvidence:cursor.refill.accessEvidence}:{})});cursor=cursor.parent;}
    arcs.reverse();visits.reverse();
    return {state:"found",arcs,visits,distanceMeters:label.distance,cost:label.cost,avoidanceCost:label.avoidance,
      retraceMeters:label.retraceMeters||0,remainingUsableMeters:fuel?label.remaining:null,endTurnState:label.turnState,goalEvidence,
      diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  }
  if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  add({node:start,turnState:initialTurnState,remaining:fuel?fuel.initialUsableMeters:Infinity,cost:0,avoidance:0,refills:0,distance:0,parent:null});
  let cur;
  while((cur=heap.pop())) {
    if(!cur.active)continue;
    if(!budget.consume()) return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
    expanded++;
    const atGoal=typeof end==="function"?end(cur.node):cur.node===end;
    if(atGoal&&(!fuel||fuelCovers(cur.remaining,destinationEscapeMeters))) {
      const verdict=acceptGoal?acceptGoal({node:cur.node,turnState:cur.turnState,remainingUsableMeters:cur.remaining}):{accepted:true};
      if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
      if(verdict.accepted)return materialize(cur,verdict.evidence??null);
    }
    // Physical station proof is required for verified fuel. Experimental road
    // projections retain their provisional evidence through every visit.
    // Refuelling does not erase turn history.
    const station=fuel?graph.stationAt(cur.node):null;
    if(station && cur.remaining<fuel.usableRangeMeters) {
      add({...cur,refills:cur.refills+1,remaining:fuel.usableRangeMeters,parent:cur,arc:null,refill:station,retreatCursor:preferOnwardFuel?cur:null,fuelApproach:preferOnwardFuel&&retainFuelApproach?cur:null});
    }
    if(labelLimitReached)return labelLimitResult();
    for(const arc of graph.outgoing(cur.node)) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
      if(!Number.isFinite(arc.distanceMeters)||arc.distanceMeters<0)throw new TypeError("Invalid arc length");
      if(fuel&&!fuelCovers(cur.remaining,arc.distanceMeters))continue;
      const transition=graph.transition(cur.turnState,arc);
      if(!transition.allowed)continue;
      const avoidance=avoidanceCost?avoidanceCost(arc):0;
      if(!Number.isFinite(avoidance)||avoidance<0)throw new TypeError("Avoidance costs must be finite and nonnegative");
      // Charge once per continuous dirt run, not once per graph edge. Fuel
      // actions retain onDirt; station projections cannot multiply the charge.
      const onDirt=surfaceKind(arc.surfaceLeaf)==="dirt";
      const cost=edgeCost(arc)+(onDirt&&!cur.onDirt?dirtEntryCost:0);
      let retreatCursor=null,retraceMeters=cur.retraceMeters||0;
      // A continued retreat must retain its approach cursor; otherwise a tiny
      // reversal beyond a station could reset the price of the long return.
      let incoming=cur.retreatCursor||cur;
      const reverses=arrival=>arrival?.arc&&arrival.arc.id===arc.id&&arrival.arc.from===arc.to&&arrival.arc.to===arc.from;
      if(preferOnwardFuel&&!reverses(incoming)&&cur.fuelApproach)incoming=approachIndex(cur.fuelApproach)?.get(`${arc.from}:${arc.id}:${arc.to}`);
      if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
      if(preferOnwardFuel&&reverses(incoming)) {
        retraceMeters+=2*arc.distanceMeters;
        retreatCursor=incoming.parent;
        while(retreatCursor&&!retreatCursor.arc)retreatCursor=retreatCursor.parent;
      }
      // A station exit may also join the old approach in its original
      // direction. Repeating that road is still repetition, not new riding.
      else if(preferOnwardFuel&&cur.fuelApproach&&approachIndex(cur.fuelApproach)?.has(`${arc.to}:${arc.id}:${arc.from}`))retraceMeters+=2*arc.distanceMeters;
      if(!Number.isFinite(cost)||cost<0)throw new TypeError("Search costs must be finite and nonnegative");
      add({node:arc.to,turnState:transition.state,cost:cur.cost+cost,avoidance:cur.avoidance+avoidance,refills:cur.refills,
        remaining:fuel?Math.max(0,cur.remaining-arc.distanceMeters):Infinity,distance:cur.distance+arc.distanceMeters,parent:cur,arc,refill:null,retreatCursor,retraceMeters,onDirt,fuelApproach:cur.fuelApproach});
      if(labelLimitReached)return labelLimitResult();
    }
  }
  if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  return {state:"exhausted",reason:fuel?"no_fuel_feasible_path_in_supplied_graph":"no_path_in_supplied_graph",
    diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
}
// Exact reverse distances in the eligible graph, relaxing turn/fuel state.
// This is an admissible bound for the same additive costs, not a distance cap
// or a requirement that every next road move geographically toward the pin.
// Caller-owned immutable graph/cost preparation, reusable across targets only
// while graph and cost-function identities remain unchanged. No global cache.
// Chunked typed storage avoids millions of JS arrays/objects and growth copies.
function prepareReverseCosts({graph,nodeCount,edgeCost,budget,maxBytes=256*1024*1024}) {
  if(!Number.isSafeInteger(nodeCount)||nodeCount<1||nodeCount>0x7fffffff)throw new TypeError("Valid node count required");
  if(!Number.isSafeInteger(maxBytes)||maxBytes<0)throw new TypeError("Finite reverse storage byte limit required");
  const incomplete=reason=>({state:"incomplete",reason});
  if(!budget.check())return incomplete(budget.snapshot().reason);
  let byteLength=nodeCount*4;
  if(byteLength>maxBytes)return incomplete("reverse_storage_limit");
  const heads=new Int32Array(nodeCount);heads.fill(-1);
  const chunks=[],chunkSize=16384;let arcCount=0;
  for(let node=0;node<nodeCount;node++) {
    if(!budget.consume())return incomplete(budget.snapshot().reason);
    for(const arc of graph.outgoing(node)) {
      if(!budget.consume())return incomplete(budget.snapshot().reason);
      if(!Number.isInteger(arc.to)||arc.to<0||arc.to>=nodeCount)throw new TypeError("Arc target outside graph");
      const cost=edgeCost(arc);
      if(!Number.isFinite(cost)||cost<0)throw new TypeError("Search costs must be finite and nonnegative");
      if(arcCount>=0x7fffffff)return incomplete("reverse_storage_limit");
      const offset=arcCount%chunkSize;
      if(offset===0) {
        if(byteLength+chunkSize*16>maxBytes)return incomplete("reverse_storage_limit");
        chunks.push({from:new Uint32Array(chunkSize),next:new Int32Array(chunkSize),cost:new Float64Array(chunkSize)});
        byteLength+=chunkSize*16;
      }
      const chunk=chunks[chunks.length-1];
      chunk.from[offset]=node;chunk.next[offset]=heads[arc.to];chunk.cost[offset]=cost;
      heads[arc.to]=arcCount++;
    }
  }
  return {state:"complete",graph,nodeCount,edgeCost,heads,chunks,chunkSize,arcCount,byteLength};
}
function buildLowerBounds({graph,nodeCount,target,edgeCost,budget,reverseCosts=null,maxReverseBytes,stopAt=null}) {
  if(!Number.isInteger(target)||target<0||target>=nodeCount)throw new TypeError("Valid bound target required");
  if(stopAt!==null&&(!Number.isInteger(stopAt)||stopAt<0||stopAt>=nodeCount))throw new TypeError("Valid bound stopping node required");
  if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason};
  const reverse=reverseCosts||prepareReverseCosts({graph,nodeCount,edgeCost,budget,maxBytes:maxReverseBytes});
  if(reverseCosts&&(reverse.state!=="complete"||reverse.graph!==graph||reverse.edgeCost!==edgeCost||reverse.nodeCount!==nodeCount))throw new TypeError("Reverse costs must belong to this graph and cost model");
  if(reverse.state!=="complete")return reverse;
  const distances=new Float64Array(nodeCount);distances.fill(Infinity);distances[target]=0;
  const heap=new Heap();heap.push({node:target,cost:0,priority:0});let cur;
  while((cur=heap.pop())) {
    if(cur.cost!==distances[cur.node])continue;
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    if(cur.node===stopAt) {
      // Dijkstra has proved all unsettled distances >= this cost. Saturating
      // every bound at that floor remains admissible, including disconnected
      // nodes. It imposes no corridor or ride-length cap on the forward search.
      for(let n=0;n<nodeCount;n++) {
        if(n%4096===0&&!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
        distances[n]=Math.min(distances[n],cur.cost);
      }
      return {state:"complete",target,graph,edgeCost,distances,coverage:"capped",capCost:cur.cost};
    }
    for(let id=reverse.heads[cur.node];id!==-1;) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
      const chunk=reverse.chunks[Math.floor(id/reverse.chunkSize)],offset=id%reverse.chunkSize;
      const from=chunk.from[offset],cost=cur.cost+chunk.cost[offset];id=chunk.next[offset];
      if(cost<distances[from]){distances[from]=cost;heap.push({node:from,cost,priority:cost});}
    }
  }
  return {state:"complete",target,graph,edgeCost,distances,coverage:"exact"};
}
module.exports={searchResourcePath,buildLowerBounds,prepareReverseCosts};
