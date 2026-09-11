'use strict';
const {buildLowerBounds}=require('./resource-search');
// Request-owned, single-entry cache. Only immutable, identical projected
// topology and the exact exposure function may share a distance array.
function createTargetBoundsCache({releaseGraph=false}={}) {
 let entry=null;
 return {prepare(options) {
  const {graph,target,stopAt=null,edgeCost,budget}=options,t=graph.reverseTopology;
  if(!budget.check())return {state:'incomplete',reason:budget.snapshot().reason};
  if(t&&entry&&entry.pack===t.pack&&entry.key===t.key&&entry.target===target&&entry.stopAt===stopAt&&entry.edgeCost===edgeCost)
   return {...entry.result,graph,edgeCost,cacheHit:true};
  const result=buildLowerBounds(options);
  if(result.state==='complete'&&t)entry={pack:t.pack,key:t.key,target,stopAt,edgeCost,result:releaseGraph?{...result,graph:undefined}:result};
  return {...result,cacheHit:false};
 }};
}
module.exports={createTargetBoundsCache};
