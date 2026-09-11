'use strict';
// Some callers consume only the decoded pack. Keep the legacy snapping grid
// available to its real callers without eagerly duplicating adventure's index.
function attachDeferredEdgeGrid(runtime,geom,edgeCount,build) {
 let prepared=null;
 const ensure=()=>{
  if(prepared)return prepared;
  const started=Date.now(),result=build(geom,edgeCount);
  // Publish only after a successful build; a failure remains retryable.
  prepared=result;runtime.loadDiagnostics.gridMs=Date.now()-started;
  runtime.loadDiagnostics.gridDeferred=false;
  return prepared;
 };
 runtime.loadDiagnostics.gridDeferred=true;
 Object.defineProperties(runtime,{
  edgeGrid:{enumerable:true,get:()=>ensure().edgeGrid},
  GRID:{enumerable:true,get:()=>ensure().GRID}
 });
 return runtime;
}
module.exports={attachDeferredEdgeGrid};
