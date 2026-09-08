"use strict";
const {matchStations}=require('./station-matching');
// One completed, immutable matching result. Bounds limit retained records, not
// total process bytes. Fuel state, station metadata and route ownership stay live.
function createStationMatchCache({maxStations=10000}={}) {
 if(!Number.isSafeInteger(maxStations)||maxStations<0)throw new TypeError('Finite station cache capacity required');
 let entry=null;
 return {
  match(options) {
   const {pack,geom,revision,stations,maxMeters,allowUnknown=false,budget}=options;
   if(typeof revision!=='string'||!revision)throw new TypeError('Immutable station matching revision required');
   const incomplete=()=>({state:'incomplete',reason:budget.snapshot().reason,matches:[],cacheHit:false});
   if(!budget.check())return incomplete();
   if(options.index?.pack!==pack||options.index?.geom!==geom||options.index?.state!=='complete')throw new TypeError('Matching index belongs to a different graph');
   let key=null;
   if(stations.length<=maxStations) {
    const rows=[];
    for(const s of stations){if(!budget.consume())return incomplete();rows.push([s.id,s.lat,s.lon]);}
    key=JSON.stringify(rows);
   }
   if(!budget.check())return incomplete();
   if(key!==null&&entry&&entry.pack===pack&&entry.geom===geom&&entry.revision===revision&&entry.key===key&&entry.maxMeters===maxMeters&&entry.allowUnknown===allowUnknown)
    return {...entry.result,cacheHit:true,cacheStored:true};
   entry=null;
   const result=matchStations(options);
   if(result.state!=='complete'||key===null)return {...result,cacheHit:false,cacheStored:false};
   // Freeze evidence before sharing it; consumer edits cannot poison later rides.
   const stack=[result];
   while(stack.length){if(!budget.consume())return incomplete();const value=stack.pop();if(value&&typeof value==='object'&&!Object.isFrozen(value)){stack.push(...Object.values(value).filter(v=>v&&typeof v==='object'));Object.freeze(value);}}
   if(!budget.check())return incomplete();
   entry={pack,geom,revision,key,maxMeters,allowUnknown,result};
   return {...result,cacheHit:false,cacheStored:true};
  },
  clear(){entry=null;},
  diagnostics(){return {entries:entry?1:0,stations:entry?.result.matches.length||0,maxStations,maxCandidateRecords:maxStations*12};}
 };
}
module.exports={createStationMatchCache};
