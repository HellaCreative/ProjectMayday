"use strict";

const {haversineMeters}=require("../legal-topology/find-path-v4");
const {summarizeSurface}=require("./surface");

function measuredPolyline(coords,budget) {
  const cumulative=[0];
  for(let i=1;i<coords.length;i++) {
    if(!budget.consume())return null;
    cumulative.push(cumulative[i-1]+haversineMeters(coords[i-1],coords[i]));
  }
  return {coords,cumulative,length:cumulative[cumulative.length-1]||0};
}
function pointAt(line,fraction) {
  const distance=line.length*fraction;
  if(fraction<=0)return line.coords[0].slice();
  if(fraction>=1)return line.coords[line.coords.length-1].slice();
  let i=1;while(i<line.cumulative.length-1&&line.cumulative[i]<distance)i++;
  const span=line.cumulative[i]-line.cumulative[i-1];
  const t=span>0?(distance-line.cumulative[i-1])/span:0;
  const a=line.coords[i-1],b=line.coords[i];
  return [a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t];
}
function clip(line,from,to) {
  const low=Math.min(from,to),high=Math.max(from,to);
  const coords=[pointAt(line,low)];
  for(let i=1;i<line.coords.length-1;i++) {
    const fraction=line.length?line.cumulative[i]/line.length:0;
    if(fraction>low&&fraction<high)coords.push(line.coords[i].slice());
  }
  coords.push(pointAt(line,high));
  return from<=to?coords:coords.reverse();
}

// Existing snap fractions divide geometric distance by rounded pack length.
// Normalize against actual geometry here so start/end pixels remain at the
// projection; search length stays proportional to the authoritative edge length.
function pointFromMatch(id,match,geom,budget,station=null) {
  const line=measuredPolyline(geom.polyline(match.edgeIndex),budget);
  if(!line)return null;
  if(!line.coords.length)throw new TypeError("Matched edge has no geometry");
  const fraction=line.length?Math.max(0,Math.min(1,match.distanceAlongM/line.length)):0;
  return {id,edgeIndex:match.edgeIndex,fraction,...(station?{station}:{})};
}

function materializeRoute({pack,geom,result,budget}) {
  if(result.state!=="found")return {state:"unverified",reason:result.reason||result.state};
  const lines=new Map(),segments=[],geometry=[];
  let previousNode=null;
  for(const arc of result.arcs) {
    if(!budget.consume())return {state:"unverified",reason:budget.snapshot().reason};
    if(previousNode!==null&&arc.from!==previousNode)throw new Error("Disconnected route arcs");
    previousNode=arc.to;
    let line=lines.get(arc.id);
    if(!line){line=measuredPolyline(geom.polyline(arc.id),budget);if(!line)return {state:"unverified",reason:budget.snapshot().reason};lines.set(arc.id,line);}
    if(line.coords.length<2)throw new Error("Missing source edge geometry");
    const forward=pack.edgeFrom[arc.id]===arc.from;
    const from=arc.fromFraction??(forward?0:1),to=arc.toFraction??(forward?1:0);
    const coords=clip(line,from,to);
    if(geometry.length) {
      const last=geometry[geometry.length-1],first=coords[0];
      if(Math.abs(last[0]-first[0])>1e-7||Math.abs(last[1]-first[1])>1e-7)throw new Error("Source geometry does not join at the route node");
      geometry.push(...coords.slice(1));
    } else geometry.push(...coords);
    segments.push({edgeIndex:arc.id,edgeId:pack.edgeId(arc.id),fromNode:arc.from,toNode:arc.to,
      fromFraction:from,toFraction:to,distanceMeters:arc.distanceMeters,surfaceLeaf:arc.surfaceLeaf,accessClass:({0:"motorized_verified",1:"motorized_unknown",2:"motorized_excluded",3:"motorized_restricted",4:"motorized_restricted"})[pack.edgeAccess?.[arc.id*2+(to>from?0:1)]]||"motorized_unknown",geometry:coords});
  }
  const surface=summarizeSurface(segments,budget);
  if(!surface)return {state:"unverified",reason:budget.snapshot().reason};
  return {state:"complete",geometry,segments,distanceMeters:surface.distanceMeters,surface,
    plannedRefills:result.visits,remainingUsableMeters:result.remainingUsableMeters};
}
module.exports={pointFromMatch,materializeRoute};
