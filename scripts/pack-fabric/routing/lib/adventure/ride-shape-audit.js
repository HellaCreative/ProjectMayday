"use strict";
const {surfaceKind}=require('./surface');
// Diagnostics, not new scoring or rejection thresholds. Repeated intervals can
// be legitimate fuel/waypoint access; short dirt alone cannot prove a diversion.
function auditRideShape({segments,budget}) {
 const seen=new Map(),nodes=new Map(),repeated=[],revisited=[],dirtRuns=[];
 let at=0,run=null;
 for(const s of segments) {
  if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
  const length=s.distanceMeters,lo=Math.min(s.fromFraction,s.toFraction),hi=Math.max(s.fromFraction,s.toFraction);
  if(!Number.isFinite(length)||length<0||![lo,hi].every(Number.isFinite)||lo<0||hi>1||(!Number.isSafeInteger(s.edgeIndex)||s.edgeIndex<0))throw new TypeError('Valid measured edge intervals required');
  if(length===0)continue;
  if(hi===lo)throw new TypeError('Positive distance requires a nonzero edge interval');
  const prior=seen.get(s.edgeIndex)||[];let overlap=0;
  for(const [a,b] of prior){if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};overlap+=Math.max(0,Math.min(b,hi)-Math.max(a,lo));}
  if(overlap>1e-12)repeated.push({edgeIndex:s.edgeIndex,atMeters:at,distanceMeters:length*overlap/(hi-lo),surfaceKind:surfaceKind(s.surfaceLeaf)});
  const merged=[];let left=lo,right=hi;
  for(const [a,b] of prior){if(b<left)merged.push([a,b]);else if(a>right){merged.push([left,right]);left=a;right=b;}else{left=Math.min(left,a);right=Math.max(right,b);}}
  merged.push([left,right]);seen.set(s.edgeIndex,merged);
  if(nodes.size===0)nodes.set(s.fromNode,at);
  if(nodes.has(s.toNode))revisited.push({node:s.toNode,firstAtMeters:nodes.get(s.toNode),atMeters:at+length});
  else nodes.set(s.toNode,at+length);
  if(surfaceKind(s.surfaceLeaf)==='dirt') {
   if(!run)run={startMeters:at,distanceMeters:0};run.distanceMeters+=length;
  }else if(run){dirtRuns.push(run);run=null;}
  at+=length;
 }
 if(run)dirtRuns.push(run);
 return {state:'complete',distanceMeters:at,repeatedRoadMeters:repeated.reduce((sum,r)=>sum+r.distanceMeters,0),repeatedKnownDirtMeters:repeated.filter(r=>r.surfaceKind==='dirt').reduce((sum,r)=>sum+r.distanceMeters,0),repeatedIntervals:repeated,revisitedNodes:revisited,
  dirtRuns,shortDirtRunCounts:{under250Meters:dirtRuns.filter(r=>r.distanceMeters<250).length,under1000Meters:dirtRuns.filter(r=>r.distanceMeters<1000).length},
  limitations:['diagnostic bins are not routing thresholds','fuel and rider-waypoint spurs require context','short dirt runs alone do not prove needless diversions']};
}
module.exports={auditRideShape};
