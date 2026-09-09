'use strict';
const {tapRadiusMeters,metersPerPoint,TAP_FINGER_POINTS}=require('../legal-topology/tap-radius');
// Rider area selection may cover kilometres when zoomed out. This does not
// widen a fuel POI's binding or create a road connection across that distance.
function waypointRadiusMeters({zoom,lat,requestedMeters}={}) {
 const base=tapRadiusMeters({zoom,lat,requestedMeters,graphBinaryVersion:4});
 if(Number.isFinite(Number(requestedMeters))&&Number(requestedMeters)>0)return base;
 const mpp=metersPerPoint(zoom,lat);
 return mpp==null?base:Math.max(base,Math.min(20000,TAP_FINGER_POINTS*mpp));
}
module.exports={waypointRadiusMeters};
