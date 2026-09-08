"use strict";
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
  initialTurnState=null,destinationEscapeMeters=0,lowerBounds=null,acceptGoal=null,avoidanceCost=null}) {
  if(!Number.isFinite(destinationEscapeMeters)||destinationEscapeMeters<0) throw new TypeError("A proved destination escape distance is required");
  if(fuel!=null)validateFuel(fuel,{requireInitial:true});
  // Urban exposure precedes the experimental ride cost lexicographically. No
  // finite penalty lets a cheap urban shortcut beat a feasible rural ride.
  const compare=(a,b)=>a.avoidance-b.avoidance || a.cost-b.cost;
  const heap=new Heap((a,b)=>a.avoidance-b.avoidance || a.priority-b.priority),frontiers=new Map();
  if(lowerBounds && (lowerBounds.state!=="complete" || lowerBounds.target!==end || lowerBounds.graph!==graph || lowerBounds.edgeCost!==edgeCost)) throw new TypeError("Lower bounds must be complete and belong to this graph, target and cost model");
  let labels=0,dominated=0,expanded=0;
  function add(label) {
    const estimate=lowerBounds?lowerBounds.distances[label.node]:0;
    if(estimate===Infinity)return;
    label.priority=label.cost+estimate;
    const key=graph.stateKey(label.node,label.turnState);
    const frontier=frontiers.get(key) || [];
    if(frontier.some(old=>old.active&&compare(old,label)<=0&&old.remaining>=label.remaining)) {dominated++;return;}
    const kept=[];
    for(const old of frontier){if(compare(label,old)<=0&&label.remaining>=old.remaining){old.active=false;dominated++;}else kept.push(old);}
    label.active=true;kept.push(label);frontiers.set(key,kept);labels++;heap.push(label);
  }
  function materialize(label,goalEvidence=null) {
    const arcs=[],visits=[];let cursor=label;
    while(cursor.parent){if(cursor.arc)arcs.push(cursor.arc);if(cursor.refill)visits.push({stationId:cursor.refill.id,atMeters:cursor.distance});cursor=cursor.parent;}
    arcs.reverse();visits.reverse();
    return {state:"found",arcs,visits,distanceMeters:label.distance,cost:label.cost,avoidanceCost:label.avoidance,
      remainingUsableMeters:fuel?label.remaining:null,endTurnState:label.turnState,goalEvidence,
      diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  }
  if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  add({node:start,turnState:initialTurnState,remaining:fuel?fuel.initialUsableMeters:Infinity,cost:0,avoidance:0,distance:0,parent:null});
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
    // Station membership must mean a legal visit to the physical station,
    // never a nearby map marker. Refuelling doesn't erase turn history.
    const station=fuel?graph.stationAt(cur.node):null;
    if(station && cur.remaining<fuel.usableRangeMeters) {
      add({...cur,remaining:fuel.usableRangeMeters,parent:cur,arc:null,refill:station});
    }
    for(const arc of graph.outgoing(cur.node)) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
      if(!Number.isFinite(arc.distanceMeters)||arc.distanceMeters<0)throw new TypeError("Invalid arc length");
      if(fuel&&!fuelCovers(cur.remaining,arc.distanceMeters))continue;
      const transition=graph.transition(cur.turnState,arc);
      if(!transition.allowed)continue;
      const avoidance=avoidanceCost?avoidanceCost(arc):0;
      if(!Number.isFinite(avoidance)||avoidance<0)throw new TypeError("Avoidance costs must be finite and nonnegative");
      const cost=edgeCost(arc);
      if(!Number.isFinite(cost)||cost<0)throw new TypeError("Search costs must be finite and nonnegative");
      add({node:arc.to,turnState:transition.state,cost:cur.cost+cost,avoidance:cur.avoidance+avoidance,
        remaining:fuel?Math.max(0,cur.remaining-arc.distanceMeters):Infinity,distance:cur.distance+arc.distanceMeters,parent:cur,arc,refill:null});
    }
  }
  if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
  return {state:"exhausted",reason:fuel?"no_fuel_feasible_path_in_supplied_graph":"no_path_in_supplied_graph",
    diagnostics:{labels,dominated,expanded,...budget.snapshot()}};
}
// Exact reverse distances in the eligible graph, relaxing turn/fuel state.
// This is an admissible bound for the same additive costs, not a distance cap
// or a requirement that every next road move geographically toward the pin.
function buildLowerBounds({graph,nodeCount,target,edgeCost,budget}) {
  const incoming=Array.from({length:nodeCount},()=>[]);
  for(let node=0;node<nodeCount;node++) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    for(const arc of graph.outgoing(node)) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
      const cost=edgeCost(arc);
      if(!Number.isFinite(cost)||cost<0)throw new TypeError("Search costs must be finite and nonnegative");
      incoming[arc.to].push({from:node,cost});
    }
  }
  const distances=new Float64Array(nodeCount);distances.fill(Infinity);distances[target]=0;
  const heap=new Heap();heap.push({node:target,cost:0,priority:0});let cur;
  while((cur=heap.pop())) {
    if(cur.cost!==distances[cur.node])continue;
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    for(const arc of incoming[cur.node]) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
      const cost=cur.cost+arc.cost;
      if(cost<distances[arc.from]){distances[arc.from]=cost;heap.push({node:arc.from,cost,priority:cost});}
    }
  }
  return {state:"complete",target,graph,edgeCost,distances};
}
module.exports={searchResourcePath,buildLowerBounds};
