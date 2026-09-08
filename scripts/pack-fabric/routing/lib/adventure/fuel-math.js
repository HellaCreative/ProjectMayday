"use strict";
// Keep search, final proof and destination escape consistent at floating-point
// boundaries. This existing proof tolerance is one micrometre in road distance,
// not an allowance to spend the rider's protected reserve.
const ROUNDING_METERS=1e-6;
function fuelCovers(remainingMeters,distanceMeters) {
  return distanceMeters<=remainingMeters+ROUNDING_METERS;
}
function validateFuel(fuel,{requireInitial=false}={}) {
  if(!fuel || typeof fuel!=="object" || Array.isArray(fuel) ||
    !Number.isFinite(fuel.usableRangeMeters) || fuel.usableRangeMeters<=0) throw new TypeError("Invalid usable fuel range");
  const initial=fuel.initialUsableMeters;
  if(initial==null) {
    if(requireInitial)throw new TypeError("Known initial fuel required for search");
    return;
  }
  if(!Number.isFinite(initial) || initial<0 || initial>fuel.usableRangeMeters) throw new TypeError("Invalid initial usable fuel");
}
module.exports={fuelCovers,validateFuel};
