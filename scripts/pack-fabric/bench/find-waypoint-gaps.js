'use strict';
const fs=require('node:fs'),path=require('node:path');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {buildEdgeIndex,matchStations}=require('../routing/lib/adventure/station-matching');
const {createBudget}=require('../routing/lib/adventure/budget');
const {weakComponentIds}=require('../routing/lib/legal-topology/snap');
const {resolveGraphRequest}=require('../routing/regional/select');
const root=process.env.REBUILD_PACK_ROOT,rows=[];
for(const [region,boxes] of Object.entries({ns:[[44.1,44.6,-65.6,-64.9],[46.55,46.95,-60.9,-60.45]],nb:[[46.9,47.6,-66.8,-65.9]]})){
 const dir=path.join(root,region),gb=fs.readFileSync(path.join(dir,'geometry.v1.bin')),geom=decodeGeometryV1(gb),pack=decodeGraphV4(fs.readFileSync(path.join(dir,'graph.v4.bin')),gb);
 const budget=createBudget({deadlineAtMs:Date.now()+120000,maxExpansions:30000000}),index=buildEdgeIndex(pack,geom,budget),components=weakComponentIds(pack,false),counts=new Map();
 for(const c of components)counts.set(c,(counts.get(c)||0)+1);
 const main=[...counts].sort((a,b)=>b[1]-a[1])[0][0];
 for(const [south,north,west,east] of boxes)for(let lat=south;lat<=north;lat+=.1)for(let lon=west;lon<=east;lon+=.1){
  const point={id:'area',lat:+lat.toFixed(5),lon:+lon.toFixed(5)};
  const resolved=resolveGraphRequest({locations:[point,point]});if(!resolved.ok||!resolved.regionIds.includes(region))continue;
  const result=matchStations({pack,geom,index,stations:[point],maxMeters:20000,budget,eligibleEdge:e=>components[pack.edgeFrom[e]]===main});
  const c=result.matches?.[0]?.candidates?.[0];if(c&&c.distanceM>2000)rows.push({region,...point,distanceMeters:c.distanceM,road:{lat:c.lat,lon:c.lon},edgeIndex:c.edgeIndex});
 }
}
rows.sort((a,b)=>b.distanceMeters-a.distanceMeters);
fs.writeFileSync(process.env.REBUILD_GAP_OUTPUT||'/tmp/dirt-waypoint-gaps.json',JSON.stringify(rows,null,2));console.log(JSON.stringify({count:rows.length,examples:rows.slice(0,12)}));
