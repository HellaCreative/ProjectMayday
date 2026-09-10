'use strict';
function validatePreferences(value) {
 if(value==null)return null;
 if(typeof value!=='object'||!Number.isFinite(value.wander)||value.wander<0||value.wander>1||typeof value.avoidCities!=='boolean'||typeof value.avoidHighways!=='boolean')throw new TypeError('Invalid ride preferences');
 if(value.preferDifferentRoads!=null&&typeof value.preferDifferentRoads!=='boolean')throw new TypeError('Invalid return road preference');
 return {wander:value.wander,avoidCities:value.avoidCities,avoidHighways:value.avoidHighways,...(value.preferDifferentRoads===true?{preferDifferentRoads:true}:{})};
}
// Wander changes the cost of extra distance while preserving each surface
// objective. Filtering the finished pool by shortest distance turned zero into
// a hidden paved profile. A positive distance charge instead discourages detours
// continuously; the chosen surface profile still ranks every feasible result.
function wanderEdgeCost(base,wander=1) {
 if(!Number.isFinite(wander)||wander<0||wander>1)throw new TypeError('Invalid wander');
 if(wander===1)return base;
 const distancePenalty=30*(1-wander)**2;
 return arc=>base(arc)+arc.distanceMeters*distancePenalty;
}
const highwayCosts=new WeakMap();
function preferenceEdgeCost(base,preferences) {
 if(!preferences?.avoidHighways)return base;
 if(!highwayCosts.has(base))highwayCosts.set(base,arc=>base(arc)*(/^(motorway|trunk|primary)(?:_link)?$|^freeway$/.test(arc.roadClassLeaf||"")?10:1));
 return highwayCosts.get(base);
}
module.exports={validatePreferences,wanderEdgeCost,preferenceEdgeCost};
