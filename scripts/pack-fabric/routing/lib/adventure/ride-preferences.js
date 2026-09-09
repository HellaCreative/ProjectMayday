'use strict';
function validatePreferences(value) {
 if(value==null)return null;
 if(typeof value!=='object'||!Number.isFinite(value.wander)||value.wander<0||value.wander>1||typeof value.avoidCities!=='boolean'||typeof value.avoidHighways!=='boolean')throw new TypeError('Invalid ride preferences');
 return {wander:value.wander,avoidCities:value.avoidCities,avoidHighways:value.avoidHighways};
}
// Wander narrows the proven shared pool; it never invents distance or relaxes
// access/fuel constraints. At 1 the accepted profile selection is unchanged.
function wanderCandidates(rows,wander=1) {
 if(!rows.length||wander===1)return rows;
 const exposure=r=>r.result.road.avoidanceMeters??r.result.road.urbanMeters??0;
 const minimum=Math.min(...rows.map(exposure));
 const eligible=rows.filter(r=>exposure(r)<=minimum+1e-6);
 const distances=eligible.map(r=>r.result.road.distanceMeters);
 const low=Math.min(...distances),high=Math.max(...distances);
 const limit=low+(high-low)*wander;
 return eligible.filter(r=>r.result.road.distanceMeters<=limit+1e-6);
}
module.exports={validatePreferences,wanderCandidates};
