"use strict";
const {buildEdgeIndex}=require("./station-matching");
const {buildUrbanExposure}=require("./urban-exposure");

// Reuse only completed, geometry-derived preparation. Pack instance AND immutable
// revision must match: a regional name cannot identify cached road data. Route
// endpoints, styles, fuel labels and turn histories never enter this cache.
function createPreparationCache({maxEntries=1,compact=false}={}) {
  if(!Number.isSafeInteger(maxEntries)||maxEntries<1)throw new TypeError("Positive preparation cache capacity required");
  let entries=[];
  return {
    prepare({pack,geom,revision,areas,budget}) {
      if(typeof revision!=="string"||!revision)throw new TypeError("Immutable preparation revision required");
      if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,cacheHit:false};
      const areaKey=JSON.stringify(areas.map(a=>[a.minLon,a.minLat,a.maxLon,a.maxLat]));
      const at=entries.findIndex(e=>e.pack===pack&&e.geom===geom&&e.revision===revision&&e.areaKey===areaKey);
      if(at>=0) {
        const [entry]=entries.splice(at,1);entries.push(entry);
        return {state:"complete",cacheHit:true,prepared:entry.prepared};
      }
      const index=buildEdgeIndex(pack,geom,budget,{compact});
      if(index.state!=="complete")return {...index,stage:"road_index",cacheHit:false};
      const urban=buildUrbanExposure({pack,geom,areas,budget,index});
      if(urban.state!=="complete")return {...urban,stage:"urban_index",cacheHit:false};
      if(!budget.check())return {state:"incomplete",reason:budget.snapshot().reason,cacheHit:false};
      const prepared=Object.freeze({index,urban,revision});
      entries.push({pack,geom,revision,areaKey,prepared});
      if(entries.length>maxEntries)entries.shift();
      return {state:"complete",cacheHit:false,prepared};
    },
    clear(){entries=[];},
    diagnostics(){return {entries:entries.length,maxEntries};}
  };
}
module.exports={createPreparationCache};
