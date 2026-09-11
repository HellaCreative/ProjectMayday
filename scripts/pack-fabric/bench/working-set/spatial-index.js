"use strict";
// LOCAL EXPERIMENT: exact same cell enumeration and source-coordinate bounds as
// station-matching.js, stored separately from immutable published pack bytes.
// Keep the oracle comparison in working-set.test.js when changing this copy.
function buildIndexData(pack,geom,budget) {
  const size=.02,cells=new Map(),broad=new Set(),bounds=new Float64Array(pack.edgeCount*4);
  for(let edge=0;edge<pack.edgeCount;edge++) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
    const range=geom.offsets&&geom.coords?{coords:geom.coords,start:geom.offsets[edge],end:geom.offsets[edge+1]}:geom.coordinateRange?.(edge);
    if(range) {
      // Decoded immutable geometry exposes its exact coordinates; avoid
      // allocating millions of temporary point arrays for this bounds pass.
      for(let i=range.start;i<range.end;i+=2) {
        if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
        const x=range.coords[i],y=range.coords[i+1];
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
  return {state:"complete",size,cells,broad,bounds};
}
function restoreIndex(data,pack,geom) {
  if(data?.state!=="complete"||data.size!==.02||!(data.cells instanceof Map)||!(data.broad instanceof Set)||
     !(data.bounds instanceof Float64Array)||data.bounds.length!==pack.edgeCount*4)
    throw new TypeError("Incomplete or incompatible spatial preparation");
  const {size,cells,broad,bounds}=data;
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

module.exports={buildIndexData,restoreIndex};
