"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {searchResourcePath,buildLowerBounds}=require("./resource-search");
const {createBudget}=require("./budget");
const work=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:100000});

// Independent exhaustive finite-state relaxation: keeps EVERY exact fuel and
// incoming-edge state. No Pareto pruning, heap or heuristic from the engine.
function oracle({arcs,pumps,blocked,capacity,initial,escape}) {
  const states=new Map();
  const put=(node,incoming,fuel,urban,cost,refills)=>{
    const key=`${node}/${incoming}/${fuel}`,old=states.get(key);
    if(old&&(old.urban<urban||(old.urban===urban&&(old.cost<cost||(old.cost===cost&&old.refills<=refills)))))return false;
    states.set(key,{node,incoming,fuel,urban,cost,refills});return true;
  };
  put(0,-1,initial,0,0,0);
  let changed=true;
  while(changed) {
    changed=false;
    for(const s of [...states.values()]) {
      if(pumps.has(s.node))changed=put(s.node,s.incoming,capacity,s.urban,s.cost,s.refills+1)||changed;
      for(const a of arcs)if(a.from===s.node&&a.distanceMeters<=s.fuel&&!blocked.has(`${s.incoming}/${a.id}`)) {
        changed=put(a.to,a.id,s.fuel-a.distanceMeters,s.urban+a.urban,s.cost+a.cost,s.refills)||changed;
      }
    }
  }
  return [...states.values()].filter(s=>s.node===5&&s.fuel>=escape).sort((a,b)=>a.urban-b.urban||a.cost-b.cost||a.refills-b.refills)[0]||null;
}
test("250 seeded directed fuel/turn/urban graphs agree with exhaustive state enumeration",()=>{
  let seed=9182026;const rand=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
  let found=0,exhausted=0;
  for(let scenario=0;scenario<250;scenario++) {
    const arcs=[];
    for(let from=0;from<6;from++)for(let to=0;to<6;to++)if(from!==to&&rand(100)<38) {
      arcs.push({id:arcs.length,from,to,distanceMeters:1+rand(4),cost:1+rand(12),urban:rand(4)===0?1+rand(3):0});
    }
    const pumps=new Set(Array.from({length:6},(_,i)=>i).filter(()=>rand(3)===0)),blocked=new Set();
    for(const a of arcs)for(const b of arcs)if(a.to===b.from&&rand(7)===0)blocked.add(`${a.id}/${b.id}`);
    const capacity=4+rand(5),initial=rand(capacity+1),escape=rand(3);
    const graph={outgoing:node=>arcs.filter(a=>a.from===node),stationAt:node=>pumps.has(node)?{id:`pump-${node}`}:null,
      stateKey:(node,incoming)=>`${node}/${incoming??-1}`,
      transition:(incoming,a)=>({allowed:!blocked.has(`${incoming??-1}/${a.id}`),state:a.id})};
    const edgeCost=a=>a.cost,options={graph,start:0,end:5,edgeCost,avoidanceCost:a=>a.urban,
      fuel:{usableRangeMeters:capacity,initialUsableMeters:initial},destinationEscapeMeters:escape};
    const expected=oracle({arcs,pumps,blocked,capacity,initial,escape});
    const lowerBounds=buildLowerBounds({graph,nodeCount:6,target:5,edgeCost,budget:work()});
    const capped=buildLowerBounds({graph,nodeCount:6,target:5,edgeCost,budget:work(),stopAt:0});
    for(const bounds of [null,lowerBounds,capped]) {
      const actual=searchResourcePath({...options,lowerBounds:bounds,budget:work()});
      assert.equal(actual.state,expected?"found":"exhausted",`scenario ${scenario}, bounds ${!!bounds}`);
      if(expected) {
        assert.deepEqual([actual.avoidanceCost,actual.cost],[expected.urban,expected.cost],`scenario ${scenario}`);
        assert.ok(actual.remainingUsableMeters>=escape);
        assert.equal(actual.visits.length,expected.refills,`refill count, scenario ${scenario}`);
        let node=0,incoming=-1,fuel=initial,meters=0;
        for(const a of actual.arcs) {
          if(actual.visits.some(v=>v.atMeters===meters&&v.stationId===`pump-${node}`))fuel=capacity;
          assert.equal(a.from,node);assert.ok(!blocked.has(`${incoming}/${a.id}`));
          fuel-=a.distanceMeters;assert.ok(fuel>=0);node=a.to;incoming=a.id;meters+=a.distanceMeters;
        }
        assert.equal(node,5);
      }
    }
    if(expected)found++;else exhausted++;
  }
  assert.ok(found>25&&exhausted>25,`coverage: ${found} found, ${exhausted} exhausted`);
});
