'use strict';
const {qualifiedPack}=require('./pack-revision-qualification');
// Reuse only deployment-pinned immutable V4 URLs and independently qualified
// graph/geometry/fuel identities. Mutable candidate URLs and local paths miss.
function sourceKey(sources) {
 if(!Array.isArray(sources)||!sources.length||new Set(sources.map(s=>s.regionId)).size!==sources.length)return null;
 for(const s of sources) {
  let graph,fuel;
  try {graph=new URL(s.graphSource);fuel=new URL(s.fuelSource);}catch{return null;}
  if(!['http:','https:'].includes(graph.protocol)||graph.search||graph.hash||fuel.search||fuel.hash)return null;
  const match=graph.pathname.match(/\/v4\/releases\/([^/]+)\/([a-z]{2})\/graph\.v4\.bin$/);
  if(!match||match[2]!==s.regionId||fuel.href!==graph.href.replace(/graph\.v4\.bin$/,'fuel.v1.json'))return null;
 }
 return JSON.stringify(sources);
}
function reusableRuntime(cache,sources) {
 const key=sourceKey(sources);
 if(!key||cache?.sourceKey!==key||cache.data?.identity?.length!==sources.length)return null;
 if(!cache.data.identity.every((id,i)=>qualifiedPack(id)&&id.regionId===sources[i].regionId&&
  new URL(sources[i].graphSource).pathname.split('/releases/')[1].split('/')[0]===id.releaseId&&id.graphSource===sources[i].graphSource&&id.geometrySource===sources[i].graphSource.replace(/graph\.v4\.bin$/,'geometry.v1.bin')&&id.fuelSource===sources[i].fuelSource))return null;
 return cache.data;
}
module.exports={sourceKey,reusableRuntime};
