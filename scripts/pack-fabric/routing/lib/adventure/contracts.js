"use strict";

function positive(value, name) {
  if (!Number.isFinite(value) || value <= 0) throw new TypeError(`${name} must be positive`);
  return value;
}
function normalizeRequest(input) {
  if (!input || !["from_here","plan","loop"].includes(input.mode)) throw new TypeError("Unknown ride mode");
  if (!Array.isArray(input.anchors)) throw new TypeError("Rider anchors required");
  const count=input.anchors.length;
  if ((input.mode==="loop" && count!==1) || (input.mode==="from_here" && count!==2) || (input.mode==="plan" && count<2)) throw new TypeError("Invalid rider anchor count");
  const ids=new Set();
  const anchors=Array.from(input.anchors,anchor=>{
    if(!anchor || typeof anchor!=="object" || Array.isArray(anchor)) throw new TypeError("Invalid rider anchor");
    if(typeof anchor.id!=="string" || !anchor.id || ids.has(anchor.id)) throw new TypeError("Unique anchor ids required");
    ids.add(anchor.id);
    if(!Number.isFinite(anchor.lat) || Math.abs(anchor.lat)>90 || !Number.isFinite(anchor.lon) || Math.abs(anchor.lon)>180) throw new TypeError("Invalid coordinates");
    if(anchor.kind && anchor.kind!=="rider") throw new TypeError("Generated fuel cannot be a rider anchor");
    if(anchor.stationId!=null && !((typeof anchor.stationId==="string" && anchor.stationId.trim()) ||
      (Number.isSafeInteger(anchor.stationId) && anchor.stationId>=0))) throw new TypeError("Invalid station identity");
    return Object.freeze({id:anchor.id,kind:"rider",lat:anchor.lat,lon:anchor.lon,
      // A station association is an intention, not a proved legal station visit.
      stationId:anchor.stationId == null ? null : String(anchor.stationId)});
  });
  const legs=input.mode==="loop" ? [{from:anchors[0].id,to:anchors[0].id,profile:input.profile,allowUnknown:input.allowUnknown}] : input.legs;
  if(!Array.isArray(legs) || legs.length!==(input.mode==="loop" ? 1 : count-1)) throw new TypeError("Exactly one primary leg per anchor pair required");
  const normalizedLegs=Array.from(legs,(leg,index)=>{
    if(!leg || typeof leg!=="object" || Array.isArray(leg)) throw new TypeError("Invalid primary leg");
    const from=anchors[index].id,to=anchors[input.mode==="loop" ? 0 : index+1].id;
    if(leg.from!==from || leg.to!==to || !["dirt","balanced","clean"].includes(leg.profile)) throw new TypeError("Invalid primary leg");
    return Object.freeze({from,to,profile:leg.profile,allowUnknown:leg.allowUnknown===true});
  });
  let loop=null;
  if(input.mode==="loop") {
    const value=input.loop || {};
    if(!["N","NE","E","SE","S","SW","W","NW"].includes(value.direction)) throw new TypeError("Loop direction required");
    if(!["distance","moving_time"].includes(value.target?.kind)) throw new TypeError("Loop target required");
    loop=Object.freeze({direction:value.direction,target:Object.freeze({kind:value.target.kind,
      value:positive(value.target.value,"Loop target"),approximate:true}),firstStop:"fuel"});
  }
  let fuel=null;
  if(input.fuel!=null) {
    if(typeof input.fuel!=="object" || Array.isArray(input.fuel)) throw new TypeError("Invalid fuel settings");
    const fullRangeMeters=positive(input.fuel.fullRangeMeters,"Full tank range");
    const reserveFraction=input.fuel.reserveFraction;
    if(!Number.isFinite(reserveFraction) || reserveFraction<0 || reserveFraction>=1) throw new TypeError("Invalid reserve fraction");
    const usableRangeMeters=fullRangeMeters*(1-reserveFraction);
    const initial=input.fuel.initialUsableMeters;
    if(initial!=null && (!Number.isFinite(initial) || initial<0 || initial>usableRangeMeters)) throw new TypeError("Invalid starting usable range");
    fuel=Object.freeze({fullRangeMeters,reserveFraction,usableRangeMeters,initialUsableMeters:initial ?? null});
  }
  if(input.mode==="loop" && !fuel) throw new TypeError("Loop requires fuel settings");
  if(input.generationId!=null && (typeof input.generationId!=="string" || !input.generationId.trim())) throw new TypeError("Invalid generation identity");
  return Object.freeze({version:"dirt-adventure.v1",mode:input.mode,anchors:Object.freeze(anchors),
    legs:Object.freeze(normalizedLegs),loop,fuel,generationId:input.generationId ?? null});
}
module.exports={normalizeRequest};
