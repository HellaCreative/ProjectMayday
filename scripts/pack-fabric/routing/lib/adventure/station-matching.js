"use strict";

const {legalSnapDetailed}=require("../legal-topology/snap");

// Coarse index only narrows the exact legal projection search. It never proves
// station arrival or connects the station to a nearby road by a synthetic arc.
function buildEdgeIndex(pack,geom,budget) {
  const size=.02,cells=new Map(),broad=new Set(),bounds=new Float64Array(pack.edgeCount*4);
  for(let edge=0;edge<pack.edgeCount;edge++) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
    if(geom.offsets&&geom.coords) {
      // Decoded immutable geometry exposes its exact coordinates; avoid
      // allocating millions of temporary point arrays for this bounds pass.
      for(let i=geom.offsets[edge];i<geom.offsets[edge+1];i+=2) {
        if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
        const x=geom.coords[i],y=geom.coords[i+1];
        minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);
      }
    } else for(const [x,y] of geom.polyline(edge)) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
      minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);
    }
    const at=edge*4;bounds[at]=minX;bounds[at+1]=minY;bounds[at+2]=maxX;bounds[at+3]=maxY;
    if(!Number.isFinite(minX))continue;
    const a=Math.floor(minX/size),b=Math.floor(maxX/size),c=Math.floor(minY/size),d=Math.floor(maxY/size);
    if((b-a+1)*(d-c+1)>1000){broad.add(edge);continue;}
    for(let x=a;x<=b;x++)for(let y=c;y<=d;y++) {
      const key=`${x}:${y}`,list=cells.get(key)||[];list.push(edge);cells.set(key,list);
    }
  }
  return {state:"complete",pack,geom,queryBox(box,work){
    const edges=new Set(broad);
    for(let x=Math.floor(box.minLon/size);x<=Math.floor(box.maxLon/size);x++)
      for(let y=Math.floor(box.minLat/size);y<=Math.floor(box.maxLat/size);y++) {
        if(!work.consume())return null;
        for(const edge of cells.get(`${x}:${y}`)||[]) {
          if(!work.consume())return null;
          edges.add(edge);
        }
      }
    return [...edges];
  },query(station,radiusMeters){
    const lat=station.lat,lon=station.lon;
    const dy=radiusMeters/110000,dx=Math.min(180,dy/Math.max(.00001,Math.cos((Math.abs(lat)+dy)*Math.PI/180)));
    const edges=new Set(broad);
    const ranges=[[Math.max(-180,lon-dx),Math.min(180,lon+dx)]];
    if(lon-dx < -180)ranges.push([lon-dx+360,180]);
    if(lon+dx > 180)ranges.push([-180,lon+dx-360]);
    // Extremely broad polar queries fall back to all edges; no false omission.
    if(dx>1)return Array.from({length:pack.edgeCount},(_,i)=>i);
    for(const [lo,hi] of ranges)for(let x=Math.floor(lo/size);x<=Math.floor(hi/size);x++)
      for(let y=Math.floor((lat-dy)/size);y<=Math.floor((lat+dy)/size);y++)for(const edge of cells.get(`${x}:${y}`)||[])edges.add(edge);
    // Exact source bounds cheaply reject roads from the same coarse cell that
    // cannot intersect the conservative search rectangle. Keep every segment
    // crossing, including those whose endpoints lie outside that rectangle.
    return [...edges].filter(edge=>{
      const at=edge*4;
      return bounds[at+3]>=lat-dy&&bounds[at+1]<=lat+dy&&ranges.some(([lo,hi])=>bounds[at+2]>=lo&&bounds[at]<=hi);
    });
  }};
}

function matchStations({pack,geom,stations,index,maxMeters,allowUnknown=false,budget,eligibleEdge=null}) {
  if(index?.state!=="complete" || index.pack!==pack || index.geom!==geom)throw new TypeError("Matching index belongs to a different graph");
  if(!Number.isFinite(maxMeters)||maxMeters<=0)throw new TypeError("Explicit station matching radius required");
  const matches=[];
  for(const station of stations) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason,matches};
    if(!station.id || !Number.isFinite(station.lat)||Math.abs(station.lat)>90||!Number.isFinite(station.lon)||Math.abs(station.lon)>180) {
      matches.push({stationId:station.id??null,state:"rejected",reason:"invalid_station_coordinates"});continue;
    }
    const queried=index.query(station,maxMeters);
    const candidateEdgeIndexes=eligibleEdge?queried.filter(eligibleEdge):queried;
    const candidates=[],counts={};
    // No bearing hints are used for stationary POIs. The nearest twelve from
    // each chunk contain every possible member of the nearest twelve overall.
    // Chunking also lets the shared deadline interrupt dense/polar matching.
    for(let offset=0;offset<candidateEdgeIndexes.length;offset+=32) {
      if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason,matches};
      const detailed=legalSnapDetailed(pack,geom,station,{candidateEdgeIndexes:candidateEdgeIndexes.slice(offset,offset+32),maxMeters,allowUnknown});
      candidates.push(...detailed.candidates);
      for(const rejection of detailed.rejections)counts[rejection.reason]=(counts[rejection.reason]||0)+1;
    }
    if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,matches};
    candidates.sort((a,b)=>a.score-b.score);
    matches.push({stationId:station.id,state:candidates.length?"candidates":"rejected",
      reason:candidates.length?null:"no_eligible_projection",searchedEdges:candidateEdgeIndexes.length,
      rejectionCounts:counts,candidates:candidates.slice(0,12)});
  }
  return {state:"complete",matches};
}
module.exports={buildEdgeIndex,matchStations};
