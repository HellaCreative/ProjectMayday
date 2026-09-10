"use strict";
const {haversineMeters}=require("../legal-topology/find-path-v4");

// Embedded major-core boxes are the existing data's explicit classification.
// The separate settlement list includes welcome rural towns; do not turn it
// into an exclusion list or infer a population threshold. Additional reviewed
// large-town boxes may be supplied explicitly, with their source identity.
function urbanAreasFromPack(pack,{additionalAreas=[]}={}) {
  const cores=pack.meta?.urbanCores;
  return {areas:[...(Array.isArray(cores)?cores:[]),...additionalAreas],
    evidence:{source:"embedded_major_cores_and_explicit_review",majorCoreCount:cores?.length||0,
      additionalAreaCount:additionalAreas.length,unclassifiedSettlementCount:pack.meta?.settlements?.length||0,
      classificationComplete:false}};
}
function validBox(box) {
  return [box.minLon,box.minLat,box.maxLon,box.maxLat].every(Number.isFinite)&&
    box.minLon<=box.maxLon&&box.minLat<=box.maxLat&&box.minLon>=-180&&box.maxLon<=180&&box.minLat>=-90&&box.maxLat<=90;
}
// Parameter interval of a source-polyline segment inside a rectangle. Using
// the complete line catches roads crossing a core with both endpoints outside.
function interval(a,b,box) {
  let lo=0,hi=1;
  for(const [axis,min,max] of [[0,box.minLon,box.maxLon],[1,box.minLat,box.maxLat]]) {
    const delta=b[axis]-a[axis];
    if(delta===0) {if(a[axis]<min||a[axis]>max)return null;continue;}
    const x=(min-a[axis])/delta,y=(max-a[axis])/delta;
    lo=Math.max(lo,Math.min(x,y));hi=Math.min(hi,Math.max(x,y));
    if(hi<=lo)return null;
  }
  return [lo,hi];
}
function buildUrbanExposure({pack,geom,areas,budget,index=null}) {
  if(areas.some(box=>!validBox(box)))throw new TypeError("Valid urban bounds required");
  if(index&&(index.state!=="complete"||index.pack!==pack||index.geom!==geom))throw new TypeError("Urban index belongs to a different graph");
  const ranges=new Map(),candidates=new Map();
  if(index) {
    for(const box of areas) {
      const edges=index.queryBox(box,budget);
      if(!edges)return {state:"incomplete",reason:budget.snapshot().reason};
      for(const edge of edges) {
        // The spatial index already excludes distant boxes without losing crossings.
        const boxes=candidates.get(edge)||[];boxes.push(box);candidates.set(edge,boxes);
      }
    }
  } else for(let edge=0;edge<pack.edgeCount;edge++) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    candidates.set(edge,areas);
  }
  for(const [edge,edgeAreas] of candidates) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    if(!areas.length)continue;
    const coords=geom.polyline(edge);
    if(coords.length<2)throw new TypeError("Urban classification requires source geometry");
    const pieces=[];let length=0;
    for(let i=1;i<coords.length;i++) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
      const a=coords[i-1],b=coords[i];
      if(![...a,...b].every(Number.isFinite)||Math.abs(b[0]-a[0])>180)throw new TypeError("Unsupported or invalid urban source geometry");
      const meters=haversineMeters(a,b);
      for(const box of edgeAreas) {
        if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
        const span=interval(a,b,box);
        if(span&&meters>0)pieces.push([length+meters*span[0],length+meters*span[1]]);
      }
      length+=meters;
    }
    if(!pieces.length||!length)continue;
    pieces.sort((a,b)=>a[0]-b[0]);const merged=[];
    for(const piece of pieces) {
      const last=merged[merged.length-1];
      if(last&&piece[0]<=last[1])last[1]=Math.max(last[1],piece[1]);else merged.push(piece.slice());
    }
    ranges.set(edge,merged.map(([from,to])=>[from/length,to/length]));
  }
  function urbanMeters(arc) {
    const spans=ranges.get(arc.id);
    if(!spans)return 0;
    const from=arc.fromFraction??0,to=arc.toFraction??1;
    const lo=Math.min(from,to),hi=Math.max(from,to);
    let fraction=0;
    for(const [a,b] of spans)fraction+=Math.max(0,Math.min(hi,b)-Math.max(lo,a));
    return Math.min(arc.distanceMeters,pack.edgeMeters[arc.id]*fraction);
  }
  return {state:"complete",pack,geom,urbanMeters,diagnostics:{areaCount:areas.length,affectedEdges:ranges.size,examinedEdges:candidates.size}};
}
module.exports={urbanAreasFromPack,buildUrbanExposure};
